# Batch Transactions

A `Transaction` stages operations locally and commits them atomically in a
single `/kit/txn` request. The daemon enforces unique, foreign-key, check, and
trigger constraints at commit time; on any violation every staged op rolls
back and `commit` throws a `ConflictException` carrying the server's
structured error code and the offending op index.

This guide covers building a batch, committing atomically, idempotency keys,
and safe retries.

```d
import mongreldb;
import std.json;
import std.stdio;
```

---

## Start a transaction

`MongrelDBClient.begin()` returns a fresh, single-use `Transaction`:

```d
auto db = new MongrelDBClient("http://127.0.0.1:8453");
auto txn = db.begin();
```

## Stage operations

Each builder method returns `this` so calls chain. Nothing is sent until
`commit`:

```d
// Insert (returning=false means the result does not echo the row).
txn.put("orders",
    [Cell.of(1, 10L), Cell.of(2, "Dave"), Cell.of(3, 50.00)],
    false);
txn.put("orders",
    [Cell.of(1, 11L), Cell.of(2, "Eve"), Cell.of(3, 75.00)],
    false);

// Delete by primary-key value.
txn.deleteByPk("orders", JSONValue(2L));

// Delete by the internal row id (the engine's storage row number, not the
// primary key).
txn.delete("orders", 7);
```

`put(table, cells, returning)` stages an insert. Set `returning = true` to ask
the daemon to echo the written row back in the per-operation result — useful
when you want server-generated values without a second round trip.

`count` reports how many ops are staged:

```d
writeln("staged: ", txn.count); // 3
```

## Commit atomically

`commit()` sends every staged op in one request. Either all apply or none do:

```d
try
{
    JSONValue[] results = txn.commit();
    writeln("committed ", results.length, " results");
}
catch (ConflictException e)
{
    // A constraint violation rolled back the whole batch.
    writeln("conflict: ", e.msg, " code=", e.code, " op=", e.opIndex);
}
```

The server's results array has one entry per staged op, in order. Each entry
is an object; its shape depends on the op and the `returning` flag.

## Idempotency keys

`commit(idempotencyKey)` makes the commit safe to retry. Pass a stable,
unique key — the daemon stores it and returns the original response on
duplicate commits, even across daemon restarts:

```d
auto txn = db.begin();
txn.put("orders",
    [Cell.of(1, 20L), Cell.of(2, "Frank"), Cell.of(3, 100.00)],
    false);

// If this call times out or the network drops, replaying the same ops under
// the same key is safe — the daemon deduplicates.
txn.commit("order-20-create");
```

A good idempotency key is:

- **Unique per logical operation.** Reusing a key for a different batch makes
  the second one a no-op (the server replays the first result).
- **Stable across retries.** Generate it once and hold it for the lifetime of
  the attempt.
- **Opaque.** The server stores it as a string; any encoding works (UUID,
  composite key, hash).

## Single-use transactions

A `Transaction` is single-use. After `commit` or `rollback`, any further call
throws `Exception("mongreldb: transaction already committed")`. Start a new
`db.begin()` for each logical unit of work:

```d
auto txn = db.begin();
txn.commit();

// reuse is an error:
// txn.put("orders", [Cell.of(1, 99L)], false);
//     -> Exception: mongreldb: transaction already committed

auto next = db.begin();
next.commit();
```

## Rollback

`rollback()` discards all staged operations without contacting the daemon.
Like `commit`, it finalizes the transaction:

```d
auto txn = db.begin();
txn.put("orders", [Cell.of(1, 1L)], false);

if (someCondition)
{
    txn.rollback(); // nothing sent to the server
    return;
}
txn.commit();
```

## Single-op convenience

For one row, `MongrelDBClient.put(table, cells, idempotencyKey)` is a one-op
transaction under the hood. It exists for ergonomics; batch real multi-op
work in a `Transaction` to get atomicity and a single round trip:

```d
// Equivalent to a Transaction with one put, committed immediately.
db.put("orders", [Cell.of(1, 1L), Cell.of(2, "Alice")], "order-1-create");
```

## Retry pattern

Combine an idempotency key with a retry loop to ride out transient failures.
Only retry on transport failures (`QueryException` with `status == -1`) or
explicit 5xx; treat `ConflictException` as a data problem to fix, not a
transient one:

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
            // Constraint violation — do NOT retry blindly. Fix the data.
            throw e;
        }
        catch (QueryException e)
        {
            if (e.status == -1 || (e.status >= 500 && e.status < 600))
            {
                // transport or server error — safe to retry with the same key
                Thread.sleep(dur!("msecs")(100));
                continue;
            }
            throw e;
        }
    }
    throw new Exception("commit failed after 3 attempts");
}
```

Because each attempt uses the same idempotency key, a retry that lands after
the daemon already applied the batch returns the original result instead of
applying the ops twice.

## Common pitfalls

**Forgetting the idempotency key on retries.** Without it, a retry after a
network timeout can double-apply the batch. Always pair retries with a stable
key.

**Committing the same `Transaction` from two fibers.** The transaction object
is not synchronized. Stage and commit from one flow of control.

**Expecting per-op atomicity.** The atomicity unit is the whole batch. A
single bad op rolls back the good ones too — that is the point. Validate data
before staging if you want to avoid the round trip.

**Swallowing `ConflictException`.** The `.code` and `.opIndex` fields tell you
exactly what went wrong and where. Log them; they are the difference between
a quick fix and a guessing game.

## Next steps

- [queries.md](queries.md) — read patterns
- [errors.md](errors.md) — the full exception hierarchy
- [sql.md](sql.md) — when to choose SQL over the typed API
