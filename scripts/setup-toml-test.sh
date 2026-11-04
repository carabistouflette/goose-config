#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
revision=$(cat TOML_TEST_REVISION)
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "TOML_TEST_REVISION must contain one full lowercase Git commit SHA" >&2
    exit 2
fi
toolchain_dir="$PWD/.toolchain/toml-test"
if [[ ! -d "$toolchain_dir/.git" ]]; then
    git init "$toolchain_dir"
    git -C "$toolchain_dir" remote add origin https://github.com/toml-lang/toml-test.git
fi
# Read commit objects, not the cache's editable checkout. Never reset or clean
# owner files, and do not change HEAD merely to build a different pinned commit.
if ! git -C "$toolchain_dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$toolchain_dir" fetch --depth 1 origin "$revision"
fi
mkdir -p .build
snapshot=$(mktemp -d "$PWD/.build/toml-test-src.XXXXXXXX")
trap 'rm -rf -- "$snapshot"' EXIT
git -C "$toolchain_dir" archive "$revision" | tar -x -C "$snapshot"
# Avoid ambient workspaces and parent-repository VCS stamps. zli documents this
# version override; it identifies the exact immutable source we exported.
(cd "$snapshot" && GOWORK=off go build -mod=readonly -buildvcs=false \
    -ldflags "-X zgo.at/zli.version=$revision" -o "$snapshot/toml-test" ./cmd/toml-test)
if (( $# > 0 )); then
    # Conformance uses this private binary; a concurrent setup cannot replace it.
    "$snapshot/toml-test" "$@"
else
    mv -f "$snapshot/toml-test" "$PWD/.build/toml-test"
fi
