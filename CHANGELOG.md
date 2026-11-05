# Changelog

No release has been tagged yet. The current `main` branch is experimental.

## Unreleased

- Add strict scalar and homogeneous-list settings with JSON and TOML layers.
- Add explicit environment and command-line bindings, direct key aliases, and
  replacement reload from caller-supplied layers.
- Add typed duration values and an optional generator for owned application
  settings and binding descriptors.
- Add runnable examples for basic settings, layered configuration, durations,
  and a live-reloading worker.
- Keep the documented input and work limits, ownership rules, and reported
  failure behavior in the [API reference](docs/api.md).

The [release page](docs/release.md) lists the remaining testing needed before a
first tag. Historical performance measurements and their currentness are
documented in the [performance status](docs/performance-status.md).
