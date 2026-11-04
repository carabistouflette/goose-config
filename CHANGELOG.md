# Changelog

## Unreleased — v0.1.0 preparation

- Document integration into the existing goose-check application: opt-in
  JSON/TOML numeric defaults, legacy CLI precedence/grammar, bounded reads,
  strict prelaunch failures and real compiler acceptance checks.

- Add an optional live-reloading job worker with bounded file reads, layered
  JSON/TOML/environment/CLI configuration, application validation and owned
  policy publication. Preserve active work behavior after rejected reloads.
- Check the worker under optimized GCC/Clang and both sanitizer compilers;
  cover file/key removal, exact byte limits, override precedence and failures.

- Audit deterministic grow/shrink/reload memory retention, identical-binary
  timing controls and coverage-checked fallback counters; retain all raw
  evidence in the [memory audit](docs/memory-and-fallback-audit.md). No runtime
  change is justified by this follow-up.
- Add isolated memory measurement and diagnostic reproduction tools with
  artifact/protocol/failure regressions and a native CI smoke.

- Stage only replacement bytes for one present scalar with unchanged combined
  source/text length; overwrite its checked span while preserving the existing
  general rebuild for every other case.
- Cover borrowed-input overlap, consumer copy overloads, empty and numeric
  values, retained lists and fallback transitions with ownership regressions.
- Add six update workloads, including full-size replacement and size/list/batch
  controls; keep the original sixteen-fixture harness unchanged.
- Retain four paired/repeat records and all observed regressions in the
  [scalar update audit](docs/scalar-update-performance.md).
- Define the supported 19-function API and patch-compatibility boundary;
  storage fields and helpers remain internal.
- Compact internal value metadata using the immutable schema kind and combine
  retained scalar source/text arena copies; preserve the supported API.
- Validate the ASCII key grammar in one bounded pass.
- Keep ordinary ASCII bytes on the validator's fast path and skip equal
  16-byte prefixes before the existing comparison remainder.
- Check key ordering against an independent bytewise reference in 132,612
  cases covering lengths, prefixes, binary bytes and every mismatch position.
- Retain all sixteen fixtures and both invocations in the
  [initialization follow-up](docs/initialization-performance.md), including
  higher large-text update medians and the limits on apply-performance claims.
- Add matched binding/list/multi-layer reload workloads.
- Retain all raw results, the observed CPU7 overlap and a separate handoff
  repeat in the [measurement audit](docs/v010-results.md). Loading timings are
  mixed; no general speedup is established.
- Keep the v0.1.0 tag pending the sustained coverage-guided campaign; existing
  model, malformed-input and sanitizer checks do not complete that gate.

Historical measurement records remain unchanged.
