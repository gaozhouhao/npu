#!/usr/bin/env python3
"""Run exact existing NPU RTL with a cycle-stepped independent C++ DDR driver."""
import argparse
import copy
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'scripts/model/run_graph_model.py').is_file())
sys.path.insert(0,str(ROOT/'scripts/model'))
import run_graph_model as runner


def require(ok,message):
    if not ok: raise ValueError(message)


def write_json(path,value):
    Path(path).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')


def safe_name(value):
    path=Path(value)
    require(not path.is_absolute() and '..' not in path.parts,'Unsafe source metadata path')
    return path


def prepare_reference(package,reference,output):
    runner.load_reference(package,reference)
    output.mkdir(parents=True,exist_ok=True)
    for name in ('reference.json','expected.bin','input.hex','layers.txt'):
        source=reference/name;target=output/name
        require(not target.exists() or target.read_bytes()==source.read_bytes(),'Existing reference differs: '+str(target))
        if not target.exists(): shutil.copyfile(str(source),str(target))
    return runner.load_reference(package,output)


def build(args,manifest,reference):
    directory=args.out/(args.label+'-rtl')
    require(not directory.exists(),'Run directory exists; use --run-only or choose a new label/output')
    original=json.loads(args.source_metadata.read_text())
    original_root=args.source_metadata.parent/'source'
    sources={}
    for name,expected in original['source_sha256'].items():
        if not name.endswith('.sv'): continue
        safe_name(name)
        data=(original_root/name).read_bytes()
        require(runner.sha256(data)==expected,'Frozen source hash differs: '+name)
        sources[name]=data
    require('sim/tb/system/graph_model_npu_tb.sv' in sources,'Missing common graph testbench')
    directory.mkdir(parents=True)
    source=directory/'source'
    for name,data in sources.items():
        target=source/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    old_listing=original_root/'rtl.f'
    if old_listing.exists(): (source/'rtl.f').write_bytes(old_listing.read_bytes())
    driver_data=args.driver.read_bytes()
    require(runner.sha256(driver_data)==args.driver_sha256,'C++ driver SHA256 differs from the frozen expected value')
    driver=source/'driver/graph_driver.cpp';driver.parent.mkdir(parents=True,exist_ok=True);driver.write_bytes(driver_data)
    tools=ROOT/'build/rollback-tools'
    compiler=tools/'bin/zig-cxx';verilator=tools/'bin/verilator'
    makeflags='CXX=%s LINK=%s AR=ar PYTHON3=%s CFG_CXXFLAGS_PCH_I=-include-pch CFG_GCH_IF_CLANG=.gch OPT_FAST=-O%d'%(compiler,compiler,ROOT/'build/resnet8-compat/runtime/bin/python',args.optimize)
    command=[str(verilator),'--cc','--exe','--build','--assert','--compiler','clang',
             '--build-jobs','1','--Mdir',str(directory/'obj'),
             '--top-module','npu_top','-Wno-fatal','+define+NPU_PERF_ENABLE',
             '-CFLAGS','-std=c++20 -O%d -pthread'%args.optimize,'-LDFLAGS','-pthread','-MAKEFLAGS',makeflags]
    excluded=[name for name in sorted(sources) if name.startswith('sim/') or (name.startswith('compat/') and name.endswith('_tb.sv'))]
    command.extend(str(source/name) for name in sorted(sources) if name not in excluded)
    command.append(str(driver))
    metadata=copy.deepcopy(original)
    metadata.update(status='BUILDING',simulator='Verilator with cycle-stepped C++ DDR driver',source_metadata_origin=str(args.source_metadata),
                    source_metadata_sha256=runner.file_hash(args.source_metadata),
                    driver_source_sha256=runner.sha256(driver_data),driver_source_path=str(driver),
                    driver_original_path=str(args.driver),driver_mode='cpp',optimization_level=args.optimize,
                    verilator_helper_sha256=runner.file_hash(Path(__file__)),
                    verilator_binary_sha256=runner.file_hash(tools/'python/verilator/bin/verilator_bin'),
                    compiler_binary_sha256=runner.file_hash(tools/'python/ziglang/zig'),
                    compiler_wrapper_sha256=runner.file_hash(compiler),
                    verilator_wrapper_sha256=runner.file_hash(verilator),
                    source_sha256=dict(original['source_sha256']),
                    excluded_verification_sources=excluded,
                    exclusion_reason='SV graph testbench/support replaced by independent cycle-stepped C++ DDR model; unrelated unit-test tops excluded; all original source bytes retained.',
                    compiled_source_sha256={name:runner.sha256(data) for name,data in sources.items() if name not in excluded},
                    command=command,read_latency_cycles=args.read_latency,
                    write_latency_cycles=args.write_latency,max_cycles=args.max_cycles,
                    package_sha256=reference['package_sha256'],reference_sha256=runner.file_hash(args.out/'reference.json'))
    write_json(directory/'source.json',metadata)
    started=time.monotonic()
    with (directory/'compile.log').open('w') as handle:
        result=subprocess.run(command,cwd=str(ROOT),stdout=handle,stderr=subprocess.STDOUT)
    metadata.update(status='BUILT' if result.returncode==0 else 'BUILD_FAILED',build_returncode=result.returncode,build_wall_seconds=time.monotonic()-started)
    write_json(directory/'source.json',metadata)
    require(result.returncode==0,'Verilator compilation failed: '+str(directory/'compile.log'))
    print('VERILATOR CPP BUILD PASS '+args.label,flush=True)


def run(args,manifest,reference):
    directory=args.out/(args.label+'-rtl');path=directory/'source.json'
    metadata=json.loads(path.read_text())
    require(metadata['status']=='BUILT','Run requires an unused successful build')
    for key,value in (('read_latency_cycles',args.read_latency),('write_latency_cycles',args.write_latency),('max_cycles',args.max_cycles),('optimization_level',args.optimize)):
        require(metadata[key]==value,'Run arguments differ from build metadata: '+key)
    require(metadata['verilator_helper_sha256']==runner.file_hash(Path(__file__)),'Helper changed after build')
    require(metadata['reference_sha256']==runner.file_hash(args.out/'reference.json'),'Reference changed after build')
    for name,expected in metadata['source_sha256'].items():
        if name.endswith('.sv'):
            require(runner.file_hash(directory/'source'/name)==expected,'Compiled source changed: '+name)
    require(runner.file_hash(Path(metadata['driver_source_path']))==metadata['driver_source_sha256'],'C++ driver changed after build')
    count=args.prefix_layers or manifest['descriptor_count']
    require(0<count<=manifest['descriptor_count'],'Invalid prefix layer count')
    is_prefix=count<manifest['descriptor_count']
    layers=reference['layers'][:count]
    checks=args.out/'layers.txt'
    if is_prefix:
        checks=directory/'prefix-layers.txt'
        checks.write_text(''.join((args.out/'layers.txt').read_text().splitlines(keepends=True)[:count]))
    last=layers[-1]
    command=[str(directory/'obj/Vnpu_top'),'+DDR_HEX='+str(args.out/'input.hex'),
             '+IMAGE_WORDS=%d'%(manifest['image_bytes']//4),'+DESC_BASE=%x'%manifest['descriptor_base'],
             '+DESC_COUNT=%d'%count,'+LOGITS_BASE=%x'%last['address'],
             '+LOGITS_COUNT=%d'%last['logical_bytes'],'+MAX_CYCLES=%d'%args.max_cycles,
             '+DDR_RD_LATENCY=%d'%args.read_latency,'+DDR_WR_LATENCY=%d'%args.write_latency,
             '+LAYER_CHECKS='+str(checks),'+DDR_DUMP='+str(directory/'ddr.hex')]
    metadata.update(status='RUNNING',run_command=command,prefix_layers=count if is_prefix else None,
                    complete_network=not is_prefix)
    write_json(path,metadata);started=time.monotonic()
    with (directory/'simulation.log').open('w') as handle:
        result=subprocess.run(command,cwd=str(ROOT),stdout=handle,stderr=subprocess.STDOUT)
    metadata.update(status='FINISHED' if result.returncode==0 else 'FAILED',returncode=result.returncode,simulation_wall_seconds=time.monotonic()-started)
    write_json(path,metadata)
    require(result.returncode==0,'Verilator simulation failed: '+str(directory/'simulation.log'))
    if not is_prefix:
        report=runner.check(args.package,args.out,args.label,args.read_latency,args.write_latency)
    else:
        partial=copy.deepcopy(reference);partial['descriptor_count']=count;partial['layers']=layers
        for metric in ('nominal_macs','useful_macs'):partial[metric]=sum(layer[metric] for layer in layers)
        summary,rows=runner.parse_perf(directory/'simulation.log',partial,args.read_latency,args.write_latency)
        expected=bytearray((args.package/'ddr.bin').read_bytes())
        for layer in layers:
            payload=runner.read_dump(layer['expected_hex'])[:layer['logical_bytes']]
            expected[layer['address']:layer['address']+len(payload)]=payload
        actual=runner.read_dump(directory/'ddr.hex');require(actual==expected,'Prefix full DDR differs')
        report=dict(status='PREFIX_PASS',complete_network=False,checked_layers=count,summary=summary,layers=rows,
                    full_ddr_sha256=runner.sha256(actual),checked_full_ddr_bytes=len(actual),source=metadata)
        write_json(args.out/(args.label+'-prefix-report.json'),report)
    if args.compare_report:
        old=json.loads(args.compare_report.read_text())
        require(old['status']==report['status'],'Comparison scope/status differs')
        require(old['full_ddr_sha256']==report['full_ddr_sha256'],'Comparison DDR SHA differs')
        for key in ('total_cycles','read_bytes','write_bytes','read_beats','write_beats','read_transactions','write_transactions'):
            require(old['summary'][key]==report['summary'][key],'Simulator counter differs: '+key)
        require(len(old['layers'])==len(report['layers']),'Simulator layer count differs')
        for a,b in zip(old['layers'],report['layers']):
            for key in ('index','cycles','executor_cycles','pool_cycles','read_bytes','write_bytes'):
                require(a[key]==b[key],'Simulator layer counter differs: layer%d %s'%(a['index'],key))
        write_json(args.out/(args.label+'-cross-simulator.json'),dict(status='PASS',same_cycles_bytes_all_layers_and_ddr=True,
                   reference_report=str(args.compare_report),reference_report_sha256=runner.file_hash(args.compare_report),
                   compared_report=str(args.out/(args.label+'-report.json')),summary=report['summary'],full_ddr_sha256=report['full_ddr_sha256']))
        print('CROSS SIMULATOR EXACT PASS '+args.label,flush=True)
    return report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-metadata',type=Path,required=True)
    p.add_argument('--driver',type=Path,default=Path(__file__).resolve().parent/'rollback_compat/graph_driver.cpp')
    p.add_argument('--driver-sha256',required=True)
    p.add_argument('--optimize',type=int,choices=(2,3),default=3)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--label',required=True)
    p.add_argument('--max-cycles',type=int,default=200000000000)
    p.add_argument('--read-latency',type=int,default=20)
    p.add_argument('--write-latency',type=int,default=0)
    p.add_argument('--prefix-layers',type=int,default=0)
    p.add_argument('--compare-report',type=Path)
    mode=p.add_mutually_exclusive_group();mode.add_argument('--build-only',action='store_true');mode.add_argument('--run-only',action='store_true')
    args=p.parse_args()
    for name in ('source_metadata','package','reference','out','driver'):
        setattr(args,name,getattr(args,name).resolve())
    if args.compare_report:args.compare_report=args.compare_report.resolve()
    require(re.fullmatch(r'[A-Za-z0-9_-]+',args.label) is not None,'Invalid label')
    manifest,reference=prepare_reference(args.package,args.reference,args.out)
    if not args.run_only:build(args,manifest,reference)
    if not args.build_only:run(args,manifest,reference)


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as error:
        sys.exit('VERILATOR GRAPH FAILED: '+str(error))
