// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.bindings;
import std;
import os;

fn binding_repeat(byte: u8, length: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for i in length { out.push(byte); }
    out
}
fn binding_integer(store: config::Store&, expected: i64, origin: const u8[:] = "seed") {
    let value, error = config::get_integer(store, "number");
    assert(error.len == 0 && value == expected);
    let source, source_error = config::source(store, "number");
    assert(source_error.len == 0 && source == origin);
}
fn binding_text(store: config::Store&, expected: const u8[:], origin: const u8[:]) {
    let value, error = config::get_text(store, "text");
    assert(error.len == 0 && value == expected);
    let source, source_error = config::source(store, "text");
    assert(source_error.len == 0 && source == origin);
}
fn binding_seed(store: config::Store&) {
    let schema = [config::Field { "number", config::Kind.Integer }, config::Field { "text", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    let defaults = [config::Override { "number", "7", "seed" }, config::Override { "text", "old", "seed" }];
    assert(config::apply(store, defaults).len == 0);
}
fn supplied_environment() {
    var store = config::Store { .. };
    binding_seed(store);
    let bindings = [config::Binding { "number", "APP_NUMBER" }, config::Binding { "text", "APP_TEXT" }];
    let missing: config::EnvValue[0] = [];
    assert(config::apply_env_values(store, bindings, missing).len == 0);
    binding_integer(store, 7); binding_text(store, "old", "seed");
    let empty = [config::EnvValue { "APP_TEXT", "" }, config::EnvValue { "app_number", "91" }];
    assert(config::apply_env_values(store, bindings, empty).len == 0);
    binding_text(store, "", "APP_TEXT"); binding_integer(store, 7);
    let invalid = [config::EnvValue { "APP_TEXT", "secret-not-displayed" }, config::EnvValue { "APP_NUMBER", "1.0" }];
    let error = config::apply_env_values(store, bindings, invalid);
    assert(error.len > 0); binding_text(store, "", "APP_TEXT"); binding_integer(store, 7);
    for byte in error { assert(byte >= 32 && byte <= 126); }
    let duplicate = [config::EnvValue { "APP_NUMBER", "8" }, config::EnvValue { "APP_NUMBER", "9" }];
    assert(config::apply_env_values(store, bindings, duplicate).len > 0);
    let duplicate_unbound = [config::EnvValue { "OTHER", "8" }, config::EnvValue { "OTHER", "9" }];
    assert(config::apply_env_values(store, bindings, duplicate_unbound).len > 0);
    let aliases = [config::Binding { "number", "FIRST" }, config::Binding { "number", "SECOND" }];
    assert(config::apply_env_values(store, aliases, missing).len > 0);
    let names = [config::Binding { "number", "SAME" }, config::Binding { "text", "SAME" }];
    assert(config::apply_env_values(store, names, missing).len > 0);
    let unknown = [config::Binding { "unknown", "APP_NUMBER" }];
    assert(config::apply_env_values(store, unknown, missing).len > 0);
    let bad_names = ["", "BAD=NAME", "BAD\x00NAME"];
    for name in bad_names {
        let bad = [config::Binding { "number", name }];
        assert(config::apply_env_values(store, bad, missing).len > 0);
        let bad_pair = [config::EnvValue { name, "8" }];
        assert(config::apply_env_values(store, bindings, bad_pair).len > 0);
    }
    var long_name = binding_repeat('x', 256);
    let limit_binding = [config::Binding { "text", long_name }];
    let limit_pair = [config::EnvValue { long_name, "limit" }];
    assert(config::apply_env_values(store, limit_binding, limit_pair).len == 0);
    long_name.push('x');
    let too_long = [config::Binding { "text", long_name }];
    assert(config::apply_env_values(store, too_long, missing).len > 0);
    var long_value = binding_repeat('x', config::MAX_VALUE_BYTES);
    let max_value = [config::EnvValue { "APP_TEXT", long_value }];
    assert(config::apply_env_values(store, bindings, max_value).len == 0);
    long_value.push('x');
    let oversize = [config::EnvValue { "APP_TEXT", long_value }];
    assert(config::apply_env_values(store, bindings, oversize).len > 0);
    var too_many: config::EnvValue[>..] = [];
    for i in 257 { too_many.push(config::EnvValue { "UNBOUND", "" }); }
    assert(config::apply_env_values(store, bindings, too_many).len > 0);
    var many_bindings: config::Binding[>..] = [];
    for i in 257 { many_bindings.push(config::Binding { "text", "NAME" }); }
    assert(config::apply_env_values(store, many_bindings, missing).len > 0);
    binding_integer(store, 7);
}
fn command_line() {
    var store = config::Store { .. };
    binding_seed(store);
    let bindings = [config::Binding { "number", "number" }, config::Binding { "text", "text" }];
    let valid = ["--number", "-12", "--text=", "--"];
    assert(config::apply_cli(store, bindings, valid).len == 0);
    binding_integer(store, -12, "--number"); binding_text(store, "", "--text");
    let inline_value = ["--text=--private=value"];
    assert(config::apply_cli(store, bindings, inline_value).len == 0);
    binding_text(store, "--private=value", "--text");
    let invalid = ["--text=changed", "--number=2.5"];
    assert(config::apply_cli(store, bindings, invalid).len > 0);
    binding_text(store, "--private=value", "--text"); binding_integer(store, -12, "--number");
    let duplicate = ["--number=1", "--number", "2"];
    assert(config::apply_cli(store, bindings, duplicate).len > 0);
    let unknown = ["--numbr=1"];
    assert(config::apply_cli(store, bindings, unknown).len > 0);
    let missing = ["--number"];
    assert(config::apply_cli(store, bindings, missing).len > 0);
    let missing_before_option = ["--text", "--number=8"];
    assert(config::apply_cli(store, bindings, missing_before_option).len > 0);
    let missing_before_end = ["--text", "--"];
    assert(config::apply_cli(store, bindings, missing_before_end).len > 0);
    let positional = ["position"];
    assert(config::apply_cli(store, bindings, positional).len > 0);
    let after_end = ["--", "--number=8"];
    assert(config::apply_cli(store, bindings, after_end).len > 0);
    let before_end = ["--number=8", "--"];
    assert(config::apply_cli(store, bindings, before_end).len == 0);
    binding_integer(store, 8, "--number");
    let shorthand = ["-n", "9"];
    assert(config::apply_cli(store, bindings, shorthand).len > 0);
    let empty_args: const u8[:][0] = [];
    let bad_names = ["", "-name", "na.me", "na me", "name\x00tail", "name=value"];
    for name in bad_names {
        let bad = [config::Binding { "text", name }];
        assert(config::apply_cli(store, bad, empty_args).len > 0);
    }
    let aliases = [config::Binding { "number", "one" }, config::Binding { "number", "two" }];
    assert(config::apply_cli(store, aliases, empty_args).len > 0);
    var many_args: const u8[:][>..] = [];
    for i in 513 { many_args.push("--"); }
    assert(config::apply_cli(store, bindings, many_args).len > 0);
    var name = binding_repeat('x', 254);
    let limit = [config::Binding { "text", name }];
    var option: u8[>..] = [];
    option.append("--"); option.append(name); option.append("=limit");
    let max_name_args: const u8[:][1] = [option[..]];
    assert(config::apply_cli(store, limit, max_name_args).len == 0);
    name.push('x');
    let oversize = [config::Binding { "text", name }];
    assert(config::apply_cli(store, oversize, empty_args).len > 0);
    binding_integer(store, 8, "--number");
}
fn native_environment() {
    var store = config::Store { .. };
    binding_seed(store);
    let bindings = [config::Binding { "number", "GOOSE_CONFIG_TEST_NUMBER" }, config::Binding { "text", "GOOSE_CONFIG_TEST_TEXT" }];
    assert(config::apply_env(store, bindings).len == 0);
    binding_integer(store, -9, "GOOSE_CONFIG_TEST_NUMBER"); binding_text(store, "", "GOOSE_CONFIG_TEST_TEXT");
    let missing = [config::Binding { "number", "GOOSE_CONFIG_TEST_UNSET" }];
    assert(config::apply_env(store, missing).len == 0);
    binding_integer(store, -9, "GOOSE_CONFIG_TEST_NUMBER");
    let invalid = [config::Binding { "text", "GOOSE_CONFIG_TEST_UPDATED" }, config::Binding { "number", "GOOSE_CONFIG_TEST_INVALID" }];
    assert(config::apply_env(store, invalid).len > 0);
    binding_integer(store, -9, "GOOSE_CONFIG_TEST_NUMBER"); binding_text(store, "", "GOOSE_CONFIG_TEST_TEXT");
    let large = [config::Binding { "text", "GOOSE_CONFIG_TEST_LARGE" }];
    assert(config::apply_env(store, large).len > 0);
    binding_text(store, "", "GOOSE_CONFIG_TEST_TEXT");
    var lists = config::Store { .. };
    let list_schema = [config::Field { "items", config::Kind.IntegerList }];
    assert(config::init(list_schema, lists).len == 0);
    let list_bindings = [config::Binding { "items", "GOOSE_CONFIG_TEST_LIST", ":" }];
    assert(config::apply_env(lists, list_bindings).len == 0);
    let items, items_error = config::get_integer_list(lists, "items");
    assert(items_error.len == 0 && items.len == 2 && items[0] == 2 && items[1] == -3);
}
fn binding_lists() {
    var store = config::Store { .. };
    let schema = [config::Field { "text", config::Kind.Text }, config::Field { "numbers", config::Kind.IntegerList },
                  config::Field { "words", config::Kind.TextList }, config::Field { "flags", config::Kind.BooleanList }];
    assert(config::init(schema, store).len == 0);
    let env = [config::Binding { "text", "TEXT" }, config::Binding { "numbers", "NUMBERS", ":" },
               config::Binding { "words", "WORDS", "::" }, config::Binding { "flags", "FLAGS" }];
    let initial = [config::EnvValue { "TEXT", "old" }, config::EnvValue { "NUMBERS", "1:-2:3" },
                   config::EnvValue { "WORDS", "::a::::b::" }, config::EnvValue { "FLAGS", "true,false" }];
    assert(config::apply_env_values(store, env, initial).len == 0);
    let numbers, ne = config::get_integer_list(store, "numbers");
    assert(ne.len == 0 && numbers.len == 3 && numbers[0] == 1 && numbers[1] == -2 && numbers[2] == 3);
    let words, we = config::get_text_list(store, "words");
    assert(we.len == 0 && words.len == 5);
    let expected_words = ["", "a", "", "b", ""];
    var word_index = 0;
    for word in words { assert(word == expected_words[word_index]); word_index++; }
    let flags, fe = config::get_boolean_list(store, "flags");
    assert(fe.len == 0 && flags.len == 2 && flags[0] && !flags[1]);
    let late_bad = [config::EnvValue { "TEXT", "changed" }, config::EnvValue { "NUMBERS", "1:bad" }];
    assert(config::apply_env_values(store, env, late_bad).len > 0);
    binding_text(store, "old", "TEXT");
    let missing: config::EnvValue[0] = [];
    assert(config::apply_env_values(store, env, missing).len == 0);
    let still_numbers, sne = config::get_integer_list(store, "numbers");
    assert(sne.len == 0 && still_numbers.len == 3 && still_numbers[1] == -2);
    let empty = [config::EnvValue { "NUMBERS", "" }];
    assert(config::apply_env_values(store, env, empty).len == 0);
    let cleared, ce = config::get_integer_list(store, "numbers");
    assert(ce.len == 0 && cleared.len == 0);
    let empty_separator = [config::Binding { "numbers", "NUMBERS", "" }];
    assert(config::apply_env_values(store, empty_separator, missing).len > 0);
    var long_separator = binding_repeat(':', 257);
    let oversize_separator = [config::Binding { "numbers", "NUMBERS", long_separator }];
    assert(config::apply_env_values(store, oversize_separator, missing).len > 0);
    let cli = [config::Binding { "text", "text" }, config::Binding { "numbers", "number" }, config::Binding { "words", "word" }];
    let args = ["--number=8", "--word=a,b", "--number", "-9", "--word="];
    assert(config::apply_cli(store, cli, args).len == 0);
    let repeated, re = config::get_integer_list(store, "numbers");
    assert(re.len == 0 && repeated.len == 2 && repeated[0] == 8 && repeated[1] == -9);
    let unsplit, ue = config::get_text_list(store, "words");
    assert(ue.len == 0 && unsplit.len == 2);
    var unsplit_index = 0;
    let expected_unsplit = ["a,b", ""];
    for word in unsplit { assert(word == expected_unsplit[unsplit_index]); unsplit_index++; }
    let bad_args = ["--text=changed", "--number=8", "--number=oops"];
    assert(config::apply_cli(store, cli, bad_args).len > 0); binding_text(store, "old", "TEXT");
    let single_empty = ["--word="];
    assert(config::apply_cli(store, cli, single_empty).len == 0);
    let singleton, singleton_error = config::get_text_list(store, "words");
    assert(singleton_error.len == 0 && singleton.len == 1);
    for word in singleton { assert(word.len == 0); }
    var max_items: const u8[:][>..] = [];
    for i in 256 { max_items.push("--number=1"); }
    assert(config::apply_cli(store, cli, max_items).len == 0);
    max_items.push("--number=1");
    assert(config::apply_cli(store, cli, max_items).len > 0);
    let kept, ke = config::get_integer_list(store, "numbers");
    assert(ke.len == 0 && kept.len == 256);
    var many_env: u8[>..] = [];
    for i in 256 { many_env.append("1:"); }
    many_env.push('1');
    let over_items = [config::EnvValue { "NUMBERS", many_env }];
    assert(config::apply_env_values(store, env, over_items).len > 0);
    var large_text: u8[>..] = []; large_text.append("--word=");
    large_text.append(binding_repeat('x', 4096));
    let big: const u8[:][1] = [large_text[..]];
    assert(config::apply_cli(store, cli, big).len == 0);
    let over_text: const u8[:][3] = ["--text=changed", large_text[..], "--word=y"];
    assert(config::apply_cli(store, cli, over_text).len > 0); binding_text(store, "old", "TEXT");
}
fn main() {
    if arg_count() > 1 {
        var mode: u8[>..] = []; arg(1, mode);
        assert(mode == "--environment"); native_environment();
    } else { supplied_environment(); command_line(); binding_lists(); }
    print("bindings tests passed");
}
