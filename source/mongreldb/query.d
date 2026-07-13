// mongreldb.query - fluent query builder for the /kit/query endpoint.
//
// A QueryBuilder builds a request for the daemon's /kit/query endpoint, where
// conditions push down to the engine's specialized indexes for sub-millisecond
// lookups.
//
// Condition parameters accept friendly aliases that are translated to the
// server's exact on-wire keys before sending (see where()):
//
//   - column         -> column_id
//   - min / max      -> lo / hi
//   - min_inclusive  -> lo_inclusive
//   - max_inclusive  -> hi_inclusive
//
// The server's canonical keys are accepted directly too.

module mongreldb.query;

import mongreldb.client;

import std.array : appender;
import std.json : JSONValue, JSONType;

///
/// Builds a request for the daemon's `/kit/query` endpoint.
///
/// Conditions are AND-ed together and pushed down to the engine's specialized
/// indexes. The builder returns itself from each method so queries can be
/// chained.
class QueryBuilder
{
    private MongrelDBClient _client;
    private string _table;
    private JSONValue[] _conditions;
    private long[] _projection;
    private bool _hasLimit;
    private long _limit;
    private bool _hasOffset;
    private long _offset;
    private bool _lastTruncated;

    ///
    /// Construct a builder bound to `client` for `table`. Use
    /// `MongrelDBClient.query()` instead of constructing one directly.
    this(MongrelDBClient client, string table)
    {
        _client = client;
        _table = table;
    }

    ///
    /// Add a native condition (AND-ed with any prior conditions).
    ///
    /// Available condition types include: `pk` (exact primary-key match,
    /// `{"value": pk}`), `bitmap_eq`, `bitmap_in`, `range`, `range_f64`,
    /// `is_null`, `is_not_null`, `fm_contains`, `fm_contains_all`, `ann`,
    /// `sparse_match`, `min_hash_similar`. `params` is a JSON object whose keys
    /// are the condition's parameters (friendly aliases accepted).
    QueryBuilder where(string condType, JSONValue params)
    {
        auto entry = JSONValue([JSONValue()]);
        entry.object = null;
        entry[condType] = normalizeCondition(condType, params);
        _conditions ~= entry;
        return this;
    }

    ///
    /// Set the column ids to return. Leave unset for all columns.
    QueryBuilder projection(long[] columnIDs)
    {
        _projection = columnIDs;
        return this;
    }

    ///
    /// Cap the number of rows returned.
    QueryBuilder limit(long n)
    {
        _hasLimit = true;
        _limit = n;
        return this;
    }

    /// Skip matching rows before applying the limit.
    QueryBuilder offset(long n)
    {
        _hasOffset = true;
        _offset = n;
        return this;
    }

    ///
    /// Build the request payload that will be sent to `/kit/query`.
    JSONValue build()
    {
        auto payload = JSONValue([JSONValue()]);
        payload.object = null;
        payload["table"] = JSONValue(_table);
        if (_conditions.length > 0)
        {
            payload["conditions"] = JSONValue(_conditions);
        }
        if (_projection.length > 0)
        {
            JSONValue[] cols;
            cols.reserve(_projection.length);
            foreach (c; _projection)
            {
                cols ~= JSONValue(c);
            }
            payload["projection"] = JSONValue(cols);
        }
        if (_hasLimit)
        {
            payload["limit"] = JSONValue(_limit);
        }
        if (_hasOffset)
        {
            payload["offset"] = JSONValue(_offset);
        }
        return payload;
    }

    ///
    /// Run the query and return the matching rows. Also records whether the
    /// result was truncated by `limit()`; check it with `truncated()`.
    JSONValue[] execute()
    {
        JSONValue resp = _client.doPost("/kit/query", build());
        JSONValue[] rows;
        _lastTruncated = false;
        if (resp.type == JSONType.object)
        {
            if ("rows" in resp.object && resp.object["rows"].type == JSONType.array)
            {
                JSONValue[] arr = resp.object["rows"].array;
                rows.reserve(arr.length);
                foreach (row; arr)
                {
                    rows ~= (row.type == JSONType.object) ? row : JSONValue([JSONValue()]);
                }
            }
            if ("truncated" in resp.object && resp.object["truncated"].type == JSONType.true_)
            {
                _lastTruncated = true;
            }
        }
        return rows;
    }

    ///
    /// Whether the most recent `execute()` result was capped by the query
    /// limit. Returns `false` until `execute()` has been called.
    @property bool truncated() const pure nothrow
    {
        return _lastTruncated;
    }

    // Translates friendly parameter aliases to the server's canonical on-wire
    // keys. Both spellings are accepted, so callers may use whichever is
    // clearer.
    private static JSONValue normalizeCondition(string condType, JSONValue params)
    {
        // `params` is a JSON object. Rebuild it with aliased keys.
        auto normalized = JSONValue([JSONValue()]);
        normalized.object = null;
        if (params.type != JSONType.object)
        {
            // Nothing to normalize; pass through.
            return params;
        }
        foreach (key, val; params.object)
        {
            string canonical;
            switch (key)
            {
            case "column":
                canonical = "column_id";
                break;
            case "min":
                canonical = "lo";
                break;
            case "max":
                canonical = "hi";
                break;
            case "min_inclusive":
                canonical = "lo_inclusive";
                break;
            case "max_inclusive":
                canonical = "hi_inclusive";
                break;
            case "value":
                // The docs historically used "value" for the FTS pattern; the
                // server's fm_contains key is "pattern". Only apply this for
                // FTS conditions, since pk/bitmap_eq use "value" canonically.
                canonical = (condType == "fm_contains" || condType == "fm_contains_all")
                        ? "pattern" : "value";
                break;
            default:
                canonical = key;
            }
            normalized[canonical] = val;
        }
        return normalized;
    }
}

unittest
{
    // Alias normalization for an FTS condition: value -> pattern.
    import std.json : parseJSON;
    auto params = parseJSON(`{"column": 2, "value": "database performance"}`);
    auto norm = QueryBuilder.normalizeCondition("fm_contains", params);
    assert(norm.object["pattern"].str == "database performance");
    assert(norm.object["column_id"].integer == 2);

    // For a pk condition, value stays value.
    auto pkParams = parseJSON(`{"value": 42}`);
    auto pkNorm = QueryBuilder.normalizeCondition("pk", pkParams);
    assert(pkNorm.object["value"].integer == 42);
}
