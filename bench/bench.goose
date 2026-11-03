// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;
import os;
const SAMPLES = 7;
fn report(name: const u8[:], samples: f64[:], checksum: i64) {
    print(name, " samples_ns=", samples, " checksum=", checksum);
    sort(samples);
    print("median=", samples[SAMPLES / 2], " min=", samples[0], " max=", samples[SAMPLES - 1]);
}
fn scenario(name: const u8[:], count: i64, fields: i64, width: i64, mode: i64) {
    var keys: u8[][>..] = [];
    for i in fields { keys.push(str("field", i)); }
    var schema: config::Field[>..] = [];
    for key in keys { schema.push(config::Field { key, config::Kind.Text }); }
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var payload: u8[>..] = [];
    for i in width { payload.push('x'); }
    var initial: config::Override[>..] = [];
    for key in keys { initial.push(config::Override { key, payload, "defaults" }); }
    assert(config::apply(store, initial).len == 0);
    var samples:  f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            if mode == 0 {
                let text, error = config::get_text(store, "field0");
                assert(error.len == 0); checksum += text.len;
            } else if mode == 1 {
                let text, error = config::get_text(store, "missing");
                assert(error.len > 0); checksum += error.len;
            } else if mode == 4 {
                let text, error = config::get_text(store, "field255");
                assert(error.len == 0); checksum += text.len;
            } else if mode == 5 {
                let input = [config::Override { "field0", "changed", "cli" }, config::Override { "unknown", "bad", "cli" }];
                let error = config::apply(store, input);
                assert(error.len > 0);
                let previous, pe = config::get_text(store, "field0");
                assert(pe.len == 0 && previous == payload); checksum += error.len + previous.len;
            } else if mode == 2 {
                let input = [config::Override { "field0", if i % 2 == 0 { "a" } else { "b" }, "cli" }];
                assert(config::apply(store, input).len == 0);
                let text, error = config::get_text(store, "field0");
                assert(error.len == 0 && text.len == 1); checksum += text[0];
            } else {
                assert(config::apply(store, initial).len == 0);
                let text, error = config::get_text(store, "field0");
                assert(error.len == 0); checksum += text.len;
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    report(name, samples, checksum);
}
fn toml_scenario(count: i64) {
    var store = config::Store { .. };
    let schema = [config::Field { "server.port", config::Kind.Integer }, config::Field { "name", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    var samples:  f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let text = if i % 2 == 0 { "name='goose'\n[server]\nport=8080" } else { "name='duck'\n[server]\nport=9000" };
            assert(config::apply_toml(store, text, "app.toml").len == 0);
            let port, error = config::get_integer(store, "server.port");
            assert(error.len == 0); checksum += port;
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    report("toml-small", samples, checksum);
}
fn main() {
    var count: i64 = 1000;
    if arg_count() > 1 {
        var argument: u8[>..] = []; arg(1, argument);
        let parsed, ok = parse_int(argument, 10);
        assert(ok && parsed > 0 && parsed <= 100000); count = parsed;
    }
    scenario("lookup-small", count, 8, 32, 0);
    scenario("lookup-missing-wide", count, 256, 32, 1);
    scenario("lookup-last-wide", count, 256, 32, 4);
    scenario("reject-layer-wide", count, 256, 32, 5);
    scenario("apply-small", count, 8, 32, 3);
    scenario("apply-wide", count, 256, 32, 3);
    scenario("update-one-large", count, 256, 4096, 2);
    toml_scenario(count);
}
