# Equal-size scalar update measurements

This change targets one present scalar replacement whose combined source/text
byte length is unchanged. It does not claim a general reload or loading speedup.

## Implementation and contract

The general transaction first copies live payloads into an independent arena,
then copies that arena into the store. That remains the implementation for
length changes, absent values, lists and multi-key batches.

For one present scalar with an equal combined source/text length, the new path
copies both replacement inputs into fresh temporary storage before touching the
store. It then takes a checked slice of exactly the previous block, writes the
staged bytes using indexed byte assignments, and updates only that value record.
All unrelated byte/item spans, keys and indexes remain untouched. Source/text
boundaries may move within the block; total length, compact storage and byte
limits are preserved. The loop uses core indexing rather than an overloadable
copy method. Replacement staging is bounded by 4,352 logical bytes.

Every input still passes normal key/type/range/size and duplicate validation
before commit. Rejected layers preserve the store. Borrowed inputs are staged
before writes; scalar borrow rules and owned list results are unchanged.
The independent-copy publication used by bindings and reload is unchanged.
Native environment/CLI ingestion and end-to-end reload speed are not measured
by these update fixtures. Applications still coordinate concurrent access.

## Workloads

The original sixteen-fixture core harness is unchanged. Its `update-one-large`
case starts with 256 × 4,096-byte Text values, then alternates the first setting
between one-byte values. The first timed update shrinks the value and rebuilds
fully; subsequent updates qualify for the new path. Median batches primarily
describe steady equal-size updates; they do not promise a cheap first resize.
Every raw batch, including the first one, remains in the record.

The six new update fixtures use 256 fields, with target `field128` and large
Text neighbors. Inputs/schema construction is outside timing; validation,
apply calls, typed getters, assertions, checksums and loop work are inside.
Final untimed checks inspect every full value and source, including list items.

| Fixture | Timed behavior | Eligible? |
| --- | --- | --- |
| `update-text-boundary-large` | Alternate `cli` + five-byte Text and `layer` + three-byte Text; eight bytes total | Yes |
| `update-text-resize-large` | Alternate one/two-byte Text with `cli`; global parity changes size on every call, even one-operation batches | No |
| `update-integer-large` | Alternate 17/29 with `cli`, retaining 255 large Text values | Yes |
| `update-text-list-large` | Alternate two/three Text items, including owned-list getter work | No |
| `update-two-text-large` | Replace fields128 and129 together | No |
| `update-text-full-large` | Alternate two 4,096-byte Text values with `cli`, including full-value getter assertion | Yes |

## Method and provenance

Before: `53a68329332d20f61f5f4e9accedd651de8094f5`. After runtime: `7f72dc34d7c154014ca2dc4a0c087dfac0097331`.
Compiler: `eadca409f68210893f366e60d0c2f0dc29a339be`; `gcc (GCC) 16.2.1 20260810`; GCC `-O2`.
Host: Intel(R) Core(TM) Ultra 7 258V; `Linux-7.2.11-arch1-1-x86_64-with-glibc2.44`; CPU affinity 7.
Acceptance measurements ran on 2026-11-04 from 18:43:40Z to 18:46:17Z after
local heavy validation finished and the preceding SQLite CPU7 series released.
A timing courtesy was announced; other host activity, frequency and thermals
remained uncontrolled. There is no exclusive-isolation or latency guarantee.

Each suite has four alternating before/after pairs and an independent second
invocation. Each process takes seven batches of 1,000 operations per fixture,
with fixture setup but no dedicated warmup. Results below are medians of four
process medians, in ns/operation. Ratio means after divided by before; lower
is faster. All 352 fixture medians and 2,464 raw samples are retained. All
checksums agree across revisions/runs. These are local microbenchmarks, not
production throughput, allocation counts or a comparison to other libraries.

## Update workloads

| Fixture | Before | After | Ratio | Repeat before | Repeat after | Repeat ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `update-text-boundary-large` | 172,630.80 | 131.46 | 0.00076 | 108,323.15 | 117.77 | 0.00109 |
| `update-text-resize-large` | 158,886.54 | 164,653.93 | 1.036 | 89,747.07 | 120,159.24 | 1.339 |
| `update-integer-large` | 167,747.31 | 130.79 | 0.00078 | 124,786.28 | 101.65 | 0.00081 |
| `update-text-list-large` | 165,071.53 | 178,299.33 | 1.080 | 131,389.60 | 85,761.50 | 0.653 |
| `update-two-text-large` | 150,038.05 | 166,940.89 | 1.113 | 125,598.90 | 90,413.55 | 0.720 |
| `update-text-full-large` | 166,472.83 | 3,003.26 | 0.018 | 121,946.30 | 2,886.74 | 0.024 |

## All original core workloads

| Fixture | Before | After | Ratio | Repeat before | Repeat after | Repeat ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `lookup-small` | 16.88 | 16.88 | 1.000 | 17.49 | 19.81 | 1.132 |
| `lookup-first-wide` | 17.10 | 16.58 | 0.969 | 17.11 | 19.47 | 1.138 |
| `lookup-mixed-wide` | 41.46 | 41.45 | 1.000 | 42.18 | 47.60 | 1.128 |
| `lookup-missing-wide` | 87.88 | 85.05 | 0.968 | 88.09 | 100.32 | 1.139 |
| `lookup-last-wide` | 30.68 | 29.50 | 0.962 | 30.92 | 34.65 | 1.121 |
| `reject-layer-wide` | 114.51 | 117.58 | 1.027 | 122.62 | 136.22 | 1.111 |
| `apply-small` | 539.05 | 517.04 | 0.959 | 535.79 | 613.35 | 1.145 |
| `apply-wide` | 13,978.17 | 13,393.93 | 0.958 | 13,966.92 | 14,948.11 | 1.070 |
| `update-one-large` | 173,606.93 | 67.77 | 0.00039 | 166,600.85 | 81.46 | 0.00049 |
| `lookup-last-long-prefix` | 160.02 | 145.50 | 0.909 | 151.09 | 145.75 | 0.965 |
| `lookup-mixed-long-prefix` | 156.85 | 145.48 | 0.927 | 153.38 | 147.75 | 0.963 |
| `apply-wide-long-prefix` | 39,317.45 | 40,016.24 | 1.018 | 39,139.14 | 39,515.25 | 1.010 |
| `init-small` | 330.98 | 340.10 | 1.028 | 328.47 | 338.51 | 1.031 |
| `init-wide` | 35,919.61 | 35,264.76 | 0.982 | 35,905.46 | 36,069.21 | 1.005 |
| `init-wide-long-prefix` | 185,441.13 | 183,661.63 | 0.990 | 179,171.83 | 184,005.37 | 1.027 |
| `toml-small` | 670.80 | 665.64 | 0.992 | 726.75 | 706.94 | 0.973 |

## Interpretation and costs

Eligible boundary Text, Integer and full-size Text updates have lower medians
in both invocations. The original first-key steady equal-size update improves
as well. The effect is narrowly scoped to avoiding copies of unrelated live
payloads; full-size replacement still stages and writes its entire changed block.
It is not evidence that parsing, initialization, getters or all updates improve.

Resizing remains slower in both recorded invocations. List and two-field batch
controls have higher medians in the first run but lower medians in the repeat.
Many unchanged getter paths also have higher medians in the core repeat.
These variations prevent a universal fallback-performance conclusion. The extra
eligibility check, binary layout and uncontrolled host effects are possible
contributors, not isolated explanations. Every regression remains visible; the
general rebuild still copies all live bytes. No fixed speedup or deadline is
promised for another application, platform, execution mode or payload shape.

Raw records: [core paired](../bench/results/scalar-core-paired.json),
[core repeat](../bench/results/scalar-core-repeat.json),
[updates paired](../bench/results/scalar-updates-paired.json),
[updates repeat](../bench/results/scalar-updates-repeat.json). Each includes
exact runtime revisions, compiler/flags, suite/path, exact harness hash, hardware,
affinity, counts, checksums and every sample. Historical records are unchanged.

## Reproduce

```sh
python3 bench/measure.py --goose /absolute/path/to/pinned/goose \
  --before-ref 53a6832 --after-ref 7f72dc3 --suite core \
  --iterations 1000 --pairs 4 --cpu 7 --output .build/core.json
python3 bench/measure.py --goose /absolute/path/to/pinned/goose \
  --before-ref 53a6832 --after-ref 7f72dc3 --suite updates \
  --iterations 1000 --pairs 4 --cpu 7 --output .build/updates.json
```

Use an available CPU and separate output files for repeats. The selected current
harness is copied byte-for-byte into both immutable library exports; its SHA-256
fingerprint identifies the measured workload. Core remains the default suite.
CI smoke-runs the update suite without performance thresholds.

## Verification

Independent ownership and security reviews checked the actual indexed-write
patch and generated C, including aliasing, byte boundaries, zero-length spans,
numeric metadata, list exclusion, compact storage, checked bounds, consumer
overloads and independent publication. No concrete runtime finding remained.
Regression guards cover old key/source/text overlap, source/text boundary shifts,
binary bytes, missing/empty values, exact large integers, Float/Boolean changes,
retained populated/empty lists, owned getters, fallback transitions and late errors.
A maximum-span guard exercises 4,096-byte Text plus a 256-byte source, overlapping
borrowed inputs, and individually oversized inputs with unchanged combined length.
Its original baseline and candidate checks pass.

The normal/debug, GCC/Clang optimized and GCC/Clang ASan/UBSan matrices passed
with all three independent models and 331 hostile-input cases per tested build.
The expanded maximum-span ownership file also passed interpreter, debug, both
optimized compilers and both sanitizer compilers. Seventeen Python record tests
and five provenance tests pass; six-workload native smoke counts 1, 2 and 3
check odd/even parity and full final state. No new runtime dependency is added.

The sustained coverage-guided campaign remains incomplete. This performance
change does not close that [release gate](release.md); v0.1.0 remains untagged.
