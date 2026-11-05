# Shared-subset Go configuration adapters

This independent Go module supplies Viper and Koanf adapters for the Goose
configuration comparison. It benchmarks three successful text lookups and one
successful TOML parse/merge fixture. It does not establish feature equivalence
or a universal performance ranking. The separate `common` mode benchmarks JSON
and TOML list replacement plus fresh current-source replay after removing a key.
The separate `bindings` mode covers native environment binding, repeated CLI
list flags, and replay of four layers with a 256-item integer list.

Library/provider versions selected with `go list -m -json MODULE@latest` on
2026-11-04; pflag retains the existing v1.0.10 pin:

| Module | Explicit version |
| --- | --- |
| [Viper](https://github.com/spf13/viper/releases) | v1.21.0 |
| [Koanf v2](https://github.com/knadh/koanf/releases) | v2.4.1 |
| [Koanf TOML v2 parser](https://pkg.go.dev/github.com/knadh/koanf/parsers/toml/v2) | v2.2.2 |
| [Koanf JSON parser](https://pkg.go.dev/github.com/knadh/koanf/parsers/json) | v1.0.0 |
| [Koanf environment v2 provider](https://pkg.go.dev/github.com/knadh/koanf/providers/env/v2) | v2.0.2 |
| [Koanf posflag provider](https://pkg.go.dev/github.com/knadh/koanf/providers/posflag) | v1.0.2 |
| [pflag](https://pkg.go.dev/github.com/spf13/pflag) | v1.0.10 |
| [Koanf rawbytes provider](https://pkg.go.dev/github.com/knadh/koanf/providers/rawbytes) | v1.0.1 |

`go.mod` and `go.sum` pin the complete resolved graph. Both TOML adapters use the
resolved `github.com/pelletier/go-toml/v2` v2.4.3 through their libraries; Go module
version selection shares this parser dependency in the combined executable.
`metadata` reports every runtime dependency and the actual Go runtime, OS and
architecture and effective `GOMAXPROCS`. The initial smoke checks used
`go1.27.3-X:nodwarf5 linux/amd64`.

From this directory:

```sh
go build -o ../../.build/comparison/competitors .
../../.build/comparison/competitors metadata
../../.build/comparison/competitors viper 1000
../../.build/comparison/competitors koanf 1000
../../.build/comparison/competitors viper 1000 common
../../.build/comparison/competitors koanf 1000 common
```

The optional iteration count defaults to 1000 and must be between 1 and 100000.
The original mode emits exactly four lines on standard output:

```text
NAME samples_ns=[seven JSON numbers] checksum=INTEGER
```

`common` mode emits exactly three lines in the same protocol, named `json-lists`,
`toml-lists`, and `reload-removal`. The count is required before `common` in the
adapter CLI. The Goose counterpart is `../common.goose [count]`, with the same
default and bounds. The original two-argument CLI and four-fixture protocol are
unchanged.

Errors go to standard error and return a failing exit status. All seven raw
samples are retained, with no warmup pass or sample selection. The outer
comparison runner controls pairing, affinity and provenance. Do not interpret
smoke checks with one or two operations as performance measurements.

The fixtures match `../bench.goose`:

- `lookup-small`: eight `field0` through `field7` keys, 32 `x` bytes each; read
  `field0` each iteration.
- `lookup-mixed-wide`: 256 such keys and values; read key `(i * 73) % 256`.
- `lookup-last-wide`: 256 such keys and values; read `field255`.
- `toml-small`: alternate exactly `name='goose'\n[server]\nport=8080` and
  `name='duck'\n[server]\nport=9000`, starting with goose in each batch. Parse and
  merge into the existing configuration each iteration, replacing both settings,
  then read and checksum the integer port.

Setup, key/payload/document allocation, and final checks are outside timing.
The lookup setup uses Viper `Set` explicit overrides, its highest-priority
lookup path, and Koanf `Set`; Goose stores its effective values directly.
Timed lookup calls use `GetString` and `String`, respectively. The timed TOML
paths use Viper `MergeConfig` and Koanf `Load` with its TOML parser and rawbytes
provider, plus their integer getters. Reader/provider creation and load error
checks are timed. Every final lookup value is checked; TOML checks the actual
final name and port. Checksums match Goose: seven times count times 32 for
lookups, or the sum of the alternating ports across seven batches.

Goose's declared schema, strict getter errors, rejection of unknown keys,
atomic failed layers, and per-setting source labels are not implemented by
these adapter paths. The competitors have their own conversion, merge and
missing-value semantics. Both source-label checks are explicitly unsupported
in `metadata`; the adapters do not synthesize source tracking, in or outside
lookup timing. The benchmark intentionally uses present, correctly typed values
and successful TOML loads, so these semantic differences remain outside this
shared performance subset. Additional validation could change both supported
behavior and timings.

The additional common fixtures match `../common.goose`:

- `json-lists` alternates `{"ports":[8080,9000],"tags":["goose","duck"]}` and
  `{"ports":[9001],"tags":["duck"]}`, starting with the first document in each
  of seven batches. Each operation parses and merges into an existing instance,
  calls its public integer-list getter, and adds the first port plus list length
  to the checksum. Final checks compare every integer and string list element,
  including list length, so replacement cannot accidentally append old values.
- `toml-lists` performs the same workload with the exact documents
  `ports=[8080,9000]\ntags=['goose','duck']` and
  `ports=[9001]\ntags=['duck']`.
- `reload-removal` alternates current JSON `{"port":9000,"name":"file"}` and
  `{"name":"edited"}` over defaults `port=8080`, `name="default"`. Each
  operation replays those sources from scratch and checksums the integer port.
  Goose calls `reload(schema, layers, store)` on the previous store. Viper creates
  a new instance, registers `SetDefault` values, then calls `ReadConfig`; Koanf
  creates a new instance, `Set`s defaults, then calls `Load`. Fresh replay makes
  the deleted port fall back to 8080 instead of retaining 9000. Final checks cover
  both port and name. Source replay, default registration, construction, parsing,
  and the getter are timed; document/schema preparation occurs before timing.

The common list getters are Goose `get_integer_list`, Viper `GetIntSlice`, and
Koanf `Int64s`. Goose guarantees an independently owned `i64` array with strict
kind errors. The Go getters use their native conversion and missing-value rules;
their general slice ownership contracts differ. These parser paths produce
generic slices which the integer getters convert. No additional clone or strict
validation is bolted onto either adapter. All fixture integers are small and
exact in the JSON parsers' numeric representations. Goose declares a 1..65535
integer range for ports, validates the schema, rejects unknown keys and commits
layers/reloads atomically; the Go adapter paths do not implement those contracts.
Goose alone verifies real source labels outside timing. Koanf uses its official
JSON parser, which uses Go's standard JSON package, and its official TOML parser.

From the configuration repository root, the dedicated runner is:

```sh
python3 bench/compare_common.py --goose .build/common-goose --cpu 2 \
  --iterations 1000 --rounds 3 --output bench/results/common.json
```

Choose a CPU in the process's allowed affinity. The runner snapshots all six
Goose source modules from a single resolved `--revision` (default `HEAD`) using
`git show`. It copies and hashes the current common harness and adapter sources
in a private `.build/common-bench` directory, builds Goose with `gcc -O2` and
the Go adapters with `-mod=readonly -trimpath -buildvcs=false`, and uses a private
`GOOSE_HOME`. It rotates library order across rounds on the same CPU, retains
every raw seven-sample run and checksum, records dependency/runtime/build/source
and binary provenance, and summarizes the median of each library's run medians.
All library checksums must agree before the atomic result write. Defaults are
1000 operations, three rounds; count bounds remain 1..100000. Counts 1 and 2
are correctness smoke checks only. The original scalar benchmark stays separate
so historical core comparisons remain available.


The `bindings` mode emits exactly three fixture lines: `env-bindings`,
`cli-lists`, and `reload-layers`. Its count is required before `bindings`.
The Goose counterpart is `../bindings.goose [count]`. Examples, from this
repository root:

```sh
python3 bench/compare_bindings.py --goose .build/common-goose --cpu 2 \
  --iterations 1000 --rounds 3 --output bench/results/bindings.json
```

The original adapter CLI and `common` mode remain available. The new fixtures
measure these successful shared observable values:

- `env-bindings`: each operation creates a fresh configuration with `port=9000`,
  `name="worker"`, and text list `tag=["a","b","c"]` from the process variables
  `GOOSE_BENCH_PORT=9000`, `GOOSE_BENCH_NAME=worker`, `GOOSE_BENCH_TAG=a b c`.
  Goose runs `init` then `apply_env` with a single-space list separator. Viper
  constructs an instance, explicitly calls `BindEnv` for all three variables,
  then calls `GetInt64`, `GetString`, and `GetStringSlice`. Viper's standard
  space splitting produces the list. Koanf constructs an instance and loads
  its official `env/v2` provider with the fixture prefix; its documented
  transformation callback strips/lowercases keys and splits only `tag` on a
  single space. The provider reads the real process environment.
- `cli-lists`: each operation creates a fresh configuration from
  `--port 9000 --name worker --tag first --tag second`. Goose runs `init` then
  `apply_cli`. Both Go paths construct a new typed pflag set, register integer,
  string and `StringArray` flags, and parse the prepared argument vector.
  Viper constructs an instance and calls `BindPFlags`; Koanf constructs an
  instance and loads the official `posflag` provider. `StringArray` preserves
  each repeated item without comma splitting, matching Goose's list flags.
- `reload-layers`: each operation replays defaults `port=8080,name="default"`
  plus three current JSON documents, in order. The lower document sets
  `port=8100,name="lower",ports=[1,...,256]`; the middle alternates
  `{"port":9000,"name":"middle"}` and `{"name":"edited"}`; the upper sets
  `name="upper",ports=[1001,...,1256]`. The final list has exactly 256 items;
  the upper list replaces the lower list. Removing the middle port exposes
  8100 from the lower document, rather than retaining the old 9000. Goose uses
  `reload`; Viper/Koanf construct new instances, register defaults, and load
  all three current documents with their JSON parsers on every operation.

All schema, binding, argument, document and layer descriptors are prepared
before timing. Fresh snapshot construction, schema/default/flag registration,
argument parsing, binding/provider setup and loads, error checks, and the three
public typed getters are timed. Every operation checksums integer port plus
list length plus name length. Final checks outside timing compare every text
or integer list element, name and port; Goose additionally checks all actual
source labels. The Go adapters explicitly do not reconstruct source labels.
The strict runner requires exactly three fixture lines with seven finite,
nonnegative samples each, rejects duplicate/unexpected/missing names, and
compares checksums to independent formulas as well as across libraries.

These are native API costs, whose contracts differ. Viper environment bindings
resolve values lazily in typed getters; Koanf scans `os.Environ` and materializes
a map during provider loading; Goose eagerly validates its declared bindings.
Goose additionally supplies schema/kind/range validation, independently owned
integer lists, atomic validated reload and per-setting source tracking. The
adapter paths do not supply these stronger guarantees. Matching successful
values does not establish matching error behavior or ownership contracts.
Koanf uses its official providers directly, rather than a hand-built map or
custom flag adapter. The pinned provider APIs and `StringArray` support were
checked against the official package documentation linked above and their
resolved source on 2026-11-04.

The bindings runner inherits the normal environment for builds, but executes
**all three libraries with the same exact seven-variable environment**: the
three fixture variables above and `GOMAXPROCS=1`, `GOGC=100`, `GOMEMLIMIT=off`,
`GODEBUG=""`. No ambient environment is forwarded to benchmark executions;
this bounds Koanf's native environment scan instead of making it scan an
unrelated developer environment. The exact environment is recorded. Both
builds and runs use the requested CPU affinity. The runner snapshots all six
Goose modules from one resolved Git commit, copies/hashes current harness and
adapter sources to its private `.build/bindings-bench` workspace, and uses a
private `GOOSE_HOME` for compilation. It records source/binary hashes, compiler
pin/version, Go dependency versions/build settings and platform/runtime
provenance, rotates the three-library order over three default rounds, and
atomically publishes the complete record after all checks succeed.
Counts 1 and 2 are marked `smoke_only` and verify both port-definition and
removal branches; they are correctness checks, not performance evidence.

Duration mode (`competitors viper|koanf COUNT durations`) compares a two-key
mixed getter and one-key textual/JSON/TOML writes plus public duration getters.
All values are exact250ms/1.5s. CONFIG eagerly validates/stores nanoseconds;
dynamic getters interpret their stored values. See the full
[measurement contracts](../../docs/duration-performance.md) before interpreting
these successful-subset timings. No new dependency versions are introduced.
