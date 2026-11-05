// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import std;
import os;
fn snapshot(store: config::Store&, expected: i64, origin: const u8[:]) {
    for key in ["server.timeout", "old.timeout", "older.timeout"] {
        let value, error = config::get_duration(store, key);
        let source, issue = config::source(store, key);
        assert(error.len == 0 && issue.len == 0 && value.nanoseconds == expected && source == origin);
    }
    let name, ne = config::get_text(store, "name");
    let source, se = config::source(store, "name");
    assert(ne.len == 0 && se.len == 0 && name == "original" && source == "seed");
}
fn rejected_schema(store: config::Store&, schema: config::Field[:], aliases: const config::Alias[:]) {
    assert(config::init(schema, store, aliases).len > 0); snapshot(store, 1000000000, "seed");
}
fn main() {
    if arg_count() > 1 { native_alias(); return; }
    let schema = [config::Field { key: "server.timeout", kind: config::Kind.Duration, required: true, int_min: 0, int_max: 2000000000 },
                  config::Field { "server.tags", config::Kind.TextList }, config::Field { "name", config::Kind.Text }];
    let aliases = [config::Alias { "old.timeout", "server.timeout" }, config::Alias { "older.timeout", "server.timeout" },
                   config::Alias { "old.tags", "server.tags" }];
    var store = config::Store { .. };
    assert(config::init(schema, store, aliases).len == 0);
    assert(config::apply(store, [config::Override { "old.timeout", "1s", "seed" }, config::Override { "name", "original", "seed" }]).len == 0);
    assert(config::validate(store).len == 0); snapshot(store, 1000000000, "seed");
    rejected_schema(store, schema, [config::Alias { "bad..key", "name" }]);
    rejected_schema(store, schema, [config::Alias { "server", "name" }]);
    rejected_schema(store, schema, [config::Alias { "server.timeout.x", "name" }]);
    rejected_schema(store, schema, [config::Alias { "name", "name" }]);
    rejected_schema(store, schema, [config::Alias { "x", "absent" }]);
    rejected_schema(store, schema, [config::Alias { "x", "old.timeout" }]);
    rejected_schema(store, schema, [config::Alias { "x", "y" }, config::Alias { "y", "x" }]);
    rejected_schema(store, schema, [config::Alias { "x", "name" }, config::Alias { "x", "server.timeout" }]);
    rejected_schema(store, schema, [config::Alias { "x", "name" }, config::Alias { "x.y", "server.timeout" }]);
    assert(config::apply(store, [config::Override { "name", "changed", "bad" }, config::Override { "old.timeout", "1s", "bad" },
                                config::Override { "server.timeout", "2s", "bad" }]).len > 0); snapshot(store, 1000000000, "seed");
    assert(config::apply(store, [config::Override { "old.timeout", "3s", "bad" }]).len > 0); snapshot(store, 1000000000, "seed");
    let json_bad = ["{\"name\":\"changed\",\"old\":{\"timeout\":\"1s\"},\"server\":{\"timeout\":\"2s\"}}",
                    "{\"old\":{\"timeout\":\"1s\"},\"older\":{\"timeout\":\"1s\"}}"];
    for text in json_bad { assert(config::apply_json(store, text, "bad.json").len > 0); snapshot(store, 1000000000, "seed"); }
    let toml_bad = ["name='changed'\nold.timeout='1s'\nserver.timeout='2s'", "old.timeout='1s'\nolder.timeout='1s'"];
    for text in toml_bad { assert(config::apply_toml(store, text, "bad.toml").len > 0); snapshot(store, 1000000000, "seed"); }
    let bindings = [config::Binding { "old.timeout", "FIRST" }, config::Binding { "server.timeout", "SECOND" }];
    assert(config::apply_env_values(store, bindings, []).len > 0);
    assert(config::apply_cli(store, bindings, []).len > 0); snapshot(store, 1000000000, "seed");
    let env = [config::Binding { "old.timeout", "TIMEOUT" }];
    assert(config::apply_env_values(store, env, [config::EnvValue { "TIMEOUT", "500ms" }]).len == 0); snapshot(store, 500000000, "TIMEOUT");
    assert(config::apply_cli(store, [config::Binding { "older.timeout", "timeout" }], ["--timeout=2s"]).len == 0); snapshot(store, 2000000000, "--timeout");
    assert(config::apply_json(store, "{\"old\":{\"timeout\":\"250ms\",\"tags\":[\"one\",\"two\"]}}", "ok.json").len == 0); snapshot(store, 250000000, "ok.json");
    let owned, oe = config::get_text_list(store, "old.tags"); assert(oe.len == 0 && owned.len == 2);
    assert(config::apply_lists(store, [config::ListOverride { "old.tags", ["a"], "bad" }, config::ListOverride { "server.tags", ["b"], "bad" }]).len > 0);
    let tag_source, tse = config::source(store, "old.tags"); assert(tse.len == 0 && tag_source == "ok.json");
    let kept, ke = config::get_text_list(store, "server.tags"); assert(ke.len == 0 && kept.len == 2);
    for value, i in kept { assert(value == (if i == 0 { "one" } else { "two" })); }
    assert(config::apply_toml(store, "old.timeout='750ms'\nold.tags=['new']", "ok.toml").len == 0); snapshot(store, 750000000, "ok.toml");
    let layers = [config::Layer { kind: config::LayerKind.Json, text: "{\"old\":{\"timeout\":\"1s\"},\"name\":\"original\"}", source: "reload.json", .. }];
    assert(config::reload(schema, layers, store, aliases).len == 0);
    let value, ve = config::get_duration(store, "server.timeout"); assert(ve.len == 0 && value.nanoseconds == 1000000000);
    assert(config::reload(schema, layers, store).len > 0);
    let alias_value, ae = config::get_duration(store, "older.timeout"); assert(ae.len == 0 && alias_value.nanoseconds == 1000000000);
    let canonical = [config::Layer { kind: config::LayerKind.Json, text: "{\"server\":{\"timeout\":\"2s\"}}", source: "canonical.json", .. }];
    assert(config::reload(schema, canonical, store).len == 0);
    let missing, me = config::get_duration(store, "old.timeout"); assert(me.len > 0);
    for value, i in owned { assert(value == (if i == 0 { "one" } else { "two" })); }
    limits_and_ownership(); reinitialize_targets(); metadata_boundaries(); maximum_bindings(); print("alias tests passed");
}
fn limits_and_ownership() {
    let schema = [config::Field { "value", config::Kind.Integer }];
    var store = config::Store { .. };
    {
        var names:   u8[][>..]          = [];
        var aliases: config::Alias[>..] = [];
        for i in config::MAX_ALIASES { names.push(str("alias", i)); }
        for name in names { aliases.push(config::Alias { name, "value" }); }
        assert(config::init(schema, store, aliases).len == 0);
    }
    assert(config::apply(store, [config::Override { "alias255", "42", "seed" }]).len == 0);
    for i in config::MAX_ALIASES {
        let value, error = config::get_integer(store, str("alias", i)); assert(error.len == 0 && value == 42);
    }
    var aliases: config::Alias[>..] = [];
    for i in config::MAX_ALIASES + 1 { aliases.push(config::Alias { "x", "value" }); }
    assert(config::init(schema, store, aliases).len > 0);
    let preserved, pe = config::get_integer(store, "alias0"); assert(pe.len == 0 && preserved == 42);
    assert(config::init(schema, store).len == 0);
    let gone, ge = config::get_integer(store, "alias0"); assert(ge.len > 0);
}

fn reinitialize_targets() {
    var store = config::Store { .. };
    let aliases = [config::Alias { "old", "value" }];
    let first = [config::Field { "value", config::Kind.Integer }];
    assert(config::init(first, store, aliases).len == 0);
    assert(config::apply(store, [config::Override { "old", "42", "first" }]).len == 0);
    let second = [config::Field { "other", config::Kind.Text }, config::Field { "value", config::Kind.Duration }];
    assert(config::init(second, store, aliases).len == 0);
    assert(config::apply(store, [config::Override { "old", "2s", "second" }]).len == 0);
    let value, error = config::get_duration(store, "value"); assert(error.len == 0 && value.nanoseconds == 2000000000);
    let wrong, issue = config::get_integer(store, "old"); assert(issue.len > 0);
}

fn metadata_boundaries() {
    var store = config::Store { .. };
    let schema = [config::Field { "value", config::Kind.Integer }];
    var key: u8[>..] = []; for i in config::MAX_KEY_BYTES { key.push('a'); }
    assert(config::init(schema, store, [config::Alias { key, "value" }]).len == 0);
    assert(config::apply(store, [config::Override { key, "42", "seed" }]).len == 0);
    key.push('a');
    assert(config::init(schema, store, [config::Alias { key, "value" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "old", key }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "", "value" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "old", "" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "bad..key", "value" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "old", "bad..key" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "a\0b", "value" }]).len > 0);
    assert(config::init(schema, store, [config::Alias { "old", "a\0b" }]).len > 0);
    var bad: u8[>..] = []; bad.push(0xff);
    assert(config::init(schema, store, [config::Alias { bad, "value" }]).len > 0);
    let value, error = config::get_integer(store, key[..config::MAX_KEY_BYTES]); assert(error.len == 0 && value == 42);
}
fn native_alias() {
    var store = config::Store { .. };
    let schema = [config::Field { "value", config::Kind.Integer }];
    assert(config::init(schema, store, [config::Alias { "legacy", "value" }]).len == 0);
    assert(config::apply_env(store, [config::Binding { "legacy", "GOOSE_CONFIG_TEST_NUMBER" }]).len == 0);
    let value, error = config::get_integer(store, "legacy"); assert(error.len == 0 && value == -9);
    let source, issue = config::source(store, "value"); assert(issue.len == 0 && source == "GOOSE_CONFIG_TEST_NUMBER");
    print("native alias environment test passed");
}
fn maximum_bindings() {
    var keys: u8[][>..] = []; var old_keys: u8[][>..] = []; var env_names: u8[][>..] = [];
    for i in config::MAX_FIELDS { keys.push(str("key", i)); old_keys.push(str("legacy", i)); env_names.push(str("ENV", i)); }
    var key_views: const u8[:][>..] = []; var old_views: const u8[:][>..] = []; var env_views: const u8[:][>..] = [];
    for key in keys { key_views.push(key); } for key in old_keys { old_views.push(key); } for name in env_names { env_views.push(name); }
    var schema:   config::Field[>..]   = []; var aliases: config::Alias[>..] = [];
    var bindings: config::Binding[>..] = []; var values: config::EnvValue[>..] = [];
    for i in config::MAX_FIELDS {
        schema.push(config::Field { key_views[i], config::Kind.Integer });
        aliases.push(config::Alias { old_views[i], key_views[i] });
        bindings.push(config::Binding { old_views[i], env_views[i] });
        values.push(config::EnvValue { env_views[i], "42" });
    }
    var store = config::Store { .. }; assert(config::init(schema, store, aliases).len == 0);
    assert(config::apply_env_values(store, bindings, values).len == 0);
    for i in config::MAX_FIELDS {
        let value, error = config::get_integer(store, key_views[i]);
        let source, issue = config::source(store, old_views[i]);
        assert(error.len == 0 && value == 42 && issue.len == 0 && source == env_views[i]);
    }
    assert(config::init(schema, store).len == 0);
    var canonical_bindings: config::Binding[>..] = [];
    for i in config::MAX_FIELDS { canonical_bindings.push(config::Binding { key_views[i], env_views[i] }); }
    assert(config::apply_env_values(store, canonical_bindings, values).len == 0);
    for i in config::MAX_FIELDS {
        let value, error = config::get_integer(store, key_views[i]); assert(error.len == 0 && value == 42);
    }
}
