#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Adversarial schema, source-generation and atomic-output regressions."""
import copy
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import generate_settings as gen


def schema():
    return {'version': 1, 'namespace': 'example_settings',
            'fields': [{'member': 'label', 'key': 'app.label', 'kind': 'Text'}]}

def encoded(document):
    return json.dumps(document).encode()

class SchemaTests(unittest.TestCase):
    def reject(self, document):
        with self.assertRaises(gen.SchemaError): gen.parse_schema(encoded(document))

    def test_all_kinds_and_exact_i64_boundaries(self):
        document = schema(); document['fields'] = []
        for i, kind in enumerate(gen.KINDS):
            field = {'member': f'value_{i}', 'key': f'value_{i}', 'kind': kind}
            if kind in gen.INTEGER_KINDS: field.update(int_min=-(2**63), int_max=2**63-1)
            document['fields'].append(field)
        parsed = gen.parse_schema(encoded(document))
        source = gen.render(parsed, '..')
        self.assertIn('-9223372036854775808', source)
        self.assertIn('9223372036854775807', source)
        self.assertNotIn('str(', source)
        self.assertIn('fn(const Settings&)', source)

    def test_invalid_root_and_scalar_types(self):
        for value in (None, [], 1, True, 'text'):
            self.reject(value)
        for name, value in [('version', True), ('version', 2), ('namespace', 'std'), ('namespace', '"; exit(0);'), ('fields', {}), ('fields', [])]:
            document = schema(); document[name] = value; self.reject(document)
        for name, value in [('member', 'fn'), ('member', 'thread_fn'), ('member', 'self'), ('member', 'a-b'), ('member', 'é'), ('member', 'x'*65), ('key', ''), ('key', 'a..b'), ('key', 'x'*257), ('key', 'x\x00'), ('key', 'é'), ('kind', []), ('kind', 'Object'), ('required', 1), ('source', 'true'), ('code', 'secret')]:
            document = schema(); document['fields'][0][name] = value; self.reject(document)

    def test_byte_depth_duplicate_and_nonfinite_limits(self):
        for raw in (b'\xff', b'{"version":1,"version":1}', b'['*2000+b']'*2000,
                    b'{"version":NaN}', b'{"version":Infinity}', b' '* (gen.MAX_INPUT_BYTES+1)):
            with self.assertRaises(gen.SchemaError): gen.parse_schema(raw)
        for token in (b'1'*129, b'0.'+b'1'*127, b'1e'+b'0'*127):
            with self.assertRaises(gen.SchemaError): gen.parse_schema(b'{"version":'+token+b'}')
        for value in (True, 2**63, -(2**63)-1, 1.5, '1'):
            document = schema(); document['fields'][0].update(kind='Integer', int_min=value); self.reject(document)
        for value in (True, float('nan'), float('inf'), 10**400):
            document = schema(); document['fields'][0].update(kind='Float', float_min=value); self.reject(document)
        with self.assertRaises(gen.SchemaError):
            gen.parse_schema(encoded(schema()).replace(b'"Text"', b'"Float", "float_min":1e999'))
        for bounds in ({'int_min': 2, 'int_max': 1}, {'float_min': 2, 'float_max': 1}):
            document = schema(); document['fields'][0].update(kind='Integer' if 'int_min' in bounds else 'Float', **bounds); self.reject(document)
        document = schema(); document['fields'][0]['int_min'] = 0; self.reject(document)

    def test_field_and_generated_name_collisions(self):
        for other in ({'member': 'label', 'key': 'other', 'kind': 'Text'},
                      {'member': 'label_present', 'key': 'other', 'kind': 'Text'},
                      {'member': 'other', 'key': 'app', 'kind': 'Text'},
                      {'member': 'other', 'key': 'app.label.child', 'kind': 'Text'}):
            document = schema(); document['fields'].append(other); self.reject(document)
            document['fields'].reverse(); self.reject(document)
        document = schema(); document['fields'][0]['source'] = True
        document['fields'].append({'member': 'label_source', 'key': 'other', 'kind': 'Text'}); self.reject(document)

    def test_alias_contracts_and_count_limits(self):
        document = schema(); document['aliases'] = [{'key': 'old.label', 'target': 'app.label'}]
        self.assertEqual(len(gen.parse_schema(encoded(document))['aliases']), 1)
        for alias in ({'key': 'app', 'target': 'app.label'}, {'key': 'old', 'target': 'unknown'}, {'key': 'old', 'target': 'old.label'}, {'key': 'bad..key', 'target': 'app.label'}, {'key': 'old.label', 'target': 'app.label', 'extra': 1}):
            bad = copy.deepcopy(document); bad['aliases'].append(alias); self.reject(bad)
        document['fields'] = [{'member': f'field_{i}', 'key': f'field_{i}', 'kind': 'Integer'} for i in range(256)]
        document['aliases'] = [{'key': f'old_{i}', 'target': f'field_{i}'} for i in range(256)]
        self.assertEqual(len(gen.parse_schema(encoded(document))['fields']), 256)
        bad = copy.deepcopy(document); bad['fields'].append({'member': 'extra', 'key': 'extra', 'kind': 'Text'}); self.reject(bad)
        document['aliases'].append({'key': 'extra', 'target': 'field_0'}); self.reject(document)

    def test_import_injection_rejected_and_deterministic_output(self):
        parsed = gen.parse_schema(encoded(schema()))
        for name in ('"; exit(0); //', 'x\nimport os;', '/absolute', 'https://example.com', 'owner/repo@main', '../a b', ''):
            with self.assertRaises(gen.SchemaError): gen.render(parsed, name)
        reordered = {key: parsed[key] for key in reversed(parsed)}
        reordered['fields'] = [dict(reversed(list(field.items()))) for field in parsed['fields']]
        for name in ('..', '../../goose-config', 'owner/repo@'+'a'*40):
            self.assertEqual(gen.render(parsed, name), gen.render(reordered, name))

class BindingMetadataTests(unittest.TestCase):
    def test_valid_byte_boundaries_and_cross_source_names(self):
        document=schema();f=document['fields'][0];f.update(env='é'*128,cli='x'*254)
        gen.parse_schema(encoded(document))
        f.update(env='SAME',cli='SAME');gen.parse_schema(encoded(document))
        f.update(kind='TextList',separator='é'*128);gen.parse_schema(encoded(document))
    def test_invalid_binding_types_and_byte_limits(self):
        for option,values in [('env',[None,False,1,[],{},'', 'x'*257,'é'*129,'a=b','a\x00b','\ud800']),('cli',[None,False,1,[],{},'', 'x'*255,'-bad','a.b','é','a b']),('separator',[None,False,1,[],{},'', 'x'*257,'é'*129,'\x00','\ud800'])]:
            for value in values:
                document=schema();f=document['fields'][0];f.update(kind='TextList',env='ENV');f[option]=value
                with self.assertRaises(gen.SchemaError):gen.parse_schema(encoded(document))
    def test_duplicates_and_invalid_separator_context(self):
        for option in ('env','cli'):
            document=schema();document['fields'][0][option]='SAME'
            document['fields'].append({'member':'other','key':'other','kind':'Text',option:'SAME'})
            with self.assertRaises(gen.SchemaError):gen.parse_schema(encoded(document))
        for extra in ({'separator':','},{'env':'ENV','separator':','}):
            document=schema();document['fields'][0].update(extra)
            with self.assertRaises(gen.SchemaError):gen.parse_schema(encoded(document))
    def test_byte_escaping_and_empty_binding_functions(self):
        document=schema();document['fields'][0]['env']='Eé"\\\n'
        source=gen.render(gen.parse_schema(encoded(document)),'..')
        self.assertNotIn('\\u',source);self.assertIn('\\xc3\\xa9',source)
        self.assertIn('fn env_bindings()',source);self.assertIn('fn cli_bindings()',source)
        source=gen.render(gen.parse_schema(encoded(schema())),'..')
        self.assertIn('fn env_bindings()',source);self.assertIn('fn cli_bindings()',source)

class OutputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name); self.input = self.base/'input.json'; self.output = self.base/'settings.goose'
        self.input.write_bytes(encoded(schema())); self.output.write_bytes(b'original'); self.output.chmod(0o600)

    def command(self, *options):
        arguments = ['generate_settings.py', str(self.input), '--output', str(self.output), '--goose', sys.executable, *options]
        with patch.object(sys, 'argv', arguments), contextlib.redirect_stderr(io.StringIO()): return gen.main()

    def test_success_atomic_replace_permissions_and_check(self):
        with patch.object(gen, 'generate', return_value=b'generated'):
            self.assertEqual(self.command(), 0); self.assertEqual(self.output.read_bytes(), b'generated')
            self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.command('--check'), 0)
            self.output.write_bytes(b'stale'); self.assertEqual(self.command('--check'), 1)
            self.assertEqual(self.output.read_bytes(), b'stale')

    def test_failures_preserve_existing_output(self):
        failures = [gen.SchemaError('bad schema'), OSError('IO'), subprocess.CalledProcessError(1, ['formatter']), subprocess.TimeoutExpired(['formatter'], 30)]
        for failure in failures:
            with patch.object(gen, 'generate', side_effect=failure): self.assertEqual(self.command(), 1)
            self.assertEqual(self.output.read_bytes(), b'original')
        with patch.object(gen, 'generate', return_value=b'generated'), patch.object(gen.os, 'replace', side_effect=OSError('replace')):
            self.assertEqual(self.command(), 1)
        self.assertEqual(self.output.read_bytes(), b'original')
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), ['input.json', 'settings.goose'])

    def test_output_symlink_preserves_target(self):
        self.output.unlink(); self.output.symlink_to(self.input)
        original = self.input.read_bytes()
        with patch.object(gen, 'generate', return_value=b'generated'): self.assertEqual(self.command(), 1)
        self.assertTrue(self.output.is_symlink()); self.assertEqual(self.input.read_bytes(), original)

    def test_new_output_respects_restrictive_permissions(self):
        self.output.unlink()
        previous = os.umask(0o077)
        try:
            with patch.object(gen, 'generate', return_value=b'generated'):
                self.assertEqual(self.command(), 0)
        finally:
            os.umask(previous)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_rejected_schema_never_invokes_compiler(self):
        with patch.object(gen.subprocess, 'run') as compiler:
            with self.assertRaises(gen.SchemaError): gen.generate(b'{"version":false}', '..', Path(sys.executable))
            compiler.assert_not_called()

if __name__ == '__main__': unittest.main()
