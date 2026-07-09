// Example: atomic batch transactions with the MongrelDB D client.
//
// Run (from a project with mongreldb as a DUB dependency):
//
//   dub run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

import mongreldb;
import mongreldb.client : Cell, Column;

import std.stdio : writeln, stderr;

void main()
{
    enum url = "http://127.0.0.1:8453";
    enum table = "example_txn";

    auto db = new MongrelDBClient(url);
    if (!db.health())
    {
        stderr.writeln("daemon not reachable at ", url);
        return;
    }
    writeln("Connected to MongrelDB");

    db.createTable(table, [
        Column(1, "id", "int64", true, false),
        Column(2, "name", "varchar", false, false),
        Column(3, "score", "float64", false, false),
    ]);
    writeln("Created table ", table);

    // Stage three puts and commit them atomically. Either every op lands or
    // none do; a constraint violation rolls back the whole batch.
    auto txn = db.begin();
    txn.put(table, [Cell.of(1, 1L), Cell.of(2, "Alice"), Cell.of(3, 95.5)], false);
    txn.put(table, [Cell.of(1, 2L), Cell.of(2, "Bob"), Cell.of(3, 82.0)], false);
    txn.put(table, [Cell.of(1, 3L), Cell.of(2, "Carol"), Cell.of(3, 78.3)], false);
    writeln("Staged ", txn.count, " operations");

    auto results = txn.commit(null);
    writeln("Committed atomically: ", results.length, " operations applied");

    writeln("Verified row count after commit: ", db.count(table));

    // Idempotent retry: stage the same batch again with an idempotency key,
    // then commit a second time with the SAME key. The daemon replays the
    // original result and applies no extra rows.
    auto retry = db.begin();
    retry.put(table, [Cell.of(1, 4L), Cell.of(2, "Dave"), Cell.of(3, 60.0)], false);
    retry.commit("example-txn-key");
    writeln("After first idempotent commit: ", db.count(table), " rows");

    auto retry2 = db.begin();
    retry2.put(table, [Cell.of(1, 4L), Cell.of(2, "Dave"), Cell.of(3, 60.0)], false);
    retry2.commit("example-txn-key");
    writeln("After duplicate idempotent commit (same key): ", db.count(table), " rows (no double-apply)");

    db.dropTable(table);
    writeln("Dropped table ", table);
}
