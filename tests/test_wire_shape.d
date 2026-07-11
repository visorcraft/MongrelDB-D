// test_wire_shape.d - Offline wire-format conformance tests.
//
// Verifies that Column.toJson() emits the exact JSON the daemon's
// /kit/create_table extractor reads, and that the /history/retention
// transport contract sends the expected method/path/body and parses the
// response keys, without needing a running MongrelDB server.
// Mirrors tests/test_wire_shape.c in the C client.
//
// Licensing: MIT OR Apache-2.0.

module test_wire_shape;

import mongreldb.client : Column, MongrelDBClient, createTablePayload;
import core.thread : Thread;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
        SocketType;
import std.stdio : writeln;
import std.string : indexOf, split, toLower;
import std.datetime : dur;

private void assertContains(string haystack, string needle, string label)
{
    assert(haystack.canFind(needle),
            label ~ ": expected substring `" ~ needle ~ "` in `" ~ haystack ~ "`");
}

private void assertNotContains(string haystack, string needle, string label)
{
    assert(!haystack.canFind(needle),
            label ~ ": unexpected substring `" ~ needle ~ "` in `" ~ haystack ~ "`");
}

// A single captured HTTP request from the mock server.
private struct CapturedRequest
{
    string method;
    string path;
    string body;
}

// Read an HTTP/1.1 chunked body from `client` after the request headers have
// already been consumed. Returns the decoded body.
private string readChunkedBody(Socket client, ref ubyte[8192] buf)
{
    import std.conv : to;

    string body;
    string pending;
    ptrdiff_t got;

    while (true)
    {
        // Read until we have a complete chunk-size line.
        while (pending.indexOf("\r\n") == -1 && (got = client.receive(buf)) > 0)
        {
            pending ~= cast(string) buf[0 .. got];
        }
        auto cr = pending.indexOf("\r\n");
        if (cr == -1)
            break;

        string sizeHex = pending[0 .. cr];
        pending = pending[cr + 2 .. $];
        long size = 0;
        try
        {
            size = sizeHex.to!long(16);
        }
        catch (Exception)
        {
            break;
        }
        if (size == 0)
        {
            // Consume the trailing \r\n after the zero-size chunk.
            while (pending.length < 2 && (got = client.receive(buf)) > 0)
            {
                pending ~= cast(string) buf[0 .. got];
            }
            break;
        }

        // Read `size` payload bytes plus the terminating \r\n.
        while (pending.length < size + 2 && (got = client.receive(buf)) > 0)
        {
            pending ~= cast(string) buf[0 .. got];
        }
        if (pending.length >= size)
        {
            body ~= pending[0 .. size];
            if (pending.length >= size + 2)
                pending = pending[size + 2 .. $];
            else
                pending = "";
        }
        else
        {
            break;
        }
    }
    return body;
}

// Read a fixed-length body of `contentLength` bytes from `client` after the
// request headers have already been consumed. Any body bytes that arrived with
// the headers are supplied in `alreadyReceived`.
private string readFixedBody(Socket client, ref ubyte[8192] buf,
        long contentLength, string alreadyReceived)
{
    string body = alreadyReceived;
    ptrdiff_t got;
    while (body.length < contentLength && (got = client.receive(buf)) > 0)
    {
        body ~= cast(string) buf[0 .. got];
    }
    return body;
}

// A tiny one-shot HTTP server used to verify the exact /history/retention
// request shape. It records the first request it receives, answers any
// Expect: 100-continue probe, then replies with `responseBody`.
private void runMockServer(ushort port, string responseBody, CapturedRequest* captured)
{
    auto listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope (exit)
        listener.close();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(1);

    auto client = listener.accept();
    scope (exit)
        client.close();

    ubyte[8192] buf;
    ptrdiff_t got;
    string req;

    // Read the request headers.
    while ((got = client.receive(buf)) > 0)
    {
        req ~= cast(string) buf[0 .. got];
        if (req.indexOf("\r\n\r\n") != -1)
            break;
    }

    // Parse Content-Length so we know exactly how many body bytes to read.
    long contentLength = -1;
    foreach (line; req.split("\r\n"))
    {
        if (line.length > 16 && line[0 .. 16].toLower == "content-length: ")
        {
            contentLength = line[16 .. $].to!long;
            break;
        }
    }
    bool chunked = req.indexOf("Transfer-Encoding: chunked") != -1 ||
            req.toLower.indexOf("transfer-encoding: chunked") != -1;

    string body;
    auto blank = req.indexOf("\r\n\r\n");
    string head = req[0 .. blank + 4];
    string alreadyReceived = req[blank + 4 .. $];

    // libcurl may wait for a 100 Continue before sending the body.
    if (req.toLower.indexOf("expect: 100-continue") != -1)
    {
        client.send(cast(ubyte[]) "HTTP/1.1 100 Continue\r\n\r\n");
        if (chunked)
        {
            body = readChunkedBody(client, buf);
        }
        else if (contentLength > 0)
        {
            body = readFixedBody(client, buf, contentLength, "");
        }
    }
    else if (chunked)
    {
        body = readChunkedBody(client, buf);
    }
    else if (contentLength > 0)
    {
        body = readFixedBody(client, buf, contentLength, alreadyReceived);
    }

    req = head ~ body;

    // Parse request-line: METHOD PATH HTTP/1.1
    auto lines = req.split("\r\n");
    if (lines.length > 0)
    {
        auto parts = lines[0].split(" ");
        if (parts.length >= 2)
        {
            captured.method = parts[0];
            captured.path = parts[1];
        }
    }

    if (blank != -1)
    {
        captured.body = body;
    }

    string response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ~
        "Content-Length: " ~ responseBody.length.to!string ~ "\r\n" ~
        "Connection: close\r\n\r\n" ~ responseBody;
    client.send(cast(ubyte[]) response);
}

private long freePort()
{
    auto s = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope (exit)
        s.close();
    s.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) s.localAddress).port;
}

int main()
{
    // Test 1: basic column - no enum_variants, no default_value.
    {
        auto c = Column(1, "id", "int64", true, false);
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"id":1`, "basic");
        assertContains(wire, `"name":"id"`, "basic");
        assertContains(wire, `"ty":"int64"`, "basic");
        assertContains(wire, `"primary_key":true`, "basic");
        assertContains(wire, `"nullable":false`, "basic");
        assertNotContains(wire, "enum_variants", "basic");
        assertNotContains(wire, "default_value", "basic");
        writeln("PASS: basic column wire shape");
    }

    // Dynamic expression takes precedence over static defaults.
    {
        auto c = Column(5, "created_at", "timestamp_nanos");
        c.default_value = "legacy";
        c.default_value_json = "3";
        c.default_expr = "now";
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"default_expr":"now"`, "dynamic default");
        assert(!wire.canFind("default_value"), wire);
        writeln("PASS: dynamic default precedence");
    }

    // Static-default matrix: one payload covering every scalar shape.
    {
        auto colString = Column(1, "s", "varchar");
        colString.default_value_json = `"hello"`;

        auto colNumber = Column(2, "n", "int64");
        colNumber.default_value_json = `42`;

        auto colBool = Column(3, "b", "bool");
        colBool.default_value_json = `true`;

        auto colNull = Column(4, "nil", "varchar");
        colNull.default_value_json = `null`;

        auto colLiteralNow = Column(5, "lit_now", "varchar");
        colLiteralNow.default_value_json = `"now"`;

        auto colExprNow = Column(6, "expr_now", "timestamp_nanos");
        colExprNow.default_expr = "now";

        auto payload = createTablePayload("typed_defaults", [
            colString, colNumber, colBool, colNull, colLiteralNow, colExprNow
        ]);
        string wire = toJSON(payload);

        assertContains(wire, `"default_value":"hello"`, "default matrix string");
        assertContains(wire, `"default_value":42`, "default matrix number");
        assertContains(wire, `"default_value":true`, "default matrix boolean");
        assertContains(wire, `"default_value":null`, "default matrix null");
        assertContains(wire, `"default_value":"now"`, "default matrix literal now");
        assertContains(wire, `"default_expr":"now"`, "default matrix expr now");

        // Inspect decoded JSON to ensure parseJSON produced the right scalar types.
        auto cols = payload["columns"].array;
        assert(cols.length == 6, "default matrix: 6 columns");
        assert(cols[0]["default_value"].str == "hello", "decoded string default");
        assert(cols[1]["default_value"].integer == 42, "decoded number default");
        assert(cols[2]["default_value"].type == JSONType.true_, "decoded boolean default");
        assert(cols[3]["default_value"].type == JSONType.null_, "decoded null default");
        assert(cols[4]["default_value"].str == "now", "decoded literal now");
        assert(cols[5]["default_expr"].str == "now", "decoded default_expr now");

        writeln("PASS: static-default matrix");
    }

    // Test 2: column with enum_variants (no default_value).
    {
        auto c = Column(2, "status", "varchar", false, false,
                cast(string[])["active", "inactive", "pending"], "");
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"enum_variants":["active","inactive","pending"]`,
                "enum_variants");
        assertNotContains(wire, "default_value", "enum_variants");
        writeln("PASS: enum_variants wire shape");
    }

    // Test 3: column with default_value (no enum_variants).
    {
        auto c = Column(3, "score", "float64", false, true,
                cast(string[])[], "0.0");
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"default_value":"0.0"`, "default_value");
        assertNotContains(wire, "enum_variants", "default_value");
        writeln("PASS: default_value wire shape");
    }

    // Test 4: full payload with a table CHECK.
    {
        auto constraints = parseJSON(
                `{"checks":[{"id":1,"name":"score_nonneg","expr":{"Ge":[{"Col":1},{"Lit":{"Int64":0}}]}}]}`);
        auto payload = createTablePayload("scores",
                [Column(1, "score", "int64")], constraints);
        string wire = toJSON(payload);
        assertContains(wire, `"constraints":{"checks":[`, "constraints.checks");
        assertContains(wire, `"name":"score_nonneg"`, "CHECK name");
        writeln("PASS: CHECK constraints wire shape");
    }

    // Test 5: /history/retention transport contract.
    {
        auto capPut = CapturedRequest();
        long portPut = freePort();
        string response = `{"history_retention_epochs":42,"earliest_retained_epoch":7}`;
        auto t = new Thread(() => runMockServer(cast(ushort) portPut, response, &capPut));
        t.start();
        Thread.sleep(dur!"msecs"(200));

        auto db = new MongrelDBClient("http://127.0.0.1:" ~ portPut.to!string);
        auto result = db.setHistoryRetentionEpochs(42);
        t.join();

        assert(capPut.method == "PUT", "retention PUT method, got: " ~ capPut.method);
        assert(capPut.path == "/history/retention",
                "retention PUT path, got: " ~ capPut.path);
        assert(capPut.body == `{"history_retention_epochs":42}`,
                "retention PUT body, got: " ~ capPut.body);
        assert(result.historyRetentionEpochs == 42,
                "retention PUT response history_retention_epochs");
        assert(result.earliestRetainedEpoch == 7,
                "retention PUT response earliest_retained_epoch");

        // historyRetentionEpochs() sends GET /history/retention and parses
        // the `history_retention_epochs` response key.
        auto capGetEpochs = CapturedRequest();
        long portGetEpochs = freePort();
        t = new Thread(() => runMockServer(cast(ushort) portGetEpochs, response, &capGetEpochs));
        t.start();
        Thread.sleep(dur!"msecs"(200));

        auto db2 = new MongrelDBClient("http://127.0.0.1:" ~ portGetEpochs.to!string);
        ulong epochs = db2.historyRetentionEpochs();
        t.join();

        assert(capGetEpochs.method == "GET",
                "retention GET method, got: " ~ capGetEpochs.method);
        assert(capGetEpochs.path == "/history/retention",
                "retention GET path, got: " ~ capGetEpochs.path);
        assert(capGetEpochs.body == "",
                "retention GET body, got: " ~ capGetEpochs.body);
        assert(epochs == 42, "retention GET response history_retention_epochs");

        // earliestRetainedEpoch() sends the same GET and parses
        // `earliest_retained_epoch`.
        auto capGetEarliest = CapturedRequest();
        long portGetEarliest = freePort();
        t = new Thread(() => runMockServer(cast(ushort) portGetEarliest, response, &capGetEarliest));
        t.start();
        Thread.sleep(dur!"msecs"(200));

        auto db3 = new MongrelDBClient("http://127.0.0.1:" ~ portGetEarliest.to!string);
        ulong earliest = db3.earliestRetainedEpoch();
        t.join();

        assert(capGetEarliest.method == "GET",
                "retention GET method (earliest), got: " ~ capGetEarliest.method);
        assert(capGetEarliest.path == "/history/retention",
                "retention GET path (earliest), got: " ~ capGetEarliest.path);
        assert(capGetEarliest.body == "",
                "retention GET body (earliest), got: " ~ capGetEarliest.body);
        assert(earliest == 7, "retention GET response earliest_retained_epoch");

        writeln("PASS: /history/retention transport contract");
    }

    writeln("All wire-shape tests passed.");
    return 0;
}
