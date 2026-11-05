// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import std;
import os;

fn duration_is(store: config::Store&, value: i64, source: const u8[:]) {
    let actual, error = config::get_duration(store, "delay");
    let origin, issue = config::source(store, "delay");
    assert(error.len == 0 && actual.nanoseconds == value && issue.len == 0 && origin == source);
}
fn duration_survivors(store: config::Store&, expected: i64[:], origin: const u8[:]) {
    let values, error = config::get_duration_list(store, "retry");
    let source, source_error = config::source(store, "retry");
    assert(error.len == 0 && source_error.len == 0 && source == origin && values.len == expected.len);
    for value, i in values { assert(value.nanoseconds == expected[i]); }
    let name, name_error = config::get_text(store, "name");
    let name_source, name_source_error = config::source(store, "name");
    assert(name_error.len == 0 && name == "original" && name_source_error.len == 0 && name_source == "seed");
}
fn parse_cases() {
    let tokens = ["0", "+0", "-0", "1ns", "-1ns", "250ms", "1m30s", ".5s", "1.s",
                  "1us", "1µs", "1μs", "1d", "-1.5h", "1s2s", "1ms1s", "0.9ns0.9ns",
                  "9223372036854775807ns", "-9223372036854775808ns",
                  "9223372036.854775807s", "-9223372036.854775808s", "9223372036854775807.9ns"];
    let expected: i64[] = [0, 0, 0, 1, -1, 250000000, 90000000000, 500000000, 1000000000,
                          1000, 1000, 1000, 86400000000000, -5400000000000, 3000000000, 1001000000, 0,
                          9223372036854775807, -9223372036854775808,
                          9223372036854775807, -9223372036854775808, 9223372036854775807];
    for token, i in tokens {
        let value, error = config::parse_duration(token);
        assert(error.len == 0 && value.nanoseconds == expected[i]);
    }
    let bad = ["", "+", "-", "1", "00", "1e3s", "1 s", " 1s", "1s ", "1s-2s", "1s+2s",
               "s", ".s", "1..s", "1S", "1w", "NaNs", "infs", "0x1s", "1ms!", "1µ", "1\0s",
               "9223372036854775808ns", "-9223372036854775809ns", "9223372036.854775808s",
               "-9223372036.854775809s", "9223372036854775807ns1ns", "-9223372036854775808ns1ns",
               "106752d", "999999999999999999999999999999999999999h"];
    for token in bad { let value, error = config::parse_duration(token); assert(error.len > 0); }
    var boundary: u8[>..] = [];
    for i in 126 { boundary.push('0'); } boundary.append("ns");
    let zero, ze = config::parse_duration(boundary); assert(ze.len == 0 && zero.nanoseconds == 0);
    boundary.push('s'); let invalid, ie = config::parse_duration(boundary); assert(ie.len > 0);
    var fraction: u8[>..] = []; fraction.append("0.");
    for i in 125 { fraction.push('9'); } fraction.push('h');
    let exact, ee = config::parse_duration(fraction); assert(ee.len == 0 && exact.nanoseconds == 3599999999999);
    var bytes: u8[>..] = []; bytes.push('1'); bytes.push(0xff); bytes.push('s');
    let wrong, we = config::parse_duration(bytes); assert(we.len > 0);
}
fn layers() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "delay", kind: config::Kind.Duration, required: true, int_min: 0, int_max: 2000000000 },
                  config::Field { key: "retry", kind: config::Kind.DurationList, required: true, int_min: 0, int_max: 2000000000 },
                  config::Field { "name", config::Kind.Text }];
    assert(config::init(schema, store).len == 0 && config::validate(store).len > 0);
    assert(config::apply(store, [config::Override { "delay", "0", "seed" }, config::Override { "name", "original", "seed" }]).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "retry", [], "seed" }]).len == 0 && config::validate(store).len == 0);
    let wrong, wrong_error = config::get_integer(store, "delay"); assert(wrong_error.len > 0);
    let wrong_list, wrong_list_error = config::get_integer_list(store, "retry"); assert(wrong_list_error.len > 0);
    assert(config::apply(store, [config::Override { "name", "changed", "bad" }, config::Override { "delay", "oops", "bad" }]).len > 0);
    duration_is(store, 0, "seed"); duration_survivors(store, [], "seed");
    let bindings = [config::Binding { "delay", "DELAY" }, config::Binding { "retry", "RETRY", ":" }];
    assert(config::apply_env_values(store, bindings, [config::EnvValue { "DELAY", "1.25s" }, config::EnvValue { "RETRY", "1s:250ms" }]).len == 0);
    duration_is(store, 1250000000, "DELAY");
    let owned, oe = config::get_duration_list(store, "retry");
    assert(oe.len == 0 && owned.len == 2 && owned[0].nanoseconds == 1000000000 && owned[1].nanoseconds == 250000000);
    assert(config::apply_env_values(store, bindings, [config::EnvValue { "DELAY", "2s" }, config::EnvValue { "RETRY", "1s:bad" }]).len > 0);
    duration_is(store, 1250000000, "DELAY"); duration_survivors(store, [1000000000, 250000000], "RETRY");
    assert(config::apply_env_values(store, bindings, [config::EnvValue { "RETRY", "" }]).len == 0);
    duration_survivors(store, [], "RETRY");
    let cli = [config::Binding { "delay", "delay" }, config::Binding { "retry", "retry" }];
    assert(config::apply_cli(store, cli, ["--delay=.5s", "--retry", "1s", "--retry=1ms"]).len == 0);
    duration_is(store, 500000000, "--delay");
    assert(config::apply_cli(store, cli, ["--delay=1s", "--retry=-1ns"]).len > 0);
    duration_is(store, 500000000, "--delay"); duration_survivors(store, [1000000000, 1000000], "--retry");
    assert(config::apply_json(store, "{\"delay\":\"1.5s\",\"retry\":[\".5s\",\"0\"]}", "ok.json").len == 0);
    duration_is(store, 1500000000, "ok.json");
    let bad_json = ["{\"delay\":0}", "{\"delay\":1.0}", "{\"retry\":[0]}", "{\"retry\":[\"1s\",1]}",
                    "{\"delay\":\"2s\",\"retry\":[\"1s\",\"bad\"]}", "{\"delay\":\"-1ns\"}",
                    "{\"name\":\"changed\",\"delay\":\"2s1ns\"}"];
    for document in bad_json {
        assert(config::apply_json(store, document, "bad.json").len > 0); duration_is(store, 1500000000, "ok.json"); duration_survivors(store, [500000000, 0], "ok.json");
    }
    assert(config::apply_toml(store, "delay='2s'\nretry=['1ms','1us']", "ok.toml").len == 0);
    duration_is(store, 2000000000, "ok.toml");
    let bad_toml = ["delay=0", "delay=1.0", "retry=[0]", "retry=['1s',1]", "delay='1s'\nretry=['1s','bad']", "delay='2s1ns'", "name='changed'\ndelay='oops'"];
    for document in bad_toml {
        assert(config::apply_toml(store, document, "bad.toml").len > 0); duration_is(store, 2000000000, "ok.toml"); duration_survivors(store, [1000000, 1000], "ok.toml");
    }
    let defaults = [config::Override { "delay", "1ns", "defaults" }];
    let retry_defaults = ["2ns"];
    let lists = [config::ListOverride { "retry", retry_defaults, "defaults" }];
    let layers = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                  config::Layer { kind: config::LayerKind.Lists, lists: lists, .. },
                  config::Layer { kind: config::LayerKind.Json, text: "{\"delay\":\"2ms\"}", source: "reload.json", .. }];
    assert(config::reload(schema, layers, store).len == 0); duration_is(store, 2000000, "reload.json");
    assert(owned.len == 2 && owned[0].nanoseconds == 1000000000 && owned[1].nanoseconds == 250000000);
    let rejected = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                    config::Layer { kind: config::LayerKind.Lists, lists: lists, .. },
                    config::Layer { kind: config::LayerKind.Toml, text: "delay='oops'", source: "bad.toml", .. }];
    assert(config::reload(schema, rejected, store).len > 0); duration_is(store, 2000000, "reload.json");
    let missing = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. }];
    assert(config::reload(schema, missing, store).len > 0); duration_is(store, 2000000, "reload.json");
    let name, ne = config::get_text(store, "name"); assert(ne.len > 0);
    // Range checks use integer nanoseconds, including truncation toward zero.
    assert(config::apply(store, [config::Override { "delay", "-0.9ns", "tiny" }]).len == 0); duration_is(store, 0, "tiny");
    assert(config::apply(store, [config::Override { "delay", "2.0000000009s", "boundary" }]).len == 0); duration_is(store, 2000000000, "boundary");
    assert(config::apply_lists(store, [config::ListOverride { "retry", ["1ns", "2s1ns"], "bad" }]).len > 0);
    let kept, ke = config::get_duration_list(store, "retry"); assert(ke.len == 0 && kept.len == 1 && kept[0].nanoseconds == 2);
}
fn limits() {
    var store = config::Store { .. };
    let schema = [config::Field { "delay", config::Kind.Duration }, config::Field { "retry", config::Kind.DurationList }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "delay", "1ns", "seed" }]).len == 0);
    var token:  u8[>..]          = []; for i in 126 { token.push('0'); } token.append("ns");
    var values: const u8[:][>..] = [];
    for i in config::MAX_LIST_ITEMS { values.push(token); }
    assert(config::apply_lists(store, [config::ListOverride { "retry", values, "max" }]).len == 0);
    var json: u8[>..] = []; json.append("{\"retry\":[");
    var toml: u8[>..] = []; toml.append("retry=[");
    for i in config::MAX_LIST_ITEMS {
        if i > 0 { json.push(','); toml.push(','); }
        json.push('"'); json.append(token); json.push('"'); toml.push('\''); toml.append(token); toml.push('\'');
    }
    json.append("]}"); toml.push(']');
    assert(config::apply_json(store, json, "max.json").len == 0);
    assert(config::apply_toml(store, toml, "max.toml").len == 0);
    values.push("0"); assert(config::apply_lists(store, [config::ListOverride { "retry", values, "too-many" }]).len > 0);
    token.push('s'); assert(config::apply(store, [config::Override { "delay", token, "long" }]).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "retry", [token], "long" }]).len > 0);
    var bad_json: u8[>..] = []; bad_json.append("{\"delay\":\""); bad_json.append(token); bad_json.append("\"}");
    var bad_toml: u8[>..] = []; bad_toml.append("delay='"); bad_toml.append(token); bad_toml.push('\'');
    assert(config::apply_json(store, bad_json, "long.json").len > 0);
    assert(config::apply_toml(store, bad_toml, "long.toml").len > 0);
    duration_is(store, 1, "seed");
    let values_after, error = config::get_duration_list(store, "retry"); assert(error.len == 0 && values_after.len == 256);
    for value in values_after { assert(value.nanoseconds == 0); }
    assert(config::apply_json(store, "{\"retry\":[\"9223372036854775807ns\",\"-9223372036854775808ns\"]}", "bounds.json").len == 0);
    let extremes, xe = config::get_duration_list(store, "retry");
    assert(xe.len == 0 && extremes.len == 2 && extremes[0].nanoseconds == 9223372036854775807 && extremes[1].nanoseconds == -9223372036854775808);
    assert(config::apply_toml(store, "retry=['9223372036854775807ns','-9223372036854775808ns']", "bounds.toml").len == 0);
    let ends, de = config::get_duration_list(store, "retry");
    assert(de.len == 0 && ends.len == 2 && ends[0].nanoseconds == 9223372036854775807 && ends[1].nanoseconds == -9223372036854775808);
}
fn native_environment() {
    var store = config::Store { .. };
    let schema = [config::Field { "delay", config::Kind.Duration }, config::Field { "retry", config::Kind.DurationList }];
    assert(config::init(schema, store).len == 0);
    let bindings = [config::Binding { "delay", "GOOSE_CONFIG_TEST_DURATION" }, config::Binding { "retry", "GOOSE_CONFIG_TEST_DURATIONS", ":" }];
    assert(config::apply_env(store, bindings).len == 0); duration_is(store, 1250000000, "GOOSE_CONFIG_TEST_DURATION");
    let values, error = config::get_duration_list(store, "retry");
    assert(error.len == 0 && values.len == 2 && values[0].nanoseconds == 1000000000 && values[1].nanoseconds == 250000000);
}
fn main() {
    if arg_count() > 1 { native_environment(); print("duration native environment tests passed"); return; }
    parse_cases(); layers(); limits();
    print("duration tests passed");
}
