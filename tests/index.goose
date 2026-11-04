// SPDX-License-Identifier: Apache-2.0
// Exercise lookup through public APIs with shuffled declaration/application
// orders, variable key lengths, shared prefixes, and both sides of the cutoff.
import config from "..";
import std;
// Global consumer helpers must not intercept the private lookup accelerator.
fn hash(key: const u8[:]) -> u64 { assert(false); 0 }
fn lookup_hash(key: const u8[:]) -> u64 { assert(false); 0 }
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
        let i = (j + count / 2) % count;
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
fn collisions() {
    // Independent length-seeded FNV-1a fixtures: each valid ASCII key maps to bucket 511 of
    // the 512-slot accelerator. Eight entries wrap to slot 6; later entries
    // must use the sorted fallback. The final key is deliberately absent.
    let keys = [
        "collision1051", "collision1316", "collision1738", "collision2289",
        "collision3840", "collision4571", "collision4618", "collision4777",
        "collision6379", "collision7624", "collision7866", "collision8162",
        "collision8913", "collision9006", "collision9428", "collision9561",
        "collision10258"];
    var schema: config::Field[>..]    = [];
    var layer:  config::Override[>..] = [];
    for i in 16 {
        schema.push(config::Field { keys[i], config::Kind.Text, true });
        layer.push(config::Override { keys[i], keys[i], "collisions" });
    }
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var occupied = 0;
    for id in store.hash_ids { if id >= 0 { occupied++; } }
    assert(occupied == 8 && store.hash_ids[511] == 0 && store.hash_ids[6] == 7);
    assert(config::apply(store, layer).len == 0);
    assert(config::validate(store).len == 0);
    for i in 16 {
        let value, error = config::get_text(store, keys[i]);
        let source, se = config::source(store, keys[i]);
        assert(error.len == 0 && value == keys[i] && se.len == 0 && source == "collisions");
    }
    let absent, ae = config::get_text(store, keys[16]);
    assert(ae.len > 0);
    let rejected = [config::Override { keys[15], "changed", "rejected" },
                    config::Override { keys[16], "missing", "rejected" }];
    assert(config::apply(store, rejected).len > 0);
    let retained, re = config::get_text(store, keys[15]);
    assert(re.len == 0 && retained == keys[15]);
    // A wide schema may borrow old values until all staged indexes are built.
    var borrowed_schema: config::Field[>..] = [];
    for i in 16 {
        let value, error = config::get_text(store, keys[i]);
        assert(error.len == 0);
        borrowed_schema.push(config::Field { value, config::Kind.Text, true });
    }
    assert(config::init(borrowed_schema, store).len == 0);
    assert(config::apply(store, layer).len == 0);
    schema.push(config::Field { keys[15], config::Kind.Text });
    assert(config::init(schema, store).len > 0);
    for i in 16 {
        let value, error = config::get_text(store, keys[i]);
        assert(error.len == 0 && value == keys[i]);
    }
}
fn suffix_collisions() {
    // Maximum-length keys differ only before the sampled suffix. They have
    // identical full accelerator hashes; equality must inspect the whole key.
    var keys: u8[..256][17] = [[]; 17];
    let digits = "0123456789";
    var schema: config::Field[>..]    = [];
    var layer:  config::Override[>..] = [];
    for i in 17 {
        keys[i].push(digits[i / 10]); keys[i].push(digits[i % 10]);
        for j in 222 { keys[i].push('a'); }
        for j in 32 { keys[i].push('z'); }
        if i < 16 {
            schema.push(config::Field { keys[i], config::Kind.Text });
            layer.push(config::Override { keys[i], keys[i], "suffix" });
        }
    }
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var occupied = 0;
    for id in store.hash_ids { if id >= 0 { occupied++; } }
    assert(occupied == 8);
    assert(config::apply(store, layer).len == 0);
    for i in 16 {
        let value, error = config::get_text(store, keys[i]);
        let source, se = config::source(store, keys[i]);
        assert(error.len == 0 && value == keys[i] && se.len == 0 && source == "suffix");
    }
    let missing, error = config::get_text(store, keys[16]);
    assert(error.len > 0);
}
fn main() {
    collisions();
    suffix_collisions();
    var store = config::Store { .. };
    // Reinitialize the same Store across wide/small/empty transitions.
    let sizes = [0, 1, 8, 9, 16, 256, 8, 256, 0, 9];
    for count in sizes {
        exercise(store, count, 253, false);
        exercise(store, count, 0, true);
    }
    for count in 257 { exercise(store, count, 0, true); }
    print("lookup order and key-boundary tests passed for all 257 schema sizes");
}
