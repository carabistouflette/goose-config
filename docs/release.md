# Release status

goose-config has no published release tag. The current public branch is
experimental; pin an exact commit and review changes before upgrading.

Before the first release, the project still needs a sustained fuzzing run that
exercises JSON, TOML, lists, and reload with coverage guidance. Existing unit,
model, malformed-input, and sanitizer suites do not replace it. No `v0.1.0`
release tag is available.

The library provides strict typed values, bounded inputs, owned list results,
source labels, and atomic reported failures. These contracts are described in
the [API reference](api.md). Applications remain responsible for file I/O,
layer order, reload triggers, business rules, and synchronization.

Performance results are scoped to the exact source revisions and workloads
listed in the [performance status](performance-status.md). They are mixed and
do not establish a general speedup. See the [benchmark records](../bench/README.md).

The project is licensed under [Apache-2.0](../LICENSE); see the
[third-party notices](../THIRD_PARTY_NOTICES.md) for bundled dependencies.
