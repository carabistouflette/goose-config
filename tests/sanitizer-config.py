#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify effective C options, including Goose debug's injected -O0.

Preprocessor markers check real compiler state rather than just our argument
list. Both optimized and explicitly unoptimized modes must retain ASan. A small
runtime control confirms UBSan reports signed overflow and terminates.
"""
import os
from pathlib import Path
import subprocess
import tempfile

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

UBSAN_SOURCE = """
#include <limits.h>
int main(int argc, char **argv) {
    volatile int maximum = INT_MAX;
    return maximum + argc;
}
"""


def check_ubsan(wrapper, environment, optimization):
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sanitizer-config-", dir=ROOT / ".build") as tmp:
        source = Path(tmp) / "overflow.c"
        executable = Path(tmp) / "overflow"
        source.write_text(UBSAN_SOURCE)
        build = subprocess.run([wrapper, "-O0", "-g", str(source), "-o", str(executable)],
                               text=True, capture_output=True, env=environment, timeout=60)
        if build.returncode != 0:
            raise SystemExit(f"UBSan control failed to compile ({optimization}):\n{build.stderr}")
        result = subprocess.run([str(executable)], text=True, capture_output=True,
                                env=environment, timeout=15)
        if (result.returncode == 0 or "runtime error:" not in result.stderr
                or "signed integer overflow" not in result.stderr):
            raise SystemExit(f"UBSan control did not report overflow ({optimization}):\n"
                             f"exit={result.returncode}\n{result.stderr}")


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
        check_ubsan(wrapper, environment, optimization)
    print("sanitizer compiler state: ASan/UBSan enabled; trailing -O2/-O0 honored")


if __name__ == "__main__":
    main()
