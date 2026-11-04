// SPDX-License-Identifier: Apache-2.0
// Successful shared feature workloads; see competitors/README.md for semantic limits.
import config from "..";
import config.reload;
import std;
import os;

const SAMPLES = 7;
fn report(name: const u8[:], samples: f64[:], checksum: i64, expected: i64) {
    assert(checksum == expected);
    print(name, " samples_ns=", samples, " checksum=", checksum);
}
fn list_scenario(count: i64, json: bool) {
    let schema = [config::Field { key: "ports", kind: config::Kind.IntegerList, int_min: 1, int_max: 65535 },
                  config::Field { "tags", config::Kind.TextList }];
    let json_documents = ["{\"ports\":[8080,9000],\"tags\":[\"goose\",\"duck\"]}", "{\"ports\":[9001],\"tags\":[\"duck\"]}"];
    let toml_documents = ["ports=[8080,9000]\ntags=['goose','duck']", "ports=[9001]\ntags=['duck']"];
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var samples: f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64 = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let error = if json { config::apply_json(store, json_documents[i % 2], "app.json") }
                        else { config::apply_toml(store, toml_documents[i % 2], "app.toml") };
            assert(error.len == 0);
            let ports, pe = config::get_integer_list(store, "ports");
            assert(pe.len == 0 && ports.len > 0);
            checksum += ports[0] + ports.len;
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    // Verify the complete replacement lists, including every text element.
    let ports, pe = config::get_integer_list(store, "ports");
    let tags, te = config::get_text_list(store, "tags");
    assert(pe.len == 0 && te.len == 0);
    if count % 2 == 0 {
        assert(ports.len == 1 && ports[0] == 9001 && tags.len == 1);
        for tag in tags { assert(tag == "duck"); }
    } else {
        assert(ports.len == 2 && ports[0] == 8080 && ports[1] == 9000 && tags.len == 2);
        for tag, i in tags { assert(tag == (if i == 0 { "goose" } else { "duck" })); }
    }
    for key in ["ports", "tags"] {
        let source, se = config::source(store, key);
        assert(se.len == 0 && source == (if json { "app.json" } else { "app.toml" }));
    }
    let expected = SAMPLES * (((count + 1) / 2) * 8082 + (count / 2) * 9002);
    report(if json { "json-lists" } else { "toml-lists" }, samples, checksum, expected);
}
fn reload_scenario(count: i64) {
    let schema = [config::Field { key: "port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true }];
    let defaults = [config::Override { "port", "8080", "defaults" }, config::Override { "name", "default", "defaults" }];
    let documents = ["{\"port\":9000,\"name\":\"file\"}", "{\"name\":\"edited\"}"];
    var store = config::Store { .. };
    var samples: f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64 = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let layers = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                          config::Layer { kind: config::LayerKind.Json, text: documents[i % 2], source: "app.json", .. }];
            assert(config::reload(schema, layers, store).len == 0);
            let port, pe = config::get_integer(store, "port");
            assert(pe.len == 0); checksum += port;
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    let port, pe = config::get_integer(store, "port");
    let name, ne = config::get_text(store, "name");
    let port_source, pse = config::source(store, "port");
    let name_source, nse = config::source(store, "name");
    assert(pe.len == 0 && ne.len == 0 && pse.len == 0 && nse.len == 0);
    assert(port == (if count % 2 == 0 { 8080 } else { 9000 }));
    assert(name == (if count % 2 == 0 { "edited" } else { "file" }));
    assert(port_source == (if count % 2 == 0 { "defaults" } else { "app.json" }) && name_source == "app.json");
    let expected = SAMPLES * (((count + 1) / 2) * 9000 + (count / 2) * 8080);
    report("reload-removal", samples, checksum, expected);
}
fn main() {
    var count: i64 = 1000;
    assert(arg_count() <= 2);
    if arg_count() == 2 {
        var argument: u8[>..] = []; arg(1, argument);
        let parsed, ok = parse_int(argument, 10);
        assert(ok && parsed > 0 && parsed <= 100000); count = parsed;
    }
    list_scenario(count, true);
    list_scenario(count, false);
    reload_scenario(count);
}
