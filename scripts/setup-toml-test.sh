#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
revision=$(cat TOML_TEST_REVISION)
toolchain_dir="$PWD/.toolchain/toml-test"
if [[ ! -d "$toolchain_dir/.git" ]]; then
    git init "$toolchain_dir"
    git -C "$toolchain_dir" remote add origin https://github.com/toml-lang/toml-test.git
fi
if [[ $(git -C "$toolchain_dir" rev-parse HEAD 2>/dev/null || true) != "$revision" ]]; then
    git -C "$toolchain_dir" fetch --depth 1 origin "$revision"
    git -C "$toolchain_dir" checkout --detach "$revision"
fi
mkdir -p .build
(cd "$toolchain_dir" && go build -mod=readonly -o ../../.build/toml-test ./cmd/toml-test)
