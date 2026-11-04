# Configuration library comparison

Reviewed 2026-11-04. goose-config is not feature-equivalent to Viper or Koanf.
The comparisons below distinguish shipped APIs from work delegated to callers.
Performance on a shared subset cannot establish full feature parity.

Primary references: [Viper documentation](https://github.com/spf13/viper),
[Viper API](https://pkg.go.dev/github.com/spf13/viper),
[Koanf documentation](https://github.com/knadh/koanf),
[Koanf API](https://pkg.go.dev/github.com/knadh/koanf/v2).
The executable comparison pins Viper 1.21.0 and Koanf 2.4.1; see
[the adapter module](../bench/competitors/go.mod) for all dependency versions.

| Capability | goose-config | Viper | Koanf |
| --- | --- | --- | --- |
| Defaults and layers | Explicit atomic scalar/list layers | Fixed source priorities | Caller load order |
| TOML | Strict scalar/list adapter | Supported | Optional parser |
| JSON | Strict scalar/list adapter | Supported | Optional parser |
| YAML | Missing | Supported | Optional parser |
| INI | Missing | Supported | No bundled parser documented |
| Environment / flags | Explicit native/supplied bindings | Native bindings | Providers |
| Nested paths | Declared dotted scalar leaves | Supported | Configurable paths |
| Primitive lists | Strict homogeneous lists | Supported | Supported |
| Map values / object lists | Nested scalar paths only | Supported | Supported |
| Duration interpretation | Missing | Getter | Getter |
| Key aliases | Missing | Native API | No native API documented |
| File discovery / reading | Caller-owned | Native | Provider |
| Source reload | Fresh-store replay and required validation | Supported | Provider callbacks |
| File watching | Missing | File watching | Provider callbacks |
| Remote configuration | Missing | Remote integration | Optional providers |
| Struct decoding | Missing | Unmarshal | Unmarshal |
| Serialization / writeback | Missing | Write APIs | Marshal; caller writes |
| Extension interfaces | Callers can produce overrides | Codec registry/hooks | Provider/parser interfaces |

Absence of a documented/bundled API is not a claim that no third-party
implementation exists. The selected common-application scope now ships:
JSON/TOML, homogeneous primitive lists, registered env/CLI bindings, validation,
and explicit replacement reload. See [the exact contracts](common-features.md).
Duration parsing, YAML/INI, aliases, remote providers, watching, struct decoding
and writeback remain outside that selected scope.

## Contract choices

Strict keys, numeric kinds, required fields, ranges, bounded input/work, atomic
reported failures and source labels are preserved. Viper-compatible coercion,
case folding, fixed priorities and live lookup bindings are not implied.
Reload uses fresh-store replay rather than reapplying a modified document;
removed keys cannot survive from stale source snapshots.

## Reproducible shared-workload measurements

```sh
python3 bench/compare.py --goose /absolute/path/to/pinned/goose \
  --iterations 10000 --rounds 3 --cpu 4 \
  --output bench/results/competitors.json
```

This requires Go (with module downloads), GCC and Linux `taskset`. It builds
Goose from the requested exact Git revision, and copies the pinned Go adapter
sources into a private build snapshot. The four matching fixtures run in the
same order: small first-key lookup, wide mixed lookup, wide last-key lookup,
and two-setting TOML parse/merge/get. All use matching payloads, iteration
counts and checksums; each process reports seven samples. Library process
order rotates each round. Setup and final checks are outside the timers.
Viper lookups use explicit `Set` overrides, its first priority tier.

Raw records include source hashes, versions, flags, CPU affinity and every
sample. Frequency, thermals and unrelated host load are uncontrolled. No
dedicated warmup occurs. Go garbage collection and the C/Go runtimes differ.
These are cross-language end-to-end microbenchmarks, not parser-only numbers,
allocation measurements, production throughput or universal rankings.

Goose validates schemas and strict types, commits rejected layers atomically,
and tracks setting sources. The competitor adapter paths do not supply that
same contract. Their larger feature sets also do work absent from our core.
Only present matching-type values are used, so differing missing/error/coercion
semantics are not timed. Values are views/strings, not copied byte throughput.

## Initial measured baseline

[Raw baseline and provenance](../bench/results/competitors-baseline.json) use
source revision `6ae9cac4f51a5d991686cce035a2c83c3c07fa7b`, 10,000 operations per batch,
three rotating rounds and seven samples per fixture/run, pinned to CPU 4.
Values are medians of run medians in ns/operation; lower is faster.

| Fixture | goose-config | Viper | Koanf |
| --- | ---: | ---: | ---: |
| `lookup-small` | 15.6 | 123.0 | 54.6 |
| `lookup-mixed-wide` | 99.6 | 124.9 | 74.5 |
| `lookup-last-wide` | 85.7 | 110.6 | 69.3 |
| `toml-small` | 561.0 | 4,232.7 | 3,060.3 |

This baseline favors goose-config on the small lookup and TOML fixture;
Koanf wins both wide lookups. No across-the-board performance claim is made.
The complete raw samples, including variation, are retained.

## Bounded-accelerator measurement

[Raw shared-workload results](../bench/results/competitors.json) measure runtime
source `efb6e5a71573c7ce5dc848b43df402d80c59f3f5` using the same count, affinity and
rotating-round protocol as the baseline. Median run medians, ns/operation:

| Fixture | goose-config | Viper | Koanf |
| --- | ---: | ---: | ---: |
| `lookup-small` | 16.2 | 127.1 | 63.2 |
| `lookup-mixed-wide` | 39.0 | 126.3 | 98.5 |
| `lookup-last-wide` | 28.5 | 111.1 | 92.1 |
| `toml-small` | 585.0 | 4,376.8 | 3,442.2 |

Goose has the lowest median in these four measured workloads. This does not
establish full feature parity or a universal speed ranking. Competitor timings
also varied between runs; retain the raw samples when interpreting ratios.

### Full before/after tradeoffs

[All sixteen fixtures](../bench/results/lookup-accelerator-paired.json) compare
`6ae9cac` with the accelerator using three alternating pairs and 1,000
operations per batch. Numbers are median run medians, ns/operation.

| Fixture | Before | After | After / before |
| --- | ---: | ---: | ---: |
| `lookup-small` | 13.4 | 11.7 | 0.87 |
| `lookup-first-wide` | 13.0 | 11.7 | 0.91 |
| `lookup-mixed-wide` | 88.1 | 29.5 | 0.33 |
| `lookup-missing-wide` | 63.2 | 60.8 | 0.96 |
| `lookup-last-wide` | 77.3 | 21.3 | 0.28 |
| `reject-layer-wide` | 113.0 | 82.7 | 0.73 |
| `apply-small` | 407.1 | 362.8 | 0.89 |
| `apply-wide` | 24,873.8 | 9,062.4 | 0.36 |
| `update-one-large` | 109,097.3 | 80,156.0 | 0.73 |
| `lookup-last-long-prefix` | 222.9 | 106.9 | 0.48 |
| `lookup-mixed-long-prefix` | 296.6 | 107.7 | 0.36 |
| `apply-wide-long-prefix` | 76,216.8 | 29,239.2 | 0.38 |
| `init-small` | 230.4 | 345.7 | 1.50 |
| `init-wide` | 20,297.0 | 31,528.9 | 1.55 |
| `init-wide-long-prefix` | 164,592.1 | 138,178.2 | 0.84 |
| `toml-small` | 424.7 | 407.0 | 0.96 |

The accelerator improves wide lookups and wide applications in this run,
including long-prefix keys. Small and wide initialization are slower: index
construction and the larger implementation have costs. Wide stores also retain
4 KiB more index payload. The tiny-schema lookup path remains linear, and
colliding keys retain bounded probing followed by sorted lookup. No regression
is removed from the record. Timings include code-generation/layout and host
variation, not only algorithmic work.

### Independent repeat

[All repeat samples](../bench/results/lookup-accelerator-repeat.json) use the
same revisions, counts and affinity, in a separate invocation.

| Fixture | Before | After | After / before |
| --- | ---: | ---: | ---: |
| `lookup-small` | 15.7 | 16.2 | 1.04 |
| `lookup-first-wide` | 15.1 | 15.7 | 1.04 |
| `lookup-mixed-wide` | 100.0 | 37.4 | 0.37 |
| `lookup-missing-wide` | 73.1 | 81.7 | 1.12 |
| `lookup-last-wide` | 89.5 | 28.3 | 0.32 |
| `reject-layer-wide` | 132.0 | 106.0 | 0.80 |
| `apply-small` | 466.4 | 453.2 | 0.97 |
| `apply-wide` | 29,243.3 | 11,681.6 | 0.40 |
| `update-one-large` | 93,499.6 | 104,436.5 | 1.12 |
| `lookup-last-long-prefix` | 284.4 | 137.2 | 0.48 |
| `lookup-mixed-long-prefix` | 386.6 | 146.6 | 0.38 |
| `apply-wide-long-prefix` | 88,871.1 | 33,729.5 | 0.38 |
| `init-small` | 317.2 | 308.4 | 0.97 |
| `init-wide` | 32,467.9 | 33,562.1 | 1.03 |
| `init-wide-long-prefix` | 172,265.1 | 159,546.3 | 0.93 |
| `toml-small` | 575.1 | 426.5 | 0.74 |

Wide lookup improvements repeat. The large initialization regressions in the
first invocation do not repeat at the same scale: small initialization is
near baseline and wide initialization is approximately 3% slower here. This
variation prevents attributing all timing changes to index construction or
claiming a fixed initialization penalty. The extra storage and bounded index
construction are real costs. Both invocations are retained without selection.

## Selected common-feature implementation

The selected scope now ships (see [API contracts](common-features.md)).
These fresh measurements use runtime source `86df42f588a6056cc935c2dfaad306c8aca98e99`
on CPU 7, not the CPU 4 of the historical runs above. They must not be used
as a direct timing ratio against those earlier records. Same-run comparisons
use matching data, counts, affinity and rotating process order.

[Scalar/shared raw results](../bench/results/common-scalar-comparison.json) use
10,000 operations per batch; [list/reload raw results](../bench/results/common-feature-comparison.json)
use 1,000. Each has three rounds and seven samples per process/fixture.
Median run medians, ns/operation (lower is faster):

| Fixture | goose-config | Viper | Koanf |
| --- | ---: | ---: | ---: |
| `lookup-small` | 17.1 | 136.3 | 71.2 |
| `lookup-mixed-wide` | 40.5 | 144.4 | 117.8 |
| `lookup-last-wide` | 30.2 | 128.9 | 82.4 |
| `toml-small` | 607.5 | 4,978.6 | 4,377.6 |
| `json-lists` | 858.5 | 6,249.5 | 10,539.7 |
| `toml-lists` | 970.1 | 4,671.3 | 7,000.1 |
| `reload-removal` | 1,132.5 | 4,533.2 | 10,571.4 |

Goose has the lowest median in all seven measured successful shared workloads
in this run. Env/CLI binding speed was not measured in that run; the later
[native-binding and layered-reload audit](v010-results.md) adds those workloads
and a 256-item list. Full provider ecosystems,
error-path equivalence and universal performance rankings are not established.

The list cases parse/replace two lists, then call a public integer-list getter.
Goose returns an independently owned list and validates schema, numeric range,
strict types and sources; the Go getters have different conversion and ownership
contracts. The reload case reconstructs defaults plus current JSON each time;
a removed file key must fall back to defaults. Viper/Koanf construct fresh
instances. Construction, source replay, parsing and getters are timed. Input
preparation and complete final checks are not. The adapters use only small,
exact integers. See [adapter details](../bench/competitors/README.md).

Reproduce the new cases with:

```sh
python3 bench/compare_common.py --goose /absolute/path/to/pinned/goose \
  --iterations 1000 --rounds 3 --cpu 7 \
  --output bench/results/common-feature-comparison.json
```

### Cost of the feature expansion

[All sixteen before/after fixtures](../bench/results/common-expansion-paired.json)
compare `f1802f9` with the common-feature implementation on CPU 7 using
three alternating pairs and 1,000 operations per batch. All checksums agree.
No result or regression is omitted.

| Fixture | Before ns/op | After ns/op | After / before |
| --- | ---: | ---: | ---: |
| `lookup-small` | 18.3 | 18.3 | 1.00 |
| `lookup-first-wide` | 17.6 | 17.6 | 1.00 |
| `lookup-mixed-wide` | 43.0 | 43.1 | 1.00 |
| `lookup-missing-wide` | 91.7 | 91.4 | 1.00 |
| `lookup-last-wide` | 31.8 | 31.8 | 1.00 |
| `reject-layer-wide` | 121.4 | 123.9 | 1.02 |
| `apply-small` | 573.5 | 579.5 | 1.01 |
| `apply-wide` | 13,769.2 | 13,877.6 | 1.01 |
| `update-one-large` | 132,905.0 | 150,872.0 | 1.14 |
| `lookup-last-long-prefix` | 144.7 | 145.6 | 1.01 |
| `lookup-mixed-long-prefix` | 143.7 | 151.3 | 1.05 |
| `apply-wide-long-prefix` | 36,938.6 | 41,244.1 | 1.12 |
| `init-small` | 325.0 | 402.5 | 1.24 |
| `init-wide` | 35,417.0 | 36,291.2 | 1.02 |
| `init-wide-long-prefix` | 222,247.1 | 216,564.3 | 0.97 |
| `toml-small` | 688.9 | 625.4 | 0.91 |

The extra list metadata has costs. Small initialization, large-text single-key
updates and long-prefix full updates are slower in this run; lookups remain
near baseline. Timings include code-generation/layout, host load and frequency
variation. These results do not justify claiming the feature expansion is free.
All original records remain unchanged.
