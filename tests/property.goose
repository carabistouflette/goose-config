// SPDX-License-Identifier: Apache-2.0
// Test-only line protocol. Each request is R + hex key/value/source triples,
// or T + hex TOML/source. Every response includes the complete persistent state.
import config from "..";
import config.toml;
import std;
import os;
import json;

struct Segment { start: i64, len: i64 }
fn digit(c: u8) -> u8 {
    if c >= '0' && c <= '9' { return c - '0'; }
    assert(c >= 'a' && c <= 'f');
    return c - 'a' + 10;
}
fn decode(text: const u8[:], bytes: u8[>..]&) -> Segment {
    assert(text.len % 2 == 0);
    let result = Segment { bytes.len, text.len / 2 };
    for i in result.len { bytes.push(digit(text[i * 2]) * 16 + digit(text[i * 2 + 1])); }
    return result;
}
fn slice(bytes: const u8[:], segment: Segment) -> const u8[:] { bytes[segment.start..segment.start + segment.len] }
fn hex(out: u8[>..]&, text: const u8[:]) {
    let digits = "0123456789abcdef";
    out.push('"');
    for c in text { out.push(digits[c / 16]); out.push(digits[c % 16]); }
    out.push('"');
}
fn provenance(store: config::Store&, key: const u8[:], out: u8[>..]&) {
    let source, error = config::source(store, key); assert(error.len == 0);
    out.push(','); hex(out, source); out.push(']');
}
fn snapshot(store: config::Store&, ok: bool) {
    var out = str("{\"ok\":", if ok { "true" } else { "false" });
    out.append(",\"i\":");
    let i, ie = config::get_integer(store, "i");
    if ie.len > 0 { out.append("null"); }
    else { out.push('['); format(out, i); provenance(store, "i", out); }
    out.append(",\"f\":");
    let f, fe = config::get_float(store, "f");
    if fe.len > 0 { out.append("null"); }
    else { out.push('['); json::format_number(out, f); provenance(store, "f", out); }
    out.append(",\"b\":");
    let b, be = config::get_boolean(store, "b");
    if be.len > 0 { out.append("null"); }
    else { out.push('['); out.append(if b { "true" } else { "false" }); provenance(store, "b", out); }
    out.append(",\"s\":");
    let s, se = config::get_text(store, "s");
    if se.len > 0 { out.append("null"); }
    else { out.push('['); hex(out, s); provenance(store, "s", out); }
    out.append("}\n"); write_stdout(out);
}
fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "i", kind: config::Kind.Integer, int_min: -1000, int_max: 1000 },
                  config::Field { key: "f", kind: config::Kind.Float, float_min: -1000.0, float_max: 1000.0 },
                  config::Field { "b", config::Kind.Boolean }, config::Field { "s", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    var line: u8[>..] = [];
    while read_line(line) {
        let parts = split(line, '\t');
        assert(parts.len >= 1);
        var bytes:    u8[>..]      = [];
        var segments: Segment[>..] = [];
        for i in 1..parts.len { segments.push(decode(parts[i], bytes)); }
        if parts[0] == "R" {
            assert(segments.len % 3 == 0);
            var inputs: config::Override[>..] = [];
            for i in segments.len / 3 {
                inputs.push(config::Override { slice(bytes, segments[i * 3]), slice(bytes, segments[i * 3 + 1]), slice(bytes, segments[i * 3 + 2]) });
            }
            let error = config::apply(store, inputs);
            snapshot(store, error.len == 0);
        } else {
            assert(parts[0] == "T" && segments.len == 2);
            let error = config::apply_toml(store, slice(bytes, segments[0]), slice(bytes, segments[1]));
            snapshot(store, error.len == 0);
        }
        line.clear();
    }
}
