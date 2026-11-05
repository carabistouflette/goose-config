#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Pinned-compiler regression for quadratic cleanup expansion in wide loaders.

This checks emitted-C size through --dry-run, not native execution or elapsed
compilation time. Functional/native maximum qualification is reported separately.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from generate_settings import generate

ROOT=Path(__file__).resolve().parents[1]
compiler=Path(sys.argv[1]).resolve(strict=True)
KINDS=('Text','Integer','Float','Boolean','Duration','TextList','IntegerList','FloatList','BooleanList','DurationList')
schema={'version':1,'namespace':'emission_fixture','fields':[{'member':f'v_{i}','key':f'field_{i}','kind':KINDS[i%10]} for i in range(256)]}
(ROOT/'.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='typed emission ',dir=ROOT/'.build') as tmp:
    work=Path(tmp)
    (work/'emission_fixture.goose').write_bytes(generate(json.dumps(schema).encode(),'../..',compiler))
    (work/'main.goose').write_text('import config from "../..";\nimport emission_fixture;\nimport std;\nfn main(){var store=config::Store{..};var settings=emission_fixture::Settings{..};let fields=emission_fixture::schema();assert(config::init(fields,store).len==0);assert(emission_fixture::load(store,settings).len==0);assert(!settings.v_255_present);}\n')
    env={key:os.environ[key] for key in ('PATH','HOME') if key in os.environ}
    env.update(GOOSE_HOME=str(work/'goose-home'),LANG='C',TZ='UTC')
    subprocess.run([str(compiler),'build',str(work/'main.goose'),'--cc','gcc','-O2','--dry-run','-o',str(work/'unused')],env=env,capture_output=True,check=True,timeout=30)
    files=list((work/'goose-home/build/prog').glob('main-*/main.c'))
    if len(files)!=1:raise RuntimeError('expected one emitted program')
    size=files[0].stat().st_size
    if size>4000000:raise RuntimeError(f'wide loader cleanup expansion: {size} C bytes exceeds 4000000 budget')
    print(f'wide loader emission: {size} bytes within pinned 4000000-byte source budget; dry-run only')
