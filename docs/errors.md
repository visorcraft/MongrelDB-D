# Error Handling

Every non-2xx response is mapped to a typed exception. Catch
`MongrelDBException` for any failure, or one of the specific subclasses to
discriminate by category.

```d
import mongreldb;
import std.stdio;
```

## The exception hierarchy

All client exceptions descend from `MongrelDBException`, which itself descends
from Phobos's `Exception`:

```
Exception
└── MongrelDBException
    ├── AuthException
    ├── NotFoundException
    ├── ConflictException
    └── QueryException
```

| Class                  | HTTP status         | Meaning |
|------------------------|---------------------|---------|
| `MongrelDBException`   | -                   | Base class for every client failure. Catch this to handle any error. |
| `AuthException`        | 401, 403            | Bad or missing credentials. |
| `NotFoundException`    | 404                 | Missing table, schema, or resource. |
| `ConflictException`    | 409                 | Unique / foreign-key / check / trigger violation rolled back a transaction. |
| `QueryException`       | 400, 5xx, transport | Catch-all for malformed queries, server errors, and transport failures (status `-1`). |

Every `MongrelDBException` carries three fields beyond `msg`:

| Field      | Type            | Meaning |
|------------|-----------------|---------|
| `.status`  | `int`           | HTTP status code from the daemon, or `-1` when unknown (e.g. a transport failure). |
| `.code`    | `string`        | The server's structured error code, when present (e.g. `UNIQUE_VIOLATION`). |
| `.opIndex` | `Nullable!long` | The offending op index within a failed transaction, when reported. |

## Catching by type

Match the specific subclass first, then fall back to the base:

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

D evaluates `catch` clauses in order, so list subclasses before their base
classes.

## Transaction conflicts

A `Transaction.commit` runs all staged ops in a single atomic batch. If any
op violates a unique, foreign-key, check, or trigger constraint, the daemon
rolls back the entire batch and returns HTTP 409, which the client surfaces
as `ConflictException`:

```d
auto txn = db.begin();
txn.put("orders", [Cell.of(1, 10L), Cell.of(2, "Dave")], false);

try
{
    txn.commit();
}
catch (ConflictException e)
{
    writeln("batch rolled back: ", e.code, " op=", e.opIndex);
    // e.code might be "UNIQUE_VIOLATION"; e.opIndex is the offending op index.
}
```

The `.code` and `.opIndex` fields tell you exactly which op tripped which
constraint. Fix that op, then retry with a fresh transaction.

## Single-use transactions

`Transaction.commit` and `Transaction.rollback` both flip an internal flag.
Calling either method on the transaction afterward throws a plain `Exception`
with the message `"mongreldb: transaction already committed"`. This is a
programming error, not a server failure, so it is not a
`MongrelDBException`. Start a new transaction for each batch:

```d
auto txn = db.begin();
txn.commit();

// reuse is an error:
// txn.put("orders", [Cell.of(1, 99L)], false);
//     -> Exception: mongreldb: transaction already committed

auto next = db.begin();
next.commit();
```

## Retries and idempotency

Network glitches and daemon restarts happen. Pair an idempotency key with a
retry loop for commit:

```d
JSONValue[] commitWithRetry(Transaction txn, string key)
{
    foreach (_; 0 .. 3)
    {
        try
        {
            return txn.commit(key);
        }
        catch (ConflictException e)
        {
            // Constraint violation - fix the data, do not retry blindly.
            throw e;
        }
        catch (QueryException e)
        {
            if (e.status == -1 || (e.status >= 500 && e.status < 600))
            {
                import std.datetime : dur, msecs;
                import std.thread : Thread;
                Thread.sleep(dur!("msecs")(100));
                continue;
            }
            throw e;
        }
    }
    throw new Exception("commit failed after 3 attempts");
}
```

Only retry on transport failures (`status == -1`) or explicit 5xx with the
same idempotency key. `ConflictException` and `QueryException` with a 4xx
status indicate a problem with the request itself and must be fixed before
retrying.

## The health check never throws

`MongrelDBClient.health()` deliberately swallows errors and returns `false`.
Use it for liveness probes where an exception would be noise; use the real
methods when you want to know what went wrong:

```d
if (!db.health())
{
    writeln("daemon down - check the URL and auth");
}
```

## Common pitfalls

**Catching `Exception` too broadly.** A bare `catch (Exception e)` will also
catch the single-use-transaction error and any unrelated Phobos exception.
Catch `MongrelDBException` (or a subclass) when you mean to handle a client
error.

**Retrying `ConflictException`.** A conflict means the batch violated a
constraint; replaying the same ops will fail the same way. Fix the offending
op, then retry.

**Forgetting the single-use contract.** A transaction is single-use. If you
share one across function boundaries, make it obvious who calls `commit` or
`rollback`.

**Ignoring `.code` and `.opIndex`.** On a `ConflictException`, these pinpoint
the failure. Log them; they are the difference between a quick fix and a
guessing game.

## Next steps

- [transactions.md](transactions.md) - atomic batches and idempotency
- [auth.md](auth.md) - where `AuthException` comes from
