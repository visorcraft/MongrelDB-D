# SQL

MongrelDB ships a `/sql` endpoint backed by DataFusion. `MongrelDBClient.sql`
runs a single statement (or script). The client requests the JSON result
format and returns the decoded rows for statements that produce a result set.
Use SQL for everything the typed API does not cover: joins, aggregates,
recursive CTEs, window functions, and DDL like `CREATE TABLE AS SELECT`.

```d
import mongreldb;
import std.json;
import std.stdio;
```

---

## Run a statement

`sql(sqlText)` POSTs `{"sql": "...", "format": "json"}` to `/sql` and returns a
`JSONValue[]`:

```d
JSONValue[] rows = db.sql("SELECT * FROM orders");
foreach (row; rows)
{
    writeln(row);
}
```

For statements that produce no row set - DDL or DML - `sql` returns an empty
array and does not throw. Success is the absence of an exception:

```d
db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)");
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500");
```

> Note: the client requests the JSON result format for `/sql`, so a `SELECT`
> returns its rows decoded into a `JSONValue[]`. Statements that produce no
> rows return an empty array.

## Joins and aggregates

```d
db.sql(`
    SELECT o.customer, SUM(o.amount) AS total
    FROM orders o
    GROUP BY o.customer
    ORDER BY total DESC
`);
```

The full DataFusion SQL dialect is available, including joins, subqueries,
`UNION`/`INTERSECT`/`EXCEPT`, and the standard aggregate functions.

## Recursive CTEs

```d
db.sql(`
    WITH RECURSIVE r(n) AS (
        SELECT 1
        UNION ALL
        SELECT n + 1 FROM r WHERE n < 10
    )
    SELECT n FROM r
`);
```

Recursive CTEs power hierarchies (org charts, threaded discussions, graph
traversal) without a separate query language.

## Window functions

```d
db.sql(`
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn
    FROM orders
`);
```

Use `ROW_NUMBER`, `RANK`, `LAG`, `LEAD`, `SUM(...) OVER (...)`, and friends
for per-group ranking, running totals, and time-shifted comparisons.

## CREATE TABLE AS SELECT

Materialize a query result into a new table:

```d
db.sql("CREATE TABLE big_orders AS SELECT * FROM orders WHERE amount > 1000");
```

Combined with the daemon's typed schema, CTAS is the fastest way to build
denormalized or pre-filtered tables for analysis.

## DDL and catalog

Beyond the typed `createTable` / `dropTable` helpers, SQL covers the rest of
the catalog surface - materialized views, indexes, and user/role management
(see [auth.md](auth.md) for the auth-specific statements):

```d
db.sql("DROP TABLE IF EXISTS archive");
db.sql("CREATE INDEX idx_orders_customer ON orders (customer)");
```

## When to use SQL vs the typed API

| Task | Prefer |
|------|--------|
| Insert / delete a single row by key | Typed `put` / `deleteByPk` |
| Filter by a native index (range, bitmap, FTS, vector) | `QueryBuilder` (see [queries.md](queries.md)) |
| Atomic multi-op batch | `Transaction` (see [transactions.md](transactions.md)) |
| Join, aggregate, window, recursive CTE | SQL |
| `CREATE TABLE AS SELECT`, materialized views | SQL |
| User/role management | SQL |

SQL is strictly more expressive, but the typed API is faster for the
patterns it covers because it skips the SQL planner and pushes straight to the
native indexes.

## Common pitfalls

**Treating an empty array as failure.** DDL and DML statements return `[]`
because they produce no result set; a `SELECT` returns its rows decoded into a
`JSONValue[]`. Errors surface as `QueryException`; check for that, not for
emptiness.

**String-interpolating values into SQL.** Build statements with parameters or
carefully escape literals. Interpolation invites injection and quoting bugs.

**Holding a long-running statement open.** SQL statements are synchronous on
the client. For large analytical queries, raise the client timeout
(`setTimeout(ms)`) or run them on a background fiber.

## Next steps

- [queries.md](queries.md) - the native index query builder
- [transactions.md](transactions.md) - atomic writes
- [auth.md](auth.md) - `CREATE USER`, roles, and grants
