#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Diagnostic only: count gs_memcpy work and sample CPU Atom counters at the
existing frozen harness timer boundaries. Never compare these timings to stock.
"""
import argparse, atexit, hashlib, json, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--workdir',type=Path,default=Path('.build/fallback-reproduction'));p.add_argument('--build-cpu',type=int,default=6);args=p.parse_args();W=args.workdir.resolve()
lock=W/'.active.lock'
try:
    descriptor=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
except FileExistsError:
    raise SystemExit('workdir is active or has a stale lock; use a distinct workdir')
os.write(descriptor,str(os.getpid()).encode());os.close(descriptor)
atexit.register(lambda: lock.unlink(missing_ok=True))
manifest=json.loads((W/'manifest.json').read_text())
for label, snapshot in manifest['snapshots'].items():
    for name, expected in snapshot['source_sha256'].items():
        if hashlib.sha256((W/label/name).read_bytes()).hexdigest()!=expected:
            raise SystemExit('snapshot hash mismatch')
(W/'instrumentation-manifest.json').unlink(missing_ok=True)
header='''
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
static unsigned long long fc_bytes, fc_calls;
static int fc_cyc=-1, fc_ins=-1, fc_tick;
static unsigned long long fc_start_bytes,fc_start_calls;
static unsigned long long fc_start_enabled,fc_start_running;
static int fc_open(unsigned long long config,int leader) {
    struct perf_event_attr attr={0};
    attr.type=10; attr.size=sizeof(attr); attr.config=config;
    attr.disabled=(leader<0); attr.pinned=(leader<0);
    attr.exclude_kernel=1; attr.exclude_hv=1;
    attr.read_format=PERF_FORMAT_GROUP|PERF_FORMAT_TOTAL_TIME_ENABLED|PERF_FORMAT_TOTAL_TIME_RUNNING;
    int fd=(int)syscall(__NR_perf_event_open,&attr,0,-1,leader,0);
    if(fd<0){perror("perf_event_open");exit(2);} return fd;
}
static void fc_ioctl(unsigned long request) {
    if(ioctl(fc_cyc,request,PERF_IOC_FLAG_GROUP)<0){perror("perf ioctl");exit(3);}
}
static void fc_read(unsigned long long data[5]) {
    if(read(fc_cyc,data,5*sizeof(*data))!=5*sizeof(*data)||data[0]!=2){
        fprintf(stderr,"invalid pinned PMU group read\\n");exit(3);
    }
}
'''
helper='''
static int64_t fc_clock(void) {
    if(fc_cyc<0){fc_cyc=fc_open(0x3c,-1);fc_ins=fc_open(0xc0,fc_cyc);}
    if((fc_tick&1)==0){
        unsigned long long data[5];
        fc_start_bytes=fc_bytes;fc_start_calls=fc_calls;
        fc_ioctl(PERF_EVENT_IOC_RESET);fc_read(data);
        fc_start_enabled=data[1];fc_start_running=data[2];
        fc_ioctl(PERF_EVENT_IOC_ENABLE);
    }else{
        unsigned long long data[5],enabled,running;
        fc_ioctl(PERF_EVENT_IOC_DISABLE);fc_read(data);
        if(data[1]<fc_start_enabled||data[2]<fc_start_running)exit(3);
        enabled=data[1]-fc_start_enabled;running=data[2]-fc_start_running;
        if(!enabled||enabled!=running){fprintf(stderr,"incomplete PMU coverage\\n");exit(3);}
        fprintf(stderr,"FC sample=%d bytes=%llu calls=%llu cycles=%llu instructions=%llu enabled=%llu running=%llu\\n",
            fc_tick/2,fc_bytes-fc_start_bytes,fc_calls-fc_start_calls,data[3],data[4],enabled,running);
    }
    fc_tick++;return gs_os_clock_ns();
}
'''
objects=list((W/'goose-home/build/runtime').rglob('goose_runtime.o'))
if len(objects) != 1: raise SystemExit('use a fresh prepared workdir with one runtime object')
runtime=objects[0]
manifest['instrumentation']={'kind':'generated C only; gs_memcpy logical byte/call count, per-timed-sample PMU',
 'pmu_type':10,'cycles_config':'0x3c','instructions_config':'0xc0',
 'excluded_kernel':True,'excluded_hypervisor':True,'pinned_group':True,
 'coverage_policy':'per-sample enabled_ns must equal running_ns and be positive; no scaling',
 'runtime_object':str(runtime),
 'runtime_object_sha256':hashlib.sha256(runtime.read_bytes()).hexdigest(),'snapshots':{}}
for label in ['baseline','candidate','candidate-copy']:
    original=next(p for p in (W/'goose-home/build/prog').rglob('bench.c')
                  if str(W/label/'bench/bench.goose')+'.' in p.read_text().splitlines()[0])
    source=original.read_text()
    (W/label/'stock-generated.c').write_text(source)
    source=source.replace('static void gs_memcpy(void *dst, const void *src, size_t n) {',
        header+'\nstatic void gs_memcpy(void *dst, const void *src, size_t n) {\n    fc_bytes+=n; fc_calls++;')
    marker='GS_API int64_t gs_os_clock_ns(void);'
    assert source.count(marker)==1 and source.count('= gs_os_clock_ns();')==2
    source=source.replace(marker,marker+'\n'+helper).replace('= gs_os_clock_ns();','= fc_clock();')
    out=W/label/'instrumented.c';out.write_text(source)
    argv=['taskset','-c',str(args.build_cpu),'gcc','-O2',str(out),str(runtime),'-lm','-pthread','-ldl','-o',str(W/label/'instrumented')]
    subprocess.run(argv,check=True,capture_output=True,timeout=120)
    manifest['instrumentation']['snapshots'][label]={'argv':argv,
        'original_c_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),
        'instrumented_c_sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
        'binary_sha256':hashlib.sha256((W/label/'instrumented').read_bytes()).hexdigest()}
def portable(value):
    if isinstance(value,dict): return {k:portable(v) for k,v in value.items()}
    if isinstance(value,list): return [portable(v) for v in value]
    if isinstance(value,str): return value.replace(str(W),'<ARTIFACTS>')
    return value
temporary=W/'.instrumentation-manifest.tmp'
temporary.write_text(json.dumps(portable(manifest),indent=2,allow_nan=False)+'\n')
temporary.replace(W/'instrumentation-manifest.json')
print('Built three diagnostic-only instrumented copies from exact frozen-harness generated C.')
