# v0.1 API contract

This contract is being prepared for v0.1.0; it does not mean the tag exists.
See [release preparation](release.md). All names use namespace `config`.
Optional imports: `config.toml`, `config.json_layer`, `config.bindings`,
`config.reload`. Use the compiler pinned by `GOOSE_REVISION`.

## Supported types

- `Kind`: Text, Integer, Float, Boolean, TextList, IntegerList, FloatList, BooleanList.
- `Field`, in order: key, kind, required=false, int_min=i64 minimum,
  int_max=i64 maximum, float_min=negative largest finite f64,
  float_max=largest finite f64. Both inclusive bound pairs must be valid.
- `Override { key, value, source }`: each field is `const u8[:]`.
- `ListOverride { key, values, source }`: key/source are `const u8[:]`;
  values is `const (const u8[:])[:]`.
- `Store`: construct as `Store { .. }`; all fields/layout are internal.
- `Binding { key, name, separator="," }`: fields are `const u8[:]`.
- `EnvValue { name, value }`: fields are `const u8[:]`.
- `LayerKind`: Values, Lists, Toml, Json, Environment, ProcessEnvironment, CommandLine.
- `Layer`, in order: kind; overrides=`const Override[:]`; lists=`const ListOverride[:]`;
  text/source=`const u8[:]` defaulting to empty; bindings=`const Binding[:]`;
  environment=`const EnvValue[:]`; arguments=`const (const u8[:])[:]`.
  Use `..` for inactive empty views; inactive nonempty data is rejected.

## Supported functions

Below, `error` means owned `u8[>..]`; empty means success. These signatures,
including slice qualifiers and argument order, define the supported surface.

```text
init(schema: Field[:], store: Store&) -> error
apply(store: Store&, inputs: Override[:]) -> error
apply_lists(store: Store&, inputs: ListOverride[:]) -> error
validate(store: Store&) -> error
get_integer(store: Store&, key: const u8[:]) -> i64, error
get_float(store: Store&, key: const u8[:]) -> f64, error
get_boolean(store: Store&, key: const u8[:]) -> bool, error
get_text(store: Store&, key: const u8[:]) -> const u8[:], error
source(store: Store&, key: const u8[:]) -> const u8[:], error
get_text_list(store: Store&, key: const u8[:]) -> u8[][>..], error
get_integer_list(store: Store&, key: const u8[:]) -> i64[>..], error
get_float_list(store: Store&, key: const u8[:]) -> f64[>..], error
get_boolean_list(store: Store&, key: const u8[:]) -> bool[>..], error
apply_toml(store: Store&, text: const u8[:], origin: const u8[:]) -> error
apply_json(store: Store&, text: const u8[:], origin: const u8[:]) -> error
apply_env(store: Store&, bindings: Binding[:]) -> error
apply_env_values(store: Store&, bindings: Binding[:], values: EnvValue[:]) -> error
apply_cli(store: Store&, bindings: Binding[:], args: const u8[:][:]) -> error
reload(schema: Field[:], layers: Layer[:], store: Store&) -> error
```

Discard getter values on error. Scalar Text/source borrow the store; lists are
independent owners, including Text elements (iterate these in Goose). Compiler
borrow rules apply even when rejected mutations preserve bytes. Inputs may
borrow the old store for a transaction; supported writers stage before publishing.

Init/reload may initialize a store; other calls reject uninitialized stores,
even on empty inputs. Successful init resets values. Empty valid apply batches
and documents are no-ops. Zero/false/empty Text/lists are present and satisfy
required fields. Apply replaces mentioned values; reload replaces current
sources after validation. Reported failures preserve the previous snapshot.
No concurrency/lock-free access, history or allocation recovery is promised.
Errors are owned ASCII, omit raw values and escape bounded labels; exact
wording, ordering and positions are not stable APIs.

## Limits and source rules

Supported constants: MAX_FIELDS=256, MAX_KEY_BYTES=256, MAX_VALUE_BYTES=4096,
MAX_SOURCE_BYTES=256, MAX_NUMBER_BYTES=128, MAX_LIST_ITEMS=256,
MAX_CLI_ARGUMENTS=512, MAX_LAYERS=32, JSON_MAX_INPUT_BYTES=1048576,
JSON_MAX_DEPTH=64 (including root), JSON_MAX_NODES=65536, JSON_MAX_WORK=16777216.
They are limits, not knobs. TOML's documented limits also constrain inputs;
its private parser symbols/constants are not supported APIs.

Environment names: 1..256 bytes excluding NUL/`=`. CLI names: 1..254 ASCII
component bytes, no initial hyphen/dots. Names/targets are unique and case
sensitive. Supplied environment pairs validate names, duplicates and value
caps even when unbound. Native environment reads copy before cap enforcement.
Separators are literal 1..256-byte strings used/validated only for environment
list bindings. Empty environment text clears a list; absence preserves it.
CLI args omit argv[0]; values beginning `--` require equals syntax; negative
separated values are supported. Repeated list flags accumulate; scalar repeats
fail. `--tag=` means one empty Text item, not an empty list. Only a final `--`
is allowed. [Complete type/source/validation rules](common-features.md).

## Compatibility boundary

Tagged 0.1.x patches preserve supported names/signatures, public struct field
order/defaults, enum variants, strict interpretation, ownership and transaction
semantics. Security-driven limit tightening requires explicit release notes.
Breaking changes require a new minor version before 1.0. Until v0.1.0 is tagged,
this remains a release-candidate contract. No binary ABI is promised.

All other visible symbols are internal: Store fields, Span/Item/Value/Candidate/
OwnedField/BoundSpan/JsonReader, lookup constants, helpers, `config_toml`, and
storage/layout/algorithm/timing behavior. `publish_store` requires distinct
stores and is not a public clone API.
