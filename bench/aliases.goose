// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;
import os;
const SAMPLES = 7;
fn alias_scenario(count: i64, fields: i64, long_prefix: bool, mode: i64) {
    var names:       u8[][>..] = [];
    var value_texts: u8[][>..] = [];
    for i in fields { value_texts.push(str(i + 1)); }
    var value_views: const u8[:][>..] = []; for text in value_texts { value_views.push(text); }
    var old_names:   u8[][>..]        = [];
    var prefix:      u8[>..]          = []; if long_prefix { for i in 230 { prefix.push('p'); } }
    for i in fields { names.push(str(prefix, "field", i)); old_names.push(str(prefix, "alias", i)); }
    var keys: const u8[:][>..] = []; var old_keys: const u8[:][>..] = [];
    for key in names { keys.push(key); } for key in old_names { old_keys.push(key); }
    var schema:  config::Field[>..]    = [];
    var aliases: config::Alias[>..]    = [];
    var inputs:  config::Override[>..] = [];
    for key, i in keys {
        schema.push(config::Field { key, config::Kind.Integer });
        aliases.push(config::Alias { old_keys[i], key });
        inputs.push(config::Override { key, value_views[i], "seed" });
    }
    let missing = str(prefix, "missing");
    var store = config::Store { .. };
    assert(config::init(schema, store, aliases).len == 0);
    assert(config::apply(store, inputs).len == 0);
    var samples: f64[SAMPLES] = [0.0; SAMPLES]; var checksum: i64 = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let id = (i * 73) % fields;
            if mode == 2 {
                let value, error = config::get_integer(store, missing); assert(error.len > 0); checksum += error.len;
            } else {
                let value, error = config::get_integer(store, if mode == 0 { keys[id] } else { old_keys[id] });
                assert(error.len == 0 && value == id + 1); checksum += value;
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    for key, i in old_names { let value, error = config::get_integer(store, key); assert(error.len == 0 && value == i + 1); }
    let name = str(if mode == 0 { "canonical" } else if mode == 1 { "alias" } else { "missing" }, "-", fields, if long_prefix { "-long" } else { "" });
    print(name, " samples_ns=", samples, " checksum=", checksum);
}
fn main() {
    var count: i64 = 10000;
    if arg_count() > 1 { var argtext: u8[>..] = []; arg(1, argtext); let n, ok = parse_int(argtext, 10); assert(ok && n > 0 && n <= 100000); count = n; }
    for fields in [8, 256] { for long_prefix in [false, true] { for mode in 3 { alias_scenario(count, fields, long_prefix, mode); } } }
}
