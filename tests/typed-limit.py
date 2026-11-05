#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Functional maximum-schema acceptance, including real optimized native code."""
import argparse,hashlib,json,os,signal,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from generate_settings import generate,KINDS

def run(command,env,timeout):
    process=subprocess.Popen(list(map(str,command)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env,start_new_session=True)
    try:out,err=process.communicate(timeout=timeout)
    except BaseException:
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        process.communicate();raise
    if process.returncode:raise RuntimeError(out+err)
    return out,err

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('goose',type=Path);p.add_argument('--cc',choices=('gcc','clang'),default='gcc');p.add_argument('--report',type=Path)
a=p.parse_args();compiler=a.goose.resolve(strict=True)
if a.report and a.report.exists():p.error('choose a fresh report path')
(ROOT/'.build').mkdir(exist_ok=True)
record={'completed':False,'fields':256,'aliases':256,'kinds':10,'max_key_bytes':256,'flags':'-O2','cc':a.cc,'native_deadline_seconds':300}
try:
 with tempfile.TemporaryDirectory(prefix='typed limit ',dir=ROOT/'.build') as tmp:
    work=Path(tmp);fields=[];aliases=[];values={};checks=[]
    for i in range(256):
     kind=list(KINDS)[i%10];member=f'v_{i}';key=f'field_{i}' if i<255 else 'p'*256
     fields.append({'member':member,'key':key,'kind':kind,'required':True,'source':i in (0,255)})
     aliases.append({'key':f'old_{i}','target':key})
     if kind=='Text': value=f'text{i}';check=f'settings.{member} == "text{i}"'
     elif kind=='Integer':value=i+1;check=f'settings.{member} == {i+1}'
     elif kind=='Float':value=i+.5;check=f'settings.{member} == {i+.5}'
     elif kind=='Boolean':value=(i//10)%2==0;check=f'settings.{member} == {str(value).lower()}'
     elif kind=='Duration':value=f'{i+1}ns';check=f'settings.{member}.nanoseconds == {i+1}'
     elif kind=='TextList':value=[f'text{i}',''];check=f'settings.{member}.len == 2';checks.append(f'for item,j in settings.{member} {{assert(item == (if j == 0 {{ "text{i}" }} else {{ "" }}));}}')
     elif kind=='IntegerList':value=[i+1,-i-1];check=f'settings.{member}.len == 2 && settings.{member}[0] == {i+1} && settings.{member}[1] == {-i-1}'
     elif kind=='FloatList':value=[i+.5,-i-.5];check=f'settings.{member}.len == 2 && settings.{member}[0] == {i+.5} && settings.{member}[1] == {-i-.5}'
     elif kind=='BooleanList':value=[True,False];check=f'settings.{member}.len == 2 && settings.{member}[0] && !settings.{member}[1]'
     else:value=[f'{i+1}ns','0s'];check=f'settings.{member}.len == 2 && settings.{member}[0].nanoseconds == {i+1} && settings.{member}[1].nanoseconds == 0'
     values[f'old_{i}']=value;checks.append('assert('+check+');')
     if i in (0,255):checks.append(f'assert(settings.{member}_source == "limit.json");')
    doc={'version':1,'namespace':'typed_limit','fields':fields,'aliases':aliases}
    (work/'typed_limit.goose').write_bytes(generate(json.dumps(doc).encode(),'../..',compiler))
    source='import config from "../..";\nimport config.json_layer;\nimport typed_limit;\nimport std;\nfn main(){var store=config::Store{..};var settings=typed_limit::Settings{..};let schema=typed_limit::schema();let aliases=typed_limit::aliases();assert(config::init(schema,store,aliases).len==0);assert(config::apply_json(store,'+json.dumps(json.dumps(values))+',"limit.json").len==0);assert(typed_limit::load(store,settings).len==0);assert(config::init([],store).len==0);\n'+'\n'.join(checks)+'\nprint("256fields/256aliases/all kinds/256byte key passed");}\n'
    (work/'main.goose').write_text(source)
    env={k:os.environ[k] for k in ('PATH','HOME') if k in os.environ};env.update(GOOSE_HOME=str(work/'goose-home'),LANG='C',TZ='UTC')
    record.update(compiler_version=run([compiler,'--version'],env,15)[0].strip(),compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),generated_sha256=hashlib.sha256((work/'typed_limit.goose').read_bytes()).hexdigest(),harness_sha256=hashlib.sha256((work/'main.goose').read_bytes()).hexdigest())
    record['jit_stdout']=run([compiler,'run',work/'main.goose'],env,120)[0]
    run([compiler,'build',work/'main.goose','--cc',a.cc,'-O2','-o',work/'native'],env,300)
    out,err=run([work/'native'],env,30)
    if err or out!='256fields/256aliases/all kinds/256byte key passed\n':raise RuntimeError('unexpected native output')
    record.update(completed=True,native_stdout=out,binary_sha256=hashlib.sha256((work/'native').read_bytes()).hexdigest())
    print(a.cc+': '+out.strip())
finally:
 if a.report:
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(record,indent=2)+'\n')
