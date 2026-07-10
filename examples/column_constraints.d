// Example: column constraints - enum_variants and default_value.
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
// Creates a single `orders` table with three constraint-bearing columns:
//   - `status` (enum)    : the value is restricted to a closed set of strings
//   - `created_at` (varchar with default_value="uuid"): the engine fills
//                          in a fresh RFC 4122 UUID when an insert omits
//                          the column
//   - `note` (varchar)   : shown for completeness; no default configured
// Then inserts one row that supplies every column explicitly, and a second
// row that omits the two defaulted columns so the engine fills them in.
// Cleans up by dropping the table.

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
    auto table = "example_constraints_" ~ Clock.currStdTime().to!string;

    auto db = new MongrelDBClient(url);

    // Health check; bail out if the daemon is unreachable.
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

    // enum_variants is the closed set of allowed strings; the server treats
    // the column as an `enum` type when `ty == "enum"` and `enum_variants`
    // is non-empty. default_value is a server-side discriminator: the two
    // supported values are "now" (ISO-8601 UTC timestamp at insert time) and
    // "uuid" (a fresh RFC 4122 UUID at insert time). Anything else returns
    // a 400 from the daemon. Empty values are omitted from the wire so
    // existing callers see no change.
    long tid = db.createTable(table, [
        Column(1, "id",         "int64",   true,  false),
        Column(2, "status",     "enum",    false, false,
                cast(string[])["pending", "shipped", "cancelled"], ""),
        Column(3, "created_at", "varchar", false, false,
                cast(string[])[], "uuid"),
        Column(4, "note",       "varchar", false, false,
                cast(string[])[], ""),
    ]);
    writeln("Created table ", table, " (id ", tid, ")");

    // First row: every column supplied explicitly.
    db.put(table, [
        Cell.of(1, 1L),
        Cell.of(2, "shipped"),
        Cell.of(3, "11111111-1111-1111-1111-111111111111"),
        Cell.of(4, "priority"),
    ], null);
    writeln("Inserted row 1 (all cells supplied)");

    // Second row: omit `created_at` and `note`. The engine fills them in
    // using the column defaults - the `created_at` default is a fresh UUID
    // and `note` falls back to nothing (no default configured).
    db.put(table, [
        Cell.of(1, 2L),
        Cell.of(2, "pending"),
    ], null);
    writeln("Inserted row 2 (defaults applied by the engine)");

    // Read both rows back and inspect them.
    auto rows = db.query(table)
        .projection([1L, 2L, 3L, 4L])
        .execute();
    writeln("Table now holds ", rows.length, " rows:");
    foreach (row; rows)
    {
        writeln("  ", row);
    }

    return 0;
}