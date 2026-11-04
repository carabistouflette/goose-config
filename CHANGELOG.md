# Changelog

## Unreleased — v0.1.0 preparation

- Define the supported 19-function API and patch-compatibility boundary;
  storage fields and helpers remain internal.
- Compact internal value metadata using the immutable schema kind and combine
  retained scalar source/text arena copies; preserve the supported API.
- Validate the ASCII key grammar in one bounded pass.
- Add matched binding/list/multi-layer reload workloads.
- Retain all raw results, the observed CPU7 overlap and a separate handoff
  repeat in the [measurement audit](docs/v010-results.md). Loading timings are
  mixed; no general speedup is established.
- Keep the v0.1.0 tag pending the sustained coverage-guided campaign; existing
  model, malformed-input and sanitizer checks do not complete that gate.

Historical measurement records remain unchanged.
