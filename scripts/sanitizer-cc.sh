#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
exec "${SANITIZER_CC:-gcc}" -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer "$@"
