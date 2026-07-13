<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB D Client</h1>

<p align="center">
  <b>Pure D client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No C ABI bindings and no external DUB dependencies - built on the standard library <code>std.net.curl</code> and <code>std.json</code>. The API mirrors the MongrelDB PHP, Go, and Java clients.
</p>

<p align="center">
  <a href="https://dlang.org/"><img src="https://img.shields.io/badge/D-%3E%3D2.100-b03203.svg" alt="D" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-D/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-D/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| D client | `mongreldb` | `dub add mongreldb` |

History retention: `historyRetention` and `setHistoryRetentionEpochs`.

## Requirements

- **D 2.100 or newer** (built and tested with LDC 1.42 / DMD 2.112)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (insert), and `deleteByPk` (delete by primary key), with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` → `column_id`, `min`/`max` → `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, per-table descriptors, and constraint-bearing columns - `enum_variants` for closed-string columns, `default_value_json` for typed static defaults, and `default_expr` for dynamic server-side fills (`"now"` or `"uuid"`).
- **Typed exceptions**: `AuthException` (401/403), `NotFoundException` (404), `ConflictException` (409, with error code + op index), and `QueryException` (everything else), all subclasses of `MongrelDBException` carrying the HTTP status and decoded server envelope.
- **Pluggable auth**: Bearer token (`--auth-token` mode) and HTTP Basic (`--auth-users` mode); the token takes precedence.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.

## Examples

Runnable, end-to-end programs and deep dives for every feature live in
[`docs/`](docs/):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Batch transactions](docs/transactions.md) - atomic multi-op commits, idempotency, and retry.
- [Native query builder](docs/queries.md) - every condition type and the alias translation rules.
- [SQL](docs/sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`.
- [Authentication](docs/auth.md) - bearer token, basic auth, and user/role management via SQL.
- [Error handling](docs/errors.md) - the exception hierarchy and recovery patterns.

A runnable demo of `Column` constraints lives in
[`examples/column_constraints.d`](examples/column_constraints.d).

## Quick Example

```d
import mongreldb;
import std.stdio;

void main()
{
    // Connect to a running mongreldb-server daemon.
    auto db = new MongrelDBClient("http://127.0.0.1:8453");

    // Create a table. Column ids are stable on-wire identifiers.
    db.createTable("orders", [
        Column(1, "id",       "int64",   true,  false),
        Column(2, "customer", "varchar", false, false),
        Column(3, "amount",   "float64", false, false),
    ]);

    // Insert rows (cells pair column id -> value).
    db.put("orders", [Cell.of(1, 1L), Cell.of(2, "Alice"), Cell.of(3, 99.50)]);
    db.put("orders", [Cell.of(1, 2L), Cell.of(2, "Bob"),   Cell.of(3, 150.00)]);

    // Query with a native index condition (learned-range index).
    auto q = db.query("orders")
        .where("range", parseJSON(`{"column": 3, "min": 100.0}`))
        .projection([1L, 2L])
        .limit(100);
    auto rows = q.execute();
    writeln("rows: ", rows.length);

    writeln("count: ", db.count("orders")); // 2

    // Run SQL.
    db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'");
}
```

## Authentication

```d
// Bearer token (--auth-token mode)
auto db = new MongrelDBClient("http://127.0.0.1:8453",
        "my-secret-token", null, null);

// HTTP Basic (--auth-users mode)
auto db2 = new MongrelDBClient("http://127.0.0.1:8453",
        null, "admin", "s3cret");

// Custom per-request timeout (milliseconds, default 30000)
auto db3 = (new MongrelDBClient("http://127.0.0.1:8453")).setTimeout(60_000);
```

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```d
auto txn = db.begin();
txn.put("orders", [Cell.of(1, 10L), Cell.of(2, "Dave"), Cell.of(3, 50.00)], false);
txn.put("orders", [Cell.of(1, 11L), Cell.of(2, "Eve"),  Cell.of(3, 75.00)], false);
txn.deleteByPk("orders", JSONValue(2L));

try
{
    auto results = txn.commit(); // atomic - all or nothing
}
catch (ConflictException e)
{
    // A constraint violation rolls back every op.
    writeln("duplicate: ", e.msg, " code=", e.code, " op=", e.opIndex);
}

// Idempotent commit - safe to retry; the daemon returns the original response.
auto txn2 = db.begin();
txn2.put("orders", [Cell.of(1, 20L), Cell.of(2, "Frank"), Cell.of(3, 100.00)], false);
txn2.commit("order-20-create");
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(→ `column_id`), `min`/`max` (→ `lo`/`hi`). The canonical keys are also
accepted directly.

```d
// Bitmap equality (low-cardinality columns).
db.query("orders")
    .where("bitmap_eq", parseJSON(`{"column": 2, "value": "Alice"}`))
    .execute();

// Range query (learned-range index).
db.query("orders")
    .where("range", parseJSON(`{"column": 3, "min": 50.0, "max": 150.0}`))
    .limit(100)
    .execute();

// Full-text search (FM-index).
db.query("documents")
    .where("fm_contains", parseJSON(`{"column": 2, "value": "database performance"}`))
    .limit(10)
    .execute();

// Check whether a result was capped by the limit.
auto q = db.query("orders")
    .where("range", parseJSON(`{"column": 3, "min": 0}`))
    .limit(100);
auto rows = q.execute();
if (q.truncated)
{
    // result set hit the limit; more matches exist on the server
}
```

## Column constraints

A `Column` can carry optional server-side hints alongside its type and
flags: `enum_variants` (a closed set of allowed string values),
`default_value_json` (a parsed static JSON scalar), and `default_expr` (`"now"`
or `"uuid"`, taking precedence). The legacy string `default_value` remains
supported.

The legacy fields remain trailing constructor arguments. Set
`default_value_json` or `default_expr` by name. Empty fields are omitted.

```d
// ty="enum" + non-empty enum_variants creates a closed-set column.
auto created = Column(3, "created", "varchar", false, false);
created.default_expr = "uuid";  // dynamic UUID fill when omitted

db.createTable("orders", [
    Column(1, "id",      "int64",   true,  false),
    Column(2, "status",  "enum",    false, false,
            cast(string[])["pending", "shipped", "cancelled"], ""),
    created,
]);

// Insert with the enum supplied; omit `created` and the engine fills a UUID.
db.put("orders", [Cell.of(1, 1L), Cell.of(2, "pending")]);
```

The engine rejects an `enum` column with an empty `enum_variants` list (400)
and an unknown `default_expr` (400). Existing callers remain compatible.

For literal defaults of any JSON scalar type, use `default_value_json`:

```d
auto c = Column(4, "attempts", "int64");
c.default_value_json = `3`;     // numeric default
auto b = Column(5, "enabled",  "bool");
b.default_value_json = `true`;  // boolean default
auto n = Column(6, "label",    "varchar");
n.default_value_json = `null`;  // explicit null default
```

See [`examples/column_constraints.d`](examples/column_constraints.d) for a
complete runnable program.

`createTable` also accepts the daemon's native `constraints` JSON value:

```d
auto checks = parseJSON(
    `{"checks":[{"id":1,"name":"amount_nonneg","expr":{"Ge":[{"Col":3},{"Lit":{"Float64":0.0}}]}}]}`);
db.createTable("orders", columns, checks);
```

## SQL

```d
db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)");
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500");

// Recursive CTEs and window functions
db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r");
db.sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders");
```

> Note: the client requests the JSON result format for `/sql`, so a `SELECT`
> returns its rows decoded into a `JSONValue[]`. Statements that produce no
> rows (DDL/DML, or an empty result set) return an empty array.

## User & role management

When the daemon runs in `--auth-users` mode, users and roles live in the
catalog and are managed with SQL through `sql`.

```d
// Create an Argon2id-hashed user.
db.sql("CREATE USER alice WITH PASSWORD 'hunter2'");

// Promote to administrator.
db.sql("ALTER USER alice ADMIN");

// Roles and table-level grants.
db.sql("CREATE ROLE analyst");
db.sql("GRANT SELECT ON orders TO analyst");
db.sql("GRANT analyst TO alice");
db.sql("REVOKE SELECT ON orders FROM analyst");
db.sql("DROP ROLE analyst");
db.sql("DROP USER alice");
```

See [docs/auth.md](docs/auth.md) for the full auth mode reference and user/role
recipes.

## History retention

`mongreldb-server` retains the last 1024 committed epochs by default. The
window can be inspected and changed at runtime by an authenticated
administrator:

```d
auto settings = db.historyRetention();
writeln("retained epochs: ", settings.historyRetentionEpochs);
writeln("earliest epoch:  ", settings.earliestRetainedEpoch);

// Shrink or expand the window. Requires ADMIN permission when catalog
// authentication (`--auth-users`) is enabled.
db.setHistoryRetentionEpochs(100);
```

Increasing the retention window cannot restore epochs that were already
pruned. Use SQL `AS OF EPOCH` to read historical snapshots that are still
inside the window.

## Error handling

Every non-2xx response is mapped to a typed exception. Catch
`MongrelDBException` for any failure, or one of the specific subclasses.

```d
try
{
    db.schemaFor("missing_table");
}
catch (NotFoundException e)
{
    writeln("not found: ", e.msg, " (status ", e.status, ")");
}
catch (ConflictException e)
{
    writeln("constraint ", e.code, " at op ", e.opIndex);
}
catch (AuthException e)
{
    writeln("not authorized");
}
catch (QueryException e)
{
    writeln("query/server error: ", e.msg);
}
```

## API reference

### `MongrelDBClient`

| Method | Description |
|--------|-------------|
| `this(url = defaultBaseURL)` | Construct an unauthenticated client |
| `this(url, token, username, password)` | Construct with auth (token takes precedence) |
| `setTimeout(ms)` | Set per-request timeout (ms); returns `this` |
| `health()` | Check daemon health |
| `tableNames()` | List table names |
| `historyRetention()` | Current retention settings (`HistoryRetention`) |
| `historyRetentionEpochs()` | Configured retention window (epoch count) |
| `earliestRetainedEpoch()` | Oldest epoch still available for `AS OF EPOCH` |
| `setHistoryRetentionEpochs(epochs)` | Set the retention window; requires admin |
| `createTable(name, columns)` / `createTable(name, columns, constraints)` | Create a table; the third argument forwards the native constraints object |
| `dropTable(name)` | Drop a table |
| `count(table)` | Row count |
| `put(table, cells, idempotencyKey = null)` | Insert a row |
| `deleteByPk(table, pk)` | Delete by primary key |
| `query(table)` | Start a native query |
| `sql(sql)` | Execute SQL |
| `schema()` | Full schema catalog (`JSONValue[string]`) |
| `schemaFor(table)` | Single-table descriptor |
| `begin()` | Start a batch |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(type, params)` | Add a native condition (AND-ed) |
| `projection(columnIDs)` | Set column projection |
| `limit(n)` | Set row limit |
| `offset(n)` | Skip matching rows before the limit |
| `build()` | Build the request payload |
| `execute()` | Run the query |
| `truncated` | Whether the last `execute` result hit the limit |

### `Transaction`

| Method | Description |
|--------|-------------|
| `put(table, cells, returning)` | Stage an insert |
| `delete(table, rowId)` | Stage a delete by row id |
| `deleteByPk(table, pk)` | Stage a delete by primary key |
| `count` | Number of staged operations |
| `commit(idempotencyKey = null)` | Commit atomically |
| `rollback()` | Discard all operations |

### Errors

| Class | HTTP status | Meaning |
|-------|-------------|---------|
| `MongrelDBException` | - | Base class for every client failure |
| `AuthException` | 401, 403 | Bad or missing credentials |
| `NotFoundException` | 404 | Missing table, schema, or resource |
| `ConflictException` | 409 | Unique/FK/check/trigger violation |
| `QueryException` | 400, 5xx, transport | Catch-all for malformed queries and server errors |

All carry `.status` (int), `.code` (string, e.g. `UNIQUE_VIOLATION`), and
`.opIndex` (`Nullable!long`, the offending op in a failed transaction).

## Building and testing

The live test suite is a standalone executable that boots a real
`mongreldb-server` daemon and exercises the full client surface. It resolves
the binary in this order: the `MONGRELDB_SERVER` env var, `./bin/mongreldb-server`,
then `mongreldb-server` on `PATH`. If none is available and `MONGRELDB_URL` is
unset, it self-skips. Set `MONGRELDB_URL` to point at an already-running daemon.

```sh
# Build the library
dub build --config=library

# Run the offline unit tests (no daemon needed)
dub test --config=unittest

# Build and run the live suite
dub build --config=live-test
./build/mongreldb   # or: MONGRELDB_URL=http://127.0.0.1:8453 ./build/mongreldb
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.52.3/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client dependency-free (Phobos only) and free of engine C ABI bindings.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
