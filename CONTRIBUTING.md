# Contributing

Keep the core small, pure, bounded, and explicit. Optional adapters implement
registered environment/CLI bindings; applications own their mappings, file I/O,
reload triggers and synchronization.
Preserve atomic updates, source ownership, strict types, and safe diagnostics.

Use focused branches (`feat/...`, `fix/...`, `docs/...`) and Conventional Commits
with imperative subjects: `feat: add ...`, `fix: reject ...`, `test: cover ...`,
`perf: reduce ...`, `docs: clarify ...`, `chore: update ...`. Commit coherent,
working milestones regularly. Before v0.1.0, the API remains a candidate.
Tagged 0.1.x patches preserve [the supported surface](docs/api.md); breaking
changes require a new minor version. Security-driven limit changes must be
called out explicitly in release notes.

Add public API regressions for behavior changes. Run `make format`,
`make check test property security sanitize`, `make bench BENCH_ITERATIONS=100`, and
`git diff --check`. Also run `make release RELEASE_CC=gcc` and
`make release RELEASE_CC=clang` to verify optimized C builds, and
`SANITIZER_CC=clang make sanitize` for the second optimized sanitizer compiler.
Request independent correctness, security, and performance reviews at
milestones; fix actionable findings and keep CI passing. Never commit
credentials, generated compilers/build output, or private workspace notes.

Run `make conformance` for vendored-parser or TOML test-runner changes. Keep
`TOML_TEST_REVISION` pinned to a reviewed full commit; do not skip failing cases.

Primitive lists replace whole values. Preserve per-list text/item limits,
numeric precision, and owned list results. JSON/TOML schema types must remain
strict. Reload rebuilds current layers; reapplying an edited file is insufficient
because removed keys must not survive from an earlier snapshot. Keep standard
module names available: the JSON adapter is `json_layer.goose`, not `json.goose`.
The common-feature model and native environment checks run through the normal
test/release/sanitizer targets. Their Python checks also support `python3 -O`.

GOOSE_REVISION pins the exact compiler. Review compiler and vendored parser
updates and rerun full validation. Report vulnerabilities through the private route in [SECURITY.md](SECURITY.md).

Profile before optimizing. Keep validation and ownership guarantees. Benchmarks
must record compiler, flags, hardware, fixture sizes, and raw samples; report
all fixtures and regressions, with no universal rankings from microbenchmarks.
