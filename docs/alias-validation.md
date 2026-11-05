# Alias validation and limits

The final runtime is `d654a6eb6138e676dfb6e49037c707cbf954a41d`.
Five runtime files add aliases; `vendor.goose`, the vendored parser, compiler pin,
native caller/process/filesystem wrappers and dependencies remain unchanged.
The original `init` and `reload` signatures remain available as overloads.

Validated locally on Linux x86-64 with pinned Goose, GCC 16.2.1 and Clang 23.1.4:

- Full formatting/type checks, normal test target, in-process execution, ordinary
  native and debug/no-BCE tests, import isolation, ownership and native environment
  bindings. Existing examples and benchmark protocol tests pass.
- Full normal/debug models: 2,206 scalar transactions, 2,109 nested transactions
  with 100,577 responses over 45 schema cycles, 1,702 common-feature transactions,
  1,487 duration cases/5,948 observations, and 331 hostile-input/resource cases
  per executable. These existing models remain unchanged.
- GCC and Clang ASan/UBSan profiles and both optimized release profiles, including
  all alias tests, native environment tests and existing models/security cases.
  Final profiles used separate frozen source exports and isolated caches.
  Runtime and alias-test bytes were checked against the exact commit afterward;
  sanitizer binary compiler sections independently identify GCC and Clang.
- Scalar/duration/list aliases, multiple aliases to one canonical field, getters
  and source labels, textual and nested JSON/TOML layers, supplied/native env,
  CLI bindings, replacement reload and source removal.
- Canonical-ID duplicate detection across aliases and canonical names, including
  identical values, nested branches and absent external binding names. Late
  failures preserve scalar/list content, presence, sources and alias metadata.
- Caller key storage destroyed after initialization; all 256 aliases remain
  usable. Successful schema replacement reorders field IDs and changes types;
  aliases target the new schema. Failed initialization/reload retains the old
  schema and aliases; successful canonical-only replacement removes aliases.
- Boundary cases: 256 aliases accepted/257 rejected, 256/257-byte keys/targets,
  empty/malformed/non-ASCII metadata, canonical/alias leaf-prefix conflicts,
  unknown targets and rejected chains. Populated 256-field/alias/env descriptors
  verify each distinct value and provenance, alongside canonical-only bindings.
- Six benchmark protocol tests pass normally and under Python `-O`: target-aware
  checksums and odd/even counts, wrong mapping, incomplete/duplicate/nonfinite
  samples, cached binary inventory/tampering and zero/unstable timing controls.

Independent design, implementation/security and performance/evidence reviewers
checked the feature and subsequent changes. Their findings strengthened staged
schema identity, ownership/rollback tests, binding lookup reuse, target-distinct
benchmark values, native calling-convention diagnosis, toolchain hashes and the
cached diagnostic protocol. All three final reviewers found no remaining
blocker after these fixes; performance costs remain visible in the
[complete measurement report](alias-performance.md).

Reproduce with `make check test property security`, `SANITIZER_CC=gcc make sanitize`,
`SANITIZER_CC=clang make sanitize`, and `make release RELEASE_CC=gcc` / `clang`.
Set `GOOSE` to the pinned compiler if it is outside the default toolchain path.
Run profiles sequentially in one checkout, or use separate source exports and
caches; sanitizer and release targets intentionally reuse output names.

These checks do not establish macOS/Windows support, thread safety, allocation
recovery, full provider-ecosystem parity or zero cost when aliases are unused.
The sustained coverage-guided JSON/TOML/list/reload fuzz gate remains incomplete.
Bounded models and sanitizer runs do not replace it; no retry or release tag is
claimed. See [release preparation](release.md) and [alias contracts](aliases.md).
