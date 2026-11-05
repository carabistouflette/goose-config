# Performance evidence status

The source baseline for this documentation audit is published Goose-config main
commit `4f977c0b1e4f06832b776c847d53897215c5a0bc`. It has no release tag. The
documentation changes in this update do not change runtime modules.

I checked recorded source hashes and Git file identities, not just recording
dates. Only the measurements below match the current implementation and harness.
Other result pages keep their original raw data and are marked as historical.

## Measurements that match current source

| Report | Measured source and identity check | Workload |
| --- | --- | --- |
| [Aliases](alias-performance.md) | The final lookup and binding records hash the same runtime, harness, compiler, and dependency inputs as current main. The paired core/update runs use runtime revision `d654a6e`; all compared runtime and harness files are unchanged through `4f977c0`. | Lookup: 9 processes, 7 batches per case, 10,000 operations per batch. Core and update comparisons: 6 before/after pairs, 7 batches per case, 1,000 operations per batch. Binding comparison: 3 rotating rounds, 7 batches per case, 1,000 operations per batch. No dedicated warmup; fixture setup is outside the timer. |
| [Generated env/CLI bindings](generated-bindings-validation.md) | Every recorded source-file hash in `generated-bindings-comparison.json` matches its file in current main. The comparison used source revision `d8b4ddabf3ac694f56f850f655f0869ebde6558e`; the source bridge is checked by file hash. | 9 shuffled rounds, 3 callers, 3 cases, 7 batches per process/case, 1,000 operations per batch. Six preflight processes are retained separately. Reference A and B are identical binaries; the first timed batches are kept. |

Both measurements used Goose compiler `eadca409f68210893f366e60d0c2f0dc29a339be`,
GCC 16.2.1 with `-O2`, Linux x86-64, and an Intel Core Ultra 7 258V. The alias
cross-library binding records also pin Viper 1.21.0, Koanf 2.4.1 and their Go
dependency graph. Raw files retain commands, versions, checksums and every
sample. Their reports show medians with observed run ranges and keep slower
cases visible. The host was shared; frequency, thermal state and unrelated load
were not controlled. These workloads do not support a general speed or library
ranking claim.

## Historical measurements

These results remain useful for their recorded source snapshots, but they are
not performance measurements of current main:

| Report | Snapshot and reason it is historical |
| --- | --- |
| [Core and schema benchmark archive](../bench/README.md) | The original run uses source `0d90a88`; paired reports use `3305e6d`→`56677f1` and `b098ce8`→`925c53e`. Their runtime and harness inputs predate current main. |
| [Shared Viper/Koanf comparison](comparison-performance-history.md) | Goose revisions `6ae9cac`, `efb6e5a`, and `86df42f`; current Goose modules and benchmark adapters have changed. Dependency versions remain recorded with each raw run. |
| [Duration workloads](duration-performance.md) | Runtime revision `f8ae9b2`; later alias work changed the measured core modules. |
| [Typed loading](typed-performance.md) | Runtime revision `5c4803b`; the measured `bench/typed_fixture.goose` file has changed since. The table does not establish current load performance. |
| [Scalar update](scalar-update-performance.md) | Runtime comparison ending at `7f72dc3`; runtime modules have since changed. |
| [Initialization](initialization-performance.md) | Runtime comparison ending at `6ad00fb`; runtime modules have since changed. |
| [Memory and fallback](memory-and-fallback-audit.md) | Runtime revision `3ba1ecf`; core modules have since changed. |
| [v0.1 preparation](v010-results.md) | Historical storage/binding snapshots ending at `f619f2d`; later runtime modules and adapters differ. |
| [Consumer startup](consumer-startup.md) | A frozen goose-check executable with goose-config `f7bef7d`, not current main. |

The historical pages and raw records preserve their original commands, source
and compiler identities, dependency versions, workloads, sample counts and
observed results. Do not combine ratios across different source revisions,
hosts, workloads, or harness versions.

## Not measured

There is no useful performance claim for the example worker, no general
throughput target, and no current end-to-end application ranking. Those are
not applicable; unrelated microbenchmarks do not answer those questions.
