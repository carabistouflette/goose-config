// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import std;
import os;

fn text_values(values: const u8[][:], expected: const (const u8[:])[:]) -> bool {
    if values.len != expected.len { return false; }
    for value, i in values { if value != expected[i] { return false; } }
    true
}
fn port_is(store: config::Store&, expected: i64, origin: const u8[:]) {
    let port, error = config::get_integer(store, "port");
    let source, se = config::source(store, "port");
    assert(error.len == 0 && port == expected && se.len == 0 && source == origin);
}
fn main() {
    if arg_count() > 1 { let argv = args(); assert(argv.len == 2 && argv[1] == "--environment"); process_environment(); return; }
    let schema = [config::Field { key: "port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true },
                  config::Field { key: "tags", kind: config::Kind.TextList }];
    let defaults = [config::Override { "port", "8080", "defaults" }, config::Override { "name", "default", "defaults" }];
    let base_tags = ["base"];
    let default_lists = [config::ListOverride { "tags", base_tags, "defaults" }];
    let env_bindings = [config::Binding { key: "port", name: "APP_PORT" }];
    let environment = [config::EnvValue { "APP_PORT", "9100" }];
    let cli_bindings = [config::Binding { key: "port", name: "port" }, config::Binding { key: "tags", name: "tag" }];
    let arguments = ["--port=9200", "--tag", "cliA", "--tag=cliB"];
    let layers = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                  config::Layer { kind: config::LayerKind.Lists, lists: default_lists, .. },
                  config::Layer { kind: config::LayerKind.Toml, text: "port=9000\nname='file'\ntags=['file']", source: "app.toml", .. },
                  config::Layer { kind: config::LayerKind.Environment, bindings: env_bindings, environment: environment, .. },
                  config::Layer { kind: config::LayerKind.CommandLine, bindings: cli_bindings, arguments: arguments, .. }];
    var store = config::Store { .. };
    assert(config::reload(schema, layers, store).len == 0);
    port_is(store, 9200, "--port");
    let cli_tags, cte = config::get_text_list(store, "tags");
    assert(cte.len == 0 && text_values(cli_tags, ["cliA", "cliB"]));
    // Deleted file keys and removed upper layers expose only current defaults.
    let edited = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                  config::Layer { kind: config::LayerKind.Lists, lists: default_lists, .. },
                  config::Layer { kind: config::LayerKind.Json, text: "{\"name\":\"edited\"}", source: "app.json", .. }];
    assert(config::reload(schema, edited, store).len == 0);
    port_is(store, 8080, "defaults");
    let tags, te = config::get_text_list(store, "tags");
    assert(te.len == 0 && text_values(tags, ["base"]) && text_values(cli_tags, ["cliA", "cliB"]));
    let name, ne = config::get_text(store, "name"); assert(ne.len == 0 && name == "edited");
    let invalid = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                   config::Layer { kind: config::LayerKind.Json, text: "{\"name\":\"SECRET-NEW\",\"port\":0}", source: "bad.json", .. }];
    let error = config::reload(schema, invalid, store);
    assert(error.len > 0 && find(error, "SECRET-NEW") < 0);
    port_is(store, 8080, "defaults");
    let kept, ke = config::get_text(store, "name"); assert(ke.len == 0 && kept == "edited");
    let incomplete = [config::Layer { kind: config::LayerKind.Json, text: "{\"name\":\"only\"}", source: "missing.json", .. }];
    assert(config::reload(schema, incomplete, store).len > 0);
    port_is(store, 8080, "defaults");
    let bad_schema = [config::Field { "a", config::Kind.Text }, config::Field { "a", config::Kind.Text }];
    assert(config::reload(bad_schema, layers, store).len > 0);
    port_is(store, 8080, "defaults");
    // Input text and schema keys may refer to the old store until publication.
    let input = [config::Override { "name", "{\"port\":7777,\"name\":\"borrowed\"}", "payload" }];
    assert(config::apply(store, input).len == 0);
    let payload, pye = config::get_text(store, "name"); assert(pye.len == 0);
    let borrowed = [config::Layer { kind: config::LayerKind.Json, text: payload, source: "borrowed.json", .. }];
    assert(config::reload(schema, borrowed, store).len == 0);
    port_is(store, 7777, "borrowed.json");
    let missing_tags, mte = config::get_text_list(store, "tags"); assert(mte.len > 0);
    let unused = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, text: "ignored?", .. }];
    assert(config::reload(schema, unused, store).len > 0);
    port_is(store, 7777, "borrowed.json");
    var too_many: config::Layer[>..] = [];
    for i in config::MAX_LAYERS + 1 { too_many.push(config::Layer { kind: config::LayerKind.Values, .. }); }
    assert(config::reload(schema, too_many, store).len > 0);
    port_is(store, 7777, "borrowed.json");
    var at_limit: config::Layer[>..] = [];
    at_limit.push(config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. });
    for i in config::MAX_LAYERS - 1 { at_limit.push(config::Layer { kind: config::LayerKind.Values, .. }); }
    assert(config::reload(schema, at_limit, store).len == 0);
    port_is(store, 8080, "defaults");
    let empty_schema: config::Field[0] = [];
    let empty_layers: config::Layer[0] = [];
    assert(config::reload(empty_schema, empty_layers, store).len == 0 && config::validate(store).len == 0);
    let gone, ge = config::get_integer(store, "port"); assert(ge.len > 0);
    var uninitialized = config::Store { .. };
    assert(config::reload(schema, incomplete, uninitialized).len > 0 && !uninitialized.initialized);
    print("fresh-store layered reload, removals, validation and publication passed");
}

// Uses the same isolated variables supplied by tests/bindings.py.
fn process_environment() {
    let schema = [config::Field { key: "i", kind: config::Kind.Integer, required: true }];
    let defaults = [config::Override { "i", "42", "defaults" }];
    let present = [config::Binding { key: "i", name: "GOOSE_CONFIG_TEST_NUMBER" }];
    let layers = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                  config::Layer { kind: config::LayerKind.ProcessEnvironment, bindings: present, .. }];
    var store = config::Store { .. };
    assert(config::reload(schema, layers, store).len == 0);
    let value, error = config::get_integer(store, "i");
    let origin, oe = config::source(store, "i");
    assert(error.len == 0 && value == -9 && oe.len == 0 && origin == "GOOSE_CONFIG_TEST_NUMBER");
    let absent = [config::Binding { key: "i", name: "GOOSE_CONFIG_TEST_UNSET" }];
    let removed = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                   config::Layer { kind: config::LayerKind.ProcessEnvironment, bindings: absent, .. }];
    assert(config::reload(schema, removed, store).len == 0);
    let fallback, fe = config::get_integer(store, "i"); assert(fe.len == 0 && fallback == 42);
    let invalid = [config::Binding { key: "i", name: "GOOSE_CONFIG_TEST_INVALID" }];
    let rejected = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                    config::Layer { kind: config::LayerKind.ProcessEnvironment, bindings: invalid, .. }];
    assert(config::reload(schema, rejected, store).len > 0);
    let kept, ke = config::get_integer(store, "i"); assert(ke.len == 0 && kept == 42);
    print("process-environment reload, removal and rejection passed");
}
