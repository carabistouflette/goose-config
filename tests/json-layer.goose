// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.json_layer;
import json;
import std;

// An adapter must not depend on the standard JSON reader's overloadable
// diagnostic builder, or consumer builder/numeric convenience overloads.
fn str(a: const u8[:]) -> u8[>..] { [] }
fn str(a: const u8[:], b: const u8[:]) -> u8[>..] { [] }
fn copy(a: u8[>..]&) -> u8[>..] { [] }
fn parse_int(text: const u8[:]) -> i64, bool { return 17, true; }
fn parse_int(text: u8[>..]&, base: i64) -> i64, bool { return 17, true; }
fn parse_flt(text: u8[>..]&) -> f64, bool { return 17.0, true; }
fn finite(value: f64) -> bool { true }
fn json_string(text: const u8[:]) -> bool { true }

fn main() {
    var formatted: u8[>..] = []; json::format_number(formatted, 1.5); assert(formatted == "1.5");
    var store = config::Store { .. };
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, int_min: 1, int_max: 65535 },
                  config::Field { "name", config::Kind.Text }, config::Field { "debug", config::Kind.Boolean },
                  config::Field { "ratio", config::Kind.Float }, config::Field { "tags", config::Kind.TextList },
                  config::Field { key: "numbers", kind: config::Kind.IntegerList, int_min: -5, int_max: 5 },
                  config::Field { "ratios", config::Kind.FloatList }, config::Field { "flags", config::Kind.BooleanList }];
    assert(config::init(schema, store).len == 0);
    let initial = "{\"server\":{\"port\":8080},\"name\":\"goose\",\"debug\":true,\"ratio\":1.5,\"tags\":[\"one\",\"two\"],\"numbers\":[-5,0,5],\"ratios\":[1.0,-5e-324],\"flags\":[true,false]}";
    assert(config::apply_json(store, initial, "app.json").len == 0);
    let port, pe = config::get_integer(store, "server.port"); assert(pe.len == 0 && port == 8080);
    let debug, de = config::get_boolean(store, "debug"); assert(de.len == 0 && debug);
    let ratio, re = config::get_float(store, "ratio"); assert(re.len == 0 && ratio == 1.5);
    let tags, te = config::get_text_list(store, "tags"); assert(te.len == 0 && tags.len == 2); var tag_index = 0; for tag in tags { assert(tag == (if tag_index == 0 { "one" } else { "two" })); tag_index++; }
    let integers, ie = config::get_integer_list(store, "numbers"); assert(ie.len == 0 && integers.len == 3 && integers[0] == -5 && integers[2] == 5);
    let ratios, rse = config::get_float_list(store, "ratios"); assert(rse.len == 0 && ratios.len == 2 && ratios[1] == -5e-324);
    let flags, fe = config::get_boolean_list(store, "flags"); assert(fe.len == 0 && flags.len == 2 && flags[0] && !flags[1]);
    let invalid = ["", "[]", "null", "42", "{}x", "{", "{\"name\":\"x\",}", "{\"name\":null}",
                   "{\"name\":1}", "{\"name\":[\"x\"]}", "{\"ratio\":1}", "{\"ratio\":1e99999}", "{\"ratio\":NaN}",
                   "{\"server\":{\"port\":1.0}}", "{\"server\":{\"port\":1e0}}", "{\"server\":{\"port\":0}}",
                   "{\"server.port\":1}", "{\"unknown\":{}}", "{\"server\":{\"unknown\":{}}}",
                   "{\"server\":{},\"server\":{\"port\":9}}", "{\"name\":\"x\",\"na\\u006de\":\"y\"}",
                   "{\"name\":\"changed\",\"numbers\":[6]}", "{\"numbers\":[1,2.0]}", "{\"numbers\":[1,true]}",
                   "{\"numbers\":[{}]}", "{\"numbers\":[[]]}", "{\"numbers\":[null]}", "{\"numbers\":[1,]}",
                   "{\"name\":\"changed\",\"tags\":[\"x\",false]}", "{\"numbers\":1}", "{\"ratios\":[1]}", "{\"ratios\":[1e99999]}",
                   "{\"debug\":truex}", "{\"ratio\":01.0}", "{\"ratio\":+1.0}", "{\"ratio\":.1}",
                   "{\"ratio\":1.}", "{\"ratio\":1e}", "{\"ratio\":1e+}", "{\"ratio\":--1.0}",
                   "{\"name\":\"\\uD800\"}", "{\"name\":\"\\uDC00\"}", "{\"name\":\"\\uD800\\u0000\"}",
                   "{\"name\":\"\\x41\"}", "{\"name\":\"line\nfeed\"}", "{\"na\\u0000me\":\"x\"}"];
    for document in invalid {
        assert(config::apply_json(store, document, "bad.json").len > 0);
        let name, ne = config::get_text(store, "name"); assert(ne.len == 0 && name == "goose");
        let origin, oe = config::source(store, "name"); assert(oe.len == 0 && origin == "app.json");
        let previous, pre = config::get_integer_list(store, "numbers"); assert(pre.len == 0 && previous.len == 3 && previous[2] == 5);
    }
    assert(config::apply_json(store, "{}", "empty").len == 0);
    assert(config::apply_json(store, "{\"server\":{}}", "known empty").len == 0);
    assert(config::apply_json(store, "{\"tags\":[],\"numbers\":[]}", "empty lists").len == 0);
    let empty, ee = config::get_text_list(store, "tags"); assert(ee.len == 0 && empty.len == 0);
    let empty_source, ese = config::source(store, "tags"); assert(ese.len == 0 && empty_source == "empty lists");
    assert(config::apply_json(store, "{\"na\\u006de\":\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000\\u00e9\\ud83d\\ude00\"}", "escapes").len == 0);
    let escaped, e = config::get_text(store, "name");
    var expected: u8[>..] = []; expected.append("\"\\/"); expected.push(8); expected.push(12); expected.append("\n\r\t"); expected.push(0); expected.append("é😀");
    assert(e.len == 0 && escaped == expected);
    precision(); boundaries(); resource_nodes(); duplicate_branches(); ownership();
    print("json: OK");
}
fn precision() {
    var store = config::Store { .. };
    let schema = [config::Field { "i", config::Kind.Integer }, config::Field { "f", config::Kind.Float }, config::Field { "items", config::Kind.IntegerList }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_json(store, "{\"i\":9223372036854775807,\"items\":[9007199254740993,-9223372036854775808,9223372036854775807],\"f\":1.7976931348623157e308}", "exact").len == 0);
    let maximum, me = config::get_integer(store, "i"); assert(me.len == 0 && maximum == 9223372036854775807);
    let exact, ee = config::get_integer_list(store, "items"); assert(ee.len == 0 && exact[0] == 9007199254740993 && exact[1] == -9223372036854775808 && exact[2] == 9223372036854775807);
    let largest, le = config::get_float(store, "f"); assert(le.len == 0 && largest == 1.7976931348623157e308);
    assert(config::apply_json(store, "{\"i\":-9223372036854775808,\"f\":-5e-324}", "minimum").len == 0);
    let minimum, mi = config::get_integer(store, "i"); assert(mi.len == 0 && minimum == -9223372036854775808);
    let tiny, ti = config::get_float(store, "f"); assert(ti.len == 0 && tiny == -5e-324);
    let invalid = ["{\"i\":9223372036854775808}", "{\"i\":-9223372036854775809}", "{\"items\":[9223372036854775808]}", "{\"f\":1.7976931348623159e308}", "{\"i\":01}", "{\"i\":-01}"];
    for document in invalid { assert(config::apply_json(store, document, "bad").len > 0); }
}
fn boundaries() {
    var store = config::Store { .. };
    let schema = [config::Field { "text", config::Kind.Text }, config::Field { "tags", config::Kind.TextList }, config::Field { "n", config::Kind.Float }, config::Field { "items", config::Kind.IntegerList }];
    assert(config::init(schema, store).len == 0);
    var document: u8[>..] = []; document.append("{\"text\":\"");
    for i in config::MAX_VALUE_BYTES { document.push('x'); } document.append("\"}");
    assert(config::apply_json(store, document, "max text").len == 0);
    document.clear(); document.append("{\"text\":\"");
    for i in config::MAX_VALUE_BYTES + 1 { document.push('x'); } document.append("\"}");
    assert(config::apply_json(store, document, "too much text").len > 0);
    document.clear(); document.append("{\"text\":\"");
    for i in config::MAX_VALUE_BYTES { document.push('x'); } document.append("\",\"tags\":[\"x\"]}");
    assert(config::apply_json(store, document, "independent text limits").len == 0);
    let separate, ste = config::get_text_list(store, "tags");
    assert(ste.len == 0 && separate.len == 1);
    for value in separate { assert(value == "x"); }
    document.clear(); document.append("{\"tags\":[\"");
    for i in config::MAX_VALUE_BYTES { document.push('x'); }
    document.append("\",\"y\"]}");
    assert(config::apply_json(store, document, "list aggregate limit").len > 0);
    let retained, rte = config::get_text_list(store, "tags");
    assert(rte.len == 0 && retained.len == 1);
    for value in retained { assert(value == "x"); }
    document.clear(); document.append("{\"items\":[");
    for i in config::MAX_LIST_ITEMS { if i > 0 { document.push(','); } document.push('1'); } document.append("]}");
    assert(config::apply_json(store, document, "max list").len == 0);
    document.clear(); document.append("{\"items\":[");
    for i in config::MAX_LIST_ITEMS + 1 { if i > 0 { document.push(','); } document.push('1'); } document.append("]}");
    assert(config::apply_json(store, document, "too many items").len > 0);
    document.clear(); document.append("{\"n\":1.");
    for i in 126 { document.push('0'); } document.push('}');
    assert(config::apply_json(store, document, "max number").len == 0);
    document.clear(); document.append("{\"n\":1.");
    for i in 127 { document.push('0'); } document.push('}');
    assert(config::apply_json(store, document, "long number").len > 0);
    document.clear(); document.append("{}");
    while document.len < 1048576 { document.push(' '); }
    assert(config::apply_json(store, document, "max input").len == 0);
    document.push(' '); assert(config::apply_json(store, document, "large input").len > 0);
    let invalid_utf8 = [0xff, 0xc0, 0x80];
    for byte in invalid_utf8 {
        document.clear(); document.append("{\"text\":\""); document.push(byte as u8); document.append("\"}");
        assert(config::apply_json(store, document, "utf8").len > 0);
    }
    document.clear(); document.append("{\"text\":\""); document.push(0xed); document.push(0xa0); document.push(0x80); document.append("\"}");
    assert(config::apply_json(store, document, "surrogate utf8").len > 0);
    var label: u8[>..] = []; for i in config::MAX_SOURCE_BYTES { label.push('s'); }
    assert(config::apply_json(store, "{}", label).len == 0); label.push('s');
    assert(config::apply_json(store, "{}", label).len > 0);
    deep_and_keys();
}
fn deep_and_keys() {
    var key: u8[>..] = []; var document: u8[>..] = [];
    for i in 63 { if i > 0 { key.push('.'); } key.push('a'); document.append("{\"a\":"); }
    key.append(".v"); document.append("{\"v\":1"); for i in 64 { document.push('}'); }
    var store = config::Store { .. }; let schema = [config::Field { key, config::Kind.Integer }];
    assert(config::init(schema, store).len == 0);
    // Root plus 63 nested objects reaches depth 64; its scalar at 65 exceeds it.
    assert(config::apply_json(store, document, "too deep").len > 0);
    key.clear(); document.clear(); for i in 62 { if i > 0 { key.push('.'); } key.push('a'); document.append("{\"a\":"); }
    key.append(".v"); document.append("{\"v\":1"); for i in 63 { document.push('}'); }
    let accepted = [config::Field { key, config::Kind.Integer }]; assert(config::init(accepted, store).len == 0);
    assert(config::apply_json(store, document, "depth 64").len == 0);
    key.clear(); for i in config::MAX_KEY_BYTES { key.push('k'); }
    let long_schema = [config::Field { key, config::Kind.Text }]; assert(config::init(long_schema, store).len == 0);
    document.clear(); document.append("{\""); document.append(key); document.append("\":\"ok\"}");
    assert(config::apply_json(store, document, "max key").len == 0);
    document.clear(); document.append("{\""); document.append(key); document.append("k\":\"bad\"}");
    assert(config::apply_json(store, document, "long key").len > 0);
}
fn ownership() {
    var store = config::Store { .. }; let schema = [config::Field { "text", config::Kind.Text }, config::Field { "tags", config::Kind.TextList }];
    assert(config::init(schema, store).len == 0);
    var document: u8[>..] = []; document.append("{\"text\":\"owned\",\"tags\":[\"first\",\"second\"]}");
    var origin:   u8[>..] = []; origin.append("owned.json");
    assert(config::apply_json(store, document, origin).len == 0); document.clear(); origin.clear();
    let value, ve = config::get_text(store, "text"); assert(ve.len == 0 && value == "owned");
    let tags, te = config::get_text_list(store, "tags"); assert(te.len == 0 && tags.len == 2); for tag in tags { assert(tag == "first" || tag == "second"); }
    let source, se = config::source(store, "tags"); assert(se.len == 0 && source == "owned.json");
    assert(config::apply_json(store, "{\"tags\":[\"replacement\"]}", source).len == 0);
    var old_index = 0; for tag in tags { assert(tag == (if old_index == 0 { "first" } else { "second" })); old_index++; }
    let replacement, re = config::get_text_list(store, "tags"); assert(re.len == 0 && replacement.len == 1); for tag in replacement { assert(tag == "replacement"); }
    let inherited, ie = config::source(store, "tags"); assert(ie.len == 0 && inherited == "owned.json");
    let error = config::apply_json(store, "{\"text\":\"TOP_SECRET_VALUE\",\"unknown\":null}", "evil'\nlabel");
    assert(error == "config: invalid JSON document, type, key, or resource limit [key='', source='evil\\x27\\x0alabel']");
}

fn resource_nodes() {
    // 255 arrays of 256 scalars plus the root contain exactly 65,536 nodes.
    var key_bytes: u8[>..] = []; var key_spans: config::Span[>..] = [];
    for i in config::MAX_FIELDS {
        let start = key_bytes.len; key_bytes.push('k'); key_bytes.append(str(i));
        key_spans.push(config::Span { start, key_bytes.len - start });
    }
    var schema: config::Field[>..] = [];
    for span in key_spans { schema.push(config::Field { config::view(key_bytes, span), config::Kind.IntegerList }); }
    var store = config::Store { .. }; assert(config::init(schema, store).len == 0);
    var document: u8[>..] = []; document.push('{');
    for i in 255 {
        if i > 0 { document.push(','); }
        document.push('"'); document.append(config::view(key_bytes, key_spans[i])); document.append("\":[");
        for j in 256 { if j > 0 { document.push(','); } document.push('0'); }
        document.push(']');
    }
    document.push('}');
    assert(config::apply_json(store, document, "max nodes").len == 0);
    document.pop(); document.append(",\"k255\":[]}");
    assert(config::apply_json(store, document, "too many nodes").len > 0);
    let missing, missing_error = config::get_integer_list(store, "k255"); assert(missing_error.len > 0);
    // The maximum number of siblings is accepted when arrays are empty.
    document.clear(); document.push('{');
    for i in config::MAX_FIELDS {
        if i > 0 { document.push(','); }
        document.push('"'); document.append(config::view(key_bytes, key_spans[i])); document.append("\":[]");
    }
    document.push('}'); assert(config::apply_json(store, document, "max siblings").len == 0);
    document.pop(); document.append(",\"k0\":[]}");
    assert(config::apply_json(store, document, "too many siblings").len > 0);
    let present, present_error = config::get_integer_list(store, "k255"); assert(present_error.len == 0 && present.len == 0);
}

fn duplicate_branches() {
    var store = config::Store { .. };
    assert(config::apply_json(store, "{}", "uninitialized").len > 0);
    let schema = [config::Field { "a.x", config::Kind.Integer }, config::Field { "a.y", config::Kind.Integer }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_json(store, "{\"a\":{\"x\":3,\"y\":4}}", "initial").len == 0);
    assert(config::apply_json(store, "{\"a\":{\"x\":1},\"a\":{\"y\":2}}", "duplicates").len > 0);
    let x, xe = config::get_integer(store, "a.x"); let y, ye = config::get_integer(store, "a.y");
    assert(xe.len == 0 && ye.len == 0 && x == 3 && y == 4);
}
