# Consumer startup cost audit

Linking the config adapters changes the existing goose-check executable even
when no file is selected. The pinned generated program initializes more data
stack regions before entering its main function. Two retained whole-invocation
runs also show higher no-file medians, with substantial round-level variation
and variation between labels of the same binary. A fixed causal latency penalty
or portable speed claim is not established. This audit makes no runtime change.

## Sources and reproduction

Consumer before: `3dae6984941ed2ba97817d34c17722a03de6d62f`.
After: `32de6c4783bf8d3242e042993dadd160a98b2945`, containing the
[explicit configuration integration](consumer-integration.md).
The after snapshot bundles goose-config
`f7bef7dcfeab2ca95c94d92d0fbb2320ab3dcb05`; its six runtime files are unchanged.
Goose pin: `eadca409f68210893f366e60d0c2f0dc29a339be`.
The runner and its provenance corrections are committed at
`3d8836d49393c03b01b2544da2a93079d6ba55d1` and
`ba608cfdc66b32edf5d523fa2c215fa88634c3e1`.

```sh
git clone https://github.com/carabistouflette/goose-check.git /path/to/goose-check
python3 bench/consumer_startup.py --consumer /path/to/goose-check \
  --goose /path/to/pinned/goose --cpu 6 --seed 606 \
  --output .build/startup-first.json
python3 bench/consumer_startup.py --consumer /path/to/goose-check \
  --goose /path/to/pinned/goose --cpu 6 --seed 607 \
  --output .build/startup-repeat.json
```

Choose an available CPU and distinct output names. Linux, Python 3.11+, Git,
GCC and the pinned compiler build with adjacent stdlib sources are required.
The refs must exist in the consumer repository. Dirty worktree files, ambient
Git repository variables and replacement objects are not exported. The runner
uses bounded immutable Git exports, private `GOOSE_HOME` and native GCC `-O2`
executables. Existing process/fs pins, native code, build manifest and compiler
wrapper must match. Every vendor inventory hash is checked against actual bytes.

The raw [first run](../bench/results/consumer-startup-first.json) and
[repeat](../bench/results/consumer-startup-repeat.json) retain all timings,
round order, exact commands, fixtures, expected outcomes, source/compiler/stdlib/
GCC-driver/binary hashes, generated-C identity, flags and startup counts. Known
temporary paths are normalized; original build diagnostic byte hashes remain.
`/bin/true` identity is checked before and after measurement. Dynamic libraries
and GCC subprocess executables are not hashed; the complete host is not frozen.

## Workloads and timing boundaries

Every record has 20 shuffled rounds, 11 cases, 16 consecutive samples per case
block and three checked preflight/warmup invocations per case. All 3,520 measured
samples per record pass exact exit/stdout/stderr checks. Across both records,
7,040 measured checker invocations are retained; 66 warmups are also outcome-
checked. The 20
rounds are the principal observations; consecutive samples within a block are
correlated, and even rounds are not guaranteed statistically independent.

All complete command cases use the same effective settings:
`expect_exit=0`, `timeout_ms=30000`, `output_limit=65536`, and execute `/bin/true`.
Small JSON/TOML files contain those three integers. The 64 KiB cases pad the same
three-field documents with whitespace: they measure boundary-sized input scans,
not large configuration models. The CLI case repeats the same values as flags.
Current A/B are two labels for the exact same executable and argument vector.

The parent monotonic timer includes Python process creation, pipe collection,
checker execution, its child supervision and reaping. It excludes compilation
and warmups. Caches are warm; these are fresh process invocations, not cold-disk
startup measurements. The help cases omit file reads and `/bin/true` execution,
but include loader/runtime setup, argument access, diagnostic output and parent
overhead. Help text differs between revisions. Help deltas cannot isolate runtime
initialization, and configured-minus-no-file deltas cannot isolate parser work.

The runs used CPU6 on an Intel Core Ultra 7 258V shared host:

- First: 2026-11-05 00:05:38.259721–00:05:56.115937 UTC.
- Repeat: 2026-11-05 00:07:41.040565–00:07:58.657113 UTC.

No exclusive isolation, frequency, thermal or ASLR control is claimed. CPU4
timing courtesy was observed. The records capture the exact observed software
versions; those local values do not describe every CI or consumer platform.

## Observations

Each cell is the median of 20 case-block medians, in milliseconds. These are
observed values, without confidence intervals or CI performance thresholds.
All cases and both runs remain in the report.

| Invocation | First, ms | Repeat, ms |
| --- | ---: | ---: |
| Before, no file | 4.682 | 4.880 |
| Current A, no file | 4.996 | 4.948 |
| Current B, no file | 4.834 | 4.976 |
| Current, small JSON | 5.468 | 5.413 |
| Current, 64 KiB JSON | 5.782 | 5.636 |
| Current, small TOML | 5.492 | 5.410 |
| Current, 64 KiB TOML | 5.610 | 5.528 |
| Current, small JSON + CLI | 5.469 | 5.492 |
| Before, help | 3.799 | 3.764 |
| Current A, help | 3.873 | 3.886 |
| Current B, help | 3.892 | 3.876 |

The aggregate ratio divides those case medians. The paired ratio instead divides
same-round block medians, then takes their median. Ranges below are the complete
observed paired round ranges, not statistical intervals.

| No-file control | First aggregate | First paired median [range] | Repeat aggregate | Repeat paired median [range] |
| --- | ---: | ---: | ---: | ---: |
| Current A / before | 1.06703 | 1.05937 [0.92533–2.33513] | 1.01396 | 1.01757 [0.92759–1.23102] |
| Current B / current A, identical binary | 0.96764 | 0.98126 [0.47836–1.09190] | 1.00578 | 1.00524 [0.94278–1.24806] |

Both no-file aggregate medians increased after integration, but their changes
differ between runs and identical-binary labels also vary. These controls do not
apportion the difference among loader work, stack reservations, code/data layout,
controller behavior, filesystem cache or scheduling. No initialization-only,
parser-only, cross-library ranking or general regression magnitude is inferred.

## Reproducible startup structure

Both builds produce these generated-C entry arguments and executable sizes:

| Generated program property | Before | Current |
| --- | ---: | ---: |
| Main data-stack count | 12 | 26 |
| Total main-region bound, including dedicated globals | 13 | 27 |
| Maximum regions per worker program | 0 | 0 |
| Produced executable bytes | 144,512 | 235,512 |

The entrypoint calls `gs_rt_init(argc, argv, 12, 13, 0)` or
`gs_rt_init(argc, argv, 26, 27, 0)` before `main_g`. That helper allocates its
descriptor block and reserves each main stack region; the global argv buffer
adds a dedicated region. The second count includes the first; do not add them.
The third count is a region bound per worker program, not a worker count.
These are virtual reservation structure and one profile's executable sizes,
not resident memory, heap-allocation counts or measured per-reservation latency.
See the [memory metric boundaries](memory-and-fallback-audit.md).

The no-file branch still skips configuration APIs. This compiler's upfront
reservation structure explains why that branch does not imply zero integration
startup effects. A selected-file read also initializes a 65,536-byte writable
buffer, even for small documents, while the three-field schema already skips
larger sorting/hash-index setup. The measurements do not isolate that buffer's
cost or justify replacing the bounded reader or validation contracts.

## Review and scope

Independent code and measurement-method reviews checked the runner, provenance,
matched settings and limitations. Ten regressions cover bounded output,
timeout/child reaping, frozen exports, Git replacement suppression, vendor
integrity, export caps, matching fixtures and path normalization. Successful cases
rely on the pinned program's direct-child cleanup; failed runner subprocesses
additionally receive private-group termination. Only trusted consumer/compiler
sources are supported. Git exports cap at 256 files, 2 MiB per blob and 16 MiB
total, with bounded command output and deadlines. Accepted output is atomic.

No boundary defect or supported runtime optimization emerged from this pass.
Goose-config and goose-check implementation bytes remain unchanged. The existing
[sustained-fuzz release gate](release.md) remains incomplete; these performance
and tool-protocol checks do not complete it.
