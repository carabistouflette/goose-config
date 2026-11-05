// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.bindings;
import generated_bindings;
import typed_fixture;
import std;
fn main() {
    let environment = generated_bindings::env_bindings(); let cli = generated_bindings::cli_bindings();
    assert(environment.len == 3 && cli.len == 3);
    assert(environment[0].key == "text" && environment[0].name == "E\xc3\xa9\x22\x5c\x0a\xf0\x9f\x98\x80");
    assert(environment[1].separator == "\xc3\xa9" && cli[1].separator == ",");
    assert(typed_fixture::env_bindings().len == 0 && typed_fixture::cli_bindings().len == 0);
    var changed = generated_bindings::env_bindings(); changed[0].name = "changed";
    assert(environment[0].name == "E\xc3\xa9\x22\x5c\x0a\xf0\x9f\x98\x80" && generated_bindings::env_bindings()[0].name == environment[0].name);
    var store = config::Store { .. }; let schema = generated_bindings::schema();
    assert(config::init(schema, store).len == 0);
    let pairs = [config::EnvValue { environment[0].name, "original" }, config::EnvValue { "TAGS", "red\xc3\xa9blue" }, config::EnvValue { "COUNT", "3" }];
    assert(config::apply_env_values(store, environment, pairs).len == 0);
    var settings = generated_bindings::Settings { .. }; assert(generated_bindings::load(store, settings).len == 0);
    assert(settings.text == "original" && settings.text_source == environment[0].name && settings.tags.len == 2 && settings.tags_source == "TAGS");
    for tag, i in settings.tags { assert(tag == (if i == 0 { "red" } else { "blue" })); }
    let bad = [config::EnvValue { environment[0].name, "changed" }, config::EnvValue { "COUNT", "10" }];
    assert(config::apply_env_values(store, environment, bad).len > 0);
    assert(generated_bindings::load(store, settings).len == 0 && settings.text == "original" && settings.count == 3);
    let arguments = ["--text=cli", "--tag=oneéitem", "--tag=two", "--count=4"];
    assert(config::apply_cli(store, cli, arguments).len == 0 && generated_bindings::load(store, settings).len == 0);
    assert(settings.text == "cli" && settings.text_source == "--text" && settings.count == 4 && settings.tags.len == 2 && settings.tags_source == "--tag");
    for tag, i in settings.tags { assert(tag == (if i == 0 { "oneéitem" } else { "two" })); }
    assert(config::apply_cli(store, cli, ["--text=bad", "--count=99"]).len > 0);
    assert(generated_bindings::load(store, settings).len == 0 && settings.text == "cli" && settings.count == 4);
    assert(config::apply_env_values(store, environment, [config::EnvValue { "TAGS", "" }]).len == 0);
    assert(generated_bindings::load(store, settings).len == 0 && settings.tags_present && settings.tags.len == 0 && settings.tags_source == "TAGS");
    print("generated env/CLI descriptors, UTF8 quoting, ownership and atomicity passed");
}
