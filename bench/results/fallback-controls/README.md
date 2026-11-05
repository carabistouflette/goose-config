# Scalar fallback performance controls

**Historical:** these runs compare revisions `53a6832` and `3ba1ecf`. Current
core modules have changed since; see the
[performance status](../../../docs/performance-status.md).

No fallback runtime fix is supported by these measurements. An identical
binary shows a +32.1% resize ratio, while before/current
resize ratios change from +5.7% to -0.1% between actual execution-order controls.
Diagnostic copies show identical requested copy bytes/calls. A refreshed,
coverage-checked PMU run also observes small instruction differences. Large latency differences remain confounded
by host/process effects.

Before: `53a68329332d20f61f5f4e9accedd651de8094f5`.
Current: `3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d`, whose `config.goose` is
byte-for-byte identical to `7f72dc34d7c154014ca2dc4a0c087dfac0097331`.
Compiler pin: `eadca409f68210893f366e60d0c2f0dc29a339be`; GCC `-O2`.
Exact compiler/GCC versions, flags, source/harness/compiler/binary hashes and
argv are retained in the manifests. Absolute workspace/artifact path prefixes
are replaced by `<WORKSPACE>` / `<ARTIFACTS>`; measured hashes are unchanged.
Each record links the corresponding sanitized manifest hash and preserves its
original local manifest hash separately.

## Untouched-binary measurements

Each row contains 12 alternating process pairs, 1,000 operations per batch,
seven batches and the entire six-fixture public updates harness. Every raw
sample, checksum, process order, stdout, and whole-process perf stderr is
retained. All 72 processes, 432 fixture medians and 3,024 timing samples parsed
and validated. Ratios are ratios of medians of process medians. A/A is right
label divided by left; A/B rows are current divided by baseline.

| Record | Resize | TextList | Two-Text batch |
| --- | ---: | ---: | ---: |
| `final-aa-same-binary.json` | 1.32114 | 1.04193 | 1.02908 |
| `final-ab.json` | 1.05701 | 0.92016 | 1.04653 |
| `final-ba-labels.json` | 0.99873 | 1.03183 | 0.96883 |

The last row swaps labels and reverses the actual initial revision order:
current→baseline, compared with baseline→current in A/B. Pair order alternates
thereafter. Its stored right/left ratios are inverted in this table. No timing
samples were removed. The operational >5% alarm goes red on final A/B resize,
but identical-binary A/A resize would also go red by a substantially larger
amount. That alarm is red-capable but cannot be used as a deterministic causal
regression test on this host.

The CPU7 runs were recorded on 2026-11-04:

- A/A: 19:38:33.276Z–19:39:34.575Z.
- A/B: 19:39:50.433Z–19:41:57.423Z.
- Opposite actual revision order: 19:42:08.311Z–19:44:03.075Z.

The machine was not exclusively isolated. Other processes, kernel activity,
frequency, thermals and memory bandwidth were
uncontrolled; the observed governor was `powersave`, unchanged. There was
fixture setup but no dedicated warmup. These controls establish that a large
apparent slowdown can occur without changing code; they do not apportion the
historical +33.9% resize result between individual host or layout causes.

## Diagnostic copy and instruction counts

Diagnostic generated-C copies add counters to `gs_memcpy` and the existing
paired clock calls; the public Goose harness and runtime source are unchanged.
Instrumented times are not acceptance measurements. `instrumentation-manifest.json`
records exact generated-C/runtime-object/binary hashes, C argv and PMU settings.
CPU Atom user-mode counters worked; sampling was not attempted. Per-sample
events exclude kernel/hypervisor work (PMU type10, cycles0x3c/instructions0xc0).
Whole-process perf counters in the untouched records mix all six fixtures and
are not used to attribute fallback instruction costs.

The original PMU records below did not capture enabled/running times and did
not pin events. Their instruction/cycle values are exploratory and are **not**
used to quantify overhead: positive counts do not exclude multiplexing. The
original records remain unchanged. Their software copy counters do not depend
on PMU coverage. At count50, eight A/B pairs (56 samples per side per fixture),
the original per-operation medians were:

| Fixture | Copied bytes before/current | Copy calls before/current | Instructions before | Instructions current | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Resize | 2,105,849 / 2,105,849 | 260 / 260 | 31,003.57 | 31,034.58 | +0.100% |
| TextList | 2,105,986 / 2,105,986 | 269 / 269 | 31,440.58 | 31,462.58 | +0.070% |
| Two-Text batch | 2,097,650 / 2,097,650 | 261 / 261 | 31,480.06 | 31,485.08 | +0.016% |

Every sample in both count2 and count50 records has exactly the stated copy
bytes/calls. These are requested logical generated-unit copy lengths, not
allocation counts, retained capacity or hardware memory traffic. Instrumentation
adds work and changes layout. Original identical-source diagnostic executable
`.text` hashes match, which controls one code-layout variable. The original PMU
values lack coverage validation and are not used quantitatively here; the
coverage-checked refresh below supplies that separate evidence. Neither set
isolates every address-layout effect or establishes portable latency.

### Coverage-checked refresh

`verified-count2.json`, `verified-count50.json` and `verified-aa-count50.json`
use a pinned cycles/instructions group on CPU6. Each timed sample records
positive, equal enabled/running nanoseconds; partial coverage is rejected
without scaling. All 1,512 refreshed samples passed. These diagnostic runs
are separate from the untouched CPU7 acceptance series.
`verified-manifest.json` and `verified-instrumentation-manifest.json` retain
the exact source, generated-C, object, binary, flag and compiler provenance.

The requested copy bytes/calls still agree exactly in both versions at both
counts. At count50 the refreshed per-operation instruction medians are:

| Fixture | Baseline instructions | Current instructions | Current / baseline |
| --- | ---: | ---: | ---: |
| Resize | 30,994.86 | 31,027.88 | 1.00107 |
| TextList | 31,431.88 | 31,455.88 | 1.00076 |
| Two-Text batch | 31,471.37 | 31,478.38 | 1.00022 |

The same-source refresh differs by at most 0.01 instructions/op in these
medians, while cycle medians vary. These small instruction differences do not
isolate every compiler/layout effect or establish a portable latency cost.

## Reproduction

From a goose-config checkout containing `bench/measure.py`, use an exact pinned
compiler. These scripts accept paths containing spaces via argument arrays and
use a private `GOOSE_HOME`. Change CPU numbers when necessary and coordinate
timing before starting. No source checkout is modified.

```sh
python3 bench/diagnostics/fallback_controls.py --goose /path/to/pinned/goose --prepare
python3 bench/diagnostics/fallback_controls.py --control same-binary --count 1000 --pairs 12 \
  --perf --output final-aa-same-binary.json
python3 bench/diagnostics/fallback_controls.py --control ab --count 1000 --pairs 12 \
  --perf --output final-ab.json
python3 bench/diagnostics/fallback_controls.py --control ba-labels --count 1000 --pairs 12 \
  --perf --output final-ba-labels.json
python3 bench/diagnostics/instrument_fallback.py
python3 bench/diagnostics/fallback_controls.py --control ab --instrumented --count 2 --pairs 2 \
  --output counters-count2.json
python3 bench/diagnostics/fallback_controls.py --control ab --instrumented --count 50 --pairs 8 \
  --output counters-count50.json
python3 bench/diagnostics/fallback_controls.py --control same-source --instrumented --count 50 \
  --pairs 8 --output counters-aa-source-count50.json
```

`--root`, `--workdir`, `--cpu` and `--build-cpu` select repository, ignored
artifacts and CPUs. The instrument builder accepts `--workdir` / `--build-cpu`.
Use distinct output names for repeats. A/B returns exit1 when any normalized
fallback median ratio exceeds1.05; data are written before this alarm. Parse,
assertion and checksum errors are separate failures. Diagnostic PMU setup is
specific to this Intel CPU Atom PMU and requires adaptation on another host.

The portable tools independently prepared all three snapshots in a fresh path
containing spaces, rebuilt all instrumented copies, and passed untouched and
coverage-checked native smokes. They reject reused preparation directories,
validate source/binary hashes before execution, serialize workdir access and
invalidate an old instrumentation manifest before rebuilding. Outputs publish
atomically; invalid records exit2, distinct from the operational timing alarm
exit1. Timeouts kill/reap only their own subprocess groups. A lock left by a
forced termination requires inspection/removal or a different workdir.
The pinned group is specific to the recorded Intel CPU Atom settings;
unsupported or partially scheduled events fail closed. CI checks tool protocol
and failure handling without requiring PMU access. `index.json` hashes the
evidence and current portable tools. Historical observations were not replaced
or relabeled with the coverage refresh.
