# Typed settings measurements

Typed generation removes repetitive declaration, ownership and loading code.
These measurements do not establish a general loading speedup, full Viper/Koanf
decoding parity or zero overhead. The baseline is an explicit reference loader
with the same typed representation and successful/error contracts.

## Method

Frozen source: `5c4803b1bca5c0217d17e0db9c4669c31f17b61a`. Original six runtime modules and Store layout remain
identical to the prior published alias revision `d7d9d7f`. The optional presence
adapter and generated modules participate in this feature.
Pinned Goose `eadca409f68210893f366e60d0c2f0dc29a339be`, GCC 16.2.1, Linux x86-64,
Intel Core Ultra 7 258V, affinity CPU 6. Compiler/stdlib/runtime-header,
GCC-driver/cc1/assembler/linker, helper, source and executable hashes are recorded.
The build environment excludes inherited Goose stdlib/runtime overrides.

Both callers are in one frozen native binary at one snapshot path. Nine seeded
shuffled rounds run generated, reference-A and reference-B. The latter two use
identical executable bytes and argv. Cases run in fixed order within processes.
Each process emits seven batches per case, 1,000 operations per batch. First
batches are retained; counts 1/2/3 for both callers are preflighted separately.
All owned heavy checks finished before timing. This is a shared host without
exclusive isolation, frequency control or control correction. Partial failed
process output/context is retained if a managed run or protocol check fails;
this series completed successfully.

| Case | Work included in clock |
|---|---|
| load-small | Prebuilt Store to fresh private staging, validation, publication into reused destination, checksum |
| load-owned | Same, about 4 KiB combined Text/TextList payload plus numeric/list families |
| cold-owned | Same owned input, fresh logical destination and destruction per iteration, in a warmed process |
| optional-removal | Alternate fully populated input and required Text only; clear optional values/flags/sources |
| refresh-owned | Replay current JSON into fresh validated Store, then staged typed load/publication |
| reject-validator | Stage owned payload, invoke same readonly rejecting validator, preserve seeded destination |
| reject-schema | An optional key is absent from the Store schema; unknown-key/schema rejection, not absent-required-value rejection |
| application-read | Alternate Integer/Duration reads from an immutable snapshot: typed fields versus Store getters |

The ten-field fixture covers all five scalar and all five homogeneous-list kinds.
Large inputs have 1,024/1,001-byte Text and 3,006/2,991-byte combined TextList
payload in alternating snapshots. Numeric values, lists, sources and payload
lengths differ. No file I/O, remote providers, alias registration, wide-schema
load timing, process startup or memory/RSS comparison is included.

The reference preflights metadata before copying. Generated loading interleaves
metadata and staging, so a late schema error copies earlier fields. The reference
fuses numeric-list range checking/copying; generated code uses separate loops.
These are real implementation differences. Both have owned values, the same
readonly validator and unchanged-destination-on-error contract. Text is staged
and published; list getters create owned temporaries, followed by candidate and
publication copies. No copy-free representation favors either caller.

Full post-timer checks cover active/probe values, every list element, presence
and sources, including preserved destinations after rejection. Timed fresh cold
destinations are consumed by a typed checksum and destroyed; full-byte checks use
separate untimed probes. Independent Python arithmetic checks odd/even counts
and every case. Corrupt/incomplete/nonfinite records, wrong checksums, stderr and
changed binaries/toolchain inputs are rejected.

Independent review checked native assembly from the exact timed binary against
its recorded SHA256. Loading loops retain staging/getters/copying and digest work
inside timed iterations; refresh retains reload plus load. Application-read
uses cached fields/registers and arithmetic, while its reference invokes checked
access each iteration. Its sub-nanosecond observation is optimized application
throughput, not fresh field-read latency or a general getter speedup.

## Observations

Values are medians of nine process medians, nanoseconds per operation. Ratios
use uncorrected medians. Above 1 means more time. Reference A/B are observations
of the same code/path, not separate implementations.

| Case | Generated | Reference A | Reference B | Generated / A | B / A control |
|---|---:|---:|---:|---:|---:|
| load-small | 861.19 | 881.93 | 999.00 | 0.976 | 1.133 |
| load-owned | 1,752.81 | 1,733.12 | 1,831.49 | 1.011 | 1.057 |
| cold-owned | 1,649.62 | 1,677.62 | 1,727.15 | 0.983 | 1.030 |
| optional-removal | 544.46 | 597.90 | 569.62 | 0.911 | 0.953 |
| refresh-owned | 16,555.08 | 19,750.12 | 16,242.81 | 0.838 | 0.822 |
| reject-validator | 1,102.26 | 1,243.34 | 1,095.02 | 0.887 | 0.881 |
| reject-schema | 600.98 | 233.77 | 224.20 | 2.571 | 0.959 |
| application-read | 0.74 | 29.17 | 26.81 | 0.025 | 0.919 |

Loading observations are close or mixed, and identical-reference variation is
material. The apparent refresh improvement versus Reference A does not persist
versus Reference B. Do not normalize away controls or infer a causal small
loading advantage. Schema rejection is slower for generated loading because
staging has copied earlier fields; the reference rejects metadata first.
The immutable read workload benefits from direct typed access and optimizer
freedom, but its ratio is not a loading result or general getter speedup.

Scope remains the ten-kind fixture. Maximum-schema native correctness is
[qualified separately](typed-validation.md); it does not establish maximum-payload
performance. No universal ranking or allocation/RSS conclusion follows.

## Reproduction and evidence

```sh
python3 bench/measure_typed.py --goose /absolute/path/to/pinned/goose \
  --revision FULL_CONFIG_COMMIT --iterations 1000 --rounds 9 --seed 606 \
  --cpu CPU --output .build/typed-comparison.json \
  --disassembly-output .build/typed-native.asm
```

Use fresh output paths. Overwriting existing JSON/native artifacts and path
collisions are rejected. A failed record stays `completed:false` and is not a
successful comparison.

[Raw comparison](../bench/results/typed-comparison.json): 27 checked timed
processes × 8 cases × 7 batches = 1,512 timed batches. Six count 1/2/3 preflight
processes retain another 336 batches, separately labeled and excluded from the
medians. Total numerical batches retained: 1,848. Samples/checksums, process order,
input identities and semantic limitations remain available. See the
[generator contract](typed-settings.md) and [validation](typed-validation.md).
