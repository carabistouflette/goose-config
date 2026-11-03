# Vendored TOML parser

`toml.goose` is an unmodified snapshot of goose-toml commit
`2179e47098a3b8553ad223676d603746cf1fe00c`, extracted from the independently
maintained `libraries/goose-toml` repository in the goose-libs workspace.
That repository had no public remote at vendoring time. Apache-2.0; see LICENSE.
Only the optional `config.toml` module imports this parser.

Updates must select one immutable source commit, preserve its license, review
the diff, update this provenance, and rerun the full config validation suite.
Do not copy uncommitted files from another checkout.
