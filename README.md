# goose-config

goose-config is a configuration library for [Goose](https://github.com/aardappel/goose).
It provides typed settings, strict JSON and TOML layers, environment and CLI
bindings, validation, direct key aliases, and explicit reload.

**Status:** experimental; no release tag has been published. Pin a full commit
in application imports. The API may change before the first release.

## Quick start

```sh
git clone https://github.com/carabistouflette/goose-config.git
cd goose-config
make setup
.toolchain/goose/build/goose run examples/settings.goose
```

The example prints `port=9000 (from APP_PORT)`. It applies sample values with
explicit source labels; it does not read the process environment. For actual
environment and CLI bindings, run `examples/layered.goose` as described in
[Common application setup](docs/common-features.md).

To use the library in another project, import a full commit. This example pins
the published implementation at `4f977c0b1e4f06832b776c847d53897215c5a0bc`;
this documentation update does not change its runtime modules:

```goose
import config from "carabistouflette/goose-config@4f977c0b1e4f06832b776c847d53897215c5a0bc";
import config.toml; // optional
```

There is no tagged `v0.1.0` release. Applications should review and pin the
exact commit they use.

## What it supports

- `Text`, `Integer`, `Float`, `Boolean`, and `Duration` values, plus homogeneous
  lists of those types.
- JSON and TOML objects with declared dotted keys and strict value types.
- Explicit environment and command-line mappings. Applications choose their
  layer order; the library does not infer names or precedence.
- Required fields, inclusive numeric ranges, owned list results, and source
  labels for values supplied by each layer.
- Direct key aliases and replacement reload from the layers supplied by the
  application.
- An optional schema generator for owned typed settings and env/CLI mappings.

The library does not discover or read configuration files, watch them, load
remote providers, reflect arbitrary application structs, or synchronize access
between threads. Applications own file I/O, reload triggers, business rules,
and concurrency control. See the [API contract](docs/api.md) and
[feature comparison](docs/comparison.md).

## Limits and behavior

Inputs have fixed limits: 256 fields and aliases, 256-byte keys and source
labels, 256 items per list, 4096 bytes of retained text per value, 32 reload
layers, and 512 CLI argument tokens. JSON and TOML documents are limited to
1 MiB; each format has additional parser limits. See the full
[API limits](docs/api.md#limits-and-source-rules).

Values must match their declared type. Lists replace whole lists. A reported
validation or parse error leaves the previous store unchanged. Reload starts
from the layers supplied for that reload, so removed values do not persist from
an earlier snapshot. Scalar text and source-label getters borrow the store;
list getters return owned arrays. Keep the store alive while using borrowed
views, and do not use a store concurrently without application synchronization.

## Examples and guides

- [Basic settings](examples/settings.goose)
- [Layering with process environment and CLI arguments](examples/layered.goose)
- [Duration values](examples/durations.goose) and [duration rules](docs/durations.md)
- [Direct aliases](docs/aliases.md)
- [Generated typed settings](docs/typed-settings.md) and [generated bindings](docs/generated-bindings.md)
- [Live-reloading worker](docs/worker.md), an optional Linux example with a
  separate pinned file-reading dependency
- [Security policy](SECURITY.md) and [release status](docs/release.md)

## Platform support

The Goose compiler revision is pinned in [`GOOSE_REVISION`](GOOSE_REVISION).
The recorded local qualification used GCC 16.2.1 and Clang 23.1.4. Hosted CI
runs on Ubuntu 24.04 x86-64 and uses the system GCC and Clang; their exact
versions are not pinned by the workflow. No other operating system has been
validated. The library itself has no file-reading API; the optional worker
example is Linux-specific.

## Performance evidence

There is no general speed claim. The checked measurements for aliases and
generated env/CLI bindings use source inputs that match the published runtime
modules. Other reports are historical snapshots, not measurements of current
main. See the [performance status and source map](docs/performance-status.md)
and the [raw benchmark records](bench/README.md). The results include slower
cases and shared-host limitations.

## Development

The quick start needs Git, CMake, a C++20 compiler, Make, and a C compiler for
native examples. Python 3.11+ is required for the test tools. Run the standard
checks with the pinned compiler:

```sh
make setup
make check test property security sanitize
SANITIZER_CC=clang make sanitize
make release RELEASE_CC=gcc
make release RELEASE_CC=clang
make conformance
```

Use `make GOOSE=/absolute/path/to/goose ...` to select an existing compiler.
`make conformance` also needs Go and downloads the pinned TOML test runner.
See [contribution instructions](CONTRIBUTING.md) for the full test matrix.

Coverage-guided testing across JSON, TOML, lists, and reload is not complete.
This is not a tagged release; completed unit, model, malformed-input, and
sanitizer checks do not replace that remaining testing.
