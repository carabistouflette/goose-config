# Duration workload measurements

Duration performance is measured separately from the pre-existing scalar/list
workloads. A getter-only comparison does not include the cost of initially
parsing and validating a value. These are successful shared subsets, not full
feature equivalence or a universal speed ranking.

`bench/durations.goose` and the pinned Go adapters expose four cases:

| Case | Timed work | Setup outside timer |
|---|---|---|
| `duration-get` | Alternate two keys with distinct 250ms/1.5s values and retrieve nanoseconds | Schema/store and both initial writes |
| `duration-override` | Alternate 250ms/1.5s textual writes plus getter | One-field schema/store |
| `duration-json` | Apply one of two JSON documents plus getter | Schema/store and document bytes |
| `duration-toml` | Apply one of two TOML documents plus getter | Schema/store and document bytes |

CONFIG parses, validates and owns canonical integer nanoseconds during writes.
Its getters read that stored representation. Viper and Koanf's public duration
getters interpret dynamic stored values. CONFIG also checks strict schema/ranges,
retains source labels, and stages atomic writes. The adapter timings do not
supply equivalent validation, provenance, error behavior or list ownership.
Viper file cases start without a Set override that would mask file values.

Every process emits seven in-process samples per fixture and a checked
nanosecond checksum. All callers validate final values outside timers. Counts 1,
2 and3 are preflighted before timing to verify odd/even operation parity.
CONFIG additionally checks every final source. Native disassembly was inspected
to confirm that the mixed-key getter loop retains field reads and checksum work;
it was not folded into constant arithmetic. No failure, list, environment/CLI,
file I/O, reload-trigger or memory comparison is implied by these cases.

`bench/compare_durations.py` exports runtime modules from one exact commit,
records all harness/adapter source hashes, compiler/stdlib/runtime header and
GCC identities, flags, Go module metadata, CPU/affinity and raw stdout/samples.
It shuffles process order reproducibly and checks binary/toolchain identities
before/after, rejecting incorrect samples/checksums or measured stderr. Its
Goose build environment excludes inherited stdlib/runtime overrides. The Go
adapters use the existing dependency lock and read-only module resolution.

Reproduce on Linux with an available CPU index:

```sh
python3 bench/compare_durations.py --goose /absolute/path/to/pinned/goose \
  --revision FULL_CONFIG_COMMIT --iterations 10000 --rounds 9 --seed 606 \
  --cpu CPU --output .build/duration-comparison.json \
  --disassembly-output .build/duration-native.asm
```

Use `bench/measure.py` against the prior exact revision for existing core and
update suites. Report every fixture and retain regressions and same-code control
variation; do not normalize or claim isolated causality from shared-host runs.
These tests and measurements do not close the [sustained-fuzz gate](release.md).

## Observed results

The frozen runtime source is `f8ae9b25ed0e17f3020bb345a152190bb9a1c055`;
the prior runtime is `e13946a7d5c644fe4c844d1f24ed6ec64baa43ca`.
The six runtime files have not changed since the duration implementation commit
`1deea72`. Benchmarks used the pinned Goose `eadca409f68210893f366e60d0c2f0dc29a339be`,
GCC 16.2.1 and Go 1.27.3-X:nodwarf5, Intel Core Ultra 7 258V, Linux x86-64,
affinity CPU 6. Full compiler/runtime settings and dependency versions are in the
raw records. All owned heavy validation finished before timing; this was a
shared host without exclusive isolation. No sample was deleted or normalized.

Nine reproducibly shuffled rounds × three callers × four cases × seven batches
retain 756 finite timings, 10,000 operations per batch. Values below are medians
of the nine process medians, in nanoseconds per operation (lower is faster).

| Case | goose-config | Viper 1.21.0 | Koanf 2.4.1 |
|---|---:|---:|---:|
| duration-get | 11.39 | 196.24 | 414.42 |
| duration-override | 70.27 | 282.52 | 2,042.94 |
| duration-json | 292.08 | 2,223.64 | 3,079.30 |
| duration-toml | 205.88 | 1,654.54 | 2,291.24 |

CONFIG had smaller medians for these successful subsets. The getter excludes
initial eager parsing; the three write cases include parsing and a getter.
These results establish neither complete feature parity nor a universal speed
ranking. Source labels, schema errors, atomic rejected updates and typed-list
ownership remain different contracts. Exact timed native assembly was retained
locally and independently inspected: the mixed getter still selects keys,
reads fields, checks the kind, loads nanoseconds and adds its checksum inside
the clocked loop. Its SHA256 is recorded in the JSON.

## Existing workloads and controls

Both old and new runtime snapshots use the same existing harness, pinned Goose,
GCC-O2 flags and 1,000 operations per batch. Each table ratio divides the median
of after-process medians by the median of before-process medians. Smaller than 1
means the after group took less time. No control correction is applied.
The control compiles the same old source twice; it is a **same-source** control,
not an assertion of identical executable bytes or paths. It does not isolate a
cause or justify subtracting noise from the paired results.

The core series and its separate control each retain 896 batches (four pairs,
16 cases, seven batches per process):

| Core case | new/old | same-source control |
|---|---:|---:|
| lookup-small | 0.848 | 0.969 |
| lookup-first-wide | 0.848 | 0.980 |
| lookup-mixed-wide | 0.840 | 0.955 |
| lookup-missing-wide | 0.830 | 0.961 |
| lookup-last-wide | 0.841 | 0.971 |
| reject-layer-wide | 0.853 | 0.999 |
| apply-small | 0.883 | 0.961 |
| apply-wide | 0.874 | 0.969 |
| update-one-large | 0.703 | 0.827 |
| lookup-last-long-prefix | 0.833 | 1.047 |
| lookup-mixed-long-prefix | 0.852 | 1.045 |
| apply-wide-long-prefix | 1.027 | 0.915 |
| init-small | 0.874 | 0.946 |
| init-wide | 0.764 | 1.071 |
| init-wide-long-prefix | 0.912 | 0.904 |
| toml-small | 0.875 | 1.068 |

The update series retains336 batches (four pairs). Two apparent large update
slowdowns prompted a targeted repeat (six pairs, 504 batches) and a separate
same-source update control (six pairs, 504 batches). All original observations
remain retained:

| Update case | initial new/old | repeat new/old | same-source control |
|---|---:|---:|---:|
| update-text-boundary-large | 0.966 | 0.981 | 1.007 |
| update-text-resize-large | 0.997 | 0.905 | 1.033 |
| update-integer-large | 0.926 | 0.989 | 0.988 |
| update-text-list-large | 0.996 | 0.999 | 0.999 |
| update-two-text-large | 1.290 | 1.019 | 0.975 |
| update-text-full-large | 1.294 | 1.043 | 1.003 |

The initial two-text/full-text ratios 1.290/1.294 did not repeat at that magnitude;
the repeat ratios were 1.019/1.043 and their same-source controls 0.975/1.003.
Both update observations remain costs, not discarded outliers. Neither those
values nor the broad apparent core speedups establish a fixed causal overhead
or improvement. Smaller repeat slowdowns remain documented; this feature is
not described as having zero cost.

## Raw evidence

- [Duration alternatives](../bench/results/duration-comparison.json): 27 checked processes, 756 timings; full source/toolchain/binary hashes and Go metadata.
- [Existing core pair](../bench/results/duration-core-paired.json) and [same-source core control](../bench/results/duration-core-control.json): eight checked processes/896 timings each.
- [Initial updates](../bench/results/duration-updates-paired.json): eight checked processes/336 timings.
- [Update repeat](../bench/results/duration-updates-repeat.json) and [same-source update control](../bench/results/duration-updates-control.json): 12 checked processes/504 timings each.

Total: 3,892 retained timing batches. Every fixture checksum matches across its
paired/cross-library runs. The old-workload records use the existing paired
recorder and its source-pin/flag/harness provenance; the new-duration recorder
additionally retains full input/executable identities. See [validation and
remaining limits](duration-validation.md). No memory/RSS or release-gate claim
follows from these timings.
