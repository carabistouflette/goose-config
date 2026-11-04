// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;

fn reject(store: config::Store&, head: config::Field[:], expected: const u8[:]) {
    var fields: config::Field[>..] = [];
    fields.append(head);
    let padding = ["pad0", "pad1", "pad2", "pad3", "pad4", "pad5", "pad6", "pad7", "pad8"];
    for key in padding { fields.push(config::Field { key, config::Kind.Text }); }
    let error = config::init(fields, store);
    assert(error == expected);
    let value, ve = config::get_text(store, "sentinel");
    let source, se = config::source(store, "sentinel");
    assert(ve.len == 0 && se.len == 0 && value == "unchanged" && source == "old");
}
fn main() {
    var store = config::Store { .. };
    assert(config::init([config::Field { "sentinel", config::Kind.Text }], store).len == 0);
    assert(config::apply(store, [config::Override { "sentinel", "unchanged", "old" }]).len == 0);
    let a = config::Field { "a", config::Kind.Text };
    let child = config::Field { "a.b", config::Kind.Text };
    let distractor = config::Field { "a-", config::Kind.Text };
    let bad = config::Field { "bad..key", config::Kind.Text };
    let range = config::Field { key: "range", kind: config::Kind.Integer, int_min: 1, int_max: 0 };
    reject(store, [a, distractor, child], "config: duplicate or conflicting schema key [key='a.b', source='']");
    reject(store, [child, distractor, a, bad], "config: duplicate or conflicting schema key [key='a', source='']");
    reject(store, [bad, a, child], "config: invalid schema key [key='bad..key', source='']");
    reject(store, [a, child, range], "config: duplicate or conflicting schema key [key='a.b', source='']");
    reject(store, [range, a, child], "config: invalid numeric range [key='range', source='']");
    reject(store, [a, a, bad], "config: duplicate or conflicting schema key [key='a', source='']");

    // Literal prefixes without a dot boundary are distinct settings. This valid
    // chain reaches the exact 256-ID bound of the ancestor-validation stack.
    var original: u8[256]            = ['a'; 256];
    var fields:   config::Field[>..] = [];
    for i in 256 { fields.push(config::Field { original[..i + 1], config::Kind.Integer }); }
    assert(config::init(fields, store).len == 0);
    original[0] = 'z';
    var query:     u8[256]               = ['a'; 256];
    var overrides: config::Override[>..] = [];
    for i in 256 { overrides.push(config::Override { query[..i + 1], "17", "chain" }); }
    assert(config::apply(store, overrides).len == 0);
    for i in 256 {
        let value, ve = config::get_integer(store, query[..i + 1]);
        let source, se = config::source(store, query[..i + 1]);
        assert(ve.len == 0 && se.len == 0 && value == 17 && source == "chain");
    }
    print("schema conflict precedence and raw-prefix boundary tests passed");
}
