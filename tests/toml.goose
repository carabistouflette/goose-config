// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;
fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, int_min: 1, int_max: 65535 },
                  config::Field { "name", config::Kind.Text }, config::Field { "debug", config::Kind.Boolean },
                  config::Field { "ratio", config::Kind.Float }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_toml(store, "name = 'goose'\ndebug = true\nratio = 1.5\n[server]\nport = 8080\n", "app.toml").len == 0);
    let port, pe = config::get_integer(store, "server.port"); assert(pe.len == 0 && port == 8080);
    let name, ne = config::get_text(store, "name"); assert(ne.len == 0 && name == "goose");
    let ratio, re = config::get_float(store, "ratio"); assert(re.len == 0 && ratio == 1.5);
    let debug, de = config::get_boolean(store, "debug"); assert(de.len == 0 && debug);
    let source, se = config::source(store, "server.port"); assert(se.len == 0 && source == "app.toml");
    let invalid = ["server.port = '123'", "server.port = 1.0", "ratio = 1", "name = 42", "name = []", "name = 1979-05-27", "ratio = inf", "ratio = nan", "[unknown]", "'server.port' = 42", "[server]\nport = 0", "name = 'first'\nname = 'duplicate'", "name = 'x'\nunknown = 1", "name = 'x'\n[server]\nport = 'bad'", "name = \"\\uD800\"", "[server"];
    for text in invalid {
        assert(config::apply_toml(store, text, "bad.toml").len > 0);
        let previous, error = config::get_text(store, "name"); assert(error.len == 0 && previous == "goose");
        let origin, oe = config::source(store, "name"); assert(oe.len == 0 && origin == "app.toml");
    }
    assert(config::apply_toml(store, "", "empty").len == 0);
    assert(config::apply_toml(store, "[server]", "empty table").len == 0);
    assert(config::apply_toml(store, "server = { port = 9000 }", "inline").len == 0);
    assert(config::apply_toml(store, "server.port = 9001\nname = ''", "dotted").len == 0);
    let empty, ee = config::get_text(store, "name"); assert(ee.len == 0 && empty.len == 0);
    print("toml: OK");
}
