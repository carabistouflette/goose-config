# Common application configuration

The shipped scope is JSON/TOML scalar objects and homogeneous primitive lists,
explicit environment/CLI bindings, schema validation, and explicit reload.
It does not claim the full Viper/Koanf provider ecosystems. File discovery,
file watching, remote stores and struct reflection are outside this scope.

See [the complete layered example](../examples/layered.goose). It applies
defaults, a supplied JSON snapshot, registered environment variables, then
registered CLI flags. Run it with `--port=9100 --tag first --tag second`.
For in-process execution use `goose run examples/layered.goose -- --port=9100`.
Applications choose source order; there is no implicit priority hierarchy.

## Typed lists

Declare `Kind.TextList`, `IntegerList`, `FloatList`, or `BooleanList`.
Every element must match the declared kind; scalar/list coercion is rejected.
`Field` numeric bounds apply to each numeric element. An empty list is present
and satisfies `required`; nonempty/business rules remain application validation.
Lists replace the whole previous list, without element-wise merging.

```goose
let schema = [config::Field { key: "ports", kind: config::Kind.IntegerList,
                             int_min: 1, int_max: 65535 }];
var store = config::Store { .. };
assert(config::init(schema, store).len == 0);
let tokens = ["8080", "9000"];
let layer = [config::ListOverride { "ports", tokens, "defaults" }];
assert(config::apply_lists(store, layer).len == 0);
let ports, error = config::get_integer_list(store, "ports");
assert(error.len == 0 && ports[0] == 8080);
```

The four `get_*_list` getters return an owned array and an owned error. Discard
the array on failure. Returned values survive store updates/destruction. Text
elements are owned, independent byte arrays; iterate them because Goose does
not randomly index arrays of variable-sized elements. Scalar Text getters
continue returning borrowed views.

Each list has at most 256 elements. Text elements have at most 4096 combined
bytes per list; numeric tokens use the scalar 128-byte limit. The maximum
number of fields remains 256, giving at most 65,536 fixed-size item records
plus text/source arenas. Transaction staging and owned getter results add
temporary storage. These are logical bounds, not exact allocator budgets.

## JSON and TOML documents

Import `config.json_layer` for `apply_json`, or `config.toml` for `apply_toml`.
JSON uses a collision-safe module filename so standard `import json` remains
available. Reload imports these adapters transitively with relative paths.

Objects/tables map to declared dotted leaves. Arrays map only to declared
homogeneous primitive lists; nested arrays, object lists, dates, and JSON null
are rejected. JSON duplicate decoded keys/object branches are rejected even
when their leaves differ. Unknown empty objects/tables also fail. JSON integers
must fit i64 exactly. Fraction/exponent tokens are Float, and integer-looking
tokens are Integer; neither is silently converted to the other. Numeric floats
must be finite. JSON and TOML never round-trip integers through f64.

Both entrypoints validate complete layers before changing values or sources.
Text is owned. JSON/TOML strings require valid UTF-8; textual core overrides
still permit arbitrary bytes. Escaped NUL in string values is supported.
Decoded key components retain the core's bounded ASCII grammar; a literal
dotted JSON key is not interchangeable with a nested object.

JSON caps: 1 MiB input, depth 64 including the root, 65,536 value/container
nodes, 256 siblings per object, 256-byte decoded keys/paths, 128-byte numeric
tokens, and 16,777,216 compared-key bytes. Lists and per-value text use the
core limits above. TOML retains its independently pinned parser bounds in
[README](../README.md#costs-and-limits). Some valid format inputs are deliberately
rejected. Errors omit raw values; JSON's parse/type/key errors are intentionally
generic. Source labels are caller metadata, not verified identities.

## Environment and CLI bindings

Import `config.bindings`. `Binding { key, name, separator = "," }` explicitly
maps a source name to a schema key. Names and targets must be unique. Unknown
binding targets are errors even if absent. No normalization or case folding
occurs. At most 256 bindings and supplied environment pairs are accepted.

`apply_env_values(store, bindings, pairs)` accepts `EnvValue { name, value }`
snapshots. It validates every supplied name/value, including unbound pairs,
then applies bound values atomically. Unbound valid names are ignored. The
native `apply_env` reads only registered names. Absent names preserve existing
values; empty scalar Text is present, while empty numeric/Boolean text fails.
Empty environment text sets a list to empty. Nonempty list text is split by
the explicit nonempty separator, preserving empty elements and whitespace.
No quoting, escaping or trimming is implied. List types still validate every
token. A native environment getter copies before the adapter can enforce its
4096-byte value cap; use supplied bounded snapshots when that I/O boundary
matters. The adapter never mutates the process environment.

`apply_cli(store, bindings, arguments)` accepts arguments excluding argv[0].
Binding names omit `--`; names use ASCII letters/digits/underscore/hyphen and
cannot start with a hyphen. Supported forms are `--name=value` and
`--name value`. Negative separated values are accepted. A value starting with
`--` must use the equals form. Repeated list options accumulate in argument
order; repeated scalar targets fail. CLI lists are not comma-split. Empty
`--tag=` adds one empty Text item. Unknown options, missing values, shorthand
and positional arguments fail. `--` is accepted only as the final argument.
The cap is 512 argument tokens. List item/text and scalar byte limits still
apply. Errors never echo raw argument/environment values. Sources are the
registered environment name or `--name`, respectively.

Mixed binding layers stage an independent owned store, then publish it only
after every bound value validates. The current implementation rebuilds live
payloads per bound key and copies the staged store at publication; this is an
explicit loading cost, not a constant-time-update claim.

## Replacement reload

Import `config.reload` and call `reload(schema, layers, store)`. Each `Layer`
must use `..` to initialize unused fields to empty views; unused nonempty data
is rejected. Kinds are `Values`, `Lists`, `Toml`, `Json`, `Environment`
(supplied pairs), `ProcessEnvironment`, and `CommandLine`. At most 32 layers
are replayed in the supplied order. Nothing in the layer snapshots is retained.

Reload initializes a fresh schema, replays current layers, checks required
fields, then publishes owned storage. Removing a file key or upper layer
exposes only a current lower layer; a value with no lower definition becomes
absent. Removing a required value rejects the reload and preserves the old
snapshot. Schema, parsing, binding, type, range, limit and required-field
failures all preserve the previous store, values and provenance. Old-store
views can supply inputs because publication happens after consumption.

Applications own file I/O, bounded snapshots, reload triggers, business-rule
validation and synchronization. Reload is atomic with respect to reported
errors, not a lock-free/concurrent operation. It does not watch files or retain
untrusted source text for automatic replay. Allocation failure follows the
Goose runtime policy rather than returning a configuration error.
