# Generated binding validation and measurements

The generated env/CLI feature is frozen at
`d8b4ddabf3ac694f56f850f655f0869ebde6558e`. All seven runtime modules, private
parser, compiler pin and license remain byte-identical to published typed-settings
revision `e4305f91a3375cf1e1e8cec6e10312bbfb73f36b`. This is build-tool and generated
application code; it changes no Store or adapter API.
The raw comparison's recorded hashes for all source inputs match the audited
public main commit `4f977c0b1e4f06832b776c847d53897215c5a0bc`, so its measurements use
the current generator and mapping code.

## Qualification

Local Linux x86-64 qualification uses pinned Goose
`eadca409f68210893f366e60d0c2f0dc29a339be`, GCC 16.2.1 and Clang 23.1.4.

- Full `make check test` and optional-worker optimized/sanitizer checks passed
  from the frozen `c469a04` export with isolated caches. This includes existing
  ownership, adapter and copied-consumer checks; it does not replace sustained
  fuzzing.
- The final non-BMP/empty-list regression at `bd6817a` passed actual GCC and Clang
  ASan/UBSan debug/no-BCE and optimized builds. Generated drift checks and sibling
  and nested copied consumers passed afterward. Copied consumers now include
  three library modules: config, typed and bindings. Final copied consumers also
  apply generated env and CLI descriptors, check source labels, then destroy the
  Store and verify the owned settings in both in-process and GCC-O2 profiles.
- Tests check UTF-8 byte identity including controls, quotes, backslashes and
  non-BMP characters; independent returned containers; empty mappings; original
  sources; environment splitting versus repeated unsplit CLI values; atomic
  preservation after rejected layers; and present empty-list clearing.
- Fifteen schema/output regressions pass normally and under Python `-O`, covering
  strict limits, duplicate providers, invalid option types, lone surrogates,
  byte boundaries, safe generation and existing atomic-output/permission behavior.
- The maximum fixture qualifies 256 fields, 256 aliases, all ten kinds, a 256-byte
  key, 256 env mappings with 256-byte names, 256 CLI mappings with 254-byte names,
  and 256-byte UTF-8 separators for every list. It passes in-process and actual
  GCC-O2 and Clang-O2, each with a 300-second native deadline and process-group
  cleanup. [GCC record](../bench/results/generated-bindings-limit-gcc.json) and
  [Clang record](../bench/results/generated-bindings-limit-clang.json) retain
  compiler, generated-source, harness and executable hashes. This proves one
  mixed boundary fixture: arrays and metadata are checked, not application of a
  256-bound env/CLI layer, maximum-payload performance or every combination.
- Seven recorder regressions pass normally and under Python `-O`: independent
  complete/partial-cycle checksums, each wrong case, malformed samples, actual
  failed/timed-out process retention, path redaction and overwrite/collision
  protection. CI smoke-runs the native recorder without timing thresholds and
  runs the maximum-binding fixture through `make typed-limit`.

The worker's mapping order and exact key/name/separator bytes match its former
manual descriptors. Its defaults, application order, validator, command protocol,
file/process contracts and pinned goose-fs dependency remain unchanged.
Sustained coverage-guided testing remains incomplete; the project has no release
tag.

## Adoption-cost method

The [raw comparison](../bench/results/generated-bindings-comparison.json) retains
27 checked timed processes × 3 cases × 7 batches = 567 timed batches. Six separate
count-1/2/3 preflight processes retain another 126 batches, excluded from medians.
Each timed batch has 1,000 operations. Nine seeded shuffled rounds select generated,
reference-A and reference-B in one frozen GCC-O2 executable. Reference A/B use
identical bytes and argv. The run was on a shared host without exclusive
isolation, frequency control, or control correction.

The manual reference uses the worker's previous fixed-array literals. Both
representations use inline helpers returning fixed arrays. All descriptor bytes
are compared outside clocks. Construction dynamically indexes descriptors and
sums lengths; environment and CLI include Store initialization, controlled adapter
application and checked maximum access. Full final typed values, lists and selected
sources are checked outside clocks. Environment uses supplied values, excluding
native getenv; neither case includes process startup, file I/O or reload.

Host: Intel Core Ultra 7 258V, Linux x86-64, affinity CPU 6. Recorded timing window:
2026-11-05 18:25:08–18:25:09 UTC. Compiler/stdlib/runtime headers, GCC driver/cc1/
assembler/linker, helper, source, executable and native disassembly hashes are
recorded and checked. First batches, variation, and slower cases remain.

The exact recorded native disassembly hash was checked. Timed
loops retain fixed-array stack writes, dynamic indexing and checksum work; the
application paths retain initialization, shared adapter routines and checked
getters. Helpers are inlined, but scheduling and stack locations differ. Exact
native equivalence is not established.

## Observations

Values are medians of nine process medians in ns/op. Brackets show the observed
minimum-to-maximum range of those nine medians, not a confidence interval.
Ratios use uncorrected medians; above 1 means more elapsed time. A/B are the
same reference code/path.

| Case | Generated | Reference A | Reference B | Generated / A | Generated / B | B / A control |
|---|---:|---:|---:|---:|---:|---:|
| construct | 16.922 [16.181–19.598] | 16.185 [15.504–21.885] | 16.913 [16.178–17.728] | 1.046 | 1.001 | 1.045 |
| supplied environment | 2373.951 [2249.987–2850.104] | 2430.605 [2162.844–2919.847] | 2256.984 [2240.592–2542.733] | 0.977 | 1.052 | 0.929 |
| CLI | 2196.957 [2077.146–2540.432] | 2173.044 [2029.676–2614.894] | 2080.406 [2031.111–2361.100] | 1.011 | 1.056 | 0.957 |

Generated construction and CLI are slower versus A; environment changes direction
against B. Identical-reference variation is material. These observations establish
neither a causal small performance change nor zero overhead. Construction can be
folded or hoisted by the optimizer and is not fresh allocation latency. No memory/
RSS, native-getenv, maximum-schema performance or cross-library ranking follows.
The benefit established here is a single explicit mapping declaration with the
existing runtime semantics and owned generated settings.

## Reproduction

```sh
python3 bench/measure_generated_bindings.py --goose /absolute/path/to/pinned/goose \
  --revision d8b4ddabf3ac694f56f850f655f0869ebde6558e \
  --iterations 1000 --rounds 9 --seed 606 --cpu CPU \
  --output .build/generated-bindings-comparison.json \
  --disassembly-output .build/generated-bindings-native.asm
python3 tests/typed-limit.py /absolute/path/to/pinned/goose --cc gcc --bindings
python3 tests/typed-limit.py /absolute/path/to/pinned/goose --cc clang --bindings
```

Choose fresh evidence paths; existing records are preserved. Failed managed
process/protocol context is retained in an incomplete record and never accepted
as a successful comparison. See the [binding contract](generated-bindings.md).
