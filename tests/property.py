#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Deterministic public-API differential tests against an independent Python model.

The driver keeps one Store alive across every request. We compare acceptance and
all four values plus provenance after every successful or rejected transaction.
Python tomllib supplies the TOML oracle; raw numeric grammar is modeled directly.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import random
import re
import subprocess
import sys
import tomllib

SEED = 0xC0F16
INTEGER = re.compile(rb"[+-]?[0-9]+")
FLOAT = re.compile(rb"[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
KEYS = (b"i", b"f", b"b", b"s")


def raw_value(key: bytes, value: bytes):
    if len(value) > 4096:
        raise ValueError("value cap")
    if key == b"s":
        return value.hex()
    if key == b"b":
        if value not in (b"true", b"false"):
            raise ValueError("bool grammar")
        return value == b"true"
    if len(value) > 128:
        raise ValueError("numeric cap")
    if key == b"i":
        if INTEGER.fullmatch(value) is None:
            raise ValueError("integer grammar")
        result = int(value)
    else:
        if FLOAT.fullmatch(value) is None:
            raise ValueError("float grammar")
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("nonfinite")
    if not -1000 <= result <= 1000:
        raise ValueError("range")
    return result


def raw_layer(batch):
    if len(batch) > 256:
        raise ValueError("batch cap")
    updates = {}
    for key, value, source in batch:
        if key not in KEYS or key.decode() in updates or len(source) > 256:
            raise ValueError("key/source")
        updates[key.decode()] = (raw_value(key, value), source.hex())
    return updates


def toml_layer(document: bytes, source: bytes):
    if len(document) > 1048576 or len(source) > 256:
        raise ValueError("byte cap")
    decoded = tomllib.loads(document.decode("utf-8"))
    updates = {}
    for key, value in decoded.items():
        if key not in ("i", "f", "b", "s"):
            raise ValueError("unknown key/table")
        expected = {"i": int, "f": float, "b": bool, "s": str}[key]
        if type(value) is not expected:
            raise ValueError("strict TOML type")
        if key == "s":
            value = value.encode()
            if len(value) > 4096:
                raise ValueError("string cap")
            value = value.hex()
        elif key in ("i", "f"):
            if not math.isfinite(value) or not -1000 <= value <= 1000:
                raise ValueError("range")
        updates[key] = value, source.hex()
    return updates


def fixtures():
    rng = random.Random(SEED)
    cases = []

    def raw(batch):
        cases.append(("R", batch))

    def toml(document, source=b"config.toml"):
        if isinstance(document, str):
            document = document.encode()
        cases.append(("T", (document, source)))

    raw([])
    raw([(b"i", b"1", b"defaults"), (b"f", b"-0.0", b"defaults"),
         (b"b", b"false", b"defaults"), (b"s", b"", b"defaults")])
    for token in (b"0", b"-0", b"+00001", b"1000", b"-1000", b"1001", b"-1001",
                  b"", b"+", b"-", b"1.0", b" 1", b"1 ", b"1e0", b"0x10",
                  b"1_0", b"1\x00", b"9223372036854775808", b"-9223372036854775809",
                  b"0" * 127 + b"1", b"0" * 128 + b"1"):
        raw([(b"s", b"rollback sentinel", b"early"), (b"i", token, b"integer")])
    for token in (b"0", b"-0.0", b"-1e-9999", b"5e-324", b"+001.25e+2", b"1000.0",
                  b"1000.000000000001", b"1e309", b"-1e309", b"nan", b"NaN", b"inf",
                  b"1.", b".5", b"1e", b"1e+", b"1e-", b" 1.0", b"0x1p0", b"1\n",
                  b"0" * 127 + b"1", b"0" * 128 + b"1", b"0e" + b"9" * 100,
                  b"-0e-" + b"9" * 100):
        raw([(b"s", b"rollback sentinel", b"early"), (b"f", token, b"float")])
    for token in (b"true", b"false", b"True", b"FALSE", b"1", b"0", b"", b"true ", b"true\x00"):
        raw([(b"b", token, b"boolean")])
    for length in (0, 1, 255, 256, 257):
        raw([(b"s", b"source boundary", b"x" * length)])
    for length in (0, 1, 4095, 4096, 4097):
        raw([(b"s", b"x" * length, b"value boundary")])
    raw([(b"s", bytes(range(256)), bytes(range(256)))])
    raw([(b"i", b"1", b"first"), (b"i", b"2", b"duplicate")])
    raw([(b"i", b"1", b"first"), (b"unknown", b"2", b"late")])
    raw([(b"i", b"1", b"oversized")] * 257)

    toml("")
    toml('i = 7\nf = -0.0\nb = true\ns = "Unicode 😀\\n"\n')
    for doc in ('i = "42"', 'f = 42', 'b = "true"', 's = 42', 'i = 1.0',
                'i = 1001', 'f = nan', 'f = +inf', 'f = -inf', 'f = 1e9999',
                'f = -1e-9999', 'f = 5e-324', 'i = 0x2a', 'i = +0b1010',
                'i = 1_000', 'i = 1\ni = 2', 'i = 1\nmissing = 2',
                'i = 1\ns = [1]', 'i = 1\ns = 1979-05-27',
                'i = 1\n[unknown]', 'i = 1\n[s]', '"s.x" = "x"',
                's = """first\nsecond"""', 's = "\\u0000"',
                'i = ', 's = "unterminated', 'f = .5', 'f = 1.'):
        toml(doc)
    toml(b"s = '\xff'")
    toml('s = "' + "x" * 4097 + '"')
    toml('s = "' + "😀" * 1024 + '"')
    toml('s = "' + "😀" * 1025 + '"')
    toml('i = 3', b"x" * 256)
    toml('i = 3', b"x" * 257)

    invalids = (b"", b"garbage", b" 3", b"3 ", b"NaN", b"1_2", b"3\x00", b"1e9999")
    for _ in range(1400):
        batch = []
        for _ in range(rng.randrange(7)):
            key = rng.choice((*KEYS, b"i", b"s", b"unknown", b"I", b"a.b"))
            source = rng.randbytes(rng.choice((0, 1, 5, 20, 255, 256, 257)))
            if key == b"i":
                value = str(rng.randrange(-1010, 1011)).encode()
            elif key == b"f":
                value = repr(rng.uniform(-1005, 1005)).encode()
            elif key == b"b":
                value = rng.choice((b"true", b"false"))
            else:
                value = rng.randbytes(rng.randrange(50))
            if rng.randrange(5) == 0:
                value = rng.choice(invalids)
            batch.append((key, value, source))
        raw(batch)

    for _ in range(700):
        items = []
        for key in rng.sample(["i", "f", "b", "s"], rng.randrange(5)):
            if key == "i":
                value = str(rng.randrange(-1010, 1011))
            elif key == "f":
                value = repr(rng.uniform(-1005, 1005))
            elif key == "b":
                value = rng.choice(("true", "false"))
            else:
                value = json.dumps("".join(rng.choices("Goose 😀é\t\n\\\"", k=rng.randrange(30))), ensure_ascii=False)
            if rng.randrange(5) == 0:
                value = rng.choice(('"wrong"', '[]', '{}', 'nan', '1979-05-27', '.5', '1_000', 'false'))
            items.append(f"{key} = {value}")
        document = "\n".join(items)
        if rng.randrange(10) == 0:
            document += "\n[unknown]"
        if rng.randrange(20) == 0:
            document += "\ni = 3"
        toml(document, rng.randbytes(rng.choice((0, 3, 20, 256, 257))))
    return cases


def encode_and_model(cases):
    lines = []
    expected = []
    state = dict.fromkeys(("i", "f", "b", "s"))
    for mode, payload in cases:
        if mode == "R":
            fields = [item.hex() for entry in payload for item in entry]
        else:
            fields = [item.hex() for item in payload]
        lines.append("\t".join([mode, *fields]))
        try:
            changes = raw_layer(payload) if mode == "R" else toml_layer(*payload)
        except (ValueError, UnicodeError, OverflowError):
            ok = False
        else:
            ok = True
            state.update(changes)
        expected.append({"ok": ok, **state})
    return ("\n".join(lines) + "\n").encode(), expected


def compare(actual, expected):
    if set(actual) != set(expected) or actual["ok"] is not expected["ok"]:
        return False
    for key in ("i", "f", "b", "s"):
        value = actual[key]
        wanted = expected[key]
        if wanted is None:
            if value is not None:
                return False
            continue
        if not isinstance(value, list) or len(value) != 2 or value[1] != wanted[1]:
            return False
        if type(value[0]) is not type(wanted[0]) and key != "f":
            return False
        if value[0] != wanted[0]:
            return False
        if key == "f" and wanted[0] == 0.0:
            if math.copysign(1, value[0]) != math.copysign(1, wanted[0]):
                return False
    return True


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: property.py DRIVER [DRIVER ...]")
    cases = fixtures()
    requests, expected = encode_and_model(cases)
    for driver in sys.argv[1:]:
        command = [str(Path(driver).resolve())]
        result = subprocess.run(command, input=requests, capture_output=True, timeout=60)
        if result.returncode != 0 or result.stderr:
            raise SystemExit(f"{driver}: exit {result.returncode}\n{result.stderr.decode(errors='replace')}")
        outputs = result.stdout.splitlines()
        if len(outputs) != len(expected):
            raise SystemExit(f"{driver}: got {len(outputs)} responses for {len(expected)} requests")
        for index, (line, wanted) in enumerate(zip(outputs, expected)):
            try:
                actual = json.loads(line)
            except (ValueError, UnicodeError) as error:
                raise SystemExit(f"{driver}: invalid JSON at case {index}: {error}") from error
            if not compare(actual, wanted):
                raise SystemExit(f"{driver}: mismatch case {index}, seed={SEED:#x}\n"
                                 f"request: {cases[index]!r}\nexpected: {wanted!r}\nactual: {actual!r}")
        print(f"{driver}: {len(cases)} differential transactions passed; seed={SEED:#x}")


if __name__ == "__main__":
    main()
