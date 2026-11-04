# Existing application integration: goose-check

[goose-check](https://github.com/carabistouflette/goose-check) is an existing
Goose command-regression checker. It now uses goose-config for explicitly
selected JSON/TOML numeric defaults. Its real C/Goose compiler workflows exercise
the integration; it is separate from the optional worker example.

The implementation starts from goose-check
`3dae6984941ed2ba97817d34c17722a03de6d62f`, with feature commit
`95dbfc5224f05527b54ce8d135df773144abd4bf` and acceptance/readiness follow-ups
`8f6df568a0f362108a950ee2b0a508dbc2c5b572` and
`a49857d996dc9978f06808d083efef07764ba8a1`.
[This immutable consumer snapshot](https://github.com/carabistouflette/goose-check/tree/a49857d996dc9978f06808d083efef07764ba8a1)
bundles goose-config at `f7bef7dcfeab2ca95c94d92d0fbb2320ab3dcb05` with
per-file hashes, licenses and nested parser attribution. All six library runtime
files are unchanged. The integration adds no goose-config API or core dependency.

## Application contract

```toml
# checker.toml
timeout_ms = 60000
output_limit = 65536
expect_exit = 0
```

```sh
.build/goose-check --config "$PWD/checker.toml" -- /bin/true
```

Layer order is built-in defaults, the selected file, then supplied CLI flags,
independent of flag position. Numeric options retain the checker's digit-only
grammar and arbitrarily long leading zeroes within OS argument limits. The
checker validates those numbers first, then passes canonical decimal overrides
to goose-config so the library's numeric-token limit does not narrow that CLI.

Only `timeout_ms`, `output_limit` and `expect_exit` integer fields are accepted.
There is no automatic discovery or environment binding. Commands, arguments and
fixture paths remain explicit application inputs. A selected invalid lower layer
is rejected even if CLI flags would overwrite all its fields. Config reads are
bounded to 65,536 bytes using the checker's existing pinned goose-fs dependency.
Paths are trusted local inputs with strict absolute/no-symlink rules. Reads have
no deadline or concurrent-writer snapshot guarantee.

The private candidate Store supplies three typed scalar values. All must validate
before assignment to application settings; no borrowed view escapes and no
internal Store field/publication helper is used. Config validation finishes
before fixture reads, signal-guard setup or child launch. Fixed diagnostics omit
paths, values and parser detail. Parse/schema failures exit 2; read/size failures
exit 125. Configured output bounds also apply to expected-stdout fixture reads.

The checker is a single-command process. Each invocation rereads current source
bytes; removing keys exposes defaults, and removing the selected file fails.
There is no application watcher or live reload loop. See its complete
[configuration contract](https://github.com/carabistouflette/goose-check/blob/a49857d996dc9978f06808d083efef07764ba8a1/docs/CONFIGURATION.md).

## Verification and limits

The consumer's maintained GCC/Clang CI runs actual release/debug CLI checks,
both sanitizer compilers, ownership faults and a real C compiler example.
Configuration cases cover both formats, each numeric flag before/after the file
option, long nonzero leading-zero tokens, exact/oversized files, schema failures,
source/key removal, bounded fixtures, capture limits and actual timeout/reaping.
Marker commands verify invalid files never launch. Valid and invalid Goose
compiler invocations use file-supplied settings too. The fixture readiness marker
is published atomically, avoiding an empty-file observation race found in a
local rerun. Native caller, signal, process and filesystem contracts are retained.

Independent design, contract and security/standards reviews found no integration
blocker. No file is read or parsed without `--config`; linked parser code can
still affect binary size/layout/startup. No latency or throughput improvement is
claimed. These functional consumer checks do not complete the existing
[sustained-fuzz release gate](release.md); goose-config remains untagged.
