# Alias workload measurements

Direct aliases are an additive, bounded configuration feature, not full Viper or
Koanf feature parity. Canonical lookup runs first; only a miss searches the sorted
owned alias keys. Additional metadata and validation still have costs even when
no aliases are registered. No zero-overhead or universal speed claim is made.

## Sources and method

The prior runtime is `498124392f224b31f2ea2fa8489ee28f80b9f288`.
The initial alias runtime measured below is `a5e4ba3`; its full revision and six
runtime hashes are in the raw records. The final runtime is
`d654a6eb6138e676dfb6e49037c707cbf954a41d`. Later commits add tooling/results/docs;
they do not change these runtime files. The pinned compiler remains
`eadca409f68210893f366e60d0c2f0dc29a339be`.

Local measurements used Linux x86-64, Intel Core Ultra 7 258V, affinity CPU 6,
GCC 16.2.1, `-O2`, and the compiler/runtime identities in each record. Bindings
adapters use Go 1.27.3-X:nodwarf5, Viper 1.21.0 and Koanf 2.4.1. This was a shared
host without exclusive isolation. All owned heavy validation finished before
these timing series. No sample was removed, normalized or corrected with a
control. Separate series and executable build paths are not interchangeable.

Alias lookups use 9 processes, 10,000 operations per batch, seven batches per case.
Schema/store initialization is outside the timer. Each of 12 cases selects mixed
canonical, alias or missing keys in 8/256-field stores with 8/256 aliases; long
cases share 230 prefix bytes. Values are distinct by target, and each getter must
return the selected target's value. Long misses retain the long prefix. Setup,
full final values, small odd/even preflights, exact checksums and finite complete
samples are checked. Case order within each process is fixed, not randomized.
The recorder retains runtime/harness/compiler/stdlib/runtime-header/GCC and native
binary identities. Exact measured final native disassembly was retained locally;
its SHA256 is in the final JSON. These are lookup timings, not initialization,
allocation/RSS, binding-descriptor or alias-heavy update timings.

## Alias-enabled lookups

Values are medians of process medians, nanoseconds per operation. Initial and
final columns are separate observations, not a causal optimization percentage.

| Case | Initial alias runtime | Final runtime |
|---|---:|---:|
| canonical-8 | 20.32 | 22.10 |
| alias-8 | 51.90 | 52.09 |
| missing-8 | 49.41 | 44.59 |
| canonical-8-long | 76.32 | 73.71 |
| alias-8-long | 196.41 | 183.44 |
| missing-8-long | 362.48 | 329.98 |
| canonical-256 | 25.31 | 25.96 |
| alias-256 | 98.80 | 88.92 |
| missing-256 | 85.53 | 79.93 |
| canonical-256-long | 94.02 | 90.32 |
| alias-256-long | 301.57 | 273.98 |
| missing-256-long | 512.06 | 458.01 |

## Existing canonical-only workloads

These stores do not register aliases. Both revisions use the existing core
harness and 1,000 operations per batch. Ratios divide the median of after-process
medians by the median of before-process medians; above 1 is slower. Initial/core
control series use four pairs; final series use six pairs, seven batches per
case. The core control compiles the same old source twice at different paths;
it is a **same-source** control, not an identical-executable control. Its variation
cannot be subtracted from other results or establish a cause.

| Core case | Initial new/old | Same-source control | Final new/old |
|---|---:|---:|---:|
| lookup-small | 1.141 | 0.925 | 1.064 |
| lookup-first-wide | 1.251 | 0.903 | 1.073 |
| lookup-mixed-wide | 1.197 | 0.915 | 1.030 |
| lookup-missing-wide | 1.062 | 0.901 | 0.953 |
| lookup-last-wide | 1.109 | 0.905 | 0.932 |
| reject-layer-wide | 1.119 | 0.916 | 0.929 |
| apply-small | 1.023 | 0.906 | 0.875 |
| apply-wide | 1.048 | 0.912 | 1.010 |
| update-one-large | 1.085 | 1.167 | 1.220 |
| lookup-last-long-prefix | 1.015 | 1.000 | 1.018 |
| lookup-mixed-long-prefix | 1.087 | 0.980 | 1.048 |
| apply-wide-long-prefix | 1.148 | 1.114 | 0.982 |
| init-small | 1.068 | 1.144 | 1.066 |
| init-wide | 1.156 | 1.170 | 0.998 |
| init-wide-long-prefix | 0.941 | 1.188 | 1.024 |
| toml-small | 0.997 | 1.108 | 1.135 |

| Update case | Initial new/old | Final new/old |
|---|---:|---:|
| update-text-boundary-large | 1.093 | 1.041 |
| update-text-resize-large | 1.544 | 0.974 |
| update-integer-large | 1.382 | 1.211 |
| update-text-list-large | 1.202 | 1.073 |
| update-two-text-large | 1.343 | 0.998 |
| update-text-full-large | 1.069 | 1.003 |

The final series retains material slower observations: `update-one-large` 1.220,
`update-integer-large` 1.211, and `toml-small` 1.135. A separate bounded targeted
integer-update check below did not repeat that magnitude. The original costs
remain observations; neither controls nor a smaller repeat justify deleting
results or claiming zero cost. Long-prefix, initialization and small-getter
results are also mixed. Future compiler changes require fresh qualification.

## Diagnosed lookup regression and bounded controls

Initial canonical getter results prompted a cached, matched-source-path probe.
It builds old/new snapshots at one source path, retains both binaries, and reuses
one exact old binary for separately shuffled before-A/before-B controls. Native
assembly showed the un-inlined combined alias resolver widened the pinned
compiler's native lookup boundary from six scalar arguments to eight, adding
stack arguments. Extracting a helper or changing Store layout did not resolve
the minimized regression and was not adopted. Marking the resolver `inline`
removes that boundary before native optimization without removing validation.
Inlining also changes layout/register allocation; timings do not attribute a
fixed percentage solely to those stack arguments.

The promoted probe uses the frozen old harness. A one-field/one-byte lookup
retains its old `lookup-first-wide` output label; dimensions are explicit in JSON.
Each invocation has 9 shuffled rounds × 3 labels × 7 batches = 189 timings and
100,000 operations per lookup batch. Controls are identical binaries **within
each invocation**; executable hashes differ between invocations. The 15% budget
is an investigation threshold, not a production SLA or elapsed-time CI gate.

| Committed runtime | after/before-A | before-B/before-A | Diagnostic verdict |
|---|---:|---:|---|
| Unfixed a5e4ba3 | 1.209 | 0.998 | regression |
| Final d654a6e | 0.976 | 0.995 | within-budget |
| Final d654a6e integer update | 1.058 | 0.972 | within-budget |

The targeted integer check uses the existing 256-field/large-neighbor workload,
10,000 operations per batch, independently checked alternating 17/29 values,
unchanged neighbors and sources. It investigates one residual cost, not all
ordinary paths. The first two lookup records were emitted by the recorder at
`fa65248`; later protocol hardening and the integer option add complete cached
binary inventory checks, zero-denominator handling, runtime-inline-header and
recorder hashes. The existing lookup records contain both correct executable
hashes and positive denominators, so those hardening changes do not invalidate
them. Original diagnostic experiments remain retained locally.

## Existing bindings and alternatives

These are the existing successful env/CLI/current-source replay subsets, without
registered aliases. They do not compare Viper's alias API or Koanf alias behavior.
Each series has three shuffled rounds × three callers × three cases × seven batches
= 189 timings, 1,000 operations per batch. Times are nanoseconds per operation.
All three observations are retained; alternatives also shifted between series.

| Caller / case | Prior snapshot | Initial aliases | Final aliases |
|---|---:|---:|---:|
| goose-config / env-bindings | 1378.55 | 1595.42 | 1184.60 |
| goose-config / cli-lists | 1257.34 | 1489.30 | 1102.42 |
| goose-config / reload-layers | 21361.58 | 26733.80 | 18452.86 |
| viper / env-bindings | 2087.46 | 2317.29 | 1961.78 |
| viper / cli-lists | 12692.27 | 13695.94 | 8898.59 |
| viper / reload-layers | 151708.09 | 182136.30 | 141879.84 |
| koanf / env-bindings | 8191.70 | 10470.08 | 8194.58 |
| koanf / cli-lists | 18745.65 | 21936.06 | 15124.49 |
| koanf / reload-layers | 319147.28 | 404983.53 | 308670.03 |

The final CONFIG medians are smaller for these subsets. The adapter contracts
differ: CONFIG validates strict schemas/ranges, retains source labels and atomic
failed snapshots; neither adapter reconstructs those source labels or supplies
matching strict failure semantics. Environment reads/provider maps and pflag
setup also differ. See [feature comparison](comparison.md) and each record's
semantic limitations. Separate snapshot differences are not attributable solely
to the inline change, and this is not a full-feature or universal ranking.

## Reproduction and raw records

Choose an available CPU; avoid overlapping your own heavy jobs. The compiler
must match `GOOSE_REVISION`. Existing Go adapters use the checked-in dependency
lock. The diagnostic workspace must be new, or use `--reuse` with matching cached
inputs. Nonzero diagnostic exit 1 means over budget; exit 2 means inconclusive.

```sh
python3 bench/measure_aliases.py --goose /absolute/path/to/pinned/goose \
  --revision d654a6eb6138e676dfb6e49037c707cbf954a41d \
  --iterations 10000 --runs 9 --cpu CPU --output .build/aliases.json
python3 bench/measure.py --goose /absolute/path/to/pinned/goose \
  --before-ref 498124392f224b31f2ea2fa8489ee28f80b9f288 \
  --after-ref d654a6eb6138e676dfb6e49037c707cbf954a41d \
  --iterations 1000 --pairs 6 --cpu CPU --output .build/alias-core.json
# Add --suite updates for the update cases.
python3 bench/diagnostics/alias_lookup.py --goose /absolute/path/to/pinned/goose \
  --before-ref 498124392f224b31f2ea2fa8489ee28f80b9f288 \
  --after-ref d654a6eb6138e676dfb6e49037c707cbf954a41d \
  --workspace .build/lookup-cache --output .build/lookup-probe.json --cpu CPU
# Add --case integer-update --iterations 10000 and use a new workspace for that check.
python3 bench/compare_bindings.py --goose /absolute/path/to/pinned/goose \
  --revision d654a6eb6138e676dfb6e49037c707cbf954a41d \
  --iterations 1000 --rounds 3 --cpu CPU --output .build/alias-bindings.json
```

| Raw record | Retained timing batches |
|---|---:|
| [alias-lookups.json](../bench/results/alias-lookups.json) | 756 |
| [alias-lookups-final.json](../bench/results/alias-lookups-final.json) | 756 |
| [alias-core-paired.json](../bench/results/alias-core-paired.json) | 896 |
| [alias-core-control.json](../bench/results/alias-core-control.json) | 896 |
| [alias-core-final.json](../bench/results/alias-core-final.json) | 1,344 |
| [alias-updates-paired.json](../bench/results/alias-updates-paired.json) | 336 |
| [alias-updates-final.json](../bench/results/alias-updates-final.json) | 504 |
| [alias-bindings-before.json](../bench/results/alias-bindings-before.json) | 189 |
| [alias-bindings-after.json](../bench/results/alias-bindings-after.json) | 189 |
| [alias-bindings-final.json](../bench/results/alias-bindings-final.json) | 189 |
| [alias-diagnostic-unfixed.json](../bench/results/alias-diagnostic-unfixed.json) | 189 |
| [alias-diagnostic-final.json](../bench/results/alias-diagnostic-final.json) | 189 |
| [alias-diagnostic-integer.json](../bench/results/alias-diagnostic-integer.json) | 189 |

Total: 6,622 retained timing batches. This is feature/regression qualification,
not sustained coverage-guided fuzzing, concurrency validation, memory/RSS
qualification or a release tag. See [validation and remaining limits](alias-validation.md).
