# Vendored TOML parser

`../vendor.goose` is a snapshot of goose-toml commit
`2179e47098a3b8553ad223676d603746cf1fe00c`, extracted from the independently
maintained `libraries/goose-toml` repository in the goose-libs workspace.
That repository had no public remote at vendoring time. Apache-2.0; see LICENSE.
Local patches rename its namespace to `config_toml`, make resource limits
`const`, construct errors with byte appends rather than overloadable `str`,
copy arenas with appends rather than generic `copy`, size indexes with a direct
conditional rather than generic `max`, and specify decimal `parse_int` base 10.
Parser errors omit positions because the adapter deliberately returns only a
generic, source-aware parse failure. No other parsing behavior is changed.
Only the optional `config.toml` module imports this parser.

Updates must select one immutable source commit, preserve its license, review
the diff, update this provenance, and rerun the full config validation suite.
Do not copy uncommitted files from another checkout.
