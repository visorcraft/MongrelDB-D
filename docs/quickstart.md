# Quickstart

Zero to a running MongrelDB D program in fifteen minutes. This guide assumes a
fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: a D toolchain and a `mongreldb-server` daemon.

### Install D 2.100 or newer

Any recent D compiler works (LDC or DMD). Verify it:

```sh
dmd --version
# or
ldc2 --version
```

If you do not have it, install from <https://dlang.org/download.html> or your
package manager (e.g. `pacman -S dlang`, `brew install ldc`). The D package
manager `dub` ships with the compiler.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

The client is published as the `mongreldb` DUB package. Add it as a path
dependency (it is pure Phobos, so there is nothing else to fetch):

```sh
mkdir demo && cd demo
dub init
dub add mongreldb
```

This adds the dependency to `dub.json`. If you are vendoring the source
locally instead, point a `path` dependency at the checkout:

```json
{
    "dependencies": {
        "mongreldb": {"path": "../mongreldb_d"}
    }
}
```

## 4. Write your first program

Create `source/app.d`:

```d
import mongreldb;
import std.stdio;
import std.json;

void main()
{
    // 1. Connect to the daemon. Empty URL falls back to http://127.0.0.1:8453.
    auto db = new MongrelDBClient("http://127.0.0.1:8453");

    // 2. Health check before doing anything else.
    if (!db.health())
    {
        writeln("daemon not reachable");
        return;
    }

    // 3. Create a table. Each Column has a stable numeric id, a name, a type,
    //    and flags. The first column is the primary key. Two optional
    //    trailing fields are constraint hints:
    //      - enum_variants : a closed set of allowed string values for a
    //                        column declared with ty="enum".
    //      - default_value : a server-side fill ("now" or "uuid") applied
    //                        when an insert omits the column.
    long tid = db.createTable("orders", [
        Column(1, "id",       "int64",   true,  false),
        Column(2, "customer", "varchar", false, false),
        Column(3, "amount",   "float64", false, false),
        Column(4, "status",   "enum",    false, false,
                cast(string[])["pending", "shipped", "cancelled"], ""),
        Column(5, "note",     "varchar", false, false,
                cast(string[])[], ""),
    ]);
    writeln("created table id: ", tid);

    // 4. Insert rows. Cell.of pairs a column id with a value. put() is a
    //    one-op transaction; the optional third argument is an idempotency key.
    //    The `status` cell is required (enum, no default); the `note` cell
    //    is optional and the server leaves it unset when omitted.
    db.put("orders", [Cell.of(1, 1L), Cell.of(2, "Alice"), Cell.of(3, 99.50),
                      Cell.of(4, "shipped"), Cell.of(5, "priority")]);
    db.put("orders", [Cell.of(1, 2L), Cell.of(2, "Bob"),   Cell.of(3, 150.00),
                      Cell.of(4, "pending")]);

    // 5. Query with a native index condition. The range index serves this in
    //    sub-millisecond. projection() selects only column ids 1 and 2.
    auto q = db.query("orders")
        .where("range", parseJSON(`{"column": 3, "min": 100.0}`))
        .projection([1L, 2L])
        .limit(100);
    auto rows = q.execute();
    foreach (row; rows)
    {
        writeln("row: ", row);
    }

    // 6. Count the rows.
    writeln("total rows: ", db.count("orders"));
}
```

Run it:

```sh
dub run
```

You should see:

```
created table id: 1
row: {"1":2,"2":"Bob"}
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `new MongrelDBClient(url)` | Builds an HTTP client targeting one daemon. Safe to share across fibers/threads. |
| `db.health()` | GET `/health`; returns `true` when the daemon answers. Always check before real work. |
| `db.createTable(name, cols)` / `db.createTable(name, cols, constraints)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. Trailing `enum_variants` and `default_value` fields encode closed-string and server-side default hints; the third argument forwards native table constraints. |
| `db.put(table, cells)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(table).where(...)` | Builds a `/kit/query` body. `where` pushes a condition down to a native index. |
| `.projection([1L, 2L])` | Server returns only those column ids, saving bandwidth. |
| `.limit(100)` | Caps the result; check `q.truncated` afterward to detect overflow. |
| `.execute()` | Sends the query and decodes the `rows` array. |
| `db.count(table)` | GET `/tables/{name}/count`. |

## 6. Column constraints

`Column` carries two optional server-side hints alongside its name, type, and
flags. Both default to "absent" - existing callers that never set them keep
producing byte-identical wire payloads.

### `enum_variants` - closed-string columns

When `ty` is `"enum"` and `enum_variants` is a non-empty list, the engine
treats the column as a closed set of allowed string values. Anything outside
the list is rejected at insert / commit time:

```d
Column(4, "status", "enum", false, false,
        cast(string[])["pending", "shipped", "cancelled"], "")
```

The server returns HTTP 400 `"enum column requires non-empty enum_variants"`
if you declare `ty = "enum"` with an empty list. An empty `enum_variants` on
a non-`enum` column is silently dropped from the wire and treated as
"any string".

### `default_value` - server-side fills

The trailing `default_value` is a server-side discriminator applied at insert
stage time when an insert omits the column or supplies it as `Null`:

| Value     | Effect |
|-----------|--------|
| `"now"`   | Fill with the current ISO-8601 UTC timestamp at insert time. |
| `"uuid"`  | Fill with a fresh RFC 4122 UUID at insert time. |
| `""`      | Absent from the wire - no default is configured. |
| anything else | HTTP 400 `unknown default_expr "<value>"` from the daemon. |

```d
// The engine fills a UUID whenever an insert omits `note`.
Column(5, "note", "varchar", false, false,
        cast(string[])[], "uuid")
```

This is not a literal-value default; it is a pointer to a server-side
generator. If you need a literal default, send the value in every insert.

### Putting it together

A constraint-bearing table with both fields, including a row that exercises
the defaults, lives in
[`../examples/column_constraints.d`](../examples/column_constraints.d).

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `createTable`, never the `name`. The query builder's
`column` alias maps to the server's `column_id` - pass the integer id, not the
string name:

```d
// Wrong:
.where("range", parseJSON(`{"column": "amount", "min": 100.0}`))
// Right:
.where("range", parseJSON(`{"column": 3, "min": 100.0}`))
```

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `ConflictException`
(HTTP 409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call throws
`Exception("mongreldb: transaction already committed")`. Create a fresh
`db.begin()` for each logical unit of work.

**Reusing a `QueryBuilder` and expecting a fresh `truncated`.** `truncated`
reflects the most recent `execute()`. Build a new query, or re-run
`execute()` before reading it.

**Expecting `sql` to always return rows.** `sql` requests `format: "json"`,
so a `SELECT` returns its rows decoded into a `JSONValue[]`. Statements that
produce no rows (DDL/DML, or an empty result set) return an empty array (not
an error).

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call raises `AuthException` unless you
pass `token` or `username`/`password` to the constructor. See [auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full exception hierarchy and recovery patterns
- [../examples/column_constraints.d](../examples/column_constraints.d) - runnable `Column` constraints demo
