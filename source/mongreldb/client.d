// mongreldb.client - pure D HTTP client for MongrelDB.
//
// This module talks to a running mongreldb-server daemon's JSON API over the
// standard library std.net.curl HTTP client - no C ABI bindings to the engine,
// no external DUB dependencies. The surface mirrors the MongrelDB PHP, Go, and
// Java clients: typed CRUD, a fluent query builder that pushes conditions down
// to the engine's native indexes, idempotent batch transactions, full SQL
// access, and schema introspection.
//
// Connect with a base URL:
//
// ---
// import mongreldb.client;
//
// auto db = new MongrelDBClient("http://127.0.0.1:8453");
// if (db.health())
// {
//     import std.stdio : writeln;
//     writeln("daemon is up");
// }
// ---

module mongreldb.client;

public import mongreldb.transaction;
public import mongreldb.query;

import std.algorithm : canFind, map;
import std.array : appender, array;
import std.base64 : Base64;
import std.conv : to, ConvException;
import std.datetime : Duration, dur;
import std.exception : enforce;
import std.format : format;
import std.json : JSONValue, JSONType, JSONException, parseJSON, toJSON;
import std.net.curl : HTTP, CurlException;
import std.string : strip;
import std.typecons : Nullable;

///
/// The daemon address used when none is supplied.
enum defaultBaseURL = "http://127.0.0.1:8453";

///
/// Caps the size of a response body read from the daemon (256 MB). Bodies
/// larger than this are aborted with a `QueryException`.
enum maxResponseBytes = 268435456;

///
/// A column id → value pair. The client flattens a slice of cells to the
/// server's on-wire `[col_id, value, col_id, value, ...]` array before
/// sending. Pair order is irrelevant - each value is preceded by its own
/// column id.
struct Cell
{
    /// Stable on-wire column identifier.
    long id;
    /// Cell value (bool, long, double, string, or JSONValue for the rest).
    JSONValue value;

    /// Build a cell from an integral value.
    ///
    /// Note: there is intentionally no `of(long, bool)` overload. D's overload
    /// resolution ranks `bool` ahead of `long` for the values 0 and 1, so a
    /// competing bool overload silently turned `Cell.of(1, 1L)` into a JSON
    /// boolean (`true`) rather than the integer `1`. To store a boolean cell,
    /// use `Cell.of(id, JSONValue(true))`.
    static Cell of(long id, long v)
    {
        return Cell(id, JSONValue(v));
    }

    /// Build a cell from a floating-point value.
    static Cell of(long id, double v)
    {
        return Cell(id, JSONValue(v));
    }

    /// Build a cell from a string value.
    static Cell of(long id, string v)
    {
        return Cell(id, JSONValue(v));
    }

    /// Build a cell from an already-built JSON value (e.g. an array).
    static Cell of(long id, JSONValue v)
    {
        return Cell(id, v);
    }
}

///
/// Describes one column in a CREATE TABLE request. It is serialized verbatim;
/// the recognized keys are `id`, `name`, `ty`, `primary_key`, and `nullable`,
/// matching the daemon's table-create extractor.
struct Column
{
    /// Stable on-wire column id.
    long id;
    /// Human-readable column name.
    string name;
    /// Column type (e.g. "int64", "varchar", "float64").
    string ty;
    /// Whether this column is (part of) the primary key.
    bool primaryKey = false;
    /// Whether NULLs are permitted.
    bool nullable = false;
    /// Allowed string values for an enum-style column. Empty = no constraint
    /// is sent to the server (a column with `enum_variants` is treated as
    /// "any string" by the wire).
    string[] enum_variants;
    /// Default value applied when an insert omits the column. Empty string
    /// is treated as "not provided" - explicitly serialize a literal empty
    /// default via a non-empty sentinel (e.g. "\0") if ever needed.
    string default_value;
    /// Raw JSON scalar for a static default. Takes precedence over
    /// default_value when non-empty.
    string default_value_json;
    /// Dynamic default discriminator: "now" or "uuid". Takes precedence over
    /// both default-value fields.
    string default_expr;

    ///
    /// Serialize to the JSON object expected by the daemon.
    JSONValue toJson() const
    {
        auto obj = JSONValue([JSONValue()]);
        obj.object = null; // clear placeholder so .object is a valid AA
        obj["id"] = JSONValue(id);
        obj["name"] = JSONValue(name);
        obj["ty"] = JSONValue(ty);
        obj["primary_key"] = JSONValue(primaryKey);
        obj["nullable"] = JSONValue(nullable);
        // Only include the optional keys when populated; the daemon treats
        // their absence as "no constraint" / "no default".
        if (enum_variants.length > 0)
        {
            obj["enum_variants"] = JSONValue(enum_variants.map!(s => JSONValue(s)).array);
        }
        if (default_expr.length > 0)
        {
            obj["default_expr"] = JSONValue(default_expr);
        }
        else if (default_value_json.length > 0)
        {
            obj["default_value"] = parseJSON(default_value_json);
        }
        else if (default_value.length > 0)
        {
            obj["default_value"] = JSONValue(default_value);
        }
        return obj;
    }
}

/// Response shape for the `/history/retention` endpoints.
struct HistoryRetention
{
    /// Configured retention window: how many committed epochs are kept.
    ulong historyRetentionEpochs;
    /// Oldest epoch that is still readable via `AS OF EPOCH`.
    ulong earliestRetainedEpoch;
}

private HistoryRetention decodeHistoryRetention(JSONValue value)
{
    return HistoryRetention(
        cast(ulong)value["history_retention_epochs"].integer,
        cast(ulong)value["earliest_retained_epoch"].integer);
}

/// Build the exact POST /kit/create_table JSON body.
JSONValue createTablePayload(string name, Column[] columns,
        JSONValue constraints = JSONValue())
{
    import std.algorithm : map;
    import std.array : array;
    auto payload = JSONValue([JSONValue()]);
    payload.object = null;
    payload["name"] = JSONValue(name);
    payload["columns"] = JSONValue(columns.map!(c => c.toJson()).array);
    if (constraints.type == JSONType.object)
    {
        payload["constraints"] = constraints;
    }
    return payload;
}

// ── Errors ──────────────────────────────────────────────────────────────────

///
/// Base class for every error raised by the MongrelDB client. Every non-2xx
/// response is mapped to a typed subclass. Catch `MongrelDBException` to
/// handle any failure, or catch one of the specific subclasses.
class MongrelDBException : Exception
{
    /// HTTP status code returned by the daemon, or `-1` when unknown.
    int status;
    /// The server's structured error code, when present (e.g.
    /// `UNIQUE_VIOLATION`).
    string code;
    /// The offending op index within a transaction, when reported.
    Nullable!long opIndex;

    ///
    /// Construct with `msg`, optional status/code/opIndex, and optional `next`.
    this(string msg, int status = -1, string code = null,
            Nullable!long opIndex = Nullable!long.init,
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
        this.status = status;
        this.code = code;
        this.opIndex = opIndex;
    }
}

///
/// Raised for HTTP 401 or 403 - bad or missing credentials.
class AuthException : MongrelDBException
{
    this(string msg, int status = -1, string code = null,
            Nullable!long opIndex = Nullable!long.init,
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, status, code, opIndex, file, line, next);
    }
}

///
/// Raised for HTTP 404 - a missing table, schema, or other resource.
class NotFoundException : MongrelDBException
{
    this(string msg, int status = -1, string code = null,
            Nullable!long opIndex = Nullable!long.init,
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, status, code, opIndex, file, line, next);
    }
}

///
/// Raised for HTTP 409 - a unique, foreign-key, check, or trigger constraint
/// violation. During a transaction commit the engine enforces all constraints
/// at commit time; on any violation every staged op rolls back.
class ConflictException : MongrelDBException
{
    this(string msg, int status = -1, string code = null,
            Nullable!long opIndex = Nullable!long.init,
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, status, code, opIndex, file, line, next);
    }
}

///
/// Raised for HTTP 400 or 5xx, and for any other request-level failure not
/// covered by the more specific subclasses. Also used for transport failures
/// (status `-1`).
class QueryException : MongrelDBException
{
    this(string msg, int status = -1, string code = null,
            Nullable!long opIndex = Nullable!long.init,
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, status, code, opIndex, file, line, next);
    }
}

// ── Client ──────────────────────────────────────────────────────────────────

///
/// The MongrelDB HTTP client. Build one with the daemon base URL and use its
/// methods for health, table management, CRUD, query, SQL, and schema.
///
/// A `MongrelDBClient` is safe to share across fibers/threads once constructed:
/// the underlying `std.net.curl.HTTP` handle is created fresh per request and
/// the instance is immutable after construction.
class MongrelDBClient
{
    /// The daemon base URL this client was configured with (no trailing slash).
    @property string baseURL() const pure nothrow @nogc
    {
        return _baseURL;
    }

    private string _baseURL;
    private string _token;
    private string _username;
    private string _password;
    private long _timeoutMs = 30_000;

    ///
    /// Construct a client for the daemon at `url` with no authentication.
    /// An empty `url` falls back to `MongrelDBClient.defaultBaseURL`.
    this(string url = defaultBaseURL)
    {
        this(url, null, null, null);
    }

    ///
    /// Construct a client with optional authentication.
    ///
    /// A non-null/non-empty `token` authenticates requests with a Bearer
    /// header (`--auth-token` mode) and takes precedence over basic-auth
    /// credentials. When `token` is empty, a non-empty `username` enables
    /// HTTP Basic auth (`--auth-users` mode); `password` may be null.
    this(string url, string token, string username, string password)
    {
        string base = (url is null || url.length == 0) ? defaultBaseURL : url;
        while (base.length > 0 && base[$ - 1] == '/')
        {
            base = base[0 .. $ - 1];
        }
        _baseURL = base;
        // Reject CR/LF in any credential: the token/username/password are placed
        // verbatim into the Authorization header, so an embedded newline would
        // allow header injection (request splitting). Reject up front rather
        // than rely on later encoding.
        if (token !is null && containsNewline(token))
        {
            throw new MongrelDBException(
                    "auth token must not contain CR or LF");
        }
        if (username !is null && containsNewline(username))
        {
            throw new MongrelDBException(
                    "auth username must not contain CR or LF");
        }
        if (password !is null && containsNewline(password))
        {
            throw new MongrelDBException(
                    "auth password must not contain CR or LF");
        }
        _token = (token is null) ? "" : token;
        _username = (username is null) ? "" : username;
        _password = (password is null) ? "" : password;
    }

    ///
    /// Set the per-request timeout (milliseconds). Defaults to 30000.
    MongrelDBClient setTimeout(long ms) pure nothrow
    {
        _timeoutMs = ms;
        return this;
    }

    // ── Health & tables ───────────────────────────────────────────────────

    ///
    /// Report whether the daemon is reachable and healthy. A transport failure
    /// or non-2xx response yields `false` rather than throwing.
    bool health()
    {
        try
        {
            doGet("/health");
            return true;
        }
        catch (MongrelDBException)
        {
            return false;
        }
    }

    ///
    /// List all table names in the database. The endpoint returns a bare JSON
    /// array of strings.
    string[] tableNames()
    {
        JSONValue v = doGet("/tables");
        if (v.type != JSONType.array)
        {
            return [];
        }
        string[] out_;
        out_.reserve(v.array.length);
        foreach (entry; v.array)
        {
            out_ ~= (entry.type == JSONType.string) ? entry.str : entry.to!string;
        }
        return out_;
    }

    /// Return the current history-retention settings.
    HistoryRetention historyRetention()
    {
        return decodeHistoryRetention(doGet("/history/retention"));
    }

    /// Return the configured retention window (number of retained epochs).
    ulong historyRetentionEpochs()
    {
        return historyRetention().historyRetentionEpochs;
    }

    /// Return the oldest epoch still available for `AS OF EPOCH` queries.
    ulong earliestRetainedEpoch()
    {
        return historyRetention().earliestRetainedEpoch;
    }

    /// Set the history-retention window to `epochs` and return the new settings.
    /// Requires an authenticated administrator principal.
    HistoryRetention setHistoryRetentionEpochs(ulong epochs)
    {
        auto body = JSONValue(["history_retention_epochs": JSONValue(epochs)]);
        return decodeHistoryRetention(doPut("/history/retention", body));
    }

    ///
    /// Create a table named `name` with the given columns and return the
    /// assigned table id.
    long createTable(string name, Column[] columns,
            JSONValue constraints = JSONValue())
    {
        auto payload = createTablePayload(name, columns, constraints);
        JSONValue resp = doPost("/kit/create_table", payload);
        if (resp.type == JSONType.object)
        {
            if ("table_id" in resp.object && resp.object["table_id"].type == JSONType.integer)
            {
                return resp.object["table_id"].integer;
            }
        }
        return 0L;
    }

    ///
    /// Drop a table by name.
    void dropTable(string name)
    {
        doDelete("/tables/" ~ urlPathEscape(name));
    }

    ///
    /// Return the row count for a table.
    long count(string table)
    {
        JSONValue v = doGet("/tables/" ~ urlPathEscape(table) ~ "/count");
        if (v.type == JSONType.object && ("count" in v.object))
        {
            return jsonToLong(v.object["count"]);
        }
        return 0L;
    }

    // ── CRUD (via the Kit typed transaction endpoint) ────────────────────

    ///
    /// Insert a row. `idempotencyKey`, when non-empty, makes the commit safe
    /// to retry - the daemon returns the original result on duplicate commits.
    ///
    /// Returns the per-operation result object (the first element of the
    /// server's results array), or an empty object if none.
    JSONValue put(string table, Cell[] cells, string idempotencyKey = null)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto putOp = JSONValue([JSONValue()]);
        putOp.object = null;
        putOp["table"] = JSONValue(table);
        putOp["cells"] = JSONValue(flattenCells(cells));
        op["put"] = putOp;

        auto results = commitOne([op], idempotencyKey);
        return firstResult(results);
    }

    ///
    /// Upsert (insert or update on PK conflict) a row. `cells` are the insert
    /// values; `updateCells`, when non-empty, are the values to apply on a
    /// primary-key conflict (an empty array means DO NOTHING).
    /// `idempotencyKey`, when non-empty, makes the commit safe to retry.
    ///
    /// Returns the per-operation result object (the first element of the
    /// server's results array), or an empty object if none.
    JSONValue upsert(string table, Cell[] cells, Cell[] updateCells = null,
            string idempotencyKey = null)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto upsertOp = JSONValue([JSONValue()]);
        upsertOp.object = null;
        upsertOp["table"] = JSONValue(table);
        upsertOp["cells"] = JSONValue(flattenCells(cells));
        if (updateCells !is null && updateCells.length > 0)
        {
            upsertOp["update_cells"] = JSONValue(flattenCells(updateCells));
        }
        op["upsert"] = upsertOp;

        auto results = commitOne([op], idempotencyKey);
        return firstResult(results);
    }

    ///
    /// Remove a row by its primary-key value.
    void deleteByPk(string table, JSONValue pk)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto del = JSONValue([JSONValue()]);
        del.object = null;
        del["table"] = JSONValue(table);
        del["pk"] = pk;
        op["delete_by_pk"] = del;

        commitOne([op], null);
    }

    ///
    /// Send a batch of staged operations atomically to `/kit/txn` and return
    /// the per-operation results array. Exposed for the `Transaction` type.
    JSONValue[] commitTxn(JSONValue[] ops, string idempotencyKey)
    {
        auto payload = JSONValue([JSONValue()]);
        payload.object = null;
        payload["ops"] = JSONValue(ops);
        if (idempotencyKey !is null && idempotencyKey.length > 0)
        {
            payload["idempotency_key"] = JSONValue(idempotencyKey);
        }
        JSONValue resp = doPost("/kit/txn", payload);
        return decodeResults(resp);
    }

    // ── Query ────────────────────────────────────────────────────────────

    ///
    /// Start a fluent `QueryBuilder` against `table`.
    QueryBuilder query(string table)
    {
        return new QueryBuilder(this, table);
    }

    // ── Transactions ─────────────────────────────────────────────────────

    ///
    /// Start a new batch transaction. Operations staged on the returned
    /// `Transaction` are committed atomically in a single `/kit/txn` request.
    Transaction begin()
    {
        return new Transaction(this);
    }

    // ── SQL ──────────────────────────────────────────────────────────────

    ///
    /// Execute a SQL statement via the `/sql` endpoint, requesting JSON output.
    /// The server returns a JSON array of row objects keyed by column name, e.g.
    /// `[{"id": 1, "name": "Alice", "score": 95.5}]`. For statements that yield
    /// no rows (DDL/DML), the body is empty and an empty array is returned.
    JSONValue[] sql(string sqlText)
    {
        auto payload = JSONValue([JSONValue()]);
        payload.object = null;
        payload["sql"] = JSONValue(sqlText);
        payload["format"] = JSONValue("json");

        string body = postRaw("/sql", payload);
        string trimmed = strip(body);
        if (trimmed.length == 0)
        {
            return [];
        }
        // JSON format requested; a leading '{' is a single object (e.g. an
        // error envelope), not a row set, so return an empty array. A '['
        // begins the row array to decode.
        if (trimmed[0] != '[')
        {
            return [];
        }
        JSONValue parsed;
        try
        {
            parsed = parseJSON(body);
        }
        catch (JSONException e)
        {
            return [];
        }
        if (parsed.type == JSONType.array)
        {
            JSONValue[] rows;
            rows.reserve(parsed.array.length);
            foreach (row; parsed.array)
            {
                rows ~= (row.type == JSONType.object) ? row : JSONValue([JSONValue()]);
            }
            return rows;
        }
        return [];
    }

    // ── Schema ───────────────────────────────────────────────────────────

    ///
    /// Return the full schema catalog: a table-name-to-descriptor map.
    JSONValue[string] schema()
    {
        JSONValue v = doGet("/kit/schema");
        JSONValue[string] out_;
        if (v.type == JSONType.object && ("tables" in v.object) &&
                v.object["tables"].type == JSONType.object)
        {
            foreach (k, desc; v.object["tables"].object)
            {
                out_[k] = desc;
            }
        }
        return out_;
    }

    ///
    /// Return the descriptor for a single table.
    JSONValue schemaFor(string table)
    {
        JSONValue v = doGet("/kit/schema/" ~ urlPathEscape(table));
        return (v.type == JSONType.object) ? v : JSONValue([JSONValue()]);
    }

    // ── HTTP plumbing ────────────────────────────────────────────────────

    ///
    /// GET `path` and decode the JSON body (null/empty body → `null` value).
    JSONValue doGet(string path)
    {
        string body = rawRequest("GET", path, null);
        if (body.length == 0)
        {
            return JSONValue([JSONValue()]); // JSON null
        }
        try
        {
            return parseJSON(body);
        }
        catch (JSONException e)
        {
            throw new QueryException("mongreldb: decode response: " ~ e.msg);
        }
    }

    ///
    /// POST `payload` (as JSON) to `path` and decode the JSON response.
    JSONValue doPost(string path, JSONValue payload)
    {
        string body = postRaw(path, payload);
        if (body.length == 0)
        {
            return JSONValue([JSONValue()]); // JSON null
        }
        try
        {
            return parseJSON(body);
        }
        catch (JSONException e)
        {
            throw new QueryException("mongreldb: decode response: " ~ e.msg);
        }
    }

    JSONValue doPut(string path, JSONValue payload)
    {
        string body = rawRequest("PUT", path, toJSON(payload));
        return body.length ? parseJSON(body) : JSONValue();
    }

    private void doDelete(string path)
    {
        rawRequest("DELETE", path, null);
    }

    ///
    /// POST `payload` (as JSON) to `path` and return the raw response body.
    string postRaw(string path, JSONValue payload)
    {
        string encoded = toJSON(payload);
        return rawRequest("POST", path, encoded);
    }

    ///
    /// Build and run one request. The server's JSON extractors require an
    /// explicit `Content-Type` header on any request carrying a JSON body, so
    /// one is added whenever `payload` is non-null. Non-2xx responses are
    /// mapped to typed exceptions via `toException`.
    string rawRequest(string method, string path, string payload)
    {
        string url = _baseURL ~ "/" ~ stripLeadingSlash(path);

        auto http = HTTP();
        http.url = url;
        http.addRequestHeader("Accept", "application/json");
        http.method = toMethod(method);
        Duration timeout = dur!("msecs")(cast(int) _timeoutMs);
        http.connectTimeout = timeout;
        http.dataTimeout = timeout;
        applyAuth(http);

        auto buf = appender!string;
        http.onReceive = (ubyte[] data)
        {
            // Cap the download: abort once the buffered body would exceed
            // maxResponseBytes so an oversized response is not buffered fully.
            if (buf.data.length + data.length > maxResponseBytes)
            {
                return cast(size_t) 0;
            }
            buf.put(cast(string) data);
            return data.length;
        };

        try
        {
            if (payload !is null && payload.length > 0)
            {
                if (method == "PUT")
                {
                    // std.net.curl's setPostData only reliably uploads for POST.
                    // For PUT, provide the payload through onSend and declare its
                    // length so libcurl sends the body correctly.
                    auto upload = cast(ubyte[]) payload;
                    http.contentLength = upload.length;
                    http.onSend = (void[] data)
                    {
                        size_t n = data.length;
                        if (n > upload.length)
                            n = upload.length;
                        if (n == 0)
                            return cast(size_t) 0;
                        data[0 .. n] = cast(void[]) upload[0 .. n];
                        upload = upload[n .. $];
                        return n;
                    };
                    http.addRequestHeader("Content-Type", "application/json");
                }
                else
                {
                    // setPostData attaches the body and sets Content-Type itself.
                    http.setPostData(payload, "application/json");
                }
            }
            http.perform();
        }
        catch (CurlException e)
        {
            throw new QueryException("mongreldb: request " ~ method ~ " " ~ path ~
                    " failed: " ~ e.msg, -1, null, Nullable!long.init,
                    __FILE__, __LINE__, e);
        }

        int status = http.statusLine.code;
        string response = buf.data;

        // An oversized body (aborted mid-read or otherwise) is a Query error.
        if (response.length > maxResponseBytes)
        {
            throw new QueryException(format!"mongreldb: response body exceeds %d bytes"(
                    maxResponseBytes), status, null, Nullable!long.init);
        }

        if (status < 200 || status >= 300)
        {
            throw toException(status, response);
        }
        return response;
    }

    // applyAuth sets the Authorization header according to the configured
    // credentials. A bearer token takes precedence over basic auth.
    private void applyAuth(HTTP http)
    {
        if (_token.length > 0)
        {
            http.addRequestHeader("Authorization", "Bearer " ~ _token);
        }
        else if (_username.length > 0)
        {
            string creds = _username ~ ":" ~ _password;
            string encoded = Base64.encode(cast(ubyte[]) creds);
            http.addRequestHeader("Authorization", "Basic " ~ encoded);
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    // commitOne sends a single-op transaction and returns the results array.
    private JSONValue[] commitOne(JSONValue[] ops, string idempotencyKey)
    {
        return commitTxn(ops, idempotencyKey);
    }
}

// ── Module-level helpers ────────────────────────────────────────────────────

///
/// Flatten a slice of cells to the server's flat
/// `[col_id, value, col_id, value, ...]` array. Pair order is not significant.
JSONValue[] flattenCells(Cell[] cells)
{
    JSONValue[] flat;
    flat.reserve(cells.length * 2);
    foreach (c; cells)
    {
        flat ~= JSONValue(c.id);
        flat ~= c.value;
    }
    return flat;
}

// decodeResults pulls the results array out of a /kit/txn response.
private JSONValue[] decodeResults(JSONValue v)
{
    if (v.type != JSONType.object)
    {
        return [];
    }
    if (!("results" in v.object))
    {
        return [];
    }
    JSONValue r = v.object["results"];
    if (r.type != JSONType.array)
    {
        return [];
    }
    JSONValue[] out_;
    out_.reserve(r.array.length);
    foreach (row; r.array)
    {
        out_ ~= (row.type == JSONType.object) ? row : JSONValue([JSONValue()]);
    }
    return out_;
}

// firstResult returns the first element of results, or an empty object.
private JSONValue firstResult(JSONValue[] results)
{
    if (results.length == 0)
    {
        return JSONValue([JSONValue()]);
    }
    return results[0];
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

// Maps an HTTP status code and response body to a typed exception. It
// best-effort decodes the server's JSON error envelope
// ({error:{message,code,op_index}}) and falls back to the raw body.
private MongrelDBException toException(int status, string body)
{
    string message;
    string code;
    Nullable!long opIndex;

    string trimmed = strip(body);
    if (trimmed.length > 0 && trimmed[0] == '{')
    {
        try
        {
            JSONValue parsed = parseJSON(body);
            if (parsed.type == JSONType.object)
            {
                // Prefer the nested {"error": {...}} envelope.
                if ("error" in parsed.object &&
                        parsed.object["error"].type == JSONType.object)
                {
                    JSONValue err = parsed.object["error"];
                    if ("message" in err.object)
                    {
                        message = jsonToString(err.object["message"]);
                    }
                    if ("code" in err.object)
                    {
                        code = jsonToString(err.object["code"]);
                    }
                    if ("op_index" in err.object)
                    {
                        opIndex = Nullable!long(jsonToLong(err.object["op_index"]));
                    }
                }
                // Fall back to a flat {"message": ..., "code": ...} object.
                if (message.length == 0 && code.length == 0 &&
                        opIndex.isNull())
                {
                    if ("message" in parsed.object)
                    {
                        message = jsonToString(parsed.object["message"]);
                    }
                    if ("code" in parsed.object)
                    {
                        code = jsonToString(parsed.object["code"]);
                    }
                }
            }
        }
        catch (JSONException)
        {
            // Not JSON; fall through to the raw body.
        }
    }
    if (message.length == 0 && body.length > 0)
    {
        message = body;
    }
    if (message.length == 0)
    {
        switch (status)
        {
        case 401, 403:
            message = format!"authentication failed (%d)"(status);
            break;
        case 404:
            message = "resource not found";
            break;
        case 409:
            message = "constraint violation";
            break;
        default:
            message = format!"server error (%d)"(status);
        }
    }

    if (message.length >= 10 && message[0 .. 10] == "not found:")
    {
        return new NotFoundException(message, 404, code, opIndex);
    }
    switch (status)
    {
    case 401, 403:
        return new AuthException(message, status, code, opIndex);
    case 404:
        return new NotFoundException(message, status, code, opIndex);
    case 409:
        return new ConflictException(message, status, code, opIndex);
    default:
        return new QueryException(message, status, code, opIndex);
    }
}

// jsonToString renders a JSON scalar to its display string for error messages.
private string jsonToString(JSONValue v)
{
    final switch (v.type)
    {
    case JSONType.string:
        return v.str;
    case JSONType.integer:
        return to!string(v.integer);
    case JSONType.uinteger:
        return to!string(v.uinteger);
    case JSONType.float_:
        return to!string(v.floating);
    case JSONType.true_:
        return "true";
    case JSONType.false_:
        return "false";
    case JSONType.null_:
        return "null";
    case JSONType.object:
        return toJSON(v);
    case JSONType.array:
        return toJSON(v);
    }
}

// stripLeadingSlash trims every leading '/' from s.
private string stripLeadingSlash(string s) pure nothrow
{
    size_t i;
    for (i = 0; i < s.length; i++)
    {
        if (s[i] != '/')
            break;
    }
    return s[i .. $];
}

// containsNewline reports whether s contains a CR or LF byte. Used to guard
// values that are interpolated into the Authorization header against header
// injection / request splitting.
private bool containsNewline(string s) pure nothrow @nogc
{
    foreach (char c; s)
    {
        if (c == '\r' || c == '\n')
        {
            return true;
        }
    }
    return false;
}

// toMethod maps an uppercase method name to std.net.curl's HTTP.Method enum.
private HTTP.Method toMethod(string method) pure
{
    switch (method)
    {
    case "GET":
        return HTTP.Method.get;
    case "POST":
        return HTTP.Method.post;
    case "DELETE":
        return HTTP.Method.del;
    case "PUT":
        return HTTP.Method.put;
    case "HEAD":
        return HTTP.Method.head;
    default:
        return HTTP.Method.undefined;
    }
}

///
/// Percent-encode a path segment so table names containing '/', '?', '#',
/// or spaces cannot inject extra segments or break routing. Only RFC 3986
/// unreserved characters pass through unescaped.
string urlPathEscape(string seg) pure nothrow
{
    static immutable hex = "0123456789ABCDEF";

    // Fast path: nothing to escape.
    bool needEscape = false;
    foreach (b; cast(ubyte[]) seg)
    {
        if (!isUnreservedOrSlash(b))
        {
            needEscape = true;
            break;
        }
    }
    if (!needEscape)
    {
        return seg;
    }

    auto buf = appender!string;
    foreach (b; cast(ubyte[]) seg)
    {
        if (isUnreservedOrSlash(b))
        {
            buf.put(cast(char) b);
        }
        else
        {
            buf.put('%');
            buf.put(hex[b >> 4]);
            buf.put(hex[b & 0x0f]);
        }
    }
    return buf.data;
}

// isUnreserved matches only RFC 3986 unreserved characters. The forward
// slash is NOT included so a table name cannot inject an extra path segment.
private bool isUnreservedOrSlash(ubyte b) pure nothrow @nogc
{
    return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') ||
            (b >= '0' && b <= '9') || b == '-' || b == '_' ||
            b == '.' || b == '~';
}

// JSONValue constructors that take a plain string are not implicit; wrap them.
// (std.json provides JSONValue(string) - no extra alias needed.)

unittest
{
    // Smoke test: urlPathEscape leaves safe strings alone.
    assert(urlPathEscape("orders") == "orders");
    // '/' is now encoded so it cannot inject an extra path segment.
    assert(urlPathEscape("a/b") == "a%2Fb");
    assert(urlPathEscape("a b") == "a%20b");
}

// Wire-shape conformance: Column.toJson() must emit exactly the keys the
// server's create_table extractor reads, and must omit enum_variants /
// default_value when not set so existing column definitions stay
// byte-identical.
unittest
{
    // Case 1: optional fields populated -> both keys present, exact spelling.
    {
        auto c = Column(1, "color", "varchar", false, false,
                cast(string[])["a", "b"], "a");
        JSONValue payload = c.toJson();
        string wire = toJSON(payload);
        assert(wire.canFind(`"enum_variants":["a","b"]`),
                "expected enum_variants array in wire JSON, got: " ~ wire);
        assert(wire.canFind(`"default_value":"a"`),
                "expected default_value string in wire JSON, got: " ~ wire);
    }

    // Case 2: optional fields empty -> both keys absent (additive safety).
    {
        auto c = Column(1, "name", "varchar", false, false);
        JSONValue payload = c.toJson();
        string wire = toJSON(payload);
        assert(!wire.canFind("enum_variants"),
                "enum_variants should be omitted when empty, got: " ~ wire);
        assert(!wire.canFind("default_value"),
                "default_value should be omitted when empty, got: " ~ wire);
        // Sanity: the always-on keys are still emitted.
        assert(wire.canFind(`"id":1`), wire);
        assert(wire.canFind(`"name":"name"`), wire);
        assert(wire.canFind(`"ty":"varchar"`), wire);
    }

    {
        auto c = Column(2, "attempts", "int64");
        c.default_value_json = "3";
        auto payload = c.toJson();
        const wire = toJSON(payload);
        assert(wire.canFind(`"default_value":3`), wire);
        assert(!wire.canFind("default_expr"), wire);
    }

    {
        auto c = Column(3, "created_at", "timestamp_nanos");
        c.default_value = "legacy";
        c.default_value_json = "3";
        c.default_expr = "uuid";
        auto payload = c.toJson();
        const wire = toJSON(payload);
        assert(wire.canFind(`"default_expr":"uuid"`), wire);
        assert(!wire.canFind("default_value"), wire);
    }
}
