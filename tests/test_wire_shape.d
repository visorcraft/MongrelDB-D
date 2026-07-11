// test_wire_shape.d - Offline wire-format conformance tests.
//
// Verifies that Column.toJson() emits the exact JSON the daemon's
// /kit/create_table extractor reads, without needing a running server.
// Mirrors tests/test_wire_shape.c in the C client.
//
// Licensing: MIT OR Apache-2.0.

module test_wire_shape;

import mongreldb.client : Column, createTablePayload;
import std.algorithm : canFind;
import std.json : JSONValue, parseJSON, toJSON;
import std.stdio : writeln;

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

    foreach (value; [`"text"`, `true`, `null`, `"now"`])
    {
        auto c = Column(9, "value", "varchar");
        c.default_value_json = value;
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"default_value":` ~ value, "default matrix");
        assertNotContains(wire, "default_expr", "literal default");
    }

    // Static JSON scalar default.
    {
        auto c = Column(4, "attempts", "int64");
        c.default_value_json = "3";
        auto payload = c.toJson();
        string wire = toJSON(payload);
        assertContains(wire, `"default_value":3`, "static default");
        assert(!wire.canFind("default_expr"), wire);
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

    writeln("All wire-shape tests passed.");
    return 0;
}
