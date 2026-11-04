# v0.1.0 preparation

The selected common-application scope is implemented. These release gates do
not declare that a v0.1.0 tag exists:

- Define the [supported API and patch compatibility boundary](api.md).
- Preserve strict types, bounded work/storage, ownership and atomic failures.
- Keep normal/debug, GCC/Clang optimized/sanitizer, model, hostile-input,
  import/ownership and TOML conformance checks green.
- Retain loading improvements/regressions, raw samples and provenance,
  including matched binding/reload workloads.
- Run sustained coverage-guided JSON/TOML/list/reload testing before tagging.
- Audit standalone usage, notices, security reporting and release notes.

The sustained coverage-guided campaign has not been completed. Existing
model, malformed-input and sanitizer suites are not a substitute for that
campaign. Do not tag v0.1.0 while this release gate remains open.

The [storage and binding audit](v010-results.md) records the validated runtime,
compiler matrix, independent reviews, all measured costs and timing limitations.
Loading results are mixed; they do not establish a general speedup.

A release identifies an exact reviewed commit, pinned compiler, validation
evidence, measured limitations and compatibility exceptions. Credentials,
generated build trees and private planning are not release assets. Apache-2.0
and third-party notices accompany sources.
