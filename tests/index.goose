// SPDX-License-Identifier: Apache-2.0
// Exercise lookup through public APIs with shuffled declaration/application
// orders, variable key lengths, shared prefixes, and both sides of the cutoff.
import config from "..";
import std;
fn exercise(store: config::Store&, count: i64, prefix_bytes: i64, varied: bool) {
    var keys: u8[..256][256] = [[]; 256];
    let digits = "0123456789";
    for i in count {
        let length = if varied { i % 9 } else { prefix_bytes };
        for j in length { keys[i].push('a'); }
        keys[i].push(digits[i / 100]); keys[i].push(digits[(i / 10) % 10]); keys[i].push(digits[i % 10]);
    }
    var schema: config::Field[>..] = [];
    for j in count { schema.push(config::Field { key: keys[count - j - 1], kind: config::Kind.Integer, required: true }); }
    assert(config::init(schema, store).len == 0);
    if count > 0 { assert(config::validate(store).len > 0); }
    var tokens: u8[3][256] = [['0', '0', '0']; 256];
    for i in count { tokens[i][0] = digits[i / 100]; tokens[i][1] = digits[(i / 10) % 10]; tokens[i][2] = digits[i % 10]; }
    var layer: config::Override[>..] = [];
    for j in count {
        let i = (j * 17) % count;
        layer.push(config::Override { keys[i], tokens[i], tokens[i] });
    }
    assert(config::apply(store, layer).len == 0);
    assert(config::validate(store).len == 0);
    for i in count {
        let value, error = config::get_integer(store, keys[i]);
        let source, se = config::source(store, keys[i]);
        assert(error.len == 0 && value == i && se.len == 0 && source == tokens[i]);
        // Valid-key prefixes that are not complete keys must remain missing.
        let missing, me = config::get_integer(store, keys[i][..keys[i].len - 1]);
        assert(me.len > 0);
    }
    let absent = ["", "!", "zzzz", "\x00", "\xff", "a.000"];
    for key in absent { let value, error = config::get_integer(store, key); assert(error.len > 0); }
    let invalid = [config::Field { "same", config::Kind.Text }, config::Field { "same", config::Kind.Text }];
    assert(config::init(invalid, store).len > 0);
    for i in count { let value, error = config::get_integer(store, keys[i]); assert(error.len == 0 && value == i); }
}
fn main() {
    var store = config::Store { .. };
    // Reinitialize the same Store across wide/small/empty transitions.
    let sizes = [0, 1, 8, 9, 16, 256, 8, 256, 0, 9];
    for count in sizes {
        exercise(store, count, 253, false);
        exercise(store, count, 0, true);
    }
    print("lookup order and key-boundary tests passed");
}
