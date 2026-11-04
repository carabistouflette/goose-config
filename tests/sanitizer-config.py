#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify effective C options, including Goose debug's injected -O0.

Preprocessor markers check real compiler state rather than just our argument
list. Both optimized and explicitly unoptimized modes must retain ASan.
"""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '''
#if defined(__SANITIZE_ADDRESS__)
ASAN_ENABLED
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
ASAN_ENABLED
#else
#error AddressSanitizer is not enabled
#endif
#else
#error AddressSanitizer is not enabled
#endif
#ifdef __OPTIMIZE__
OPT_ENABLED
#else
OPT_DISABLED
#endif
'''


def main():
    wrapper = str(ROOT / "scripts/sanitizer-cc.sh")
    for optimization, expected in (("-O2", "OPT_ENABLED"), ("-O0", "OPT_DISABLED")):
        environment = os.environ.copy()
        environment["SANITIZER_OPT"] = optimization
        result = subprocess.run([wrapper, "-O0", "-g", "-E", "-P", "-x", "c", "-"],
                                input=SOURCE, text=True, capture_output=True,
                                env=environment, timeout=30)
        markers = result.stdout.split()
        if result.returncode != 0 or markers != ["ASAN_ENABLED", expected]:
            raise SystemExit(f"sanitizer flags {optimization}: compiler state differs\n"
                             f"{result.stdout}{result.stderr}")
    print("sanitizer compiler state: ASan enabled; trailing -O2/-O0 honored")


if __name__ == "__main__":
    main()
