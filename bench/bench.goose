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
fn scenario(name: const u8[:], count: i64, fields: i64, width: i64, mode: i64, prefix: i64 = 0) {
    var keys:    u8[][>..] = [];
    var leading: u8[>..]   = [];
    for i in prefix { leading.push('a'); }
    for i in fields { keys.push(str(leading, "field", i)); }
    let first_key = str(leading, "field0");
    let last_key = str(leading, "field255");
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
            if mode == 7 {
                assert(config::init(schema, store).len == 0);
                let text, error = config::get_text(store, first_key);
                assert(error.len > 0 && find(error, "value is missing") >= 0); checksum += error.len;
            } else if mode == 0 {
                let text, error = config::get_text(store, first_key);
                assert(error.len == 0); checksum += text.len;
            } else if mode == 1 {
                let text, error = config::get_text(store, "missing");
                assert(error.len > 0); checksum += error.len;
            } else if mode == 4 {
                let text, error = config::get_text(store, last_key);
                assert(error.len == 0); checksum += text.len;
            } else if mode == 6 {
                let key = schema[(i * 73) % fields].key;
                let text, error = config::get_text(store, key);
                assert(error.len == 0); checksum += text.len;
            } else if mode == 5 {
                let input = [config::Override { first_key, "changed", "cli" }, config::Override { "unknown", "bad", "cli" }];
                let error = config::apply(store, input);
                assert(error.len > 0);
                let previous, pe = config::get_text(store, first_key);
                assert(pe.len == 0 && previous == payload); checksum += error.len + previous.len;
            } else if mode == 2 {
                let input = [config::Override { first_key, if i % 2 == 0 { "a" } else { "b" }, "cli" }];
                assert(config::apply(store, input).len == 0);
                let text, error = config::get_text(store, first_key);
                assert(error.len == 0 && text.len == 1); checksum += text[0];
            } else {
                assert(config::apply(store, initial).len == 0);
                let text, error = config::get_text(store, first_key);
                assert(error.len == 0); checksum += text.len;
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    if mode == 7 { assert(config::apply(store, initial).len == 0); }
    // Untimed checks verify every value and source, not only the timed checksum.
    for field, i in schema {
        let value, error = config::get_text(store, field.key);
        let source, se = config::source(store, field.key);
        assert(error.len == 0 && se.len == 0);
        if mode == 2 && i == 0 {
            assert(value == (if count % 2 == 0 { "b" } else { "a" }) && source == "cli");
        } else { assert(value == payload && source == "defaults"); }
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
    // Check the final document outside the timed loop, including both sources.
    let port, pe = config::get_integer(store, "server.port");
    let name, ne = config::get_text(store, "name");
    let port_source, pse = config::source(store, "server.port");
    let name_source, nse = config::source(store, "name");
    assert(pe.len == 0 && ne.len == 0 && pse.len == 0 && nse.len == 0);
    assert(port == (if count % 2 == 0 { 9000 } else { 8080 }));
    assert(name == (if count % 2 == 0 { "duck" } else { "goose" }));
    assert(port_source == "app.toml" && name_source == "app.toml");
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
    scenario("lookup-first-wide", count, 256, 32, 0);
    scenario("lookup-mixed-wide", count, 256, 32, 6);
    scenario("lookup-missing-wide", count, 256, 32, 1);
    scenario("lookup-last-wide", count, 256, 32, 4);
    scenario("reject-layer-wide", count, 256, 32, 5);
    scenario("apply-small", count, 8, 32, 3);
    scenario("apply-wide", count, 256, 32, 3);
    scenario("update-one-large", count, 256, 4096, 2);
    scenario("lookup-last-long-prefix", count, 256, 32, 4, 240);
    scenario("lookup-mixed-long-prefix", count, 256, 32, 6, 240);
    scenario("apply-wide-long-prefix", count, 256, 32, 3, 240);
    scenario("init-small", count, 8, 32, 7);
    scenario("init-wide", count, 256, 32, 7);
    scenario("init-wide-long-prefix", count, 256, 32, 7, 240);
    toml_scenario(count);
}
