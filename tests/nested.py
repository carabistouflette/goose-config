#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Differential nested-schema transactions against an independent Python model.

One Store survives 45 schema cycles spanning empty, linear, and indexed lookup.
Every accepted/rejected transaction checks required validation, every active
value and source, and unknown/wrong getters. Python tomllib supplies the TOML
oracle; schemas and textual layers are validated directly from the API contract.
"""
from __future__ import annotations

import itertools
import json
import math
from pathlib import Path
import random
import re
import subprocess
import sys
import tomllib

SEED = 0x3C0F16
COMPONENT = re.compile(r"[A-Za-z0-9_-]+")
INTEGER = re.compile(rb"[+-]?[0-9]+")
FLOAT = re.compile(rb"[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
SIZES = (0, 1, 4, 8, 9, 17, 33, 70, 128, 256)
COMPONENTS = ("a", "a-", "a0", "a_b", "aa", "abcdefgh", "abcdefgh-",
              "abcdefgh0", "z", "X")


def valid_key(key):
    return (len(key.encode()) <= 256
            and all(COMPONENT.fullmatch(part) for part in key.split(".")))


def valid_schema(fields):
    keys = [field[0] for field in fields]
    return (len(fields) <= 256
            and all(valid_key(key) for key in keys)
            and len(keys) == len(set(keys))
            and not any(child.startswith(parent + ".")
                        for parent in keys for child in keys if parent != child))


def raw_value(kind, token):
    if len(token) > 4096:
        raise ValueError("value cap")
    if kind == "s":
        return token.hex()
    if kind == "b":
        if token not in (b"true", b"false"):
            raise ValueError("boolean grammar")
        return token == b"true"
    grammar = INTEGER if kind == "i" else FLOAT
    if len(token) > 128 or grammar.fullmatch(token) is None:
        raise ValueError("numeric grammar/cap")
    value = int(token) if kind == "i" else float(token)
    if not math.isfinite(value) or not -1000 <= value <= 1000:
        raise ValueError("finite/range")
    return value


class Model:
    """Transaction oracle with staged changes and declaration-ordered schemas."""

    def __init__(self, rng):
        self.rng = rng
        self.requests = []
        self.expected = []
        self.descriptions = []
        self.schema = {}
        self.state = {}
        self.initialized = False
        self.transactions = 0

    def emit(self, mode, arguments, wanted, description):
        encoded = [item.hex() if isinstance(item, bytes)
                   else str(item).encode().hex() for item in arguments]
        self.requests.append("\t".join([mode, *encoded]))
        self.expected.append(wanted)
        self.descriptions.append(description)

    def snapshot(self, description):
        complete = self.initialized and all(
            not required or self.state[key] is not None
            for key, (_, required) in self.schema.items())
        self.emit("V", [], complete, description)
        for key, (kind, _) in self.schema.items():
            self.emit("Q", [key, kind], self.state[key], description)
        self.emit("Q", ["unknown.deep", "s"], None, description)
        if self.schema:
            key = self.rng.choice(list(self.schema))
            kind = self.schema[key][0]
            self.emit("Q", [key, "i" if kind != "i" else "s"], None, description)

    def init(self, fields, description):
        ok = valid_schema(fields)
        if ok:
            self.schema = {key: (kind, required) for key, kind, required in fields}
            self.state = dict.fromkeys(self.schema)
            self.initialized = True
        arguments = [item for key, kind, required in fields
                     for item in (key, kind, int(required))]
        self.emit("S", arguments, ok, description)
        self.transactions += 1
        self.snapshot(description)

    def raw(self, batch, description):
        updates = {}
        ok = self.initialized and len(batch) <= 256
        try:
            for key, token, source in batch:
                if key not in self.schema or key in updates or len(source) > 256:
                    raise ValueError("key/source")
                value = raw_value(self.schema[key][0], token)
                updates[key] = [value, source.hex()]
        except (ValueError, OverflowError):
            ok = False
        if ok:
            self.state.update(updates)
        self.emit("R", [item for entry in batch for item in entry], ok, description)
        self.transactions += 1
        self.snapshot(description)

    def toml(self, document, source, description):
        updates = {}
        ok = self.initialized and len(source) <= 256 and len(document.encode()) <= 1048576

        def walk(table, parent=""):
            for component, value in table.items():
                if COMPONENT.fullmatch(component) is None:
                    raise ValueError("component grammar")
                key = parent + "." + component if parent else component
                if len(key.encode()) > 256:
                    raise ValueError("path cap")
                if isinstance(value, dict):
                    if not any(field.startswith(key + ".") for field in self.schema):
                        raise ValueError("unknown table")
                    walk(value, key)
                    continue
                if key not in self.schema:
                    raise ValueError("unknown scalar")
                kind = self.schema[key][0]
                if type(value) is not {"s": str, "i": int, "f": float, "b": bool}[kind]:
                    raise ValueError("strict TOML type")
                if kind == "s":
                    if len(value.encode()) > 4096:
                        raise ValueError("string cap")
                    value = value.encode().hex()
                elif kind in ("i", "f"):
                    if not math.isfinite(value) or not -1000 <= value <= 1000:
                        raise ValueError("finite/range")
                updates[key] = [value, source.hex()]

        try:
            walk(tomllib.loads(document))
        except (ValueError, UnicodeError, OverflowError):
            ok = False
        if ok:
            self.state.update(updates)
        self.emit("T", [document, source], ok, description)
        self.transactions += 1
        self.snapshot(description)


def random_value(rng, kind):
    if kind == "s":
        return rng.choice(("", "abc", "😀", "x\ny", 'quoted " \\'))
    if kind == "b":
        return rng.choice((True, False))
    if kind == "i":
        return rng.randint(-1000, 1000)
    return rng.choice((0.0, -0.0, 1.25, rng.randint(-900, 900) * 0.5))


def literal(value):
    return json.dumps(value, ensure_ascii=False)


def raw_batch(rng, items):
    return [(key, (value if type(value) is str else literal(value)).encode(),
             rng.randbytes(rng.choice((0, 1, 10, 256)))) for key, value in items]


def tree(items):
    root = {}
    for key, value in items:
        branch = root
        parts = key.split(".")
        for part in parts[:-1]:
            branch = branch.setdefault(part, {})
        branch[parts[-1]] = value
    return root


def inline(table):
    return "{" + ", ".join(
        key + " = " + (inline(value) if isinstance(value, dict) else literal(value))
        for key, value in table.items()) + "}"


def table_document(items):
    grouped = {}
    for key, value in items:
        parent, _, leaf = key.rpartition(".")
        grouped.setdefault(parent, []).append((leaf, value))
    document = ""
    # Root assignments precede headers so their meaning is independent of scope.
    for parent, entries in sorted(grouped.items(), key=lambda item: bool(item[0])):
        if parent:
            document += "[" + parent + "]\n"
        document += "\n".join(key + " = " + literal(value)
                              for key, value in entries) + "\n"
    return document


def fixtures():
    rng = random.Random(SEED)
    model = Model(rng)
    model.raw([], "uninitialized raw")
    model.toml("", b"", "uninitialized TOML")
    for cycle in range(45):
        count = SIZES[cycle % len(SIZES)]
        keys = []
        while len(keys) < count:
            parts = [rng.choice(COMPONENTS) for _ in range(rng.randrange(1, 6))]
            parts[-1] += "_" + str(rng.randrange(1000))
            key = ".".join(parts)
            if key not in keys and not any(
                    key.startswith(old + ".") or old.startswith(key + ".")
                    for old in keys):
                keys.append(key)
        rng.shuffle(keys)
        fields = [(key, rng.choice("ifsb"), rng.randrange(5) == 0) for key in keys]
        kinds = {key: kind for key, kind, _ in fields}
        model.init(fields, f"cycle {cycle}: initialize {count} fields")
        items = [(key, random_value(rng, kinds[key])) for key in keys]
        full = raw_batch(rng, items)
        rng.shuffle(full)
        model.raw(full, f"cycle {cycle}: full shuffled raw batch")
        items = [(key, random_value(rng, kinds[key])) for key in keys]
        rng.shuffle(items)
        model.toml("\n".join(key + " = " + literal(value) for key, value in items),
                   b"full TOML", f"cycle {cycle}: full shuffled TOML batch")
        for step in range(40):
            description = f"cycle {cycle}, step {step}"
            if step in (9, 19, 29):
                # Invalid reinitialization must preserve the old schema and values.
                invalid = list(fields)
                if invalid:
                    target = rng.choice(keys)
                    conflict = (target.rsplit(".", 1)[0] if "." in target
                                else target + ".child")
                    invalid.append((conflict, "s", False))
                else:
                    invalid = [("a..b", "i", False)]
                rng.shuffle(invalid)
                model.init(invalid, description + ": conflicting schema")
                continue
            subset = rng.sample(keys, rng.randrange(min(count, 17) + 1))
            items = [(key, random_value(rng, kinds[key])) for key in subset]
            if step % 2:
                batch = raw_batch(rng, items)
                if step % 7 == 0:
                    batch.append(("unknown.deep", b"1", b"rejected"))
                if step % 11 == 0 and batch:
                    batch.append(batch[0])
                if step % 13 == 0 and batch:
                    key, token, _ = batch[-1]
                    batch[-1] = (key, b"1001" if kinds[key] in "if" else token,
                                 b"x" * 257)
                rng.shuffle(batch)
                model.raw(batch, description + ": sparse/rejected raw batch")
                continue
            if step % 6 == 0:
                document = "\n".join(
                    key + " = " + (inline(value) if isinstance(value, dict)
                                   else literal(value))
                    for key, value in tree(items).items())
            elif step % 6 == 2:
                document = table_document(items)
            else:
                document = "\n".join(key + " = " + literal(value)
                                     for key, value in items)
            if step % 8 == 0:
                document += "\n[unknown.deep]"
            if step % 10 == 0 and items:
                document += "\n" + items[0][0] + " = 2"
            if step % 14 == 0:
                parents = [key.rsplit(".", 1)[0] for key in keys if "." in key]
                if parents:
                    # A proper table prefix is known; its lexical neighbor is not.
                    document = "[" + rng.choice(parents) + ("0" if step % 28 == 0 else "") + "]"
            source = b"toml" + rng.randbytes(rng.choice((0, 10, 250)))
            model.toml(document, source, description + ": TOML " + repr(document))

    # Prefix conflicts must be found even when a lexical neighbor sorts between them.
    for distractor in ("a-", "a0", "aa", "a_", "abcdefgh-", "abcdefgh0"):
        root = "abcdefgh" if distractor.startswith("abcdefgh") else "a"
        fields = [(root, "s", False), (distractor, "i", False), (root + ".x", "s", False)]
        for order in itertools.permutations(fields):
            model.init(list(order), "exact prefix conflict permutation " + repr(order))

    # Valid lexical neighbors independently exercise table-prefix boundaries.
    neighbors = (("a", ("a-", "a0", "a_", "aa")),
                 ("abcdefgh", ("abcdefgh-", "abcdefgh0", "abcdefgh_")))
    for root, distractors in neighbors:
        fields = [(root, "s", True)] + [(key + ".x", "i", False) for key in distractors]
        for _ in range(8):
            rng.shuffle(fields)
            model.init(fields, "valid lexical-neighbor schema")
            model.raw([(root, b"root", b"original")]
                      + [(key + ".x", b"17", key.encode()) for key in distractors],
                      "seed lexical-neighbor values")
            for key in distractors:
                model.toml("[" + key + "]", b"empty", "known empty neighbor table")
            model.toml("[" + root + "]", b"unknown", "scalar is not a table")
            model.toml("[" + root + ".x]", b"unknown", "scalar descendant is unknown")
            model.toml("[" + root + "00]", b"unknown", "adjacent unknown table")
    return model


def compare(actual, wanted):
    if wanted is None:
        return actual is None
    if type(wanted) is bool:
        return type(actual) is bool and actual is wanted
    if type(actual) is not list or len(actual) != 2:
        return False
    value, source = actual
    expected_value, expected_source = wanted
    if type(source) is not str or source != expected_source:
        return False
    if type(expected_value) is float:
        # JSON may spell an integral float as an integer, but never as a boolean.
        if type(value) not in (int, float) or value != expected_value:
            return False
        return (expected_value != 0.0
                or math.copysign(1, value) == math.copysign(1, expected_value))
    return type(value) is type(expected_value) and value == expected_value


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: nested.py DRIVER [DRIVER ...]")
    model = fixtures()
    requests = ("\n".join(model.requests) + "\n").encode()
    for driver in sys.argv[1:]:
        try:
            result = subprocess.run([str(Path(driver).resolve())], input=requests,
                                    capture_output=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            raise SystemExit(f"{driver}: nested model exceeded 120 seconds") from error
        if result.returncode != 0 or result.stderr:
            raise SystemExit(f"{driver}: exit {result.returncode}\n"
                             f"{result.stderr.decode(errors='replace')}")
        lines = result.stdout.splitlines()
        if len(lines) != len(model.expected):
            raise SystemExit(f"{driver}: {len(lines)} responses for "
                             f"{len(model.expected)} requests")
        for index, (line, wanted) in enumerate(zip(lines, model.expected)):
            try:
                actual = json.loads(line)
            except (ValueError, UnicodeError) as error:
                raise SystemExit(f"{driver}: invalid JSON at response {index}: {error}") from error
            if not compare(actual, wanted):
                raise SystemExit(
                    f"{driver}: mismatch response {index}, seed={SEED:#x}\n"
                    f"case: {model.descriptions[index]}\n"
                    f"request: {model.requests[index]}\n"
                    f"expected: {wanted!r}\nactual: {actual!r}")
        print(f"{driver}: {model.transactions} differential transactions, "
              f"{len(lines)} responses passed across 45 nested schema cycles; seed={SEED:#x}")


if __name__ == "__main__":
    main()
