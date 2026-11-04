# Shared-subset Go configuration adapters

This independent Go module supplies Viper and Koanf adapters for the Goose
configuration comparison. It benchmarks three successful text lookups and one
successful TOML parse/merge fixture. It does not establish feature equivalence
or a universal performance ranking.

Versions selected with `go list -m -json MODULE@latest` on 2026-11-04:

| Module | Explicit version |
| --- | --- |
| [Viper](https://github.com/spf13/viper/releases) | v1.21.0 |
| [Koanf v2](https://github.com/knadh/koanf/releases) | v2.4.1 |
| [Koanf TOML v2 parser](https://pkg.go.dev/github.com/knadh/koanf/parsers/toml/v2) | v2.2.2 |
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
```

The optional iteration count defaults to 1000 and must be between 1 and 100000.
Each invocation emits exactly four lines on standard output:

```text
NAME samples_ns=[seven JSON numbers] checksum=INTEGER
```

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
