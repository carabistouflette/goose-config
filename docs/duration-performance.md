# Duration workload measurements

Duration performance is measured separately from the pre-existing scalar/list
workloads. A getter-only comparison does not include the cost of initially
parsing and validating a value. These are successful shared subsets, not full
feature equivalence or a universal speed ranking.

`bench/durations.goose` and the pinned Go adapters expose four cases:

| Case | Timed work | Setup outside timer |
|---|---|---|
| `duration-get` | Alternate two keys with distinct250ms/1.5s values and retrieve nanoseconds | Schema/store and both initial writes |
| `duration-override` | Alternate250ms/1.5s textual writes plus getter | One-field schema/store |
| `duration-json` | Apply one of two JSON documents plus getter | Schema/store and document bytes |
| `duration-toml` | Apply one of two TOML documents plus getter | Schema/store and document bytes |

CONFIG parses, validates and owns canonical integer nanoseconds during writes.
Its getters read that stored representation. Viper and Koanf's public duration
getters interpret dynamic stored values. CONFIG also checks strict schema/ranges,
retains source labels, and stages atomic writes. The adapter timings do not
supply equivalent validation, provenance, error behavior or list ownership.
Viper file cases start without a Set override that would mask file values.

Every process emits seven in-process samples per fixture and a checked
nanosecond checksum. All callers validate final values outside timers. Counts1,
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
