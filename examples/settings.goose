// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;

fn main() {
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { "server.host", config::Kind.Text }, config::Field { "debug", config::Kind.Boolean }];
    var settings = config::Store { .. };
    assert(config::init(schema, settings).len == 0);
    let defaults = [config::Override { "server.host", "localhost", "defaults" },
                    config::Override { "debug", "false", "defaults" }];
    assert(config::apply(settings, defaults).len == 0);
    assert(config::apply_toml(settings, "[server]\nport = 8080\n", "app.toml").len == 0);
    // The application reads environment/argv and explicitly maps supplied values.
    let environment = [config::Override { "server.port", "9000", "APP_PORT" }];
    let cli = [config::Override { "debug", "true", "--debug" }];
    assert(config::apply(settings, environment).len == 0);
    assert(config::apply(settings, cli).len == 0);
    assert(config::validate(settings).len == 0);
    let port, error = config::get_integer(settings, "server.port");
    let origin, source_error = config::source(settings, "server.port");
    assert(error.len == 0 && source_error.len == 0);
    print("port=", port, " (from ", origin, ")");
}
