# Generated environment and CLI bindings

The optional settings generator accepts `env`, `cli` and `separator` on each
field. These are explicit names, not automatic prefix/case conversion. For example:

```json
{"member":"queues","key":"worker.queues","kind":"TextList",
 "env":"GOOSE_WORKER_QUEUES","cli":"queue","separator":","}
```

Every generated module imports `config.bindings` and exposes:

```text
env_bindings() -> config::Binding[N_env]
cli_bindings() -> config::Binding[N_cli]
```

Counts are known at generation time. Both functions exist even when their count
is zero. Each call returns a fresh fixed-size container in field declaration
order; it is not a growable builder. Its key/name/separator views reference
immutable generated literals. Changing a descriptor does not change other calls.
To extend a mapping, append the result into your own `config::Binding[>..]` builder.
Helpers are marked inline to preserve the former fixed-literal construction shape.
No source is read or applied by constructing these arrays.

Bindings always target the field's canonical key. One mapping per field/source
makes duplicate resolved targets impossible in a valid generated schema. Env and
CLI names must be unique separately, case-sensitively; a spelling may be reused
across the two sources. Omission means unbound. Empty/null/nonstring properties
are invalid. Generated helper names are reserved identifiers.

- Env names: valid UTF-8, 1..256 encoded bytes, excluding NUL and `=`. Controls,
  quotes, backslashes and non-BMP characters are encoded safely as Goose bytes.
- CLI names: 1..254 ASCII letters/digits/underscore/hyphen, without an initial
  hyphen. Dots, whitespace and Unicode are rejected. Do not include `--`.
- Separator: only allowed on an env-bound list, default comma, 1..256 UTF-8 bytes,
  excluding NUL. CLI lists retain repeated-flag accumulation; they are not split.
  This metadata restriction is narrower than the existing supplied-value runtime
  API, which can use arbitrary byte separators. The runtime API is unchanged.

All existing schema/input limits remain. Unpaired surrogates, duplicate names,
invalid inactive separators and bad byte lengths fail before formatting/output
replacement. Source generation uses UTF-8 byte escapes; JSON Unicode escapes are
not inserted into Goose source. Existing output remains unchanged on failure.

Applications choose layer order, explicit application and reload timing:

```goose
let environment = worker_settings::env_bindings();
let cli = worker_settings::cli_bindings();
```

Pass these arrays to the existing adapters or Layers. Empty environment text
clears a list; absent values preserve it. Original source labels, type/range
checks, list behavior, duplicate detection and atomic failures remain those of
[the binding API](common-features.md). Defaults remain application-owned.

The [worker schema](../schemas/worker.json) is now the single declaration of its
field-to-env/CLI mappings. Its native file reads, command protocol, defaults,
source ordering and business rules are unchanged. Generated modules now require
`config.bindings` as well as `config.typed`; minimal copied consumers need
`bindings.goose` too. This imports declarations, not environment reads.

Use `make generated` and `make generated-check` with the pinned compiler. See
[typed settings](typed-settings.md) for tool invocation and root dependency rules.
This milestone does not close the sustained-fuzz release gate or create a tag.

See [qualification and retained adoption-cost measurements](generated-bindings-validation.md).
