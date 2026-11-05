#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded exact-integer corpus; checks stay active under Python -O.

Each executable reports acceptance, canonical values and provenance after
persistent accepted/rejected parser/override/JSON/TOML operations.
"""
import json
import random
import re
import subprocess
import sys

UNITS = {'ns': 1, 'us': 1000, 'µs': 1000, 'μs': 1000, 'ms': 10**6,
         's': 10**9, 'm': 60*10**9, 'h': 3600*10**9, 'd': 86400*10**9}
COMPONENT = re.compile(r'(?P<number>(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))(?P<unit>ns|us|µs|μs|ms|s|m|h|d)')
SEED = 0xD012A710

def check(condition, message):
    if not condition:
        raise ValueError(message)

def oracle(token):
    if not 0 < len(token) <= 128: return None
    try: text = token.decode('utf-8')
    except UnicodeDecodeError: return None
    negative = text.startswith('-')
    if text[0] in '+-': text = text[1:]
    if text == '0': return 0
    if not text: return None
    at = 0
    total = 0
    # Independent forward regex and arbitrary-precision rational decomposition.
    while at < len(text):
        match = COMPONENT.match(text, at)
        if not match: return None
        whole, dot, fraction = match['number'].partition('.')
        unit = UNITS[match['unit']]
        total += int(whole or '0') * unit
        if fraction: total += int(fraction) * unit // (10 ** len(fraction))
        at = match.end()
    value = -total if negative else total
    return value if -(1 << 63) <= value < (1 << 63) else None

def corpus():
    tokens = [b'', b'0', b'+0', b'-0', b'00', b'.5s', b'1.s', b'0.9ns0.9ns', b'-0.9ns0.9ns',
              b'9223372036854775807ns', b'-9223372036854775808ns', b'9223372036854775808ns',
              b'-9223372036854775809ns', b'9223372036.854775807s', b'-9223372036.854775808s',
              b'9223372036.854775808s', b'-9223372036.854775809s',
              b'9223372036854775807ns1ns', b'-9223372036854775808ns1ns', b'106752d',
              b'0'*126+b'ns', b'0'*127+b'ns', b'0.'+b'9'*125+b'h',
              b'1\x00s', b'1\xffs', b'1\xc2s', b'1\xce\xbcs', b'1\xc2\xb5s', b'1\xc0\xafs']
    rng = random.Random(SEED)
    units = tuple(UNITS)
    for _ in range(700):
        parts = []
        for __ in range(rng.randrange(1, 5)):
            whole = rng.choice(['', '0', str(rng.randrange(0, 10**12)), str(2**63 + rng.randrange(-3, 4))])
            fraction = ''.join(str(rng.randrange(10)) for ___ in range(rng.choice([0, 1, 3, 9, 18, 80])))
            number = whole + ('.'+fraction if fraction or not whole or rng.randrange(3)==0 else '')
            parts.append(number+rng.choice(units))
        token = (rng.choice(['', '+', '-'])+''.join(parts)).encode()
        tokens.append(token)
        at = rng.randrange(len(token)+1)
        tokens.append(token[:at]+rng.choice([b' ', b'e3', b'\x00', b'+', b'-', b'..', b'X', b'\xff'])+token[at:])
    for unit, scale in UNITS.items():
        for boundary in [2**63-1, 2**63, 2**63+1]:
            whole, rest = divmod(boundary, scale)
            for sign in ['', '-']: tokens.append(f'{sign}{whole}{unit}{rest}ns'.encode())
    return tokens

def main():
    check(len(sys.argv)>1, 'usage: duration-model.py DRIVER...')
    tokens = corpus()
    protocol = []
    expected = []
    value, source = 1, 'seed'
    for token in tokens:
        number = oracle(token)
        accepted = number is not None
        expected.append('P '+(str(number) if accepted else 'error'))
        try:
            text = token.decode('utf-8')
            literal = json.dumps(text, ensure_ascii=True)
            documents = [json.dumps({'delay': text}, ensure_ascii=True).encode(), ('delay='+literal).encode()]
        except UnicodeDecodeError: documents = [None, None]
        protocol.append('\t'.join([token.hex(), *[d.hex() if d is not None else '-' for d in documents]]))
        for label, new_source, skipped in [('O', 'override', False), ('J', 'json', documents[0] is None), ('T', 'toml', documents[1] is None)]:
            if skipped:
                expected.append(label+' skipped'); continue
            if accepted: value, source = number, new_source
            expected.append(f'{label} {str(accepted).lower()} {value} {source}')
    payload = '\n'.join(protocol)+'\n'
    for executable in sys.argv[1:]:
        p = subprocess.run([executable], input=payload, capture_output=True, text=True, timeout=120)
        check(p.returncode==0 and not p.stderr, f'{executable}: failed {p.returncode}: {p.stderr}')
        actual = p.stdout.splitlines()
        check(len(actual)==len(expected), f'{executable}: expected {len(expected)} lines got {len(actual)}')
        for i, (want, got) in enumerate(zip(expected, actual)):
            check(want==got, f'{executable}: case {i//4} {tokens[i//4]!r}: expected {want!r}, got {got!r}')
        print(f'duration model passed: {len(tokens)} cases, {len(expected)} observations, seed={SEED}, {executable}')

if __name__ == '__main__': main()
