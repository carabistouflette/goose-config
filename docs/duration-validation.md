# Duration validation and limits

The six runtime modules are unchanged after feature commit `1deea72`.
Boundary/model tests were extended at `46e99213ac754790bd97cdb7ad81e7877600d52a`.
The pinned compiler and vendored TOML source were not changed.

Validated locally on Linux x86-64 with GCC 16.2.1 and Clang 23.1.4:

- Formatting/type checks, full normal test target, in-process execution,
  ordinary native builds, debug/no-BCE builds, import isolation and ownership.
- Full property, nested and common-feature models and 331 hostile-input/resource
  cases in normal and debug profiles.
- Full GCC and Clang ASan/UBSan profiles and GCC-O2/Clang-O2 release profiles,
  including existing models/security cases and new duration/native-env tests.
- The duration oracle covers 1,487 fixed/seeded cases and 5,948 observations per
  executable: parser acceptance/value, override state, JSON state and TOML state,
  including provenance after failed writes. It uses forward regex parsing and
  arbitrary-precision integer fractions, independently of the library's reverse
  fractional recurrence. Checks stay active under Python `-O`.
- Exact positive/negative i64 boundaries, fractional and component-sum overflow,
  per-component truncation, Unicode microsecond spellings at 128/129-byte bounds,
  malformed bytes, lists up to 256×128 decoded bytes, strict document types,
  empty environment lists, native bindings, full-state layer rollback,
  required-field reload failure and independent list ownership.
- Five benchmark-protocol regressions pass normally and under Python `-O`.
- Anonymous credential-disabled standalone clone of `46e9921`: duration example
  passed in-process and GCC-O2, with a clean source tree. README's full-commit
  dependency quickstart also passed with a fresh credential-disabled fetch.

Initial local GCC/Clang commands shared output names, so those logs are retained
as provisional. The qualified profile runs used independent build directories
and isolated caches, with source hashes checked against the frozen export;
GCC ran in the clean source checkout and Clang in its frozen standalone export.
The eight runtime/test source identities were checked again after both finished.
The sanitizer binaries' compiler sections independently identify GCC and Clang.
Validation strengthened full-state rollback checks, list/grammar docs, benchmark
key variation, native-loop inspection, compiler input identities and clean
build-environment controls. See the
[grammar/API contract](durations.md) and [all measured results](duration-performance.md).

These checks are targeted feature qualification plus existing regression suites.
They do not establish Windows/macOS support, allocation recovery, concurrency
safety, full Viper/Koanf feature parity or a universal performance ranking.
Sustained coverage-guided JSON/TOML/list/reload testing remains incomplete;
bounded oracle/model/sanitizer tests do not replace it. No v0.1.0 release tag is
available. See [release status](release.md).
