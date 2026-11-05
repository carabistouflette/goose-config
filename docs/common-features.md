# Common application setup

goose-config supports scalar settings and homogeneous primitive lists from JSON,
TOML, supplied environment values, the process environment, and CLI arguments.
It validates each layer and can rebuild a store from layers supplied at reload.
It does not discover files, watch them, load remote providers, or choose source
priority for the application.

From the repository root, run `make setup` once to install the pinned Goose
compiler. The [layered example](../examples/layered.goose) applies defaults, JSON,
registered environment variables, then registered CLI arguments. Applications
choose another order by passing layers in that order. The example also shows
how to pass actual process arguments:

```sh
GOOSE_EXAMPLE_PORT=9000 .toolchain/goose/build/goose run \
  examples/layered.goose -- --port=9100
```

For a running application with bounded file reads, see the optional
[job worker](worker.md).

## Lists

Declare `TextList`, `IntegerList`, `FloatList`, `BooleanList`, or `DurationList`.
Every item must match the declared kind. Numeric ranges apply to every item.
An empty list is present and satisfies `required`; use application validation
when a list must be nonempty. Applying a list replaces the whole old list.

```goose
let schema = [config::Field { key: "ports", kind: config::Kind.IntegerList,
                              int_min: 1, int_max: 65535 }];
var store = config::Store { .. };
assert(config::init(schema, store).len == 0);
let ports = ["8080", "9000"];
assert(config::apply_lists(store,
    [config::ListOverride { "ports", ports, "defaults" }]).len == 0);
let result, error = config::get_integer_list(store, "ports");
assert(error.len == 0 && result[0] == 8080);
```

List getters return owned arrays that remain valid after store updates or
destruction. Text-list items are separately owned and must be iterated in Goose.
See the [API limits](api.md#limits-and-source-rules) for list sizes.

## JSON and TOML

Import `config.json_layer` for `apply_json` and `config.toml` for `apply_toml`.
Objects and tables map to declared dotted keys. Arrays map only to declared
homogeneous primitive lists. Nested arrays, object lists, TOML date/time values,
and JSON `null` are rejected.

Types are strict: an integer is not accepted for a Float field, and a quoted
number is not accepted for an Integer field. Unknown keys, duplicate decoded
JSON keys, invalid UTF-8 strings, and unknown empty objects/tables are errors.
Integers are checked as integers; they are not converted through floating point.

Each layer is validated before it changes the store. A rejected document leaves
all values and source labels unchanged. JSON and TOML strings must be valid
UTF-8; text overrides applied through the core API may contain arbitrary bytes.
The JSON adapter limits input to 1 MiB, nesting depth to 64 including the root,
nodes to 65,536, and object siblings to 256. TOML has separate limits described
in [the API reference](api.md#limits-and-source-rules). Some inputs allowed by
the format specifications exceed these limits or the supported subset.

Errors do not echo raw values. Source labels are caller-provided text, not
verified file or environment identities.

## Environment and CLI bindings

Import `config.bindings`. A `Binding` maps a declared key to one exact source
name. There is no case folding, prefix matching, or name normalization.

- `apply_env_values` accepts an explicit snapshot of `EnvValue` pairs. It
  validates supplied pairs even when no binding uses them. Valid unbound names
  are ignored. `apply_env` reads only the names in the binding list.
- A missing environment value leaves the current value unchanged. Empty scalar
  Text is present; empty numbers and Booleans are invalid. Empty text for a list
  sets that list to empty.
- Environment list values split on the declared literal separator. There is no
  trimming, quoting, or escaping. Empty items and whitespace are preserved.
- `apply_cli` receives arguments without `argv[0]`. Use `--name=value` or
  `--name value`. A value beginning with `--` must use the equals form.
  Repeated list options accumulate; repeated scalar options are errors. CLI
  lists are not split on separators.

Binding names and targets must be unique. Errors omit raw environment and
argument values. Native environment reads copy the value before the adapter can
enforce its byte limit; use supplied snapshots when the input boundary must be
controlled by the caller.

## Reload

Import `config.reload` and call `reload(schema, layers, store)`. The supplied
layers are replayed in order into a new store, required fields are checked, and
the new store is published only if every step succeeds. A removed value falls
back to a value in a current lower layer or becomes absent. Removing a required
value rejects reload and preserves the old store. At most 32 layers are allowed.

The application supplies bounded file contents and chooses when to reload.
goose-config does not watch files or retain old layer contents. The guarantee is
atomicity for reported errors; it does not provide allocation recovery,
thread-safety, or lock-free access. Applications must synchronize concurrent
readers and writers.

[Duration values](durations.md) use the same strict type, layer, and reload rules.
