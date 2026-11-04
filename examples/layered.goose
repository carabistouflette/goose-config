// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import std;
import os;

fn main() {
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, required: true, int_min: 1, int_max: 65535 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true },
                  config::Field { key: "tags", kind: config::Kind.TextList }];
    let defaults = [config::Override { "server.port", "8080", "defaults" },
                    config::Override { "name", "worker", "defaults" }];
    let default_tags = ["default"];
    let list_defaults = [config::ListOverride { "tags", default_tags, "defaults" }];
    let env = [config::Binding { key: "server.port", name: "GOOSE_EXAMPLE_PORT" },
               config::Binding { key: "tags", name: "GOOSE_EXAMPLE_TAGS", separator: "," }];
    let cli = [config::Binding { key: "server.port", name: "port" },
               config::Binding { key: "tags", name: "tag" }];
    let argv = args();
    var arguments: const u8[:][>..] = [];
    for i in 1..argv.len { arguments.push(argv[i]); }
    // Applications supply bounded file snapshots and choose when to reload.
    let layers = [config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. },
                  config::Layer { kind: config::LayerKind.Lists, lists: list_defaults, .. },
                  config::Layer { kind: config::LayerKind.Json,
                                  text: "{\"server\":{\"port\":9000},\"tags\":[\"from-file\"]}", source: "app.json", .. },
                  config::Layer { kind: config::LayerKind.ProcessEnvironment, bindings: env, .. },
                  config::Layer { kind: config::LayerKind.CommandLine, bindings: cli, arguments: arguments, .. }];
    var store = config::Store { .. };
    let error = config::reload(schema, layers, store);
    if error.len > 0 { write_stderr(error); write_stderr("\n"); exit(1); }
    let port, pe = config::get_integer(store, "server.port");
    let tags, te = config::get_text_list(store, "tags");
    assert(pe.len == 0 && te.len == 0);
    print("port=", port);
    // Owned variable-sized Text elements are iterated in Goose.
    for tag in tags { print("tag=", tag); }
}
