// SPDX-License-Identifier: Apache-2.0
// Test-only protocol for persistent stores with replaceable nested schemas.
// S: key/kind/required triples; R: key/value/source triples; T: TOML/source;
// V: required validation; Q: typed value plus provenance (or null on failure).
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
fn slice(bytes: const u8[:], segment: Segment) -> const u8[:] {
    bytes[segment.start..segment.start + segment.len]
}
fn hex(out: u8[>..]&, text: const u8[:]) {
    let digits = "0123456789abcdef";
    out.push('"');
    for c in text { out.push(digits[c / 16]); out.push(digits[c % 16]); }
    out.push('"');
}
fn decode_kind(text: const u8[:]) -> config::Kind {
    if text == "i" { return config::Kind.Integer; }
    if text == "f" { return config::Kind.Float; }
    if text == "b" { return config::Kind.Boolean; }
    assert(text == "s");
    return config::Kind.Text;
}
fn query(store: config::Store&, key: const u8[:], kind: const u8[:]) {
    var out:   u8[>..] = [];
    var error: u8[>..] = [];
    if kind == "i" {
        let value, failure = config::get_integer(store, key); error.append(failure);
        if error.len == 0 { format(out, value); }
    } else if kind == "f" {
        let value, failure = config::get_float(store, key); error.append(failure);
        if error.len == 0 { json::format_number(out, value); }
    } else if kind == "b" {
        let value, failure = config::get_boolean(store, key); error.append(failure);
        if error.len == 0 { out.append(if value { "true" } else { "false" }); }
    } else {
        assert(kind == "s");
        let value, failure = config::get_text(store, key); error.append(failure);
        if error.len == 0 { hex(out, value); }
    }
    if error.len > 0 { print("null"); return; }
    let source, source_error = config::source(store, key); assert(source_error.len == 0);
    var result: u8[>..] = [];
    result.push('['); result.append(out); result.push(','); hex(result, source); result.append("]\n");
    write_stdout(result);
}
fn main() {
    var store = config::Store { .. };
    var line: u8[>..] = [];
    while read_line(line) {
        let parts = split(line, '\t');
        assert(parts.len >= 1);
        var bytes:    u8[>..]      = [];
        var segments: Segment[>..] = [];
        for i in 1..parts.len { segments.push(decode(parts[i], bytes)); }
        var error: u8[>..] = [];
        if parts[0] == "S" {
            assert(segments.len % 3 == 0);
            var fields: config::Field[>..] = [];
            for i in segments.len / 3 {
                fields.push(config::Field {
                    key:      slice(bytes, segments[i * 3]), kind: decode_kind(slice(bytes, segments[i * 3 + 1])),
                    required: slice(bytes, segments[i * 3 + 2]) == "1",
                    int_min:  -1000, int_max: 1000, float_min: -1000.0, float_max: 1000.0,
                });
            }
            error = config::init(fields, store);
        } else if parts[0] == "R" {
            assert(segments.len % 3 == 0);
            var inputs: config::Override[>..] = [];
            for i in segments.len / 3 {
                inputs.push(config::Override { slice(bytes, segments[i * 3]), slice(bytes, segments[i * 3 + 1]), slice(bytes, segments[i * 3 + 2]) });
            }
            error = config::apply(store, inputs);
        } else if parts[0] == "T" {
            assert(segments.len == 2);
            error = config::apply_toml(store, slice(bytes, segments[0]), slice(bytes, segments[1]));
        } else if parts[0] == "V" {
            assert(segments.len == 0);
            error = config::validate(store);
        } else {
            assert(parts[0] == "Q" && segments.len == 2);
            query(store, slice(bytes, segments[0]), slice(bytes, segments[1]));
            line.clear(); continue;
        }
        print(if error.len == 0 { "true" } else { "false" });
        line.clear();
    }
}
