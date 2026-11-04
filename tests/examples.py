#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the runnable common-feature example with controlled process inputs."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    compiler = str(Path(sys.argv[1]).resolve(strict=True))
    root = Path(__file__).resolve().parents[1]
    base = os.environ.copy()
    base.pop("GOOSE_EXAMPLE_PORT", None)
    base.pop("GOOSE_EXAMPLE_TAGS", None)
    cases = [({}, [], "port=9000\ntag=from-file\n"),
             ({"GOOSE_EXAMPLE_PORT": "9200", "GOOSE_EXAMPLE_TAGS": "envA,envB"}, [],
              "port=9200\ntag=envA\ntag=envB\n"),
             ({"GOOSE_EXAMPLE_PORT": "9200"}, ["--port=9100", "--tag", "first", "--tag=second"],
              "port=9100\ntag=first\ntag=second\n")]
    for extra, arguments, expected in cases:
        result = subprocess.run([compiler, "run", "examples/layered.goose", "--", *arguments],
                                cwd=root, env=dict(base, **extra), capture_output=True,
                                text=True, timeout=60)
        if result.returncode != 0 or result.stdout != expected or result.stderr:
            raise RuntimeError(f"layered example failed: {result.returncode}, {result.stdout!r}, {result.stderr!r}")
    result = subprocess.run([compiler, "run", "examples/layered.goose"], cwd=root,
                            env=dict(base, GOOSE_EXAMPLE_PORT="SECRET-INVALID"),
                            capture_output=True, text=True, timeout=60)
    if result.returncode == 0 or result.stdout or "SECRET-INVALID" in result.stderr or "config:" not in result.stderr:
        raise RuntimeError("layered example did not safely reject invalid environment input")
    print("layered example: defaults/JSON/environment/CLI and rejection passed")


if __name__ == "__main__":
    main()
