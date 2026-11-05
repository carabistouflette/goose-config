#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run native environment binding checks with an isolated supplied environment."""
import os
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: bindings.py EXECUTABLE...")
    environment = os.environ.copy()
    environment.pop("GOOSE_CONFIG_TEST_UNSET", None)
    environment.update(
        GOOSE_CONFIG_TEST_NUMBER="-9",
        GOOSE_CONFIG_TEST_TEXT="",
        GOOSE_CONFIG_TEST_UPDATED="changed",
        GOOSE_CONFIG_TEST_INVALID="1.0",
        GOOSE_CONFIG_TEST_LARGE="x" * 4097,
        GOOSE_CONFIG_TEST_LIST="2:-3",
        GOOSE_CONFIG_TEST_DURATION="1.25s",
        GOOSE_CONFIG_TEST_DURATIONS="1s:250ms",
    )
    for executable in sys.argv[1:]:
        subprocess.run([executable, "--environment"], env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
