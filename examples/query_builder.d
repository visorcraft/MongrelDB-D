// Example: query builder conditions with the MongrelDB D client.
//
// Run (from a project with mongreldb as a DUB dependency):
//
//   dub run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.

import mongreldb;
import mongreldb.client : Cell, Column;

import std.conv : to;
import std.datetime : Clock;
import std.json : parseJSON;
import std.stdio : writeln, stderr;

int main()
{
    enum url = "http://127.0.0.1:8453";
    // Unique table name per run so concurrent/repeated runs never collide.
    auto table = "example_query_" ~ Clock.currStdTime().to!string;

    auto db = new MongrelDBClient(url);
    if (!db.health())
    {
        stderr.writeln("daemon not reachable at ", url);
        return 1;
    }
    writeln("Connected to MongrelDB");

    // Always drop the table on exit, even if an earlier step threw.
    scope (exit)
    {
        db.dropTable(table);
        writeln("Dropped table ", table);
    }

    db.createTable(table, [
        Column(1, "id", "int64", true, false),
        Column(2, "name", "varchar", false, false),
        Column(3, "score", "float64", false, false),
    ]);
    writeln("Created table ", table);

    // Five rows with varying scores.
    db.put(table, [Cell.of(1, 1L), Cell.of(2, "Alice"), Cell.of(3, 40.0)], null);
    db.put(table, [Cell.of(1, 2L), Cell.of(2, "Bob"), Cell.of(3, 65.0)], null);
    db.put(table, [Cell.of(1, 3L), Cell.of(2, "Carol"), Cell.of(3, 82.0)], null);
    db.put(table, [Cell.of(1, 4L), Cell.of(2, "Dave"), Cell.of(3, 91.0)], null);
    db.put(table, [Cell.of(1, 5L), Cell.of(2, "Eve"), Cell.of(3, 12.5)], null);
    writeln("Inserted 5 rows");

    // Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
    // server's column_id; pass the numeric column id (3), not the name. The
    // "score" column is float64, so use the range_f64 condition (plain "range"
    // expects an i64 bound and rejects floats); range_f64 also requires
    // lo_inclusive/hi_inclusive (supplied via min_inclusive/max_inclusive).
    auto rng = db.query(table)
        .where("range_f64", parseJSON(`{"column": 3, "min": 60.0, "max": 90.0, "min_inclusive": true, "max_inclusive": true}`))
        .execute();
    writeln("Range query (score in [60,90]) returned ", rng.length, " rows:");
    foreach (row; rng)
    {
        writeln("  ", row);
    }

    // Primary-key condition: fetch the single row with id == 4.
    auto pk = db.query(table)
        .where("pk", parseJSON(`{"value": 4}`))
        .execute();
    writeln("PK query (id == 4) returned ", pk.length, " rows:");
    foreach (row; pk)
    {
        writeln("  ", row);
    }

    return 0;
}
