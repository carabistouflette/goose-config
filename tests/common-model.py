#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent json/tomllib oracle for persistent typed-list layers and reloads.

Usage: common-model.py DRIVER [DRIVER ...]. Every transaction compares acceptance,
every field, and every source, including rejected updates and deleted reload keys.
J/T apply document/source pairs. R/V replay format/document/source triples into a
fresh optional/required-i schema; lower document layers supply caller defaults.
The random TOML corpus uses short numeric tokens; JSON token limits are checked
independently by json's parse_int/parse_float callbacks.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import random
import subprocess
import sys
import time
import tomllib

SEED = 0xC011157
KEYS = ("i", "s", "is", "ss", "fs", "bs")
TYPES = {"i": int, "s": str, "is": int, "ss": str, "fs": float, "bs": bool}
MAX_DOCUMENT = 1048576


def check(condition, message):
    # These checks deliberately remain active under python -O.
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        check(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def json_integer(token):
    check(len(token) <= 128, "JSON integer token cap")
    value = int(token)
    check(-(1 << 63) <= value < (1 << 63), "JSON i64 overflow")
    return value


def json_float(token):
    check(len(token) <= 128, "JSON float token cap")
    value = float(token)
    check(math.isfinite(value), "JSON nonfinite float")
    return value


def reject_constant(token):
    raise ValueError(f"non-JSON constant: {token}")


def primitive(key, value):
    check(type(value) is TYPES[key], "strict scalar/element type")
    if type(value) is str:
        encoded = value.encode("utf-8")  # Reject unpaired JSON surrogates.
        check(len(encoded) <= 4096, "string byte cap")
        return encoded.hex()
    if type(value) is float:
        check(math.isfinite(value), "finite float")
    if key in ("i", "is"):
        check(-1000 <= value <= 1000, "integer range")
    return value


def document_layer(mode, document, source):
    check(len(document) <= MAX_DOCUMENT and len(source) <= 256, "document/source cap")
    text = document.decode("utf-8")
    if mode == "J":
        decoded = json.loads(text, object_pairs_hook=unique_object,
                             parse_int=json_integer, parse_float=json_float,
                             parse_constant=reject_constant)
    else:
        check(mode == "T", "protocol format")
        decoded = tomllib.loads(text)
    check(type(decoded) is dict, "object root")
    result = {}
    for key, value in decoded.items():
        check(key in KEYS, "unknown key/table")
        if key in ("i", "s"):
            normalized = primitive(key, value)
        else:
            check(type(value) is list and len(value) <= 256, "list kind/item cap")
            normalized = [primitive(key, item) for item in value]
            if key == "ss":
                check(sum(len(item) // 2 for item in normalized) <= 4096, "list byte cap")
        result[key] = [normalized, source.hex()]
    return result


def json_document(values):
    return json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()


def toml_document(values):
    # json's string/list spelling is valid TOML for this selected character set.
    return "\n".join(f"{key} = {json.dumps(value, ensure_ascii=False)}"
                     for key, value in values.items()).encode()


def fixtures():
    rng = random.Random(SEED)
    cases = []

    def apply(mode, document, source=b"file"):
        if isinstance(document, str):
            document = document.encode()
        cases.append((mode, [(mode, document, source)]))

    def reload(layers=(), required=False):
        cases.append(("V" if required else "R", list(layers)))

    initial = {"i": 4, "s": "seed 😀", "is": [-1000, 0, 1000],
               "ss": ["one", "é", ""], "fs": [-0.0, 1.5, -5e-324], "bs": [True, False]}
    defaults = ("J", json_document(initial), b"defaults")
    reload()
    apply("J", json_document(initial), b"initial.json")
    apply("T", toml_document(initial), b"initial.toml")
    for mode in ("J", "T"):
        encoder = json_document if mode == "J" else toml_document
        for key in KEYS:
            for value in (None, True, False, 1, 1.0, "wrong", [], {},
                          [True], [1], [1.0], ["x"], [None], [[]], [{}], [1, True]):
                # Ensure every failed late field must roll back a valid earlier scalar.
                apply(mode, encoder({"s": "rollback sentinel", key: value}), b"wrong-type")
        for key in ("is", "ss", "fs", "bs"):
            for count in (0, 1, 255, 256, 257):
                value = {"is": 3, "ss": "", "fs": -0.0, "bs": False}[key]
                apply(mode, encoder({key: [value] * count}), b"item-boundary")
        for count in (4095, 4096, 4097):
            apply(mode, encoder({"s": "x" * count}), b"scalar-bytes")
            apply(mode, encoder({"ss": ["x" * count]}), b"list-bytes")
        for values in ({"ss": ["x" * 4096, "y"]}, {"ss": ["é" * 2048]},
                       {"ss": ["😀" * 1024]}, {"ss": ["😀" * 1024, "x"]},
                       {"s": "a" * 4096, "ss": ["b" * 4096]},
                       {"i": -1001}, {"i": 1001}, {"is": [0, -1001]},
                       {"is": [1001]}, {"fs": [float("inf")]}, {"fs": [float("nan")]}):
            apply(mode, encoder(values), b"caps-and-ranges")
        for count in (0, 1, 255, 256, 257):
            apply(mode, encoder({"i": 9, "bs": []}), b"s" * count)
        apply(mode, b"{}" if mode == "J" else b"", b"empty")
        empty = b"{}" if mode == "J" else b""
        apply(mode, empty + b" " * (MAX_DOCUMENT - len(empty)), b"document-cap")
        apply(mode, empty + b" " * (MAX_DOCUMENT + 1 - len(empty)), b"document-cap")

    for token in ("1", "1.0", "1e0", "true", "-0", "-0.0", "-1e-9999", "5e-324",
                  "1e309", "NaN", "Infinity", "01", "+1", ".1", "1.", "1e+", "--1",
                  "1000", "-1000", "1001", "9223372036854775808",
                  "-9223372036854775809", "1." + "0" * 126, "1." + "0" * 127):
        for key in ("i", "is", "fs"):
            value = token if key == "i" else "[" + token + "]"
            apply("J", '{"s":"rollback number","' + key + '":' + value + '}', b"numeric")
    for document in ('[]', 'null', '42', '{}x', '{', '{"i":1,}',
                     '{"s":"first","s":"last"}', '{"s":"first","\\u0073":"last"}',
                     '{"i":1,"unknown":{}}', '{"i":1,"s":{"nested":2}}',
                     '{"ss":["\\uD800"]}', '{"s":"\\uDC00"}', '{"s":"\\x41"}',
                     '{"s":"literal\nnewline"}', '{"s":"\\u0000"}',
                     '{"s":"\\ud83d\\ude00","ss":["\\u00e9"]}',
                     '{"ss":[' * 65 + '0' + ']}' * 65):
        apply("J", document, b"syntax")
    apply("J", b'{"s":"\xff"}', b"invalid utf8")
    for document in ('i=0x10\nis=[0b10,0o10,1_000]', 'i=1\ni=2', 's="x"\n[unknown]',
                     's="x"\nis=[1,2.0]', 's="x"\nfs=[1]', 'fs=[nan]', 'fs=[+inf]',
                     'fs=[1e9999]', 'fs=[-1e-9999,5e-324]', 's=1979-05-27',
                     'is=[[1]]', 'ss=["x",false]', 's="unterminated', 'i='):
        apply("T", document, b"toml-syntax")

    # Explicit source removal, key deletion, empty-list presence, and rollback.
    reload([defaults, ("T", b'i=20\nss=["upper"]\nbs=[]', b"upper.toml")])
    reload([defaults, ("T", b's="edited"', b"upper.toml")])
    reload([("J", b'{"ss":[]}', b"only-current")])
    reload()
    reload([defaults, ("J", b'{"s":"must rollback","is":[1001]}', b"bad")])
    reload([defaults], required=True)
    reload([("T", b's="missing required i"', b"incomplete")], required=True)
    reload(required=True)
    reload([("J", b'{"i":3}', b"required-present")], required=True)
    for count in (31, 32, 33):
        reload([("J", b'{}', b"empty")] * count)
    reload([defaults])

    def random_values():
        values = {}
        for key in rng.sample(KEYS, rng.randrange(len(KEYS) + 1)):
            if key == "i":
                value = rng.randint(-1005, 1005)
            elif key == "s":
                value = "".join(rng.choices("Goose 😀é\t\n\\\"", k=rng.randrange(24)))
            else:
                value = []
                for _ in range(rng.randrange(12)):
                    value.append({"is": lambda: rng.randint(-1005, 1005),
                                  "ss": lambda: "".join(rng.choices("goose é😀", k=rng.randrange(12))),
                                  "fs": lambda: rng.choice((-0.0, -5e-324, rng.uniform(-1e5, 1e5))),
                                  "bs": lambda: bool(rng.randrange(2))}[key]())
            if rng.randrange(6) == 0:
                value = rng.choice((None, True, 1, 1.0, "wrong", {}, [None], [True], [1], [1.0]))
            values[key] = value
        if rng.randrange(13) == 0:
            values["unknown"] = "rejected late key"
        return values

    def random_layer():
        mode = rng.choice(("J", "T"))
        values = random_values()
        encoder = json_document if mode == "J" else toml_document
        source = rng.randbytes(rng.choice((0, 3, 12, 256, 257)))
        document = encoder(values)
        if rng.randrange(17) == 0:
            document += b"!"
        return mode, document, source

    for _ in range(800):
        mode, document, source = random_layer()
        apply(mode, document, source)
    for _ in range(500):
        layers = [defaults] if rng.randrange(2) else []
        layers.extend(random_layer() for _ in range(rng.randrange(5)))
        reload(layers, required=rng.randrange(4) == 0)
    return cases


def encode_and_model(cases):
    state = dict.fromkeys(KEYS)
    lines, expected = [], []
    for mode, layers in cases:
        if mode in ("J", "T"):
            fields = [layers[0][1].hex(), layers[0][2].hex()]
        else:
            fields = [part.hex() for fmt, doc, source in layers for part in (fmt.encode(), doc, source)]
        lines.append("\t".join([mode, *fields]))
        try:
            check(mode in ("J", "T") or len(layers) <= 32, "reload layer cap")
            next_state = state.copy() if mode in ("J", "T") else dict.fromkeys(KEYS)
            for fmt, doc, source in layers:
                next_state.update(document_layer(fmt, doc, source))
            check(mode != "V" or next_state["i"] is not None, "reload required field")
        except (ValueError, UnicodeError, OverflowError, RecursionError):
            ok = False
        else:
            ok, state = True, next_state
        expected.append({"ok": ok, **state})
    return ("\n".join(lines) + "\n").encode(), expected


def equal_value(actual, expected, floating=False):
    if floating:
        return (type(actual) in (int, float) and math.isfinite(actual) and actual == expected
                and (expected != 0.0 or math.copysign(1, actual) == math.copysign(1, expected)))
    return type(actual) is type(expected) and actual == expected


def compare(actual, expected):
    if type(actual) is not dict or set(actual) != set(expected) or actual["ok"] is not expected["ok"]:
        return False
    for key in KEYS:
        got, wanted = actual[key], expected[key]
        if wanted is None:
            if got is not None:
                return False
            continue
        if type(got) is not list or len(got) != 2 or type(got[1]) is not str or got[1] != wanted[1]:
            return False
        if key in ("i", "s"):
            if not equal_value(got[0], wanted[0]):
                return False
        else:
            if type(got[0]) is not list or len(got[0]) != len(wanted[0]):
                return False
            if not all(equal_value(a, b, key == "fs") for a, b in zip(got[0], wanted[0])):
                return False
    return True


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: common-model.py DRIVER [DRIVER ...]")
    deadline = time.monotonic() + 180
    cases = fixtures()
    requests, expected = encode_and_model(cases)
    accepted = sum(item["ok"] for item in expected)
    check(accepted > 300 and len(cases) - accepted > 300, "corpus acceptance/rejection coverage")
    for driver in sys.argv[1:]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit("common-model: whole-run deadline exceeded")
        try:
            result = subprocess.run([str(Path(driver).resolve())], input=requests,
                                    capture_output=True, timeout=min(60, remaining))
        except subprocess.TimeoutExpired as error:
            diagnostics = (error.stderr or b"").decode(errors="replace")
            raise SystemExit(f"{driver}: driver deadline exceeded\n{diagnostics}") from error
        if result.returncode != 0 or result.stderr:
            raise SystemExit(f"{driver}: exit {result.returncode}\n{result.stderr.decode(errors='replace')}")
        outputs = result.stdout.splitlines()
        check(len(outputs) == len(expected), f"{driver}: {len(outputs)} responses for {len(expected)} requests")
        for index, (line, wanted) in enumerate(zip(outputs, expected)):
            try:
                actual = json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant)
            except (ValueError, UnicodeError) as error:
                raise SystemExit(f"{driver}: invalid response at case {index}: {error}") from error
            if not compare(actual, wanted):
                raise SystemExit(f"{driver}: mismatch case {index}; seed={SEED:#x}\n"
                                 f"request: {repr(cases[index])[:1600]}\n"
                                 f"expected: {repr(wanted)[:2400]}\nactual: {repr(actual)[:2400]}")
        print(f"{driver}: {len(cases)} differential transactions passed "
              f"({accepted} accepted, {len(cases) - accepted} rejected); seed={SEED:#x}")


if __name__ == "__main__":
    main()
