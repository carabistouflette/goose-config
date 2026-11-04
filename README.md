# goose-config

Pure, schema-driven configuration for the [Goose language](https://github.com/aardappel/goose).
Apache-2.0. Experimental API; no tagged release yet.

Explicit layers of defaults, TOML, environment values and CLI overrides; strict
Text/Integer/Float/Boolean types, numeric ranges, required settings, owned
values and source labels. No runtime dependencies beyond Goose's standard
library. Applications own file/process I/O and the order of layers.

## Quick start

```sh
git clone https://github.com/carabistouflette/goose-config.git
cd goose-config
make setup check test
.toolchain/goose/build/goose run examples/settings.goose
```

The example prints `port=9000 (from APP_PORT)`. `make setup` builds the pinned
compiler locally; see the development requirements below.

For another project, declare a full-commit dependency in its root Goose file:

```goose
import config from "carabistouflette/goose-config@d3082dc0b15a9f56e3c59146f343ecfd67b2a6ee";
import config.toml; // optional; omit for key/value-only applications
import std;

fn main() {
    let schema = [config::Field {
        key: "server.port", kind: config::Kind.Integer,
        required: true, int_min: 1, int_max: 65535
    }];
    var settings = config::Store { .. };
    assert(config::init(schema, settings).len == 0);
    assert(config::apply_toml(settings, "[server]\nport = 8080", "app.toml").len == 0);
    let overrides = [config::Override { "server.port", "9000", "APP_PORT" }];
    let error = config::apply(settings, overrides);
    if error.len > 0 { print(error); return; }
    let missing = config::validate(settings);
    if missing.len > 0 { print(missing); return; }
    let port, read_error = config::get_integer(settings, "server.port");
    if read_error.len > 0 { print(read_error); return; }
    print(port);
}
```

`assert` keeps this example short; applications should handle all returned errors.
See [the layered example](examples/settings.goose). The full commit above pins
the reviewed implementation; select a newer full commit when updating.
For a neighboring checkout, use `import config from "../goose-config";` instead.
Examples inside this repository use `import config from "..";`.

## Platforms

Validated on Linux x86_64 with the pinned Goose compiler, GCC 16.2.1 and
Clang 23.1.4. CI targets Ubuntu 24.04 x86_64 with its installed GCC and Clang.
Other platforms and compiler revisions have not been validated by this project.
The core and TOML modules perform no OS I/O; setup, test and benchmark scripts
currently target a Linux development environment.

## API

| API | Contract |
| --- | --- |
| `Field { key, kind, required = false, ... }` | Declare one setting and optional inclusive bounds |
| `Override { key, value, source }` | One textual override with an explicit source label |
| `init(schema, store)` | Validate and copy a schema; success clears old settings; failure preserves the old store |
| `apply(store, overrides)` | Atomically apply one textual layer; last successful layer wins |
| `apply_toml(store, text, source)` | Atomically apply a TOML document; requires `import config.toml` |
| `validate(store)` | Check required settings after layering |
| `get_integer`, `get_float`, `get_boolean`, `get_text` | Return `(value, error)`; no implicit fallback or coercion |
| `source(store, key)` | Return `(borrowed source label, error)` for a present setting |

Every error is an owned byte builder: empty means success. Getter values on
failure must be discarded. Unknown keys, absent values, wrong getters, and
uninitialized stores return errors. Empty text, zero, and false are present
values. Optional settings may remain absent; every field is optional unless
`required: true`. An empty schema is valid. `validate` does not freeze a store:
further explicit layers are allowed. Successful initialization resets all values.

`Field` has `int_min`/`int_max` (`i64`) and `float_min`/`float_max` (`f64`), defaulting
to the full finite range. Bounds are inclusive, must be ordered, and float bounds
must be finite. Both pairs are validated for every field; only its matching kind
uses them. Integer bounds remain integers, including above 2^53. Types and ranges
are checked on every apply; required presence is checked only by `validate`.
Application-specific rules, including allowed text choices, remain application
validation.

## Layers and spelling

There are no implicit sources or fixed source priorities. Apply defaults, file
contents, supplied environment values and CLI overrides in that order if that
is the desired precedence. Source labels are caller-provided metadata, not
verified identities. Explicitly map names such as `APP_PORT` or `--port` to
`server.port`; absent environment variables/options should produce no override.
There is no case folding or underscore/dot normalization.

Keys are case-sensitive ASCII components of letters, digits, `_`, or `-`, joined
by dots. Components cannot be empty. Duplicate schema keys and prefix conflicts
(`server` and `server.port`) are rejected. Duplicate keys within a textual batch
are rejected, even with identical values. Unknown settings always fail. Empty
batches leave the store unchanged. A rejected override is an error even when a
later layer could replace it. Applications should stop and handle that error;
there is no automatic fallback to old values.

Textual overrides accept:

- Text: arbitrary bytes, including empty strings, NUL and invalid UTF-8. No trimming.
- Integer: optional `+`/`-` and one or more decimal digits within `i64`.
- Float: optional sign, decimal digits, optional fraction with digits on both sides
  of `.`, and optional `e`/`E` exponent with optional sign and required digits.
  Integer-looking tokens and leading zeroes are accepted. Only finite `f64`
  results are accepted; correctly rounded underflow to signed zero is allowed.
- Boolean: exactly `true` or `false`.

Whitespace, hexadecimal, separators, suffixes, `.5`, `1.`, NaN and infinity are
not accepted as textual numbers. Numeric tokens are bounded before conversion.

## TOML

The optional adapter imports its private parser with an explicit relative
module path, so unrelated application packages named `vendor` can coexist.
It vendors a fixed Apache-2.0 TOML parser; see
[vendor provenance and local hardening](vendor/README.md). It targets TOML 1.0
within the parser limits. Dotted keys, tables and inline tables become dotted
schema paths. Decoded key components must follow the same ASCII grammar:
`"server.port"` is rejected as an ambiguous single component, while
`server.port` is valid. Every table must prefix a declared field; unknown empty
tables are errors. Empty known tables and empty documents apply no values.

Scalar types must match exactly: `port = "42"` cannot satisfy Integer, `ratio = 1`
cannot satisfy Float, and `name = 42` cannot satisfy Text. Numeric TOML values are
transferred directly, without a text formatting round trip. TOML integer bases
and float syntax follow TOML 1.0. Strings are decoded UTF-8. Arrays, arrays of
tables, date/time values and nonfinite numbers are rejected. No parser partial
result reaches the store. Parse errors return a generic source-aware error;
line/column details are deliberately not exposed in this version.

## Ownership, atomicity and diagnostics

The store copies schema keys, values and source labels; inputs can be changed or
destroyed after the call. Scalar getters return independent values. `get_text`
and `source` return read-only borrowed views: keep the store alive and do not
mutate it while using them. Goose checks these lifetimes. Borrowed views can be
used solely as the next override's inputs: the transaction stages all data
before replacing the previous arena. Schema keys, TOML text, and TOML source
labels may likewise borrow old store storage solely as inputs to their next
initialization/update: they are staged before replacement. Reinitialization invalidates old views.

Failed `init`, `apply` and `apply_toml` preserve all values and source labels.
Successful layers replace only mentioned settings and retain no history.
This guarantee covers reported validation/parse failures; allocator failure
follows Goose's runtime behavior, with no recovery promise. Store fields and
helper functions are implementation details; direct mutation is unsupported.
Applications coordinate any concurrent use.

Errors escape non-ASCII, control, quote and backslash bytes in key/source labels,
truncate long labels, and never include raw values or TOML text. Diagnostics
contain printable ASCII and no newline. This is not general secret redaction:
keys and source labels should not themselves contain secrets. Consumer overload
regressions protect error construction and numeric validation from application
formatting, copy, sizing and growable-buffer parser overloads.

## Costs and limits

- Schema and one override batch: at most **256** settings.
- Key and source label: at most **256 bytes** each.
- Text override or decoded TOML string: at most **4096 bytes**.
- Textual numeric token: at most **128 bytes** before conversion.
- TOML parser: **1 MiB** input, **65,536 nodes**, logical depth **64**, bare scalar
  token **128 bytes**, cumulative index work **16,777,216 units**.

These deliberately reject some otherwise valid inputs. Limits are immutable
constants; modifying internal data or the vendored parser is outside the API.

For valid schemas wider than eight fields, initialization checks field rules,
builds the index with bounded merge sort in O(fields × log(fields)) key
comparisons, then detects duplicate and dotted-prefix conflicts using an
ancestor stack with O(fields) bounded comparisons. Raw-prefix ancestors are
retained across lexical neighbors such as `a-` between `a` and `a.b`. Small or
rejected schemas use the original quadratic validator, preserving exact
first-error precedence and failed-initialization atomicity. Up to eight fields
use linear lookup. Wider schemas keep a sorted array of field IDs and use
deterministic binary search,
with a fast path for the first declared field. Metadata and validation errors
retain declaration order. Comparisons skip equal eight-byte prefixes using
bounds-checked slices; no unaligned casts or hash-table collision assumptions
are involved. Layer validation performs one bounded lookup per entry; TOML
table-prefix validation remains linear in schema size. Commit uses a fixed
field-indexed replacement map, then rebuilds the live value arena once to
ensure atomic ownership. Even a one-key update copies all current text and
source bytes. Persistent logical payload is bounded by
256 × (4096 + 256) bytes plus at most 256 × 256 key bytes and fixed-size metadata.
Temporary transaction data adds another live payload; parsing TOML adds its own
bounded arenas. These are logical size bounds, not exact allocator budgets.
Repeated layers retain no history and have no total layer-count limit. Runtime
storage can retain high-water capacity. See [benchmarks](bench/README.md).

## Development

```sh
make setup
make format check test property security sanitize
SANITIZER_CC=clang make sanitize
make release RELEASE_CC=gcc
make release RELEASE_CC=clang
make conformance
make bench BENCH_ITERATIONS=1000
```

Setup needs Git, CMake 3.27+, C/C++20 compilers, and Make; Linux's in-process
runner needs libc development headers. Tests need Python 3.11+. Sanitizers and
benchmarks target Linux with GCC; `SANITIZER_CC=clang` can select Clang's compatible
sanitizer flags. Sanitizers use C `-O2` with `--debug --no-bce`. Goose's debug
mode emits `-O0`; the wrapper appends `SANITIZER_OPT` last so its setting wins.
A compiler-state prerequisite checks actual ASan/optimization markers and
requires a UBSan runtime overflow diagnostic before running the suite.
`SANITIZER_OPT=-O0` selects unoptimized debugging. Use
`make GOOSE=/absolute/path/to/goose ...` with an existing compiler. Optimized
release checks require the selected GCC or Clang compiler.
`GOOSE_REVISION` pins the same compiler as goose-json; compatibility
with other revisions is not guaranteed. The optional `conformance` target needs
Go 1.27+ (or automatic Go toolchain downloads); it builds the official runner
at `TOML_TEST_REVISION` from a private immutable Git export with read-only
module dependencies and ambient Go workspaces disabled. Dirty cache files and
HEAD are preserved. Conformance executes the private binary, so concurrent
setup cannot replace the runner mid-check.

Tests exercise in-process, native, native debug, and optimized GCC/Clang
execution, plus compile-time ownership and consumer-overload checks. Eight
isolated consumer cases exercise import ordering, module-name collisions,
transitive imports, paths containing spaces, and a core-only package without
the TOML files; each runs in-process and as a GCC `-O2` executable. Two
independent models check 2,206 flat-schema transactions and 2,109 nested
transactions with 100,577 responses across 45 reinitialization cycles.

The hostile-input suite checks 331 resource/malformed cases per build,
including genuine bucket and full-hash collision budget rejection with a
five-second per-case timeout. A fixed-length control verifies all 500
long-key hashes against the pinned Goose implementation. Accepted small and
near-limit controls guard against blanket rejection; larger clusters must
report the parser's work limit. Rejected layers are checked for preservation of
every seeded value and source. AddressSanitizer/UndefinedBehaviorSanitizer cover
behavior, ownership, independent-model and hostile-input suites. CI runs both
optimized compilers and optimized GCC/Clang sanitizer builds, and smoke-runs
benchmarks without timing thresholds. Thirteen Python regressions reject corrupt
benchmark records, including nonfinite or boolean samples, duplicate rows,
and renamed fixtures.

`make conformance` checks the vendored parser against all 208 valid and 509
invalid TOML 1.0 cases at the pinned official `toml-test` revision. It compares
decoded values and types, not only acceptance. This tests the full private
parser; the public config adapter deliberately supports only its documented
scalar subset. No encoder is provided or tested. The suite is not exhaustive.
See [CONTRIBUTING.md](CONTRIBUTING.md).

See [the feature-gap matrix and reproducible cross-library comparison](docs/comparison.md)
for Viper/Koanf coverage and measurement limits. Feature parity is not yet implemented.

[Apache-2.0](LICENSE). Copyright 2026 goose-config contributors.
See [third-party notices](THIRD_PARTY_NOTICES.md), [security reporting](SECURITY.md),
and [contribution standards](CONTRIBUTING.md).
