#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded hostile-input checks, including public rollback and real hash collisions.

Pass one or more builds of tests/security.goose. Each document gets a fresh
process and a five-second deadline. Checks remain active with Python -O.
The inverted hash workload must be revalidated when the compiler pin changes.
"""
import argparse
import json
import random
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HASH_REVISION = "eadca409f68210893f366e60d0c2f0dc29a339be"
MAX_INPUT_BYTES = 1048576
MAX_NODES = 65536
MAX_DEPTH = 64
MASK = (1 << 64) - 1
MULTIPLIER = 11400714819323198485
FINAL_MULTIPLIER = 15485907386658061715
SANITIZER_MARKERS = (
    b"AddressSanitizer", b"UndefinedBehaviorSanitizer", b"LeakSanitizer", b"runtime error:"
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def collision_keys(count):
    """Invert the pinned stdlib's eight-byte hash to collide at the root.

    Root hash_mix(0) is zero, hence key_hash == string_hash + MULTIPLIER.
    All generated keys have key_hash & 0x1ffff == 0, so they collide throughout
    the index sizes used by this test. JSON quoting escapes ASCII controls into
    legal TOML basic keys. This derives from goose-toml's security-test.py.
    """
    inverse_first = pow(MULTIPLIER, -1, 1 << 64)
    inverse_final = pow(FINAL_MULTIPLIER, -1, 1 << 64)
    keys = []
    for index in range(1 << 24):
        target = (index << 17) + ((-MULTIPLIER) & ((1 << 17) - 1))
        value = ((target ^ (target >> 32)) * inverse_final) & MASK
        value ^= value >> 32
        word = ((value * inverse_first) & MASK) ^ ((8 * MULTIPLIER) & MASK)
        raw = word.to_bytes(8, "little")
        if all(byte < 128 for byte in raw):
            keys.append(raw.decode("ascii"))
            if len(keys) == count:
                return keys
    raise RuntimeError("bounded collision search did not produce enough ASCII keys")


def config_oracle(source):
    """Independent oracle for short flat documents, within all parser budgets."""
    try:
        decoded = tomllib.loads(source.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False
    for key, value in decoded.items():
        if key == "s":
            if not isinstance(value, str) or len(value.encode("utf-8")) > 4096:
                return False
        elif key == "i":
            if type(value) is not int or not -(1 << 63) <= value < (1 << 63):
                return False
        else:
            return False
    return True


def documents():
    # mode, label, source, expected acceptance, optional parser diagnostic.
    cases = []

    def add(label, source, accepted, diagnostic=None, mode="config"):
        cases.append((mode, label, source, accepted, diagnostic))

    for source in [b"", b" # comment\n", b"i=0", b"s=''\ni=-9223372036854775808",
                   b"s='goose'\ni=9223372036854775807", b"i=0xff\ns=\"\\u0000\\U0001F600\"",
                   b"s=\"\"\"a\\\n  b\"\"\"\ni=+42"]:
        add("valid public control", source, True)
    for suffix in [b"i='wrong'", b"unknown=1", b"s='duplicate'", b"[unknown]", b"unknown={}",
                   b"i=[]", b"i=42.0", b"i=true", b"i=1979-05-27", b"i=9223372036854775808",
                   b"i=inf", b"i=nan", b"[s]", b"'a.b'=1"]:
        add("late rejection rolls back every value/source", b"s='SECRET-NEW-VALUE'\n" + suffix, False)
    add("maximum decoded string", b"s='" + b"a" * 4096 + b"'", True)
    add("oversized decoded string rolls back", b"i=7\ns='" + b"a" * 4097 + b"'", False)
    add("escaped string bound counts decoded bytes", b's="' + b"\\u0061" * 4096 + b'"', True)
    add("escaped string over decoded bound", b'i=7\ns="' + b"\\u0061" * 4097 + b'"', False)
    add("input exactly at limit", b" " * MAX_INPUT_BYTES, True)
    add("input over limit", b" " * (MAX_INPUT_BYTES + 1), False)
    add("parser input over limit", b" " * (MAX_INPUT_BYTES + 1), False, b"input exceeds 1 MiB", "parser")
    full_string = b"s='" + b"a" * (MAX_INPUT_BYTES - 4) + b"'"
    require(len(full_string) == MAX_INPUT_BYTES, "full-string fixture has wrong size")
    add("parser string at input cap", full_string, True, mode="parser")
    add("large decoded string rejected atomically", full_string, False)
    add("late malformed string rolls back", full_string[:-1] + b"x", False)
    add("late malformed trailing bytes roll back", full_string[:-2] + b"'x", False)
    add("late malformed parser string", full_string[:-1] + b"x", False, b"unterminated string", "parser")

    # Root, array, then one node per element: these hit the node cap exactly.
    dense = b"v=[" + b"1," * (MAX_NODES - 2) + b"]"
    add("array at node cap", dense, True, mode="parser")
    add("array over node cap", dense[:-1] + b"1,]", False, b"node limit exceeded", "parser")
    add("node cap preserves public state", b"s='changed'\ni=" + dense[2:-1] + b"1,]", False)
    inline_count = (MAX_NODES - 2) // 2
    add("dense inline tables at node cap", b"v=[" + b"{a=1}," * inline_count + b"]", True, mode="parser")
    # v is depth one; each nested inline table/array advances another level.
    at_depth = b"v=" + b"[" * (MAX_DEPTH - 1) + b"1" + b"]" * (MAX_DEPTH - 1)
    over_depth = b"v=" + b"[" * MAX_DEPTH + b"1" + b"]" * MAX_DEPTH
    add("array at depth cap", at_depth, True, mode="parser")
    add("array over depth cap", over_depth, False, b"nesting limit exceeded", "parser")
    add("depth cap preserves public state", b"s='changed'\ni=" + over_depth[2:], False)
    broad = b"v=" + b"{a=" * 62 + b"[" + b"1," * 64001 + b"]" + b"}" * 62
    add("deep inline sealing with broad subtree", broad, True, mode="parser")
    integer = b"0x" + b"0" * 126
    add("numeric token at 128 bytes", b"i=" + integer, True)
    add("numeric token over 128 bytes", b"s='changed'\ni=" + integer + b"0", False)
    add("parser numeric token over cap", b"i=" + integer + b"0", False, b"scalar token exceeds 128 bytes", "parser")
    add("float token at 128 bytes", b"v=1." + b"0" * 126, True, mode="parser")

    for bad in [b"\x80", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe2\x82", b"\xff"]:
        add("invalid UTF-8 preserves public state", b"s='changed'\ni=7\n#" + bad, False)
        add("invalid UTF-8 parser diagnostic", b"s='" + bad + b"'", False, b"invalid UTF-8", "parser")
    for source in [b"s='\x00'", b"s='\x7f'", b"#\x1b", b's="\\uD800"', b's="\\U00110000"',
                   b"i=1\r", b"s='unterminated", b"i=1_", b"i=0x_1"]:
        add("malformed scalar/control document", source, False)

    keys = collision_keys(5000)
    require(len(set(keys)) == len(keys), "collision fixture keys are not unique")
    lines = [(json.dumps(key) + "=1\n").encode("ascii") for key in keys]
    add("small genuine collision control", b"".join(lines[:200]), True, mode="parser")
    attack = b"".join(lines)
    require(len(attack) < MAX_INPUT_BYTES and len(keys) + 1 < MAX_NODES,
            "collision fixture exceeds an unrelated resource budget")
    add("real collision index budget (revalidate pinned hash on failure)", attack, False,
        b"work limit exceeded", "parser")
    add("real collision budget preserves public state", b"s='changed'\n" + attack, False)

    rng = random.Random(0x5EC017)
    seeds = [b"s='hello'\ni=42", b"s=\"\\u0061\"", b"i=0xff", b"s=''", b"# comment\n"]
    for index in range(256):
        if index % 4 == 0:
            source = bytes(rng.randrange(256) for _ in range(rng.randrange(1024)))
        elif index % 4 == 1:
            source = rng.choice(seeds)
            for _ in range(rng.randrange(1, 5)):
                offset = rng.randrange(len(source) + 1)
                source = source[:offset] + bytes([rng.randrange(256)]) + source[offset:]
        elif index % 4 == 2:
            source = ("s=" + json.dumps("".join(chr(rng.randrange(32, 127)) for _ in range(rng.randrange(80))))
                      + "\ni=" + str(rng.randrange(-(1 << 63), 1 << 63))).encode("ascii")
        else:
            seed = rng.choice(seeds)
            source = seed[:rng.randrange(len(seed) + 1)]
        add(f"deterministic byte probe {index}", source, config_oracle(source))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("drivers", nargs="+", type=Path)
    args = parser.parse_args()
    revision = (ROOT / "GOOSE_REVISION").read_text().strip()
    if revision != HASH_REVISION:
        parser.error("collision generator must be revalidated against the changed GOOSE_REVISION")
    cases = documents()
    for driver in args.drivers:
        binary = str(driver.resolve())
        for mode, label, source, accepted, diagnostic in cases:
            command = [binary] + (["parser"] if mode == "parser" else [])
            try:
                result = subprocess.run(command, input=source, capture_output=True, timeout=5)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"{driver.name}: {label}: five-second deadline exceeded") from error
            context = f"{driver.name}: {label}: {result.stderr[:1000]!r}"
            require(not any(marker in result.stderr for marker in SANITIZER_MARKERS),
                    f"runtime/sanitizer diagnostic: {context}")
            require(result.returncode in (0, 1), f"abnormal exit {result.returncode}: {context}")
            require(result.returncode == (0 if accepted else 1), f"unexpected acceptance/rejection: {context}")
            require(not result.stdout, f"unexpected stdout: {context}")
            if accepted:
                require(not result.stderr, f"unexpected success diagnostic: {context}")
            else:
                require(bool(result.stderr), f"missing failure diagnostic: {context}")
                if mode == "config":
                    require(b"SECRET-NEW-VALUE" not in result.stderr, f"value exposed in diagnostic: {context}")
            if diagnostic is not None:
                require(diagnostic in result.stderr, f"expected diagnostic {diagnostic!r} absent: {context}")
        print(f"{driver.name}: {len(cases)} hostile-input/resource documents passed, including real collision budget rejection")


if __name__ == "__main__":
    main()
