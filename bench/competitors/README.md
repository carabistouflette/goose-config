# Shared-subset Go configuration adapters

This independent Go module supplies Viper and Koanf adapters for the Goose
configuration comparison. It benchmarks three successful text lookups and one
successful TOML parse/merge fixture. It does not establish feature equivalence
or a universal performance ranking. The separate `common` mode benchmarks JSON
and TOML list replacement plus fresh current-source replay after removing a key.

Versions selected with `go list -m -json MODULE@latest` on 2026-11-04:

| Module | Explicit version |
| --- | --- |
| [Viper](https://github.com/spf13/viper/releases) | v1.21.0 |
| [Koanf v2](https://github.com/knadh/koanf/releases) | v2.4.1 |
| [Koanf TOML v2 parser](https://pkg.go.dev/github.com/knadh/koanf/parsers/toml/v2) | v2.2.2 |
| [Koanf JSON parser](https://pkg.go.dev/github.com/knadh/koanf/parsers/json) | v1.0.0 |
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
Each invocation emits exactly four lines on standard output:

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
