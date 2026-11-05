# Typed settings validation and limits

The implementation is frozen at `5c4803b1bca5c0217d17e0db9c4669c31f17b61a`.
Later result/documentation commits do not change generated runtime behavior.
Original six runtime modules, Store layout, vendored parser, dependencies and
pinned compiler remain unchanged from the published alias revision `d7d9d7f`.
The new runtime surface is the optional `config.typed.has_value` adapter.

## Functional and tooling qualification

Validated locally on Linux x86-64 with pinned Goose, GCC 16.2.1 and Clang 23.1.4:

- Full normal tests, native/debug/no-BCE tests, import/ownership checks, examples,
  existing model/property and hostile-input/security suites. Those existing
  models and their underlying six runtime modules remain unchanged.
- Complete GCC/Clang ASan/UBSan and optimized release profiles at `d851e08`,
  including the worker. After the generated-cleanup fix, targeted typed tests
  and the worker were repeated in both sanitizer and optimized compiler profiles
  from separate frozen `529c0f3` exports and isolated caches. Runtime, generator,
  generated fixture and worker bytes matched the final implementation afterward.
- All ten scalar/list kinds, aliases, values and sources, checked requiredness,
  numeric bounds independent of a differently constrained Store, wrong kinds
  even when absent, unknown keys and no validator invocation before stage success.
- Populated destination preservation after stage and callback failures; successful
  replacement clears every stale optional payload/flag/source. Empty/zero/false
  remain present. Full content survives source replacement and destruction,
  including binary Text and nested TextList bytes.
- Eleven strict-schema/output regressions pass normally and under Python `-O`:
  malformed/deep/oversized UTF-8 JSON, duplicates, unknown properties, token caps,
  exact i64 bounds, nonfinite/boolean numeric inputs, key/identifier/prefix/name
  collisions, aliases, formatter/timeout/output failures and permission handling.
  New outputs remain 0600 under umask 077; replacements retain existing rwx bits.
- Actual pinned-compiler ownership checks: positive control plus ten rejected
  cases cover readonly scalar/Text/list/nested TextList/builder mutation, mutable
  validator spelling, views used across replacement, output escaping its owner,
  and a validator attempting to retain candidate storage.
- Standalone consumers use a copied two-module library with no test/example
  dependency. Sibling and nested generated modules pass in-process and GCC-O2,
  with paths containing spaces and explicit root dependency declarations.
- Seven benchmark protocol regressions pass normally and under Python `-O`,
  including independent odd/even checksums, every wrong-case checksum,
  incomplete/nonfinite records, actual failed/timed-out process output retention,
  protocol-failure context and native-evidence overwrite/collision guards.

## Maximum schema and cleanup regression

The initial monolithic generator qualified in-process at 256 fields/256 aliases
but its optimized GCC build exceeded separate 180-second and 600-second budgets.
Neither attempt produced a qualified native binary. The expired first build's
remaining compiler child completed later; no repeat started while it remained.
The second attempt used process-group timeout cleanup. Original logs/probes
remain retained locally; these were compiler-resource checks, not load timings.

A reduced optional-Integer case reproduced emitted-C expansion without aliases,
JSON input or candidate list owners. Field-scope error builders accumulated until
function exit, while the mixed-kind owning candidate also required cleanup at
each early return. Independent inspection found those two cleanup patterns
accounted for most of the original large function. The fix keeps per-field
errors in short lexical scopes and reads through a borrowed `stage` helper.
The outer `load` still owns its private candidate, invokes the actual readonly
validator, and publishes only after success. No validation, ownership check or
shared alias-inline policy was removed or changed.

The pinned dry-run regression failed before the fix at 10,612,649 emitted C bytes
and passed after at 1,843,065, below its 4,000,000-byte source budget. This is a
source-expansion guard, not elapsed compile-time or runtime performance evidence.
Diagnostic paths affect exact bytes; no causal speed percentage is claimed.
`tests/typed-codegen.py` reaches the actual generator/compiler seam without
executing a native compiler. It remains distinct from the following native proof.

The original full fixture now passes in-process and real GCC-O2/Clang-O2:
256 fields, 256 direct aliases, all ten kinds and a 256-byte key. It applies distinct
JSON values through aliases, loads typed settings, destroys the Store and checks
every full scalar/list value and selected sources. Each native build has a fixed
300-second deadline; failure terminates its process group and reaps the direct
child. This is
one mixed boundary fixture, not every combination of maximum payload sizes.

- [GCC maximum qualification](../bench/results/typed-limit-gcc.json)
- [Clang maximum qualification](../bench/results/typed-limit-clang.json)

The records retain generated/harness/compiler/binary hashes and successful native
output. Reproduce with `make typed-limit GOOSE=/absolute/path/to/pinned/goose`.
No smaller public generated-field cap was adopted.

## Remaining scope

Validation strengthened actual const-reference enforcement (a static function
bound alone was insufficient), output permissions, token conversion bounds,
temporary-owner lifetimes, maximum native qualification, import rules, benchmark
controls and failed-output retention.
The [complete measurements](typed-performance.md) retain slower schema rejection,
material identical-reference variation and optimized-read interpretation.

The optional build tool does not supply arbitrary struct reflection, maps/object
lists, dynamic code/default expressions or coercions. No concurrency, allocation
recovery, memory/RSS, maximum-payload performance or additional-platform support
is established. Validators retain the documented purity/reentrancy requirement;
caller-authored errors are not automatically value-free diagnostics.

The sustained coverage-guided JSON/TOML/list/reload testing remains incomplete.
Bounded tests/models and sanitizers do not replace it. No release tag is
available; see [release status](release.md).
