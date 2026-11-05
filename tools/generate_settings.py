#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate owned, checked Goose settings from a bounded declarative schema."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAX_INPUT_BYTES = 1048576
MAX_NUMBER_BYTES = 128
KINDS = {
    'Text': ('u8[>..]', 'text'), 'Integer': ('i64', 'integer'),
    'Float': ('f64', 'float'), 'Boolean': ('bool', 'boolean'),
    'Duration': ('config::Duration', 'duration'),
    'TextList': ('u8[][>..]', 'text_list'), 'IntegerList': ('i64[>..]', 'integer_list'),
    'FloatList': ('f64[>..]', 'float_list'), 'BooleanList': ('bool[>..]', 'boolean_list'),
    'DurationList': ('config::Duration[>..]', 'duration_list'),
}
INTEGER_KINDS = {'Integer', 'IntegerList', 'Duration', 'DurationList'}
FLOAT_KINDS = {'Float', 'FloatList'}
# Metadata never supplies code fragments, function bodies or type expressions.
RESERVED = set('alias and as assert auto bitcast block bool break case cast const continue defer do else enum export extern f16 f32 f64 false fn for guard i8 i16 i32 i64 if import in inline is let loop match namespace never null or return root size sizeof static str struct switch true type u8 u16 u32 u64 union var void while with config std os json math schema aliases load accept publish settings'.split())
RESERVED.update('thread_fn simd recursive pad reusable self varint own_text'.split())
IDENTIFIER = re.compile(r'[a-z][a-z0-9_]{0,63}\Z', re.ASCII)
KEY = re.compile(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\Z', re.ASCII)
LOCAL_IMPORT = re.compile(r'(?:\.{1,2}|[A-Za-z0-9_-]+)(?:/(?:\.{1,2}|[A-Za-z0-9_-]+))*\Z', re.ASCII)
PINNED_IMPORT = re.compile(r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+@[a-f0-9]{40}\Z', re.ASCII)

class SchemaError(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise SchemaError(message)

def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON property')
        result[key] = value
    return result

def reject_constant(_):
    raise SchemaError('nonfinite JSON number')

def parse_integer(token):
    require(len(token) <= MAX_NUMBER_BYTES, 'schema number exceeds token limit')
    return int(token)

def parse_number(token):
    require(len(token) <= MAX_NUMBER_BYTES, 'schema number exceeds token limit')
    value = float(token)
    require(math.isfinite(value), 'nonfinite JSON number')
    return value

def identifier(value):
    return type(value) is str and IDENTIFIER.fullmatch(value) and value not in RESERVED

def key(value):
    return type(value) is str and len(value) <= 256 and KEY.fullmatch(value)

def conflict(a, b):
    return a == b or a.startswith(b + '.') or b.startswith(a + '.')

def parse_schema(data):
    require(len(data) <= MAX_INPUT_BYTES, 'schema exceeds byte limit')
    try:
        document = json.loads(data.decode('utf-8'), object_pairs_hook=object_pairs,
                              parse_constant=reject_constant, parse_int=parse_integer,
                              parse_float=parse_number)
    except (UnicodeError, ValueError, RecursionError):
        raise SchemaError('invalid schema JSON') from None
    require(type(document) is dict and set(document) <= {'version', 'namespace', 'fields', 'aliases'}, 'invalid schema properties')
    require(type(document.get('version')) is int and document['version'] == 1, 'unsupported schema version')
    require(identifier(document.get('namespace')), 'invalid namespace')
    fields = document.get('fields')
    require(type(fields) is list and 1 <= len(fields) <= 256, 'expected 1..256 fields')
    names = set(); keys = []
    for i, field in enumerate(fields):
        label = f'field {i}'
        require(type(field) is dict and set(field) <= {'member', 'key', 'kind', 'required', 'source', 'int_min', 'int_max', 'float_min', 'float_max'}, label + ': invalid properties')
        require(identifier(field.get('member')), label + ': invalid member')
        require(key(field.get('key')), label + ': invalid key')
        kind = field.get('kind')
        require(type(kind) is str and kind in KINDS, label + ': invalid kind')
        require(type(field.get('required', False)) is bool and type(field.get('source', False)) is bool, label + ': invalid boolean option')
        generated = [field['member']]
        if not field.get('required', False): generated.append(field['member'] + '_present')
        if field.get('source', False): generated.append(field['member'] + '_source')
        require(not any(name in names for name in generated), label + ': member collision')
        names.update(generated)
        require(not any(conflict(field['key'], other) for other in keys), label + ': key conflict')
        keys.append(field['key'])
        for bound in ('int_min', 'int_max'):
            if bound in field:
                require(kind in INTEGER_KINDS and type(field[bound]) is int and -(2**63) <= field[bound] < 2**63, label + ': invalid integer bound')
        for bound in ('float_min', 'float_max'):
            if bound in field:
                value = field[bound]
                require(kind in FLOAT_KINDS and type(value) in (int, float), label + ': invalid float bound')
                try: valid = math.isfinite(float(value))
                except OverflowError: valid = False
                require(valid, label + ': nonfinite float bound')
                field[bound] = float(value)
        require(field.get('int_min', -(2**63)) <= field.get('int_max', 2**63-1), label + ': reversed integer bounds')
        require(field.get('float_min', -sys.float_info.max) <= field.get('float_max', sys.float_info.max), label + ': reversed float bounds')
    aliases = document.get('aliases', [])
    require(type(aliases) is list and len(aliases) <= 256, 'expected at most 256 aliases')
    alias_keys = []
    for alias in aliases:
        require(type(alias) is dict and set(alias) == {'key', 'target'}, 'invalid alias properties')
        require(key(alias['key']) and key(alias['target']), 'invalid alias key or target')
        require(alias['target'] in keys, 'alias target is not canonical')
        require(not any(conflict(alias['key'], other) for other in keys + alias_keys), 'alias key conflict')
        alias_keys.append(alias['key'])
    document['aliases'] = aliases
    return document

def quote(value):
    return json.dumps(value, ensure_ascii=True)

def render(document, config_import):
    require(type(config_import) is str and len(config_import) <= 512 and
            (LOCAL_IMPORT.fullmatch(config_import) or PINNED_IMPORT.fullmatch(config_import)), 'invalid config import')
    identity = hashlib.sha256(json.dumps(document, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    lines = ['// SPDX-License-Identifier: Apache-2.0', '// Generated by tools/generate_settings.py; do not edit.',
             f'// Schema SHA256: {identity}', f'import config from {quote(config_import)};', 'import config.typed;', 'import std;',
             f'namespace {document["namespace"]};', '', 'root struct Settings {']
    fields = document['fields']
    for field in fields:
        member = field['member']; kind = field['kind']; typ = KINDS[kind][0]
        default = ' = 0' if kind == 'Integer' else ' = 0.0' if kind == 'Float' else ' = false' if kind == 'Boolean' else ''
        lines.append(f'    {member}: {typ}{default},')
        if not field.get('required', False): lines.append(f'    {member}_present: bool = false,')
        if field.get('source', False): lines.append(f'    {member}_source: u8[>..],')
    lines += ['}', '', 'fn schema() -> config::Field[>..] {', '    [']
    for field in fields:
        parts = [f'key: {quote(field["key"])}', f'kind: config::Kind.{field["kind"]}']
        for option in ('required', 'int_min', 'int_max', 'float_min', 'float_max'):
            if option in field: parts.append(f'{option}: {json.dumps(field[option])}')
        lines.append('        config::Field { ' + ', '.join(parts) + ' },')
    lines += ['    ]', '}', '', 'fn aliases() -> config::Alias[>..] {', '    [']
    lines += [f'        config::Alias {{ {quote(a["key"])}, {quote(a["target"])} }},' for a in document['aliases']]
    lines += ['    ]', '}', '', 'fn own_text(input: const u8[:]) -> u8[>..] {',
              '    var output: u8[>..] = []; output.append(input); output', '}',
              'fn accept(candidate: const Settings&) -> u8[>..] { [] }',
              'fn load(store: config::Store&, destination: Settings&) -> u8[>..] { load(store, destination, accept) }',
              'fn load<Validate: fn(const Settings&) -> u8[>..]>(store: config::Store&, destination: Settings&) -> u8[>..] {',
              '    var candidate = Settings { .. };']
    for i, field in enumerate(fields):
        member = field['member']; kind = field['kind']; key_text = quote(field['key'])
        lines += [f'    let present_{i}, state_error_{i} = config::has_value(store, {key_text}, config::Kind.{kind});',
                  f'    if state_error_{i}.len > 0 {{ return state_error_{i}; }}']
        if field.get('required', False):
            lines.append(f'    if !present_{i} {{ return own_text({quote("config typed: required value is missing [key=" + field["key"] + "]")}); }}')
        else: lines.append(f'    candidate.{member}_present = present_{i};')
        lines += [f'    if present_{i} {{', f'        let value, error = config::get_{KINDS[kind][1]}(store, {key_text});',
                  '        if error.len > 0 { return error; }']
        element = 'item.nanoseconds' if kind == 'DurationList' else 'item' if kind.endswith('List') else 'value.nanoseconds' if kind == 'Duration' else 'value'
        checks = []
        for option, operator in [('int_min', '<'), ('int_max', '>'), ('float_min', '<'), ('float_max', '>')]:
            if option in field: checks.append(f'{element} {operator} {json.dumps(field[option])}')
        if checks:
            check = f'if {" || ".join(checks)} {{ return own_text({quote("config typed: value outside generated range [key=" + field["key"] + "]")}); }}'
            lines.append('        ' + ('for item in value { ' + check + ' }' if kind.endswith('List') else check))
        if kind == 'Text': lines.append(f'        candidate.{member}.append(value);')
        elif kind.endswith('List'):
            lines.append(f'        for item in value {{ candidate.{member}.push({"own_text(item)" if kind == "TextList" else "item"}); }}')
        else: lines.append(f'        candidate.{member} = value;')
        if field.get('source', False):
            lines += [f'        let origin, source_error = config::source(store, {key_text});',
                      '        if source_error.len > 0 { return source_error; }', f'        candidate.{member}_source.append(origin);']
        lines.append('    }')
    # The static function bound alone is documentation in pinned Goose. Pass an
    # actual const reference so a mutable callback cannot bypass range checks.
    lines += ['    let readonly: const Settings& = candidate;',
              '    let error = Validate(readonly);', '    if error.len > 0 { return error; }']
    for field in fields:
        member = field['member']; kind = field['kind']
        if kind == 'TextList':
            lines += [f'    destination.{member}.clear();', f'    for item in candidate.{member} {{ destination.{member}.push(own_text(item)); }}']
        elif kind == 'Text' or kind.endswith('List'):
            lines += [f'    destination.{member}.clear(); destination.{member}.append(candidate.{member});']
        else: lines.append(f'    destination.{member} = candidate.{member};')
        if not field.get('required', False): lines.append(f'    destination.{member}_present = candidate.{member}_present;')
        if field.get('source', False): lines.append(f'    destination.{member}_source.clear(); destination.{member}_source.append(candidate.{member}_source);')
    lines += ['    []', '}']
    return '\n'.join(lines) + '\n'

def generate(data, config_import, compiler):
    source = render(parse_schema(data), config_import)
    pin = (ROOT/'GOOSE_REVISION').read_text().strip()
    version = subprocess.run([str(compiler), '--version'], capture_output=True, text=True, check=True, timeout=15)
    require(version.stdout.startswith(f'goose {pin[:7]} '), 'compiler pin mismatch')
    formatted = subprocess.run([str(compiler), 'format', '-'], input=source, capture_output=True,
                               text=True, check=True, timeout=30)
    require(not formatted.stderr, 'formatter wrote diagnostics')
    return formatted.stdout.encode('utf-8')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('schema', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--config-import', default='..')
    parser.add_argument('--goose', default=str(ROOT/'.toolchain/goose/build/goose'))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    temporary = None
    try:
        require(args.output.suffix == '.goose', 'output must have .goose suffix')
        with args.schema.open('rb') as stream: data = stream.read(MAX_INPUT_BYTES + 1)
        compiler = Path(shutil.which(args.goose) or args.goose).resolve(strict=True)
        result = generate(data, args.config_import, compiler)
        if args.check:
            require(args.output.read_bytes() == result, 'generated output is stale')
        else:
            require(args.schema.resolve() != args.output.resolve(), 'schema and output must differ')
            require(not args.output.is_symlink(), 'output may not be a symbolic link')
            mode = stat.S_IMODE(args.output.stat().st_mode) & 0o777 if args.output.exists() else 0o600
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=args.output.parent, prefix='.'+args.output.name+'.', delete=False) as stream:
                temporary = Path(stream.name); stream.write(result)
            os.chmod(temporary, mode)
            os.replace(temporary, args.output); temporary = None
    except (SchemaError, OSError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, SchemaError) else 'schema, compiler or output operation failed'
        print('config-gen: ' + message, file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            try: temporary.unlink(missing_ok=True)
            except OSError: pass
    return 0

if __name__ == '__main__':
    sys.exit(main())
