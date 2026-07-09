// Example: basic CRUD operations with the MongrelDB D client.
//
// Run (from a project with mongreldb as a DUB dependency):
//
//   dub run
//
// Or compile directly against the vendored source:
//
//   ldc2 -Isource examples/basic_crud.d
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows, "updates"
// one row by overwriting it at its primary key, deletes one row, then drops
// the table. Progress is printed at every step.

import mongreldb;
import mongreldb.client : Cell, Column;

import std.conv : to;
import std.datetime : Clock;
import std.json : JSONValue;
import std.stdio : writeln, stderr;

int main()
{
    enum url = "http://127.0.0.1:8453";
    // Unique table name per run so concurrent/repeated runs never collide.
    auto table = "example_crud_" ~ Clock.currStdTime().to!string;

    auto db = new MongrelDBClient(url);

    // Health check; bail out if the daemon is unreachable.
    if (!db.health())
    {
        stderr.writeln("daemon not reachable at ", url);
        return 1;
    }
    writeln("Connected to MongrelDB");

    // Always drop the table on exit, even if an earlier step threw. This is
    // registered before createTable so a failed create still cleans up safely.
    scope (exit)
    {
        db.dropTable(table);
        writeln("Dropped table ", table);
    }

    // Create the table. Schema: id (int64 PK), name (varchar), score (float64).
    long tid = db.createTable(table, [
        Column(1, "id", "int64", true, false),
        Column(2, "name", "varchar", false, false),
        Column(3, "score", "float64", false, false),
    ]);
    writeln("Created table ", table, " (id ", tid, ")");

    // Insert three rows. Cell.of pairs a column id with a value.
    db.put(table, [Cell.of(1, 1L), Cell.of(2, "Alice"), Cell.of(3, 95.5)], null);
    db.put(table, [Cell.of(1, 2L), Cell.of(2, "Bob"), Cell.of(3, 82.0)], null);
    db.put(table, [Cell.of(1, 3L), Cell.of(2, "Carol"), Cell.of(3, 78.3)], null);
    writeln("Inserted 3 rows");

    writeln("Total rows: ", db.count(table));

    // Query all rows (no conditions).
    auto all = db.query(table).execute();
    writeln("Query returned ", all.length, " rows:");
    foreach (row; all)
    {
        writeln("  ", row);
    }

    // Update Alice's score. `put` is insert-only and raises a uniqueness
    // conflict on an existing primary key, so `upsert` is used instead:
    // `cells` selects the row by its primary key and `updateCells` carries
    // the columns to overwrite on conflict.
    db.upsert(
        table,
        [Cell.of(1, 1L)],
        [Cell.of(2, "Alice"), Cell.of(3, 100.0)],
        null
    );
    writeln("Updated Alice's score to 100.0");
    writeln("Total rows after update: ", db.count(table));

    // Delete Carol (primary key 3).
    db.deleteByPk(table, JSONValue(3L));
    writeln("Deleted Carol; remaining rows: ", db.count(table));

    return 0;
}
