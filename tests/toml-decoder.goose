// SPDX-License-Identifier: Apache-2.0
// Test-only adapter for the official toml-test tagged JSON protocol.
import config from "..";
import config.toml;
import std;
import json;
import os;
fn tag(out: u8[>..]&, name: u8[:], value: u8[:]) {
    out.append("{\"type\":"); json::format_string(out, name);
    out.append(",\"value\":"); json::format_string(out, value); out.push('}');
}
recursive fn encode(doc: config_toml::Document&, id: i64, out: u8[>..]&) {
    let n = doc.nodes[id];
    if n.kind == config_toml::Kind.Table || n.kind == config_toml::Kind.Array {
        let table = n.kind == config_toml::Kind.Table;
        out.push(if table { '{' } else { '[' });
        var child = n.first;
        while child >= 0 {
            if child != n.first { out.push(','); }
            if table { json::format_key(out, config_toml::key(doc, child)); }
            encode(doc, child, out);
            child = doc.nodes[child].next;
        }
        out.push(if table { '}' } else { ']' });
    } else if n.kind == config_toml::Kind.String { tag(out, "string", config_toml::text(doc, id)); }
    else if n.kind == config_toml::Kind.Integer { tag(out, "integer", str(n.integer)); }
    else if n.kind == config_toml::Kind.Boolean { tag(out, "bool", if n.boolean { "true" } else { "false" }); }
    else if n.kind == config_toml::Kind.Float {
        var value: u8[>..] = [];
        if n.number != n.number { value.append("nan"); }
        else if n.number > 1.7976931348623157e308 { value.append("inf"); }
        else if n.number < -1.7976931348623157e308 { value.append("-inf"); }
        else { json::format_number(value, n.number); }
        tag(out, "float", value);
    } else {
        var value = str(config_toml::text(doc, id));
        for &c in value { if c == 't' || c == ' ' { c = 'T'; } else if c == 'z' { c = 'Z'; } }
        if n.kind == config_toml::Kind.OffsetDateTime { tag(out, "datetime", value); }
        else if n.kind == config_toml::Kind.LocalDateTime { tag(out, "datetime-local", value); }
        else if n.kind == config_toml::Kind.LocalDate { tag(out, "date-local", value); }
        else { tag(out, "time-local", value); }
    }
}
fn main() {
    var source: u8[>..] = [];
    read_stdin(source);
    var doc = config_toml::Document { .. };
    let error = config_toml::parse_into(source, doc);
    if error.len > 0 { write_stderr(error); write_stderr("\n"); exit(1); }
    var out: u8[>..] = [];
    encode(doc, 0, out);
    write_stdout(out); write_stdout("\n");
}
