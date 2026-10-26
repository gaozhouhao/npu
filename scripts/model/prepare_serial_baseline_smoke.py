#!/usr/bin/env python3
from pathlib import Path
import argparse,sys,json,hashlib,struct
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description='Prepare the fixed nonzero K288 serial-control validation graph.')
p.add_argument('--package',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
args=p.parse_args()
for target in (args.package,args.out):
    if target.exists() or target.is_symlink():
        raise SystemExit('Refusing existing destination: '+str(target))
if args.package.resolve()==args.out.resolve():
    raise SystemExit('Package and reference directories must differ')
sys.path.insert(0,str(root/'compiler'))
sys.path.insert(0,str(root/'scripts/model'))
from graph_compiler import compile_graph,write_package,benchmark_quantization
from target import hardware_defaults
from run_graph_model import prepare
class SeededGraph(dict):
    def load_weights(self,node):
        n,k=node['weights']['shape']
        return [(((channel*3+index*2)%11)-5)*(channel%4+1)*0.0075
                for channel in range(n) for index in range(k)]
    def load_tensor(self,name):
        size=32 if name=='conv.b' else 1001
        return [(i%9-4)*0.013 for i in range(size)]
nodes=[dict(name='conv',op='Conv',inputs=['input'],output='conv',shape=[7,7,32],
            attrs=dict(kernel=[3,3],strides=[1,1],pads=[1,1,1,1]),
            weights=dict(name='conv.w',shape=[32,288]),bias=dict(name='conv.b',shape=[32])),
       dict(name='residual',op='Add',inputs=['conv','input'],output='residual',shape=[7,7,32]),
       dict(name='pool',op='MaxPool',inputs=['residual'],output='pool',shape=[4,4,32],
            attrs=dict(kernel=[3,3],strides=[2,2],pads=[1,1,1,1])),
       dict(name='gap',op='GlobalAveragePool',inputs=['pool'],output='gap',shape=[1,1,32]),
       dict(name='fc',op='FullyConnected',inputs=['gap'],output='logits',shape=[1001],
            weights=dict(name='fc.w',shape=[1001,32]),bias=dict(name='fc.b',shape=[1001]))]
graph=SeededGraph(input=dict(name='input',shape=[7,7,32]),nodes=nodes,output='logits',
                  source='deterministic historical compatibility smoke fixture')
profile=benchmark_quantization(graph)
cfg=hardware_defaults()
cfg.update(ddr_capacity_bytes=1024*1024,ddr_base=0,alignment_bytes=8,activation_layout='HWC')
seed=8;values=[]
for i in range(1568):
    seed=(1664525*seed+1013904223)&0xffffffff
    value=((seed>>24)%255)-127
    values.append((value if value else 1)&255)
inputs=bytes(values)
plan,image,descriptors=compile_graph(graph,cfg,profile,inputs,benchmark_only=True)
out=args.package.resolve()
check=args.out.resolve()
write_package(str(out),plan,image,descriptors)
reference=prepare(out,check)
assert reference['status']=='PASS' and reference['descriptor_count']==5
assert plan['commands'][0]['k']==288
assert plan['commands'][0]['m']==49 and plan['commands'][-1]['m']==1 and plan['commands'][-1]['n']==1001
assert plan['commands'][0]['flags']&8 and plan['commands'][-1]['flags']&8
summary=dict(status='PASS',purpose='integer_performance',calibrated=False,dataset_accuracy_measured=False,
             input_generator='LCG seed8; signed nonzero INT8',input_sha256=hashlib.sha256(inputs).hexdigest(),
             descriptor_count=5,image_bytes=len(image),pool_padding=[1,1,1,1],
             expected_sha256=reference['expected_sha256'],
             package_sha256=reference['package_sha256'],
             nodes=[dict(index=i,op=n['op'],shape=n['shape'],flags=plan['commands'][i]['flags']) for i,n in enumerate(nodes)])
(out/'generation.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
