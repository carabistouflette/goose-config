// SPDX-License-Identifier: Apache-2.0
// Explicit source replacement; applications own file I/O and reload triggers.
import config;
import .toml;
import .json_layer;
import .bindings;
namespace config;

const MAX_LAYERS = 32;
enum LayerKind { Values, Lists, Toml, Json, Environment, ProcessEnvironment, CommandLine }
struct Layer {
    kind:      LayerKind,
    overrides: const Override[:], lists: const ListOverride[:],
    text:      const u8[:] = "", source: const u8[:] = "",
    bindings:  const Binding[:], environment: const EnvValue[:],
    arguments: const (const u8[:])[:],
}

// Reject accidental fields that the selected layer would otherwise ignore.
fn layer_problem(layer: Layer&) -> u8[>..] {
    if layer.overrides.len > MAX_FIELDS || layer.lists.len > MAX_FIELDS || layer.bindings.len > MAX_FIELDS ||
       layer.environment.len > MAX_FIELDS || layer.arguments.len > MAX_CLI_ARGUMENTS { return problem("layer entry limit exceeded"); }
    if layer.kind != LayerKind.Values && layer.overrides.len > 0 { return problem("unused override layer data"); }
    if layer.kind != LayerKind.Lists && layer.lists.len > 0 { return problem("unused list layer data"); }
    let document = layer.kind == LayerKind.Toml || layer.kind == LayerKind.Json;
    if !document && (layer.text.len > 0 || layer.source.len > 0) { return problem("unused document layer data"); }
    let bound = layer.kind == LayerKind.Environment || layer.kind == LayerKind.ProcessEnvironment || layer.kind == LayerKind.CommandLine;
    if !bound && layer.bindings.len > 0 { return problem("unused binding layer data"); }
    if layer.kind != LayerKind.Environment && layer.environment.len > 0 { return problem("unused environment layer data"); }
    if layer.kind != LayerKind.CommandLine && layer.arguments.len > 0 { return problem("unused command-line layer data"); }
    []
}

// Fresh schema and source snapshots are replayed in caller order. Validation
// precedes publication; removal of a source/key exposes only lower layers.
// Nothing in Layer is retained. Input slices may borrow the old store.
fn reload(schema: Field[:], layers: Layer[:], store: Store&, aliases: const Alias[:] = []) -> u8[>..] {
    if layers.len > MAX_LAYERS { return problem("too many configuration layers"); }
    var next = Store { .. };
    var error = init(schema, next, aliases);
    if error.len > 0 { return error; }
    for layer in layers {
        let unused = layer_problem(layer);
        if unused.len > 0 { error.append(unused); return error; }
        // Copy bounded slice descriptors, never payloads, into writable views
        // for the existing adapters. The caller's source snapshots stay intact.
        var bindings: Binding[>..] = []; bindings.append(layer.bindings);
        if layer.kind == LayerKind.Values {
            var values: Override[>..] = []; values.append(layer.overrides);
            error = apply(next, values);
        } else if layer.kind == LayerKind.Lists {
            var values: ListOverride[>..] = []; values.append(layer.lists);
            error = apply_lists(next, values);
        }
        else if layer.kind == LayerKind.Toml { error = apply_toml(next, layer.text, layer.source); }
        else if layer.kind == LayerKind.Json { error = apply_json(next, layer.text, layer.source); }
        else if layer.kind == LayerKind.Environment {
            var values: EnvValue[>..] = []; values.append(layer.environment);
            error = apply_env_values(next, bindings, values);
        } else if layer.kind == LayerKind.ProcessEnvironment { error = apply_env(next, bindings); }
        else if layer.kind == LayerKind.CommandLine {
            var values: const u8[:][>..] = []; values.append(layer.arguments);
            error = apply_cli(next, bindings, values);
        }
        else { return problem("unsupported configuration layer kind"); }
        if error.len > 0 { return error; }
    }
    error = validate(next);
    if error.len > 0 { return error; }
    publish_store(store, next);
    []
}
