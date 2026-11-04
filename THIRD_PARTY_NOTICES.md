# Third-party notices

## goose-toml

Copyright 2026 goose-toml contributors.

The optional parser in `vendor.goose` derives from goose-toml commit
`2179e47098a3b8553ad223676d603746cf1fe00c`, under the Apache License 2.0.
Its complete license is preserved in [vendor/LICENSE](vendor/LICENSE).
The source file carries a modification notice; [vendor/README.md](vendor/README.md)
lists the local changes. No upstream NOTICE file existed at that source revision.

The TOML conformance adapter, initial runner setup, and collision-generation
regressions also adapt Apache-2.0 development utilities from goose-toml.
The full-hash collision fixture derives from
[goose-toml commit cd5977cd2a7e4f4b3b918dded98a55c9159a24b6](https://github.com/carabistouflette/goose-toml/commit/cd5977cd2a7e4f4b3b918dded98a55c9159a24b6);
local checks remain active under Python optimization and verify every generated
key with the pinned Goose hash implementation.

## Development tools

The Goose compiler and official toml-test runner are fetched separately at
`GOOSE_REVISION` and `TOML_TEST_REVISION`. Their source trees and binaries are not
vendored or distributed in this repository. Their own upstream licenses apply.
The library has no runtime dependency on the Go test runner.
