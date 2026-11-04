#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
# Goose --debug emits -O0 even if its CLI also requests -O2. The final C
# optimization flag wins, so append it after all compiler-generated arguments.
optimization="${SANITIZER_OPT:--O2}"
case "$optimization" in
    -O0|-O1|-O2|-O3|-Og|-Os) ;;
    *) echo "SANITIZER_OPT must be one optimization flag (-O0..-O3, -Og, -Os)" >&2; exit 2 ;;
esac
exec "${SANITIZER_CC:-gcc}" -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer "$@" "$optimization"
