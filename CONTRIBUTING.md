# Contributing

Keep the API small, pure, bounded, and explicit. Applications own file/process
I/O and the mapping of environment variables and CLI options to setting keys.
Preserve atomic updates, source ownership, strict types, and safe diagnostics.

Use focused branches (`feat/...`, `fix/...`, `docs/...`) and Conventional Commits
with imperative subjects: `feat: add ...`, `fix: reject ...`, `test: cover ...`,
`perf: reduce ...`, `docs: clarify ...`, `chore: update ...`. Commit coherent,
working milestones regularly. No stability guarantee exists before 1.0.

Add public API regressions for behavior changes. Run `make format`,
`make check test property security sanitize`, `make bench BENCH_ITERATIONS=100`, and
`git diff --check`. Request independent correctness, security, and performance
reviews at milestones; fix actionable findings and keep CI passing. Never commit
credentials, generated compilers/build output, or private workspace notes.

GOOSE_REVISION pins the exact compiler. Review compiler and vendored parser
updates and rerun full validation. Report vulnerabilities privately using
GitHub advisory reporting when available.

Profile before optimizing. Keep validation and ownership guarantees. Benchmarks
must record compiler, flags, hardware, fixture sizes, and raw samples; report
all fixtures and regressions, with no universal rankings from microbenchmarks.
