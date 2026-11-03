// SPDX-License-Identifier: Apache-2.0
// One document per process: failures must preserve both values and sources.
// The parser mode exposes resource diagnostics hidden by the public adapter.
import config from "..";
import config.toml;
import std;
import os;

fn main() {
    var document: u8[>..] = [];
    read_stdin(document);
    let argv = args();
    if argv.len > 1 {
        assert(argv.len == 2 && argv[1] == "parser");
        var parsed = config_toml::Document { .. };
        let error = config_toml::parse_into(document, parsed);
        if error.len > 0 { write_stderr(error); write_stderr("\n"); exit(1); }
        return;
    }
    var store = config::Store { .. };
    let schema = [config::Field { "s", config::Kind.Text }, config::Field { "i", config::Kind.Integer }];
    assert(config::init(schema, store).len == 0);
    let baseline = [config::Override { "s", "before", "baseline" }, config::Override { "i", "42", "baseline" }];
    assert(config::apply(store, baseline).len == 0);
    let error = config::apply_toml(store, document, "hostile.toml");
    if error.len > 0 {
        let text, text_error = config::get_text(store, "s");
        let integer, integer_error = config::get_integer(store, "i");
        let text_source, text_source_error = config::source(store, "s");
        let integer_source, integer_source_error = config::source(store, "i");
        assert(text_error.len == 0 && text == "before");
        assert(integer_error.len == 0 && integer == 42);
        assert(text_source_error.len == 0 && text_source == "baseline");
        assert(integer_source_error.len == 0 && integer_source == "baseline");
        for byte in error { assert(byte >= 32 && byte <= 126); }
        write_stderr(error); write_stderr("\n"); exit(1);
    }
}
