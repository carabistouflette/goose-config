// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;
fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { "name", config::Kind.Text },
                  config::Field { "debug", config::Kind.Boolean },
                  config::Field { "ratio", config::Kind.Float }];
    assert(config::init(schema, store).len == 0);
    assert(config::validate(store).len > 0);
    let defaults = [config::Override { "server.port", "8080", "defaults" },
                    config::Override { "name", "Goose", "defaults" },
                    config::Override { "debug", "false", "defaults" },
                    config::Override { "ratio", "1.5", "defaults" }];
    assert(config::apply(store, defaults).len == 0);
    assert(config::validate(store).len == 0);
    let port, pe = config::get_integer(store, "server.port"); assert(pe.len == 0 && port == 8080);
    let name, ne = config::get_text(store, "name"); assert(ne.len == 0 && name == "Goose");
    let debug, de = config::get_boolean(store, "debug"); assert(de.len == 0 && !debug);
    let ratio, re = config::get_float(store, "ratio"); assert(re.len == 0 && ratio == 1.5);
    let overrides = [config::Override { "server.port", "9000", "APP_PORT" }];
    assert(config::apply(store, overrides).len == 0);
    let updated, ue = config::get_integer(store, "server.port"); assert(ue.len == 0 && updated == 9000);
    let origin, oe = config::source(store, "server.port"); assert(oe.len == 0 && origin == "APP_PORT");
    let invalid = [config::Override { "name", "changed", "cli" }, config::Override { "server.port", "0", "cli" }];
    assert(config::apply(store, invalid).len > 0);
    let old, old_error = config::get_text(store, "name"); assert(old_error.len == 0 && old == "Goose");
    print("config: OK");
}
