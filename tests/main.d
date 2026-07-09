// Live integration tests for the mongreldb D client.
//
// Boots a real mongreldb-server daemon and exercises the client end to end.
// The daemon binary is resolved in this order:
//   1. MONGRELDB_SERVER env var (path to the server binary).
//   2. ./bin/mongreldb-server relative to the current working directory.
//   3. mongreldb-server on PATH.
//
// If no binary is available and MONGRELDB_URL is unset, every test self-skips.
// Set MONGRELDB_URL to point at an already-running daemon to skip the boot.

module main;

import mongreldb;

import std.conv : to, ConvException;
import std.digest.md : md5Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.file : exists, remove, mkdirRecurse;
import std.json : JSONValue, JSONType;
import std.process : environment, execute, spawnProcess, Config, Pid;
import std.random : uniform;
import std.socket : InternetAddress, Socket, SocketType, ProtocolType,
        AddressFamily;
import std.stdio : writeln, stderr;
import std.string : format;
import std.datetime : Clock, dur;
import std.datetime.stopwatch : StopWatch;
import core.thread : Thread;

// A minimal test framework: assertCollect collects failures; the runner exits
// non-zero if any assertion failed.
private int g_passed;
private int g_failed;

private void check(bool cond, lazy string msg, string file = __FILE__, size_t line = __LINE__)
{
    if (cond)
    {
        g_passed++;
    }
    else
    {
        g_failed++;
        stderr.writeln("FAIL: ", msg, "  (", file, ":", line, ")");
    }
}

private string uniqueTable(string prefix)
{
    auto now = Clock.currStdTime();
    auto tag = md5Of(cast(ubyte[]) (now.to!string ~ prefix));
    return prefix ~ "_" ~ toHexString(tag).idup;
}

private long freePort()
{
    auto s = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    s.bind(new InternetAddress("127.0.0.1", 0));
    auto port = (cast(InternetAddress) s.localAddress).port;
    s.close();
    return port;
}

private bool waitForHealth(MongrelDBClient db, long maxMs)
{
    import std.datetime.stopwatch : AutoStart;
    auto sw = StopWatch(AutoStart.yes);
    while (sw.peek.total!"msecs" < maxMs)
    {
        if (db.health())
            return true;
        Thread.sleep(dur!"msecs"(500));
    }
    return false;
}

// cellValue looks up a column value in the flat `cells` array of a Kit row
// (shape: [col_id, value, ...]), returning JSONValue(null) if absent.
private JSONValue cellValue(JSONValue row, long colId)
{
    if (row.type != JSONType.object || ("cells" !in row.object) ||
            row.object["cells"].type != JSONType.array)
    {
        return JSONValue([JSONValue()]); // JSON null
    }
    auto cells = row.object["cells"].array;
    for (size_t i = 0; i + 1 < cells.length; i += 2)
    {
        if (jsonToLong(cells[i]) == colId)
        {
            return cells[i + 1];
        }
    }
    return JSONValue([JSONValue()]); // JSON null
}

// cellInt64 extracts an int64 value for colId from a Kit row.
private long cellInt64(JSONValue row, long colId)
{
    return jsonToLong(cellValue(row, colId));
}

// cellFloat64 extracts a float64 value for colId from a Kit row.
private double cellFloat64(JSONValue row, long colId)
{
    JSONValue v = cellValue(row, colId);
    final switch (v.type)
    {
    case JSONType.float_:
        return v.floating;
    case JSONType.integer:
        return cast(double) v.integer;
    case JSONType.uinteger:
        return cast(double) v.uinteger;
    case JSONType.string:
        try
        {
            return to!double(v.str);
        }
        catch (ConvException)
        {
            return 0.0;
        }
    case JSONType.null_, JSONType.true_, JSONType.false_,
            JSONType.object, JSONType.array:
        return 0.0;
    }
}

// jsonToLong coerces a JSON number/integer/string to a long, returning 0 on
// failure.
private long jsonToLong(JSONValue v)
{
    final switch (v.type)
    {
    case JSONType.integer:
        return v.integer;
    case JSONType.uinteger:
        return cast(long) v.uinteger;
    case JSONType.float_:
        return cast(long) v.floating;
    case JSONType.string:
        try
        {
            return to!long(v.str);
        }
        catch (ConvException)
        {
            return 0L;
        }
    case JSONType.null_:
        return 0L;
    case JSONType.true_:
        return 1L;
    case JSONType.false_:
        return 0L;
    case JSONType.object:
        return 0L;
    case JSONType.array:
        return 0L;
    }
}

int main()
{
    string url = environment.get("MONGRELDB_URL", "");
    MongrelDBClient db;
    if (url.length > 0)
    {
        db = new MongrelDBClient(url);
        if (!db.health())
        {
            stderr.writeln("mongreldb: MONGRELDB_URL=", url, " is not reachable");
            return 1;
        }
    }
    else
    {
        auto bin = resolveServerBinary();
        if (bin.length == 0)
        {
            writeln("No mongreldb-server binary found; skipping live tests.");
            return 0;
        }
        auto port = freePort();
        string dataDir = "/tmp/mongreldb-d-test-" ~ port.to!string;
        if (exists(dataDir))
            remove(dataDir);
        mkdirRecurse(dataDir);

        auto args = [bin, dataDir, "--port", port.to!string];
        // Redirect the daemon's stdout/stderr to a log file so the parent's
        // pipes are not held open (which would block the test runner). Spawn
        // detached so the daemon outlives the test process; the OS reaps the
        // throwaway data dir.
        import std.stdio : File, stdin;
        auto log = File(dataDir ~ ".log", "w");
        auto child = spawnProcess(args, stdin, log, log, null,
                Config.detached);
        db = new MongrelDBClient("http://127.0.0.1:" ~ port.to!string);
        if (!waitForHealth(db, 30_000))
        {
            stderr.writeln("mongreldb: server did not become healthy");
            log.close();
            return 1;
        }
        log.close();
    }

    runTests(db);

    writeln("passed=", g_passed, " failed=", g_failed);
    return (g_failed == 0) ? 0 : 1;
}

private string resolveServerBinary()
{
    auto env = environment.get("MONGRELDB_SERVER", "");
    if (env.length > 0 && exists(env))
        return env;
    if (exists("bin/mongreldb-server"))
        return "bin/mongreldb-server";
    // Last resort: try to locate it on PATH.
    auto r = execute(["sh", "-c", "command -v mongreldb-server"]);
    if (r.status == 0 && r.output.length > 0)
    {
        import std.string : chomp;
        return chomp(r.output);
    }
    return "";
}

private void runTests(MongrelDBClient db)
{
    import mongreldb.client : Cell, Column;

    // health
    check(db.health(), "health");

    // createTable + count
    {
        auto name = uniqueTable("d_tbl");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "float64", false, false),
        ]);
        check(db.count(name) == 0, "count empty == 0");
    }

    // put + count round trip
    {
        auto name = uniqueTable("d_put");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "float64", false, false),
        ]);
        db.put(name, [Cell.of(1, 1L), Cell.of(2, 99.5)], null);
        db.put(name, [Cell.of(1, 2L), Cell.of(2, 150.0)], null);
        check(db.count(name) == 2, "count == 2 after two puts");
    }

    // upsert inserts then updates on PK conflict
    {
        auto name = uniqueTable("d_upsert");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "float64", false, false),
        ]);
        // First upsert inserts.
        db.upsert(name, [Cell.of(1, 1L), Cell.of(2, 99.5)], [Cell.of(2, 99.5)]);
        check(db.count(name) == 1, "upsert inserts (count == 1)");
        // Second upsert on the same PK updates (still one row).
        db.upsert(name, [Cell.of(1, 1L), Cell.of(2, 120.0)], [Cell.of(2, 120.0)]);
        check(db.count(name) == 1, "upsert updates (count still 1)");

        // The updated value is returned by a query; verify the cell changed.
        import std.json : parseJSON;
        auto params = parseJSON(`{"value": 1}`);
        auto rows = db.query(name).where("pk", params).execute();
        check(rows.length == 1, "upsert: pk query returns 1 row");
        check(cellInt64(rows[0], 1) == 1, "upsert: returned pk == 1");
        check(cellFloat64(rows[0], 2) == 120.0, "upsert: updated amount == 120.0");
    }

    // query by pk
    {
        auto name = uniqueTable("d_pk");
        db.createTable(name, [Column(1, "id", "int64", true, false)]);
        db.put(name, [Cell.of(1, 42L)], null);
        db.put(name, [Cell.of(1, 43L)], null);

        import std.json : parseJSON;
        auto params = parseJSON(`{"value": 42}`);
        auto rows = db.query(name).where("pk", params).execute();
        check(rows.length == 1, "pk query returns 1 row");
        check(cellInt64(rows[0], 1) == 42, "pk query returns the queried pk");
    }

    // query range + truncated
    {
        auto name = uniqueTable("d_range");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "int64", false, false),
        ]);
        db.put(name, [Cell.of(1, 1L), Cell.of(2, 50L)], null);
        db.put(name, [Cell.of(1, 2L), Cell.of(2, 120L)], null);
        db.put(name, [Cell.of(1, 3L), Cell.of(2, 200L)], null);

        import std.json : parseJSON;
        auto params = parseJSON(`{"column": 2, "min": 100, "max": 150}`);
        auto q = db.query(name).where("range", params).limit(100);
        auto rows = q.execute();
        // Only the row with amount=120 (pk=2) falls in [100, 150].
        check(rows.length == 1, "range query returns exactly 1 row");
        check(!q.truncated, "range query not truncated");
        check(cellInt64(rows[0], 1) == 2, "range query: returned pk == 2");
        check(cellInt64(rows[0], 2) == 120, "range query: returned amount == 120");
    }

    // transaction put + commit
    {
        auto name = uniqueTable("d_txn");
        db.createTable(name, [Column(1, "id", "int64", true, false)]);

        auto txn = db.begin();
        txn.put(name, [Cell.of(1, 1L)], false);
        txn.put(name, [Cell.of(1, 2L)], false);
        txn.put(name, [Cell.of(1, 3L)], false);
        check(txn.count == 3, "txn stages 3 ops");
        auto results = txn.commit(null);
        check(results.length == 3, "txn commit returns 3 results");
        check(db.count(name) == 3, "txn count == 3");
    }

    // deleteByPk
    {
        auto name = uniqueTable("d_del");
        db.createTable(name, [Column(1, "id", "int64", true, false)]);
        db.put(name, [Cell.of(1, 5L)], null);
        check(db.count(name) == 1, "deleteByPk: count == 1 before delete");
        db.deleteByPk(name, JSONValue(5L));
        check(db.count(name) == 0, "deleteByPk: count == 0 after delete");
    }

    // sql: INSERT via SQL increases the count; JSON SELECT returns the row.
    {
        auto name = uniqueTable("d_sql");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "int64", false, false),
        ]);
        check(db.count(name) == 0, "sql: count == 0 before insert");
        auto insertRows = db.sql(format!"INSERT INTO %s (id, amount) VALUES (10, 42)"(name));
        check(db.count(name) == 1, "sql: count increased to 1 after INSERT");
        auto selectRows = db.sql(format!"SELECT id, amount FROM %s"(name));
        check(selectRows.length == 1, "sql: JSON SELECT returns 1 row");
    }

    // schema + schemaFor
    {
        auto name = uniqueTable("d_schema");
        db.createTable(name, [
            Column(1, "id", "int64", true, false),
            Column(2, "amount", "float64", false, false),
        ]);

        auto catalog = db.schema();
        check((name in catalog) !is null, "schema catalog contains table");

        auto desc = db.schemaFor(name);
        check(desc.type == JSONType.object, "schemaFor returns object");
        check(("columns" in desc.object) !is null, "schemaFor has columns");
        check(desc.object["columns"].array.length == 2, "schemaFor has 2 columns");
    }

    // tableNames lists created table
    {
        auto name = uniqueTable("d_tables");
        db.createTable(name, [Column(1, "id", "int64", true, false)]);
        auto names = db.tableNames();
        bool found = false;
        foreach (n; names)
        {
            if (n == name)
                found = true;
        }
        check(found, "tableNames lists created table");
    }

    // error: schemaFor on a nonexistent table throws NotFoundException
    {
        auto name = uniqueTable("d_missing");
        bool threw = false;
        try
        {
            db.schemaFor(name);
        }
        catch (NotFoundException)
        {
            threw = true;
        }
        catch (MongrelDBException)
        {
            // Some daemon builds return a different non-2xx; accept any typed
            // client error here.
            threw = true;
        }
        check(threw, "schemaFor on missing table throws");
    }
}
