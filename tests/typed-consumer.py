#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Standalone generated consumers with sibling/nested modules and spaced paths."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from generate_settings import generate
ROOT=Path(__file__).resolve().parents[1];compiler=Path(sys.argv[1]).resolve(strict=True)
document={'version':1,'namespace':'app_settings','fields':[{'member':'port','key':'server.port','kind':'Integer','required':True,'int_min':1,'int_max':65535,'env':'APP_PORT','cli':'port'},{'member':'label','key':'server.label','kind':'Text','source':True,'env':'APP_LABEL','cli':'label'}],'aliases':[{'key':'server.old_port','target':'server.port'}]}
(ROOT/'.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='typed consumers ',dir=ROOT/'.build') as tmp:
    base=Path(tmp);library=base/'goose-config';library.mkdir()
    # This is a consumer snapshot, not a checkout or shared-source mutation.
    for name in ('config.goose','typed.goose','bindings.goose'):shutil.copyfile(ROOT/name,library/name)
    env={key:os.environ[key] for key in ('PATH','HOME') if key in os.environ};env.update(GOOSE_HOME=str(base/'goose-home'),LANG='C',TZ='UTC')
    for nested in (False,True):
        app=base/('nested app' if nested else 'sibling app');app.mkdir();generated=app/'generated' if nested else app;generated.mkdir(exist_ok=True)
        (generated/'app_settings.goose').write_bytes(generate(json.dumps(document).encode(),'../../goose-config' if nested else '../goose-config',compiler))
        source=app/'main.goose';source.write_text('import config from "../goose-config";\nimport '+('generated.app_settings' if nested else 'app_settings')+''';
import config.bindings;
import std;
fn main(){var store=config::Store{..};var settings=app_settings::Settings{..};let fields=app_settings::schema();let aliases=app_settings::aliases();assert(config::init(fields,store,aliases).len==0);assert(config::apply(store,[config::Override{"server.old_port","8080","cli"}]).len==0);assert(app_settings::load(store,settings).len==0);assert(settings.port==8080 && !settings.label_present && settings.label.len==0 && settings.label_source.len==0);let environment=app_settings::env_bindings();let cli=app_settings::cli_bindings();assert(config::apply_env_values(store,environment,[config::EnvValue{"APP_PORT","9090"},config::EnvValue{"APP_LABEL","env"}]).len==0);assert(app_settings::load(store,settings).len==0 && settings.port==9090 && settings.label=="env" && settings.label_source=="APP_LABEL");assert(config::apply_cli(store,cli,["--port=7070","--label=cli"]).len==0);assert(app_settings::load(store,settings).len==0 && settings.port==7070 && settings.label=="cli" && settings.label_source=="--label");assert(config::init([],store).len==0);assert(settings.port==7070 && settings.label=="cli");print("consumer passed");}
''')
        def run(command):
            process=subprocess.Popen(list(map(str,command)),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            try:out,err=process.communicate(timeout=90)
            except BaseException:
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                process.communicate();raise
            if process.returncode:raise RuntimeError(out+err)
            return out
        if run([compiler,'run',source])!='consumer passed\n':raise RuntimeError('unexpected consumer output')
        run([compiler,'build',source,'--cc','gcc','-O2','-o',app/'native'])
        if run([app/'native'])!='consumer passed\n':raise RuntimeError('unexpected native consumer output')
        print(('nested' if nested else 'sibling')+': in-process and GCC-O2 consumer passed')
