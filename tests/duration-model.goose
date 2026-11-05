// SPDX-License-Identifier: Apache-2.0
// Token, JSON, TOML as hex; '-' skips a document for non-UTF8 raw tokens.
import config from "..";
import config.reload;
import std;
import os;
fn duration_hex(c: u8) -> u8 {
    if c >= '0' && c <= '9' { return c - '0'; }
    assert(c >= 'a' && c <= 'f'); c - 'a' + 10
}
fn duration_decode(text: const u8[:], out: u8[>..]&) {
    assert(text.len % 2 == 0);
    for i in text.len / 2 { out.push(duration_hex(text[i * 2]) * 16 + duration_hex(text[i * 2 + 1])); }
}
fn duration_snapshot(store: config::Store&, label: const u8[:], accepted: bool) {
    let value, error = config::get_duration(store, "delay");
    let source, issue = config::source(store, "delay");
    assert(error.len == 0 && issue.len == 0);
    print(label, " ", accepted, " ", value.nanoseconds, " ", source);
}
fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { "delay", config::Kind.Duration }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "delay", "1ns", "seed" }]).len == 0);
    var line: u8[>..] = [];
    while read_line(line) {
        let parts = split(line, '\t'); assert(parts.len == 3);
        var token: u8[>..] = []; duration_decode(parts[0], token);
        let parsed, error = config::parse_duration(token);
        if error.len == 0 { print("P ", parsed.nanoseconds); } else { print("P error"); }
        let applied = config::apply(store, [config::Override { "delay", token, "override" }]);
        duration_snapshot(store, "O", applied.len == 0);
        for i in 1..3 {
            let label = if i == 1 { "J" } else { "T" };
            if parts[i] == "-" { print(label, " skipped"); continue; }
            var document: u8[>..] = []; duration_decode(parts[i], document);
            var issue:    u8[>..] = [];
            if i == 1 { issue = config::apply_json(store, document, "json"); }
            else { issue = config::apply_toml(store, document, "toml"); }
            duration_snapshot(store, label, issue.len == 0);
        }
        line.clear();
    }
}
