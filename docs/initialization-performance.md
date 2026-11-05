# Long-prefix initialization follow-up

**Historical:** this comparison ends at `6ad00fb`; current runtime modules have
changed since. See the [performance status](performance-status.md) before using
these values to describe the current implementation.

This follow-up retains the [earlier mixed loading results](v010-results.md)
and targets schema initialization. It does not claim a general loading speedup.

The later [scalar update audit](scalar-update-performance.md) measures a separate
exact-size replacement fast path. The records below remain historical.

## Change and diagnosis

An ordinary key byte previously passed a dot test before its ASCII alphabet
check. The validator now accepts ordinary allowed bytes on its fast path and
handles component boundaries on the remaining dot path. It still scans every
byte once and accepts exactly the same case-sensitive grammar.

The key comparator skips equal 16-byte blocks before its existing eight-byte
and bytewise remainder. All slices remain checked and equality remains
alignment-safe. Sorting the 256-key fixture with 240 shared prefix bytes
needs fewer chunk-loop iterations; declaration order and exact byte ordering
are unchanged. An early mismatch can add an extra bounded equality check,
so the optimization is not a universal comparison-speed guarantee.

Diagnostic probes isolated the validator branch order and comparison chunk
changes separately. Short alternating batches and swapped-side probes helped
distinguish initialization work from host drift. Identical-code controls exposed
an apply-side bias in the same-process diagnostic harness; its apply timings
were discarded as evidence of a runtime regression or improvement. The public
results below instead use the existing reproducible separate-process harness.

## Final measurements

Before: `b9cf0b2ddb166e14f9c8e4fcb560a4332138fc19`. After: `6ad00fb3b80a7c94a797d272292af4f5f962ecb6`.
Compiler: `eadca409f68210893f366e60d0c2f0dc29a339be`; `gcc (GCC) 16.2.1 20260810`, GCC `-O2`.
Host: Intel(R) Core(TM) Ultra 7 258V; `Linux-7.2.11-arch1-1-x86_64-with-glibc2.44`; CPU affinity 7.
Each invocation takes four alternating before/after pairs, seven batches per
fixture and 1,000 operations per batch. The second invocation is an independent
repeat with freshly built private snapshots. Both ran between
2026-11-04T17:24:23Z and 17:25:39Z. The host was shared, with no exclusive
isolation, frequency or thermal control, or dedicated warmup. Other activity
remained uncontrolled.

Values are median process medians in ns/operation. Each ratio is the after
median divided by the before median; lower is faster. Every fixture and every
raw sample is retained, and all checksums agree.

| Fixture | Before | After | Ratio | Repeat before | Repeat after | Repeat ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `lookup-small` | 16.7 | 16.4 | 0.98 | 16.3 | 15.9 | 0.98 |
| `lookup-first-wide` | 16.1 | 16.1 | 1.00 | 15.7 | 16.1 | 1.03 |
| `lookup-mixed-wide` | 39.0 | 40.1 | 1.03 | 38.1 | 38.3 | 1.00 |
| `lookup-missing-wide` | 83.3 | 83.0 | 1.00 | 81.6 | 80.4 | 0.99 |
| `lookup-last-wide` | 29.3 | 28.9 | 0.99 | 28.4 | 28.3 | 1.00 |
| `reject-layer-wide` | 113.9 | 112.1 | 0.98 | 110.5 | 112.1 | 1.01 |
| `apply-small` | 558.3 | 501.9 | 0.90 | 495.4 | 517.4 | 1.04 |
| `apply-wide` | 13,515.6 | 13,529.7 | 1.00 | 12,641.9 | 12,821.7 | 1.01 |
| `update-one-large` | 143,557.1 | 148,536.8 | 1.03 | 126,653.8 | 139,176.7 | 1.10 |
| `lookup-last-long-prefix` | 146.3 | 145.5 | 0.99 | 137.8 | 137.7 | 1.00 |
| `lookup-mixed-long-prefix` | 148.7 | 146.5 | 0.99 | 137.9 | 139.1 | 1.01 |
| `apply-wide-long-prefix` | 38,985.6 | 40,072.2 | 1.03 | 36,880.2 | 35,989.6 | 0.98 |
| `init-small` | 326.1 | 326.4 | 1.00 | 295.4 | 300.8 | 1.02 |
| `init-wide` | 34,692.7 | 35,587.6 | 1.03 | 32,630.4 | 31,965.0 | 0.98 |
| `init-wide-long-prefix` | 226,289.3 | 182,435.5 | 0.81 | 214,062.5 | 166,532.6 | 0.78 |
| `toml-small` | 645.8 | 664.1 | 1.03 | 614.2 | 628.6 | 1.02 |

Long-prefix initialization has a lower median in both invocations. Wide
long-prefix apply changes direction between runs, so no improvement is claimed.
The large-text single-key update is slower in both runs, and the small TOML
case also has a higher median. These paths do not call the changed validator
or comparator on these fixtures; binary layout and host variation are possible
contributors, not established explanations. The observed costs remain in the
record. The full-arena copy of approximately 1 MiB per large-text update remains
a separate profiling target. The results establish neither a universal speedup
nor a timing deadline.

Raw records: [paired](../bench/results/initialization-paired.json),
[independent repeat](../bench/results/initialization-repeat.json). These retain
exact revisions, harness hash, compiler/flags, hardware, affinity, all samples
and checksums. Earlier records have not been relabeled or replaced.

## Reproduce

```sh
python3 bench/measure.py --goose /absolute/path/to/pinned/goose \
  --before-ref b9cf0b2 --after-ref 6ad00fb --iterations 1000 \
  --pairs 4 --cpu 7 --output .build/initialization.json
```

Use an available CPU and separate output names for independent runs. The script
exports immutable runtime snapshots and uses the same sixteen-fixture
harness for both. Do not compare timing ratios across different historical
hosts, affinities or harness hashes.

## Contracts and verification

The supported API, limits, error selection, hash/index layout, ownership and
atomic publication are unchanged. Validation checked grammar equivalence,
lexicographic ordering, checked-slice bounds, overflow, alignment safety and
consumer-overload behavior.

An independent bytewise reference checks 132,612 comparator calls, covering
lengths 0–256, every first-mismatch position, equal/prefix cases, both directions
and binary bytes. Those guards passed before and after the change. Existing
all-byte key-grammar checks cover both tiny and indexed schemas. Normal/debug,
GCC/Clang optimized builds and GCC/Clang ASan/UBSan passed, including all three
independent models, 331 hostile-input cases per build, ownership, import and
consumer-overload regressions.

The required sustained coverage-guided fuzzing remains incomplete. These
bounded checks do not replace it; no v0.1.0 tag is available. See
[release status](release.md).
