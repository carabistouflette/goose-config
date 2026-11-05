# Generated typed settings

The optional build tool turns one bounded declarative JSON schema into a Goose
module. Applications get an owned `Settings` struct, `schema()`, `aliases()` and
checked `load` overloads. Generated modules import `config.typed`; applications
that use only the original Store/getter interface do not need this adapter.
The original six runtime modules, Store layout and compiler pin are unchanged.
Generated `stage`, `accept` and `own_text` functions are unsupported internal
helpers. `stage` requires fresh private staging and does not provide the public
loader's atomic-publication contract by itself.

The generator needs Python 3.11+ and the pinned Goose compiler for formatting.
Generation does not evaluate schema expressions or fetch imports. Commit the
schema and generated source, then check regeneration in CI:

```sh
make generated GOOSE=/absolute/path/to/pinned/goose
make generated-check GOOSE=/absolute/path/to/pinned/goose
```

These targets regenerate/check the real worker and the all-kinds test fixture.
For another application, create a schema such as:

```json
{
  "version": 1,
  "namespace": "app_settings",
  "fields": [
    {"member": "port", "key": "server.port", "kind": "Integer",
     "required": true, "int_min": 1, "int_max": 65535},
    {"member": "label", "key": "server.label", "kind": "Text", "source": true}
  ],
  "aliases": [{"key": "server.old_port", "target": "server.port"}]
}
```

Generate into the application's source directory. The explicit import points to
its neighboring goose-config checkout. The root application must declare this
`config` dependency too: the generated module's import is a requirement, not a
transitive declaration. A remote `owner/repo@FULL_40_HEX_COMMIT` reference is also
supported; use the same repository/full commit in the root declaration and choose
a commit containing `typed.goose`. The earlier alias-only dependency pin does not.

```sh
python3 /path/to/goose-config/tools/generate_settings.py settings.json \
  --output app_settings.goose --config-import ../goose-config \
  --goose /absolute/path/to/pinned/goose
# Repeat with --check and the same import argument to reject stale output.
```

```goose
import config from "../goose-config";
import app_settings;
import std;
fn main() {
    let fields = app_settings::schema();
    let aliases = app_settings::aliases();
    var store = config::Store { .. };
    assert(config::init(fields, store, aliases).len == 0);
    assert(config::apply(store, [config::Override { "server.old_port", "8080", "cli" }]).len == 0);
    var settings = app_settings::Settings { .. };
    let error = app_settings::load(store, settings);
    if error.len > 0 { print(error); return; }
    assert(settings.port == 8080 && !settings.label_present);
}
```

Paths resolve relative to each importing file. If this module is instead under
`app/generated/` beside `app/main.goose`, generation uses
`--config-import ../../goose-config`, while the root still uses `../goose-config`
and imports `generated.app_settings`.
The default `..` is convenient for this repository's `examples` and `tests`
directories; it is not a portable default for arbitrary outputs.

Applications should handle initialization/layer errors rather than using the
example's assertions. `schema()` and `aliases()` return fresh metadata arrays
with literal key storage; the normal `init`/`reload` APIs own their copies.
Source ordering, defaults, binding names and reload triggers remain explicit
application choices. Aliases must be resupplied on replacement reload.

## Owned values and optional presence

All ten current kinds are supported: Text, Integer, Float, Boolean, Duration and
their homogeneous list kinds. Text and source fields are owned byte builders;
TextList fields own every element. Values outlive the Store and later reloads.
Goose variable-sized arrays must be iterated, not randomly indexed.

Each field has `member`, `key`, `kind`, optional `required=false` and `source=false`.
Integer/Duration kinds and their lists allow inclusive `int_min`/`int_max`;
Float kinds allow inclusive `float_min`/`float_max`. Integer bounds stay exact i64
values. Float bounds are binary-f64 constraints: integer JSON bounds convert to
f64 and may round. Schema strings are metadata, not value defaults or code.

An optional field adds `<member>_present`. Absence resets that flag, its payload
and any source: scalar zero/false, zero nanoseconds, or an empty owner. These are
placeholders, not configured defaults. Empty/zero/false configured values remain
present. Read the presence flag before using an optional payload. `source:true`
adds independently owned `<member>_source`, empty when the field is absent.
Generated-name collisions are rejected, including these added names.

Construct Settings as `Settings { .. }`, then load before use. Its fields are
application values; modifying them does not mutate the Store or revalidate them.
The generated struct layout may change when its schema changes; it is not a
binary compatibility interface.

## Validation and publication

`load(store, destination) -> owned error` stages a fresh private Settings and
changes the destination only after every check succeeds. It uses checked getters
and `config::has_value(store, key, expected_kind)` from `config.typed`. That helper
returns `(bool, owned error)`: absent declared values return false/success;
unknown keys, uninitialized stores and wrong kinds return errors. Kind checking
also applies to absent optional values; aliases resolve normally.

Loading is a projection onto declared keys: extra Store fields are permitted,
including unrelated absent required fields. Each generated key must exist with
the expected kind, potentially through the Store's registered aliases. The
loader independently checks its own requiredness and explicit value bounds,
including every list item. A differently constrained Store cannot bypass those
checks. It does not certify the Store's complete schema identity or validate
unrelated keys. Normal `reload` still validates that Store's required fields.

For application rules, use `load(store, destination, validator)`. The last
argument is a named/static function taking `const Settings&` and returning owned
`u8[>..]`; empty means success. The generator passes an actual const reference,
so even a mutable callback spelling cannot write candidate fields. Validation
runs after staging and before publication. Getter/range/required failures never
invoke it. The worker uses this overload for identifier, queue and min/max rules.

Validators must not modify or reentrantly load the destination through captured
references. External callback side effects are not rolled back. Candidate views
cannot escape their scope under the pinned compiler's borrow rules. Generated
errors omit values; arbitrary validator errors are authored by the application
and do not automatically inherit the core's safe-diagnostic guarantee.

Reported failures preserve the previous destination. This does not promise
allocation recovery, thread safety, lock-free publication or rollback of process
aborts. One publication copy does not mean one total copy: Text is staged then
copied; list getters produce owned temporaries, followed by candidate and
publication copies. No zero-copy or loading speedup is implied.

## Tool limits and output safety

Input is at most 1 MiB, with 1..256 fields and at most 256 direct aliases. Ordinary
key/alias grammar, prefix conflicts and 256-byte key limits apply. Namespace and
member names use lower-case ASCII identifiers beginning with a letter, up to 64
bytes; reserved words and
emitted-name collisions fail. Unknown properties, duplicate JSON properties,
malformed UTF-8, oversized/deep malformed JSON, nonfinite numbers, booleans in
numeric positions, reversed bounds and number tokens over 128 bytes fail.

Imports accept relative components containing ASCII letters/digits/`_`/`-`, plus
`.` and `..`, or full-commit package references. Absolute paths, spaces and dotted
directory names are rejected. Metadata cannot supply arbitrary Goose types,
expressions or validator bodies. The compiler is an explicitly trusted local
executable; version/format commands have deadlines and use argument arrays,
not a shell. Schema validation precedes formatter invocation.

Output is replaced atomically only after successful validation/formatting.
Failed generation and `--check` leave existing files unchanged. New outputs are
owner-only (0600); replacements retain existing rwx permission bits. Writable output
symlinks are rejected.

The [worker](worker.md) demonstrates actual files, native environment and CLI
settings followed by validated typed publication. Its existing filesystem,
process, signal and trusted-input limits remain in effect. This feature does
not complete the sustained-fuzz release gate or imply a release tag.

See [validation and maximum native qualification](typed-validation.md) and
[measured workload costs and controls](typed-performance.md).
