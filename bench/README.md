# Configuration benchmarks

Run `make bench BENCH_ITERATIONS=1000` from the library root. The harness builds
one native GCC `-O2` executable and takes seven timed batches per fixture,
printing each raw sample in ns/operation plus median, min, max and checksum.
A second independent invocation checks repeatability. Fixture/schema setup is
outside the timer; validation, output checking, checksum consumption, loop
work, getters used to verify results, and error creation are inside it.
Successful layers reuse a Store, replacing the current arena without retaining
history. There is no external I/O in the timed loop.

## Fixtures

- `lookup-small`: successful first-key Text getter in an eight-field schema;
  best-case linear lookup, 32-byte values.
- `lookup-missing-wide`: failed getter in a 256-field schema, including safe
  diagnostic construction.
- `lookup-last-wide`: successful getter for the final key in that same schema.
- `reject-layer-wide`: stage a valid first override, reject an unknown second
  key, then check the previous first value remains unchanged.
- `apply-small`: replace all eight 32-byte Text values and read the first one.
- `apply-wide`: replace all 256 32-byte Text values and read the first one.
- `update-one-large`: initialize 256 × 4096-byte Text values, then alternate
  one key between `a` and `b`; every update copies the other 255 large values.
  This deliberately exposes the full-arena atomicity cost, approximately 1 MiB
  per call. The initial first-key value shrinks on the first timed call.
- `toml-small`: alternate two two-setting TOML documents, including parse,
  strict kind checking, transaction commit and a checked integer getter.

All fixtures assert acceptance/rejection and consume results. These are local
microbenchmarks, not production throughput, an allocation benchmark, a general
ranking, or a claim about other configuration libraries. No CPU affinity or
frequency governor was controlled; other processes and CPU frequency scaling
can affect results. There is no separate warmup pass; the store is initialized
before timing, and the first batch can include cold effects. Report all raw
samples rather than selecting the fastest batch. CI runs small smoke workloads
without timing thresholds.

## Recorded measurement

Raw samples: [current run](results/current.txt), [independent repeat](results/repeat.txt).
Environment and exact source/toolchain revisions: [metadata](results/environment.txt).
Results use 1,000 operations per batch on an Intel Core Ultra 7 258V under Linux,
GCC 16.2.1. The compiler and vendored parser are pinned. The native compiler
commands are `gcc -O2 -c <runtime.c> -o <runtime.o>` and
`gcc -O2 <program.c> <runtime.o> -o <binary> -lm -pthread -ldl`.

The field-indexed transaction replacement map and duplicate bitmap eliminate
nested bookkeeping scans; key resolution still compares schema keys linearly.
The large-text update remains dominated by copying the complete live arena.
No numerical speedup is claimed from the exploratory pre-change measurements,
which were collected under different transient load and fixture coverage.

When changing the implementation, preserve the contract tests, keep all
fixtures, record the source SHA, compiler, flags and hardware, and retain both
raw runs. Add profiling before changing key lookup or trading away atomicity
for lower copying costs.
