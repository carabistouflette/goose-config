// SPDX-License-Identifier: Apache-2.0
// Successful native binding and current-source replay subsets; see competitors/README.md.
import config from "..";
import config.bindings;
import config.reload;
import std;
import os;

const SAMPLES = 7;
fn report(name: const u8[:], samples: f64[:], checksum: i64, expected: i64) {
    assert(checksum == expected);
    print(name, " samples_ns=", samples, " checksum=", checksum);
}
fn binding_scenario(count: i64, cli: bool) {
    let schema = [config::Field { key: "port", kind: config::Kind.Integer, int_min: 1, int_max: 65535 },
                  config::Field { "name", config::Kind.Text }, config::Field { "tag", config::Kind.TextList }];
    let environment = [config::Binding { "port", "GOOSE_BENCH_PORT" }, config::Binding { "name", "GOOSE_BENCH_NAME" },
                       config::Binding { "tag", "GOOSE_BENCH_TAG", " " }];
    let flags = [config::Binding { "port", "port" }, config::Binding { "name", "name" }, config::Binding { "tag", "tag" }];
    let arguments = ["--port", "9000", "--name", "worker", "--tag", "first", "--tag", "second"];
    var store = config::Store { .. };
    var samples:  f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            assert(config::init(schema, store).len == 0);
            let error = if cli { config::apply_cli(store, flags, arguments) }
                        else { config::apply_env(store, environment) };
            assert(error.len == 0);
            let port, pe = config::get_integer(store, "port");
            let name, ne = config::get_text(store, "name");
            let tags, te = config::get_text_list(store, "tag");
            assert(pe.len == 0 && ne.len == 0 && te.len == 0);
            checksum += port + tags.len + name.len;
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    let port, pe = config::get_integer(store, "port");
    let name, ne = config::get_text(store, "name");
    let tags, te = config::get_text_list(store, "tag");
    assert(pe.len == 0 && ne.len == 0 && te.len == 0 && port == 9000 && name == "worker");
    if cli {
        assert(tags.len == 2);
        for tag, i in tags { assert(tag == (if i == 0 { "first" } else { "second" })); }
    } else {
        let expected = ["a", "b", "c"];
        assert(tags.len == 3);
        for tag, i in tags { assert(tag == expected[i]); }
    }
    for binding, i in flags {
        let source, se = config::source(store, binding.key);
        assert(se.len == 0);
        assert(source == (if cli { str("--", binding.name) } else { str(environment[i].name) }));
    }
    report(if cli { "cli-lists" } else { "env-bindings" }, samples, checksum,
           SAMPLES * count * (9000 + 6 + (if cli { 2 } else { 3 })));
}
fn reload_scenario(count: i64) {
    let schema = [config::Field { key: "port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true },
                  config::Field { key: "ports", kind: config::Kind.IntegerList, required: true, int_min: 1, int_max: 65535 }];
    let defaults = [config::Override { "port", "8080", "defaults" }, config::Override { "name", "default", "defaults" }];
    var lower: u8[>..] = []; lower.append("{\"port\":8100,\"name\":\"lower\",\"ports\":[");
    var upper: u8[>..] = []; upper.append("{\"name\":\"upper\",\"ports\":[");
    for i in 256 {
        if i > 0 { lower.push(','); upper.push(','); }
        format(lower, i + 1); format(upper, i + 1001);
    }
    lower.append("]}"); upper.append("]}");
    let middle = ["{\"port\":9000,\"name\":\"middle\"}", "{\"name\":\"edited\"}"];
    let present = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                   config::Layer { kind: config::LayerKind.Json, text: lower, source: "lower.json", .. },
                   config::Layer { kind: config::LayerKind.Json, text: middle[0], source: "middle.json", .. },
                   config::Layer { kind: config::LayerKind.Json, text: upper, source: "upper.json", .. }];
    let removed = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                   config::Layer { kind: config::LayerKind.Json, text: lower, source: "lower.json", .. },
                   config::Layer { kind: config::LayerKind.Json, text: middle[1], source: "middle.json", .. },
                   config::Layer { kind: config::LayerKind.Json, text: upper, source: "upper.json", .. }];
    var store = config::Store { .. };
    var samples:  f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let error = if i % 2 == 0 { config::reload(schema, present, store) }
                        else { config::reload(schema, removed, store) };
            assert(error.len == 0);
            let port, pe = config::get_integer(store, "port");
            let name, ne = config::get_text(store, "name");
            let ports, le = config::get_integer_list(store, "ports");
            assert(pe.len == 0 && ne.len == 0 && le.len == 0);
            checksum += port + ports.len + name.len;
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    let port, pe = config::get_integer(store, "port");
    let name, ne = config::get_text(store, "name");
    let ports, le = config::get_integer_list(store, "ports");
    assert(pe.len == 0 && ne.len == 0 && le.len == 0);
    assert(port == (if count % 2 == 0 { 8100 } else { 9000 }) && name == "upper" && ports.len == 256);
    for value, i in ports { assert(value == i + 1001); }
    for key in ["name", "ports"] {
        let source, se = config::source(store, key); assert(se.len == 0 && source == "upper.json");
    }
    let source, se = config::source(store, "port");
    assert(se.len == 0 && source == (if count % 2 == 0 { "lower.json" } else { "middle.json" }));
    report("reload-layers", samples, checksum, SAMPLES * (((count + 1) / 2) * 9261 + (count / 2) * 8361));
}
fn main() {
    var count: i64 = 1000;
    assert(arg_count() <= 2);
    if arg_count() == 2 {
        var argument: u8[>..] = []; arg(1, argument);
        let parsed, ok = parse_int(argument, 10);
        assert(ok && parsed > 0 && parsed <= 100000); count = parsed;
    }
    binding_scenario(count, false);
    binding_scenario(count, true);
    reload_scenario(count);
}
