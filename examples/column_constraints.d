// Example: column constraints - CHECK expressions and nullable columns.
//
// Run (from a project with mongreldb as a DUB dependency):
//
//   dub run
//
// Or compile directly against the vendored source:
//
//   ldc2 -Isource examples/column_constraints.d
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a single `orders` table with a CHECK constraint on `id` and a
// nullable `note` column. Keeps types to core scalars so the example stays
// portable across engine minor releases (uuid/timestamp defaults have moved
// between 0.55–0.59 wire shapes).

import mongreldb;
import mongreldb.client : Cell, Column;

import std.conv : to;
import std.datetime : Clock;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln, stderr;

int main()
{
    enum url = "http://127.0.0.1:8453";
    auto table = "example_constraints_" ~ Clock.currStdTime().to!string;

    auto db = new MongrelDBClient(url);

    if (!db.health())
    {
        stderr.writeln("daemon not reachable at ", url);
        return 1;
    }
    writeln("Connected to MongrelDB");

    scope (exit)
    {
        db.dropTable(table);
        writeln("Dropped table ", table);
    }

    auto constraints = parseJSON(
        `{"checks":[{"id":1,"name":"positive_id","expr":{"Gt":[{"Col":1},{"Lit":{"Int64":0}}]}}]}`);
    long tid = db.createTable(table, [
        Column(1, "id",     "int64",   true,  false),
        Column(2, "status", "varchar", false, false),
        Column(3, "note",   "varchar", false, true),
    ], constraints);
    writeln("Created table ", table, " (id ", tid, ")");

    db.put(table, [
        Cell.of(1, 1L),
        Cell.of(2, "shipped"),
        Cell.of(3, "priority"),
    ], null);
    writeln("Inserted row 1 (all cells supplied)");

    db.put(table, [
        Cell.of(1, 2L),
        Cell.of(2, "pending"),
    ], null);
    writeln("Inserted row 2 (nullable note omitted)");

    auto rows = db.query(table)
        .projection([1L, 2L, 3L])
        .execute();
    writeln("Table now holds ", rows.length, " rows:");
    foreach (row; rows)
    {
        writeln("  ", row);
    }

    return 0;
}
