# Memory retention and fallback-cost audit

**Historical:** this audit uses runtime revision `3ba1ecf`; current core modules
have changed since. Its memory and timing observations apply only to that
snapshot. See the [performance status](performance-status.md).

The tested processes plateau after their first growth, including after shrinking,
rejected reloads and Store teardown. Their resident pages remain retained.
Untouched-binary timing controls do not support a fallback runtime fix: the same
binary can show a larger apparent regression than the changed source. No runtime
change is made by this audit, and no general leak-freedom or speed claim follows.

## Sources and reproduction

Both memory invocations export the six runtime files from
`3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d`. They remain byte-for-byte unchanged
in this follow-up. Compiler pin: `eadca409f68210893f366e60d0c2f0dc29a339be`.
The native builds use GCC `-O2`, without sanitizers. Measurement tools and
regressions were committed as `fdf0b79ad696097ced23983017f74a082fabf1e4`.

```sh
python3 bench/measure_memory.py --goose /path/to/pinned/goose \
  --ref 3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d \
  --cycles 100 --repeats 3 --cpu 6 --output .build/memory-first.json
python3 bench/measure_memory.py --goose /path/to/pinned/goose \
  --ref 3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d \
  --cycles 100 --repeats 3 --cpu 6 --output .build/memory-repeat.json
```

Use an available CPU and distinct output files. Linux `/proc`, `taskset`, Python
3.11+ and the pinned compiler/GCC are required. Paths with spaces are supported.
The runner uses private temporary sources, binary and `GOOSE_HOME`, inherits
`HOME` unchanged, excludes ambient credentials and atomically publishes results.
Each raw record retains exact source/harness/driver/compiler/standard-library/
GCC/binary hashes, flags, environment policy and process measurements. Known
temporary diagnostic paths are normalized; original diagnostic byte hashes
remain recorded. No generated binaries or build trees are publication assets.

Accepted records: [first invocation](../bench/results/memory-cycles.json) and
[independent repeat](../bench/results/memory-cycles-repeat.json). Their UTC windows
are 2026-11-04 20:27:21.713048–20:27:24.084146 and
20:27:33.027202–20:27:35.254612. Both used CPU6 on a shared host; no isolation
claim is made. Each invocation runs three modes three times plus three
same-binary launcher controls: 24 children and 174 checkpoints across both.

## Workloads and metric boundaries

The harness verifies every full value, source and list element after every
phase. Checkpoints pause the direct native child on an input handshake while
the parent reads its memory. Owned getter results leave helper scope before
sampling. Initial setup includes schema and reusable input fixtures. Checkpoints
include first growth/shrink, cycles 10 and 100, failed reloads, and final return
from the scenario scope. No explicit memory trimming is performed.

All live Stores have 256 fields and 1,938 logical key bytes. Large scalar and
list payloads use 256 fields × 4,096 value bytes; lists contain 256 × 256
sixteen-byte items. Reload starts with 255 such lists and one Text field;
layered JSON replaces one list and later removes the other 254. Required-field
and unknown-key failures must preserve the last valid snapshot.

| Mode | Large logical value/source bytes | Large list items | Small bytes / items |
| --- | ---: | ---: | ---: |
| Scalar | 1,049,856 | 0 | 1,280 / 0 |
| Lists | 1,049,856 | 65,536 | 1,280 / 0 |
| Reload | 1,049,854 | 65,280 | 13 / 0 |

Final released counters are zero because no Store remains in scope. They do
not measure allocator capacity. RSS includes the runtime, harness, prebuilt
inputs, getter verification and error handling; it is not library-only memory.

RSS and private pages come from `/proc/PID/smaps_rollup` (private is clean plus
dirty); these describe resident pages, not requested allocations.
[`proc_pid_smaps(5)`](https://man7.org/linux/man-pages/man5/proc_pid_smaps.5.html)
documents these fields. Post-exec VmHWM and VmSize come from status; VmHWM is
approximate, while VmSize describes virtual address space, not physical RAM.
See [`proc_pid_status(5)`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html).

## Observed retention

Within each measured child, RSS and private memory are exactly flat from first
growth through every later sampled shrink, rejection and final teardown. The
ranges below span six independent processes per mode across both invocations;
they are observed ranges, not confidence intervals or CI memory budgets.

| Mode | Retained RSS, KiB | Retained private, KiB | Post-exec VmHWM, KiB |
| --- | ---: | ---: | ---: |
| Scalar | 4,608–4,712 | 2,528–2,540 | 4,608–4,712 |
| Lists | 18,000–18,056 | 15,840–15,852 | 18,000–18,056 |
| Reload | 25,308–25,344 | 23,136–23,140 | 25,308–25,344 |

All processes reserve 104,913,212 KiB of virtual space (about 100 GiB); this
is not 100 GiB of RAM usage. The pinned runtime rewinds stack tops on clear or
scope exit while retaining touched pages for reuse. These results are consistent
with that implementation, but do not count allocator blocks or prove behavior
for arbitrary workloads, longer runs or other platforms.

The runner separately records `wait4` lifetime peak RSS. Every workload and
launcher control reports 28,256 KiB in the first invocation and 28,372 KiB in
the repeat. That metric includes the inherited pre-exec Python/taskset launcher
floor. Same-binary control initial post-exec RSS is only 2,388–2,496 KiB. Thus lifetime
peak must not be called the native workload's allocation peak, and controls
must not be mechanically subtracted. Both metric families remain in the raw
records. Ordinary shrink/teardown does not promise to return physical pages.

## Fallback controls

The [complete diagnostic package](../bench/results/fallback-controls/README.md)
retains reproduction commands, raw data, windows, provenance and coverage
limits. Untouched native binaries run the full six-fixture updates harness,
1,000 operations per batch, seven batches, 12 alternating process pairs per
control. All 72 processes and 3,024 timing samples are retained.

Baseline is `53a68329332d20f61f5f4e9accedd651de8094f5`; current is the same
`3ba1ecf` runtime measured above. Ratios divide median process medians. A/A is
right/left for the exact same binary; A/B rows are current/baseline. The last
row reverses the actual initial revision order and inverts its stored label ratio.

| Control | Resize | TextList | Two-Text batch |
| --- | ---: | ---: | ---: |
| Identical binary A/A | 1.32114 | 1.04193 | 1.02908 |
| Baseline then current | 1.05701 | 0.92016 | 1.04653 |
| Current then baseline | 0.99873 | 1.03183 | 0.96883 |

The operational 5% timing alarm cannot establish a causal regression on this
host: unchanged code exceeds it, and revision-order controls change the apparent
result. Frequency, thermals, other processes and memory bandwidth remain
uncontrolled. Historical regressions remain published unchanged.

Generated-C diagnostics count requested `gs_memcpy` lengths, including timed
getter/check work. Before/current exactly match: resize 2,105,849 bytes/260 calls,
list 2,105,986/269, two-Text batch 2,097,650/261 per operation. These are neither
allocation counts nor hardware traffic, and instrumentation changes code layout.

Original PMU samples lack scheduling-coverage metadata and are exploratory.
A separate pinned-group refresh records positive equal enabled/running times
for all 1,512 samples and rejects partial coverage without scaling. Group-time
deltas follow [`perf_event_open(2)`](https://man7.org/linux/man-pages/man2/perf_event_open.2.html);
resetting counters does not reset those times. Refreshed current/baseline
instruction ratios at count50 are 1.00107, 1.00076 and 1.00022 respectively.
They show small instruction differences, without isolating eligibility checks
from every compiler/layout effect or establishing portable latency. PMU setup
is specific to the recorded Intel CPU Atom events. Instrumented timing is not
used as acceptance timing.

## Validation and release boundary

Forty-four Python regressions exercise measurement parsing/provenance and the
tools, including
timeouts, direct-child sampling/reaping, stale artifacts, rejected multiplexing,
output limits and atomic publication. CI adds a one-cycle native memory smoke
without timing or RSS thresholds; it does not require PMU access.

The runtime is unchanged. This audit does not replace the required sustained
coverage-guided fuzzing, which remains incomplete. No v0.1.0 release tag is
available; see [release status](release.md).
