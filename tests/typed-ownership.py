#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual pinned-compiler checks for generated readonly and ownership contracts."""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from generate_settings import generate

ROOT = Path(__file__).resolve().parents[1]
compiler = Path(sys.argv[1]).resolve(strict=True)
setup = '''
    var store = config::Store { .. }; var destination = typed_fixture::Settings { .. };
    let schema = typed_fixture::schema();
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "label", "original", "seed" }]).len == 0);
'''
mutations = {'scalar': 'candidate.count = 9;', 'text': "candidate.label[0] = 'X';",
             'list': 'candidate.counts[0] = 9;', 'text-list': "for item in candidate.tags { item[0] = 'X'; }",
             'builder': 'candidate.label.clear();', 'list-builder': 'candidate.tags.clear();'}
(ROOT/'.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='typed ownership ', dir=ROOT/'.build') as tmp:
    base = Path(tmp)
    (base/'typed_fixture.goose').write_bytes(generate((ROOT/'schemas/typed-test.json').read_bytes(), '../..', compiler))
    imports = 'import config from "../..";\nimport typed_fixture;\nimport std;\n'
    cases = {}
    cases['mutable-validator'] = ('fn validate(candidate: typed_fixture::Settings&) -> u8[>..] { candidate.count = 99; [] }\nfn main() {\n'+setup+' typed_fixture::load(store, destination, validate);\n}', ('const',))
    for name, mutation in mutations.items():
        helper = 'fn validate(candidate: const typed_fixture::Settings&) -> u8[>..] { '+mutation+' [] }\n'
        cases[name] = (helper + 'fn main() {\n'+setup+' typed_fixture::load(store, destination, validate);\n}', ('const',))
    cases['borrow-after-load'] = ('fn main() {\n'+setup+'''
        assert(typed_fixture::load(store, destination).len == 0);
        let borrowed: const u8[:] = destination.label;
        assert(typed_fixture::load(store, destination).len == 0);
        print(borrowed);
    }''', ('borrowed', 'still used'))
    cases['escape-output'] = ('''fn escape() -> const u8[:] {
'''+setup+'''assert(typed_fixture::load(store, destination).len == 0); return destination.label;
    }
    fn main() { print(escape()); }''', ('dies with this function',))
    cases['escape-validator'] = ('var escaped: const u8[:] = "";\nfn validate(candidate: const typed_fixture::Settings&) -> u8[>..] { escaped = candidate.label; [] }\nfn main() {\n'+setup+' typed_fixture::load(store, destination, validate); print(escaped);\n}', ('does not outlive',))
    control = 'fn validate(candidate: const typed_fixture::Settings&) -> u8[>..] { assert(candidate.label == "original"); [] }\nfn main() {\n'+setup+'''
        assert(typed_fixture::load(store, destination, validate).len == 0);
        assert(config::init([], store).len == 0);
        assert(destination.label == "original" && destination.label_source == "seed");
    }'''
    for name, (body, expected) in {'positive-control': (control, ()), **cases}.items():
        source = base/(name+'.goose'); source.write_text(imports+body)
        result = subprocess.run([str(compiler), 'check', str(source)], capture_output=True, text=True, timeout=30)
        diagnostic = result.stdout + result.stderr
        if not expected:
            if result.returncode != 0: raise RuntimeError('positive control rejected: '+diagnostic)
            subprocess.run([str(compiler), 'run', str(source)], check=True, timeout=30)
        elif result.returncode != 1 or not all(text in diagnostic for text in expected):
            raise RuntimeError(name+': expected ownership rejection: '+diagnostic)
        print(name+(': rejected' if expected else ': accepted and executed'))
