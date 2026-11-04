// SPDX-License-Identifier: Apache-2.0
// J/T apply one document/source; R/V reload format/document/source triples.
// V makes i required. R and V replay exactly the supplied current sources.
import config from "..";
import config.toml;
import config.json_layer;
import config.reload;
import std;
import os;
import json;

struct Segment { start: i64, len: i64 }
fn digit(c: u8) -> u8 {
    if c >= '0' && c <= '9' { return c - '0'; }
    assert(c >= 'a' && c <= 'f');
    c - 'a' + 10
}
fn decode(text: const u8[:], bytes: u8[>..]&) -> Segment {
    assert(text.len % 2 == 0);
    let result = Segment { bytes.len, text.len / 2 };
    for i in result.len { bytes.push(digit(text[i * 2]) * 16 + digit(text[i * 2 + 1])); }
    result
}
fn slice(bytes: const u8[:], segment: Segment) -> const u8[:] { bytes[segment.start..segment.start + segment.len] }
fn hex(out: u8[>..]&, text: const u8[:]) {
    let digits = "0123456789abcdef";
    out.push('"');
    for c in text { out.push(digits[c / 16]); out.push(digits[c % 16]); }
    out.push('"');
}
fn missing(store: config::Store&, key: const u8[:], out: u8[>..]&) {
    let source, error = config::source(store, key); assert(error.len > 0);
    out.append("null");
}
fn provenance(store: config::Store&, key: const u8[:], out: u8[>..]&) {
    let source, error = config::source(store, key); assert(error.len == 0);
    out.push(','); hex(out, source); out.push(']');
}
fn snapshot(store: config::Store&, ok: bool) {
    var out = str("{\"ok\":", if ok { "true" } else { "false" });
    out.append(",\"i\":");
    let i, ie = config::get_integer(store, "i");
    if ie.len > 0 { missing(store, "i", out); }
    else { out.push('['); format(out, i); provenance(store, "i", out); }
    out.append(",\"s\":");
    let s, se = config::get_text(store, "s");
    if se.len > 0 { missing(store, "s", out); }
    else { out.push('['); hex(out, s); provenance(store, "s", out); }
    out.append(",\"is\":");
    let integers, integers_error = config::get_integer_list(store, "is");
    if integers_error.len > 0 { missing(store, "is", out); }
    else {
        out.append("[["); for value, index in integers { if index > 0 { out.push(','); } format(out, value); }
        out.push(']'); provenance(store, "is", out);
    }
    out.append(",\"ss\":");
    let texts, texts_error = config::get_text_list(store, "ss");
    if texts_error.len > 0 { missing(store, "ss", out); }
    else {
        out.append("[["); var index = 0;
        for value in texts { if index > 0 { out.push(','); } hex(out, value); index++; }
        out.push(']'); provenance(store, "ss", out);
    }
    out.append(",\"fs\":");
    let floats, floats_error = config::get_float_list(store, "fs");
    if floats_error.len > 0 { missing(store, "fs", out); }
    else {
        out.append("[["); for value, index in floats { if index > 0 { out.push(','); } json::format_number(out, value); }
        out.push(']'); provenance(store, "fs", out);
    }
    out.append(",\"bs\":");
    let booleans, booleans_error = config::get_boolean_list(store, "bs");
    if booleans_error.len > 0 { missing(store, "bs", out); }
    else {
        out.append("[["); for value, index in booleans { if index > 0 { out.push(','); } out.append(if value { "true" } else { "false" }); }
        out.push(']'); provenance(store, "bs", out);
    }
    out.append("}\n"); write_stdout(out);
}
fn main() {
    var schema = [config::Field { key: "i", kind: config::Kind.Integer, int_min: -1000, int_max: 1000 },
                  config::Field { "s", config::Kind.Text },
                  config::Field { key: "is", kind: config::Kind.IntegerList, int_min: -1000, int_max: 1000 },
                  config::Field { "ss", config::Kind.TextList }, config::Field { "fs", config::Kind.FloatList },
                  config::Field { "bs", config::Kind.BooleanList }];
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var line: u8[>..] = [];
    while read_line(line) {
        let parts = split(line, '\t'); assert(parts.len > 0);
        var bytes: u8[>..] = []; var segments: Segment[>..] = [];
        for i in 1..parts.len { segments.push(decode(parts[i], bytes)); }
        var error: u8[>..] = [];
        if parts[0] == "J" || parts[0] == "T" {
            assert(segments.len == 2);
            let document = slice(bytes, segments[0]); let source = slice(bytes, segments[1]);
            if parts[0] == "J" { error = config::apply_json(store, document, source); }
            else { error = config::apply_toml(store, document, source); }
        } else {
            assert((parts[0] == "R" || parts[0] == "V") && segments.len % 3 == 0);
            schema[0].required = parts[0] == "V";
            var layers: config::Layer[>..] = [];
            for i in segments.len / 3 {
                let kind = slice(bytes, segments[i * 3]); assert(kind == "J" || kind == "T");
                layers.push(config::Layer { kind: if kind == "J" { config::LayerKind.Json } else { config::LayerKind.Toml },
                                            text: slice(bytes, segments[i * 3 + 1]), source: slice(bytes, segments[i * 3 + 2]), .. });
            }
            error = config::reload(schema, layers, store);
        }
        snapshot(store, error.len == 0); line.clear();
    }
}
