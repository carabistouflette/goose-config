// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;

fn put(store: config::Store&, key: const u8[:], value: const u8[:], source: const u8[:] = "test") -> u8[>..] {
    let input = [config::Override { key, value, source }];
    return config::apply(store, input);
}
fn integer(store: config::Store&, key: const u8[:], expected: i64) {
    let value, error = config::get_integer(store, key);
    assert(error.len == 0 && value == expected);
}
fn floating(store: config::Store&, key: const u8[:], expected: f64) {
    let value, error = config::get_float(store, key);
    assert(error.len == 0 && value == expected);
}
fn text(store: config::Store&, key: const u8[:], expected: const u8[:]) {
    let value, error = config::get_text(store, key);
    assert(error.len == 0 && value == expected);
}
fn origin(store: config::Store&, key: const u8[:], expected: const u8[:]) {
    let value, error = config::source(store, key);
    assert(error.len == 0 && value == expected);
}
fn repeated(c: u8, count: i64) -> u8[>..] {
    var value: u8[>..] = [];
    for i in count { value.push(c); }
    return value;
}

fn numbers() {
    var store = config::Store { .. };
    let schema = [config::Field { "integer", config::Kind.Integer },
                  config::Field { "float", config::Kind.Float },
                  config::Field { "boolean", config::Kind.Boolean }];
    assert(config::init(schema, store).len == 0);
    assert(put(store, "integer", "-9223372036854775808").len == 0);
    integer(store, "integer", -9223372036854775808);
    assert(put(store, "integer", "+9223372036854775807").len == 0);
    integer(store, "integer", 9223372036854775807);
    assert(put(store, "integer", "00000000000000000000042").len == 0);
    integer(store, "integer", 42);
    let invalid_integer = ["9223372036854775808", "-9223372036854775809", "", "+", "-", " 1", "1 ", "1.0", "1e1", "0x10", "1_000", "--1", "1\n", "NaN"];
    for invalid in invalid_integer {
        assert(put(store, "integer", invalid).len > 0);
        integer(store, "integer", 42);
    }
    assert(put(store, "float", "1.7976931348623157e308").len == 0);
    floating(store, "float", 1.7976931348623157e308);
    assert(put(store, "float", "-1.7976931348623157e308").len == 0);
    floating(store, "float", -1.7976931348623157e308);
    assert(put(store, "float", "5e-324").len == 0);
    floating(store, "float", 5e-324);
    assert(put(store, "float", "-0.0").len == 0);
    let zero, ze = config::get_float(store, "float");
    assert(ze.len == 0 && zero == 0.0 && 1.0 / zero < 0.0);
    assert(put(store, "float", "-1e-9999").len == 0);
    let underflow, ue = config::get_float(store, "float");
    assert(ue.len == 0 && underflow == 0.0 && 1.0 / underflow < 0.0);
    assert(put(store, "float", "+001.25E+2").len == 0);
    floating(store, "float", 125.0);
    let invalid_float = ["", "+", "-", ".5", "1.", "1e", "1e+", "1e-", " 1", "1 ", "1_000", "0x1p0", "NaN", "nan", "inf", "-inf", "Infinity", "1e9999", "-1e9999", "1.7976931348623159e308", "1\n", "1\x00"];
    for invalid in invalid_float {
        assert(put(store, "float", invalid).len > 0);
        floating(store, "float", 125.0);
    }
    // Numeric limits are checked before expensive decimal conversion.
    var number = repeated('0', config::MAX_NUMBER_BYTES - 1);
    number.push('1');
    assert(put(store, "integer", number).len == 0);
    assert(put(store, "float", number).len == 0);
    integer(store, "integer", 1); floating(store, "float", 1.0);
    number.push('0');
    assert(put(store, "integer", number).len > 0);
    assert(put(store, "float", number).len > 0);
    integer(store, "integer", 1); floating(store, "float", 1.0);
    assert(put(store, "boolean", "true").len == 0);
    let yes, ye = config::get_boolean(store, "boolean"); assert(ye.len == 0 && yes);
    let invalid_boolean = ["", "1", "0", "True", "FALSE", " true", "true ", "true\n", "false\x00"];
    for invalid in invalid_boolean { assert(put(store, "boolean", invalid).len > 0); }
    assert(put(store, "boolean", "false").len == 0);
    let no, ne = config::get_boolean(store, "boolean"); assert(ne.len == 0 && !no);
}

fn constraints_and_access() {
    var store = config::Store { .. };
    assert(config::validate(store).len > 0);
    assert(put(store, "x", "1").len > 0);
    let uninitialized, ui = config::get_integer(store, "x"); assert(ui.len > 0);
    let no_source, ns = config::source(store, "x"); assert(ns.len > 0);
    let schema = [config::Field { key: "port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { key: "ratio", kind: config::Kind.Float, float_min: 0.5, float_max: 2.0 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true },
                  config::Field { "optional", config::Kind.Boolean },
                  config::Field { key: "precise", kind: config::Kind.Integer, int_min: 9007199254740993, int_max: 9007199254740993 }];
    assert(config::init(schema, store).len == 0);
    assert(config::validate(store).len > 0);
    let missing, me = config::get_integer(store, "port"); assert(me.len > 0);
    let optional, ope = config::get_boolean(store, "optional"); assert(ope.len > 0);
    let missing_source, mse = config::source(store, "name"); assert(mse.len > 0);
    assert(put(store, "port", "1").len == 0);
    assert(config::validate(store).len > 0);
    assert(put(store, "name", "").len == 0);
    assert(config::validate(store).len == 0);
    text(store, "name", "");
    assert(put(store, "port", "65535").len == 0);
    assert(put(store, "port", "0").len > 0);
    assert(put(store, "port", "65536").len > 0);
    integer(store, "port", 65535);
    assert(put(store, "ratio", "0.5").len == 0);
    assert(put(store, "ratio", "2.0").len == 0);
    assert(put(store, "ratio", "0.4999999999999999").len > 0);
    assert(put(store, "ratio", "2.000000000000001").len > 0);
    floating(store, "ratio", 2.0);
    assert(put(store, "precise", "9007199254740993").len == 0);
    assert(put(store, "precise", "9007199254740992").len > 0);
    assert(put(store, "precise", "9007199254740994").len > 0);
    integer(store, "precise", 9007199254740993);
    let wrong_text, wte = config::get_text(store, "port"); assert(wte.len > 0);
    let wrong_int, wie = config::get_integer(store, "name"); assert(wie.len > 0);
    let wrong_float, wfe = config::get_float(store, "port"); assert(wfe.len > 0);
    let wrong_bool, wbe = config::get_boolean(store, "port"); assert(wbe.len > 0);
    let unknown, une = config::get_integer(store, "PORT"); assert(une.len > 0);
    assert(put(store, "PORT", "80").len > 0);
}

fn schema_and_ownership() {
    var store = config::Store { .. };
    {
        var key = str("name");
        let schema = [config::Field { key: key, kind: config::Kind.Text, required: true }];
        assert(config::init(schema, store).len == 0);
        key[0] = 'X';
    }
    {
        var key = str("name"); var value = str("hello 😀\n"); var source = str("APP_NAME");
        assert(put(store, key, value, source).len == 0);
        key[0] = 'X'; value[0] = 'X'; source[0] = 'X';
    }
    text(store, "name", "hello 😀\n"); origin(store, "name", "APP_NAME");
    let invalid_keys = ["", ".name", "name.", "a..b", "a b", "a/b", "a\\b", "a\n", "é", "a\x00"];
    for key in invalid_keys {
        let schema = [config::Field { key, config::Kind.Text }];
        assert(config::init(schema, store).len > 0);
        text(store, "name", "hello 😀\n"); origin(store, "name", "APP_NAME");
        assert(config::validate(store).len == 0);
    }
    let duplicates = [config::Field { "a", config::Kind.Integer }, config::Field { "a", config::Kind.Text }];
    assert(config::init(duplicates, store).len > 0);
    let prefixes = [config::Field { "a", config::Kind.Integer }, config::Field { "a.b", config::Kind.Text }];
    assert(config::init(prefixes, store).len > 0);
    let reverse = [config::Field { "a.b", config::Kind.Integer }, config::Field { "a", config::Kind.Text }];
    assert(config::init(reverse, store).len > 0);
    let invalid_int_range = [config::Field { key: "a", kind: config::Kind.Integer, int_min: 2, int_max: 1 }];
    assert(config::init(invalid_int_range, store).len > 0);
    let invalid_float_range = [config::Field { key: "a", kind: config::Kind.Float, float_min: 2.0, float_max: 1.0 }];
    assert(config::init(invalid_float_range, store).len > 0);
    let infinite_range = [config::Field { key: "a", kind: config::Kind.Float, float_max: 1.0 / 0.0 }];
    assert(config::init(infinite_range, store).len > 0);
    let nan_range = [config::Field { key: "a", kind: config::Kind.Float, float_min: 0.0 / 0.0 }];
    assert(config::init(nan_range, store).len > 0);
    text(store, "name", "hello 😀\n"); origin(store, "name", "APP_NAME");
    let replacement = [config::Field { "new.key-1_A", config::Kind.Integer }, config::Field { "ab", config::Kind.Text }, config::Field { "a.b", config::Kind.Boolean }];
    assert(config::init(replacement, store).len == 0);
    assert(config::validate(store).len == 0);
    let erased, ee = config::get_text(store, "name"); assert(ee.len > 0);
    let absent, ae = config::get_integer(store, "new.key-1_A"); assert(ae.len > 0);
    assert(put(store, "new.key-1_A", "7").len == 0);
    integer(store, "new.key-1_A", 7);
    let empty: config::Field[0] = [];
    assert(config::init(empty, store).len == 0);
    assert(config::validate(store).len == 0);
    let erased_again, eae = config::get_integer(store, "new.key-1_A"); assert(eae.len > 0);
}

fn transactional_layers() {
    var store = config::Store { .. };
    let schema = [config::Field { "name", config::Kind.Text }, config::Field { "count", config::Kind.Integer }];
    assert(config::init(schema, store).len == 0);
    let defaults = [config::Override { "name", "default", "defaults" }, config::Override { "count", "1", "defaults" }];
    assert(config::apply(store, defaults).len == 0);
    let env = [config::Override { "count", "2", "APP_COUNT" }];
    assert(config::apply(store, env).len == 0);
    text(store, "name", "default"); origin(store, "name", "defaults"); integer(store, "count", 2); origin(store, "count", "APP_COUNT");
    let unknown = [config::Override { "name", "changed", "cli" }, config::Override { "unknown", "9", "cli" }];
    assert(config::apply(store, unknown).len > 0);
    let duplicate = [config::Override { "name", "changed", "cli" }, config::Override { "name", "again", "cli" }];
    assert(config::apply(store, duplicate).len > 0);
    let invalid = [config::Override { "name", "changed", "cli" }, config::Override { "count", "SECRET", "cli" }];
    let error = config::apply(store, invalid);
    assert(error.len > 0 && find(error, "SECRET") < 0);
    text(store, "name", "default"); origin(store, "name", "defaults"); integer(store, "count", 2); origin(store, "count", "APP_COUNT");
    let empty: config::Override[0] = [];
    assert(config::apply(store, empty).len == 0);
    text(store, "name", "default"); origin(store, "count", "APP_COUNT");
    for i in 1000 {
        let value = str(i);
        assert(put(store, "count", value, "loop").len == 0);
        integer(store, "count", i); origin(store, "count", "loop");
    }
    text(store, "name", "default"); origin(store, "name", "defaults");
    assert(put(store, "name", "", "cli").len == 0);
    text(store, "name", ""); origin(store, "name", "cli");
}

fn limits_and_diagnostics() {
    var store = config::Store { .. };
    var key = repeated('a', config::MAX_KEY_BYTES);
    let schema = [config::Field { key, config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    var value = repeated('x', config::MAX_VALUE_BYTES);
    var source = repeated('s', config::MAX_SOURCE_BYTES);
    assert(put(store, key, value, source).len == 0);
    text(store, key, value); origin(store, key, source);
    var long_source = repeated('s', config::MAX_SOURCE_BYTES + 1);
    assert(put(store, key, "changed", long_source).len > 0);
    var long_value = repeated('x', config::MAX_VALUE_BYTES + 1);
    assert(put(store, key, long_value, "changed").len > 0);
    text(store, key, value); origin(store, key, source);
    var long_key = repeated('a', config::MAX_KEY_BYTES + 1);
    let long_schema = [config::Field { long_key, config::Kind.Text }];
    assert(config::init(long_schema, store).len > 0);
    assert(put(store, long_key, "changed").len > 0);
    text(store, key, value); origin(store, key, source);
    // Keys and source labels are escaped; a secret value is never echoed.
    let diagnostic = put(store, "bad\nkey\x1b'\\", "DO-NOT-PRINT", "env\r\n\x1b'\\");
    assert(diagnostic.len > 0 && find(diagnostic, "DO-NOT-PRINT") < 0);
    assert(find(diagnostic, "\\x0a") >= 0 && find(diagnostic, "\\x1b") >= 0);
    assert(find(diagnostic, "\\x27") >= 0 && find(diagnostic, "\\x5c") >= 0);
    for c in diagnostic { assert(c >= 32 && c <= 126); }
    let huge_label = repeated(0xff, 100000);
    let bounded = put(store, huge_label, "DO-NOT-PRINT", huge_label);
    assert(bounded.len < 2200 && find(bounded, "DO-NOT-PRINT") < 0);
    for c in bounded { assert(c >= 32 && c <= 126); }
    text(store, key, value); origin(store, key, source);
}

fn count_limits() {
    var store = config::Store { .. };
    var keys: u8[4][257] = [['k', '0', '0', '0']; 257];
    let digits = "0123456789";
    for i in keys.len {
        keys[i][1] = digits[i / 100]; keys[i][2] = digits[(i / 10) % 10]; keys[i][3] = digits[i % 10];
    }
    var schema:    config::Field[>..]    = [];
    var overrides: config::Override[>..] = [];
    for i in config::MAX_FIELDS {
        schema.push(config::Field { keys[i], config::Kind.Integer });
        overrides.push(config::Override { keys[i], "42", "all-fields" });
    }
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, overrides).len == 0);
    for i in config::MAX_FIELDS { integer(store, keys[i], 42); origin(store, keys[i], "all-fields"); }
    schema.push(config::Field { keys[256], config::Kind.Integer });
    overrides.push(config::Override { keys[256], "99", "oversized" });
    assert(config::init(schema, store).len > 0);
    assert(config::apply(store, overrides).len > 0);
    for i in config::MAX_FIELDS { integer(store, keys[i], 42); origin(store, keys[i], "all-fields"); }
}
fn main() {
    numbers(); constraints_and_access(); schema_and_ownership(); transactional_layers(); limits_and_diagnostics(); count_limits();
    permuted_layers();
    print("behavior: OK");
}

fn permuted_layers() {
    var keys:  u8[4][256] = [['k', '0', '0', '0']; 256];
    var texts: u8[3][256] = [['0', '0', '0']; 256];
    let digits = "0123456789";
    for i in 256 {
        keys[i][1] = digits[i / 100]; keys[i][2] = digits[(i / 10) % 10]; keys[i][3] = digits[i % 10];
        texts[i][0] = keys[i][1]; texts[i][1] = keys[i][2]; texts[i][2] = keys[i][3];
    }
    var schema: config::Field[>..] = [];
    for i in 256 { schema.push(config::Field { keys[i], config::Kind.Integer }); }
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var layer: config::Override[>..] = [];
    for j in 256 {
        let i = (j * 17 + 79) % 256;
        layer.push(config::Override { keys[i], texts[i], texts[i] });
    }
    assert(config::apply(store, layer).len == 0);
    for i in 256 {
        let value, err = config::get_integer(store, keys[i]);
        let source, se = config::source(store, keys[i]);
        assert(err.len == 0 && se.len == 0 && value == i && source == texts[i]);
    }
    var other: config::Override[>..] = [];
    for i in 256 { if i % 2 == 1 { other.push(config::Override { keys[i], "-42", "changed" }); } }
    assert(config::apply(store, other).len == 0);
    for i in 256 {
        let value, err = config::get_integer(store, keys[i]);
        let source, se = config::source(store, keys[i]);
        assert(err.len == 0 && se.len == 0);
        assert(value == (if i % 2 == 1 { -42 } else { i }));
        assert(source == (if i % 2 == 1 { "changed" } else { texts[i] }));
    }
    print("permuted 256-field map and sparse updates passed");
}
