# MongrelDB D Documentation

End-to-end guides for the pure-D MongrelDB client. Each guide is self-contained
and uses idiomatic D (Phobos only, no external DUB dependencies).

| Guide | What you'll learn |
|-------|-------------------|
| [Quickstart](quickstart.md) | Install D and the daemon, write and run a complete program. Includes `enum_variants` and `default_value` on `Column`. |
| [Batch transactions](transactions.md) | Atomic multi-op commits, idempotency keys, and safe retries. |
| [Native query builder](queries.md) | Every native index condition and the alias translation rules. |
| [SQL](sql.md) | Recursive CTEs, window functions, `CREATE TABLE AS SELECT`. |
| [Authentication](auth.md) | Bearer token, HTTP Basic, and user/role management via SQL. |
| [Error handling](errors.md) | The exception hierarchy and recovery patterns. |

Runnable programs under [`../examples/`](../examples/) complement the
guides - start with
[`column_constraints.d`](../examples/column_constraints.d) for the
`Column` constraint surface, then `basic_crud.d`, `query_builder.d`, and
`transactions.d` for the rest.

The D client talks HTTP/JSON to a running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
daemon. If you have not already, start with the [Quickstart](quickstart.md).
