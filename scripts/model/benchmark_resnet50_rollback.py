#!/usr/bin/env python3
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'scripts/model'))
import run_graph_model as runner
ROOT_OUT=root/'build/resnet50-rollback-compare'
REFS={'legacy00':'00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47','legacy46':'46f756efffccfb9da44fd255661507afca353c05'}
def sha(b):return hashlib.sha256(b).hexdigest()
def snapshot(directory,source_ref):
 variant=args.variant; source=Path(directory)/'source';source.mkdir(parents=True,exist_ok=True)
 paths={}
 for path in sorted((ROOT_OUT/variant/'source/rtl').rglob('*.sv')): paths[str(path.relative_to(ROOT_OUT/variant/'source'))]=path
 for path in sorted((ROOT_OUT/'compat').glob('*.sv')):paths['compat/'+path.name]=path
 rtl=[]; hashes={}
 for name,path in paths.items():
  target=source/name;target.parent.mkdir(parents=True,exist_ok=True);data=path.read_bytes();target.write_bytes(data);hashes[name]=sha(data);rtl.append(str(target))
 tbname='sim/tb/system/graph_model_npu_tb.sv'; shared=[tbname]+[str(p.relative_to(root)) for p in sorted((root/'sim/tb/support').glob('*.sv'))]; support=[]
 for name in shared:
  target=source/name;target.parent.mkdir(parents=True,exist_ok=True);data=(root/name).read_bytes();target.write_bytes(data);hashes[name]=sha(data);support.append(str(target))
 listing='\n'.join(paths)+'\n';(source/'rtl.f').write_text(listing);hashes['sim/filelists/rtl.f']=sha(listing.encode())
 metadata=dict(source_ref=REFS[variant],resolved_commit=REFS[variant],source_sha256=hashes,source_set_sha256=sha(json.dumps(hashes,sort_keys=True).encode()),runner_sha256=runner.file_hash(Path(runner.__file__)),makefile_sha256=runner.file_hash(root/'Makefile'),rollback_runner_sha256=sha(Path(__file__).read_bytes()),functional_compatibility=True,variant=variant,common_external_read_bits=64,legacy_internal_operand_bits=32,compatibility_note='Historical GEMM/scheduler/read path retained; shared descriptor/AXI64 shell plus exact declared functional perchannel/pool/tail compatibility patches. No host execution.')
 return rtl,support[0],support[1:],metadata
p=argparse.ArgumentParser(description='Run a genuine historical RTL snapshot with declared functional compatibility patches.');p.add_argument('--snapshots',type=Path,default=ROOT_OUT);p.add_argument('--variant',choices=REFS,required=True);p.add_argument('--package',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--max-cycles',type=int,default=200000000000);p.add_argument('--read-latency',type=int,default=20);p.add_argument('--check-only',action='store_true');args=p.parse_args()
ROOT_OUT=args.snapshots.resolve()
if not args.check_only:
 runner.snapshot_sources=snapshot
 runner.run_rtl(args.package,args.out,label=args.variant,source_ref=REFS[args.variant],read_latency=args.read_latency,max_cycles=args.max_cycles)
runner.check(args.package,args.out,label=args.variant,read_latency=args.read_latency)
print('HISTORICAL ROLLBACK PASS',args.variant,flush=True)
