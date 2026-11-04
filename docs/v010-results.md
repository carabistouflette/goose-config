# v0.1 preparation: storage and binding measurements

This is an audit of an experimental commit, not a tagged release or a general
performance ranking. [API candidate](api.md), [remaining release gate](release.md).

## Sources and method

Before: `669aa22d31765b5e44862eec8e6eba44c95381b3`. After: `f619f2d8a1bd2ad8f9d19a520332918ec86bf224`.
Compiler: `eadca409f68210893f366e60d0c2f0dc29a339be`; `gcc (GCC) 16.2.1 20260810`; GCC `-O2`.
Host: Intel(R) Core(TM) Ultra 7 258V, `Linux-7.2.11-arch1-1-x86_64-with-glibc2.44`, CPU affinity 7.
Each loading invocation has four alternating pairs, seven samples per fixture
and 1,000 operations per sample. The binding comparison has three rotating
process-order rounds, seven samples per fixture and 1,000 operations per sample.
All reported values are medians of process medians in ns/operation. Each ratio
is the after median divided by the before median; lower is faster. Every checksum agreed.
Frequency, thermals and unrelated system activity were uncontrolled. There was
no dedicated warmup beyond fixture setup. No allocation count or latency bound
is inferred. Raw samples, exact source/tool versions and hashes are retained.

## Timing overlap and handoff

The original series started at **2026-11-04T13:39:27Z**. An independent SQLite
storage series started at **13:39:34Z**, also on CPU7. Both continued normally.
The original loading pair, its independent repeat and original binding result
are retained below with this overlap disclosure. They must not be presented as
uncontended measurements.

After explicit completion of the SQLite series, a separate loading/binding
repeat ran from **13:42:57Z to 13:43:58Z** on the same CPU. The SQLite owner
deferred further CPU7 measurements until completion. This courtesy does not
establish exclusive isolation: background processes and other cores remained
active. The handoff results supplement the originals; they do not replace them.

## Loading and metadata

The change replaces two internal payload spans with one selected by the
immutable schema kind, saving one 16-byte span per value record (4,096 bytes
across 256 logical records). This is not an exact allocator or peak-RSS saving.
Retained scalar source/text spans are copied together; list item/source spans
are independently rebased. Key grammar validation uses one bounded pass. The
supported API, strict validation, ownership and failure atomicity are preserved.

All sixteen fixtures remain visible. The handoff aggregate shows smaller
large-text single-key update and small-init medians, but slower wide apply and
wide/long-prefix initialization. The two original invocations differ markedly,
and even unchanged getter paths vary across pairs. These data do **not** establish
a consistent general loading speedup. Long-prefix apply/initialization costs
remain a profiling target; the change does not remove the full-arena copy.

| Fixture | Handoff before ns/op | Handoff after ns/op | Original ratio | Original repeat ratio | Handoff ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `lookup-small` | 14.9 | 14.7 | 1.00 | 0.93 | 0.98 |
| `lookup-first-wide` | 14.5 | 14.3 | 1.00 | 0.96 | 0.99 |
| `lookup-mixed-wide` | 35.7 | 35.5 | 0.98 | 0.91 | 0.99 |
| `lookup-missing-wide` | 74.4 | 73.1 | 1.01 | 0.92 | 0.98 |
| `lookup-last-wide` | 26.2 | 25.6 | 0.99 | 0.93 | 0.98 |
| `reject-layer-wide` | 102.4 | 102.2 | 1.03 | 0.94 | 1.00 |
| `apply-small` | 443.8 | 450.4 | 1.04 | 1.01 | 1.02 |
| `apply-wide` | 11,449.5 | 11,848.4 | 1.03 | 0.95 | 1.03 |
| `update-one-large` | 115,053.8 | 105,436.8 | 1.01 | 1.21 | 0.92 |
| `lookup-last-long-prefix` | 137.1 | 133.7 | 1.00 | 1.26 | 0.97 |
| `lookup-mixed-long-prefix` | 138.2 | 133.2 | 1.00 | 1.26 | 0.96 |
| `apply-wide-long-prefix` | 29,699.6 | 33,673.1 | 0.98 | 1.05 | 1.13 |
| `init-small` | 272.1 | 244.2 | 0.77 | 1.10 | 0.90 |
| `init-wide` | 24,266.5 | 25,458.8 | 0.98 | 1.07 | 1.05 |
| `init-wide-long-prefix` | 150,543.2 | 166,771.3 | 1.11 | 1.25 | 1.11 |
| `toml-small` | 543.7 | 478.6 | 0.95 | 1.36 | 0.88 |

Raw loading records: [original](../bench/results/v010-loading-paired.json),
[original independent repeat](../bench/results/v010-loading-repeat.json),
[handoff repeat](../bench/results/v010-loading-handoff.json).

## Native bindings and layered reload

Pinned comparison dependencies include Viper 1.21.0, Koanf 2.4.1, pflag 1.0.10,
Koanf env/v2 2.0.2 and posflag 1.0.2, built with Go 1.27.3 (the raw build
metadata records its `nodwarf5` experiment). All three processes receive the
same seven-variable environment: three fixture variables and explicit Go
runtime controls (`GOMAXPROCS=1`, `GOGC=100`, `GOMEMLIMIT=off`, `GODEBUG=`).

- `env-bindings`: fresh schema/instance and three native environment bindings,
  including a separated text list. Viper resolves lazily in getters; Koanf
  scans/materializes environment data; Goose eagerly validates registered names.
- `cli-lists`: fresh typed flags/schema, parsing, native binding/provider load
  and getters, with repeated list flags. Fresh flag sets avoid retained values.
- `reload-layers`: defaults plus three current JSON layers, alternating removal
  of a middle-layer port to expose the lower current layer; the upper layer
  replaces a 256-item integer list. Fresh snapshots/replay are timed.

Input preparation and complete final checks are outside timing. Every operation
consumes port, list length and name length in an independently verified checksum.
Final checks inspect all 256 list elements and Goose source labels. Viper/Koanf
adapter paths do not supply Goose strict schema/range validation, independent
i64-list ownership, atomic validated reload or per-setting provenance. No file
I/O, reload trigger, error-path equivalence or full provider ecosystem is timed.
See [adapter contracts](../bench/competitors/README.md).

### Original (overlapping series)

| Fixture | goose-config ns/op | Viper ns/op | Koanf ns/op |
| --- | ---: | ---: | ---: |
| `env-bindings` | 2,343.2 | 3,139.5 | 18,211.2 |
| `cli-lists` | 2,435.4 | 18,654.4 | 31,418.6 |
| `reload-layers` | 39,439.7 | 309,747.5 | 626,036.7 |

### Separate handoff repeat

| Fixture | goose-config ns/op | Viper ns/op | Koanf ns/op |
| --- | ---: | ---: | ---: |
| `env-bindings` | 1,545.1 | 2,377.5 | 9,498.4 |
| `cli-lists` | 1,454.2 | 12,389.0 | 18,955.7 |
| `reload-layers` | 24,247.7 | 202,470.8 | 427,226.1 |

Goose has the lowest median in these three successful shared workloads in
both invocations. This establishes neither complete feature parity nor
performance superiority on different workloads, hardware or failure paths.

Raw binding records: [original](../bench/results/v010-bindings-comparison.json),
[handoff repeat](../bench/results/v010-bindings-handoff.json).

## Reproduce

```sh
python3 bench/measure.py --goose /absolute/path/to/pinned/goose \
  --before-ref 669aa22 --after-ref f619f2d --iterations 1000 \
  --pairs 4 --cpu 7 --output .build/loading.json
python3 bench/compare_bindings.py --goose /absolute/path/to/pinned/goose \
  --revision f619f2d --iterations 1000 --rounds 3 --cpu 7 \
  --output .build/bindings.json
```

Use an available CPU, retain all runs and disclose observed overlap. The scripts
export immutable runtime revisions and isolate their snapshots/binaries. A
result records the harness/adapters actually used; do not relabel an old result
with a later harness or interpret smoke workloads as performance measurements.

## Validation and review

The measured runtime passed normal/debug execution, GCC and Clang `-O2`, and
GCC/Clang ASan/UBSan. Independent models covered 2,206 flat and 2,109 nested
transactions (100,577 responses), plus 1,702 common-feature transactions.
The hostile-input suite passed 331 cases per tested build. Official TOML 1.0
conformance passed 208 valid and 509 invalid cases. Import/ownership/consumer
overload regressions and benchmark record/provenance checks passed. Independent
reviews checked payload-span invariants, supported API preservation, benchmark
fairness and publication documentation; the checksum portability and import
provenance findings were corrected.

The standalone clone example printed `port=9000 (from APP_PORT)`. These checks
are not exhaustive and do not establish absence of vulnerabilities. The sustained
coverage-guided campaign remains incomplete; **v0.1.0 is not tagged**.
