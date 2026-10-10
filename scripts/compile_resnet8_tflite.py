#!/usr/bin/env python3
"""Compile a supported quantized TFLite ResNet-8 graph for NPU V1.

Requires: pip install numpy tflite
Artifacts: ddr.bin, ddr.hex, descriptors.bin, manifest.json.

Ops supported: CONV_2D, ADD, AVERAGE_POOL_2D (global only),
FULLY_CONNECTED, RESHAPE (alias), SOFTMAX (argmax bypass).
Only NONE and RELU fused activation are supported.

Real TFLite uses different integer rounding from this NPU V1. This is an
initial hardware-execution compiler, NOT a bit-exact TFLite converter.
"""
import argparse
import json
import math
import struct
from pathlib import Path

import numpy as np

try:
    import tflite
except ImportError as exc:
    raise SystemExit('Install flatbuffer bindings: pip install tflite') from exc

OP_GEMM, OP_CONV, OP_AVG, OP_ADD = 1, 2, 4, 5
DESC_WORDS = 16

def align(v, a):
    return ((v + a - 1) // a) * a

def words(*items):
    return b''.join(struct.pack('<I', int(v) & 0xffffffff) for v in items)

def qscale(t):
    q = t.Quantization()
    if q is None:
        return [], []
    scales = [float(q.Scale(i)) for i in range(q.ScaleLength())]
    zp = [int(q.ZeroPoint(i)) for i in range(q.ZeroPointLength())]
    return scales, zp

def scale_1(t):
    s,z = qscale(t)
    if len(s) != 1 or len(z) != 1:
        raise ValueError(f'Activation requires per-tensor scale/ZP: {t.Name()}')
    return s[0], z[0]

def tensor_shape(t):
    return [int(t.Shape(i)) for i in range(t.ShapeLength())]

def quant_mr(ratio):
    """Choose maximum safe fixed-point precision.

    Hardware:
      signed 33-bit adjusted accumulator
      positive 31-bit multiplier
      signed 64-bit product and rounding
      6-bit right shift
    """
    if ratio < 0 or not math.isfinite(ratio):
        raise ValueError(f'Invalid scale ratio: {ratio}')

    if ratio == 0:
        return 0, 0

    max_multiplier = (1 << 31) - 1
    max_int64 = (1 << 63) - 1
    max_acc = (1 << 32) - 1

    for shift in range(62, -1, -1):
        m = round(ratio * (1 << shift))

        if m < 0 or m > max_multiplier:
            continue

        rounding_offset = (1 << (shift - 1)) if shift else 0

        # Conservative bound including rounding addition.
        if max_acc * m + rounding_offset > max_int64:
            continue

        return int(m), int(shift)

    raise ValueError(
        f'No safe fixed-point representation for ratio={ratio}'
    )

def options(op, cls):
    tab = op.BuiltinOptions()
    if tab is None:
        raise ValueError(f'Missing options: {cls}')
    obj = cls()
    obj.Init(tab.Bytes, tab.Pos)
    return obj

def fused_relu(op, cls):
    act = int(options(op, cls).FusedActivationFunction())
    if act not in (0, 1):
        raise NotImplementedError(f'Fused activation {act} (only NONE/RELU supported)')
    return act == 1

class DDR:
    def __init__(self):
        self.raw = bytearray(0x10000)  # leave room for MMIO/boot regions
        self.cursor = 0x10000
    def put(self, b, boundary=64):
        b = bytes(b)
        start = align(self.cursor, boundary)
        end = start + len(b)
        if end > len(self.raw):
            self.raw.extend(b'\0' * (end - len(self.raw)))
        self.raw[start:end] = b
        self.cursor = end
        return start
    def reserve(self, nbytes, boundary=64):
        return self.put(b'\0'*align(nbytes, 4), boundary)

class Compiler:
    def __init__(self, blob):
        self.model = tflite.Model.GetRootAsModel(bytearray(blob),0)
        if self.model.SubgraphsLength() != 1:
            raise ValueError('Only single-subgraph models supported')
        self.graph = self.model.Subgraphs(0)
        self.tensors = [self.graph.Tensors(i) for i in range(self.graph.TensorsLength())]
        self.mem = DDR()
        self.address = {}
        self.desc = []
        self.layers = []
        self.input_tid = int(self.graph.Inputs(0))
        self.input_tensor = self.tensors[self.input_tid]
        self.input_shape = tensor_shape(self.input_tensor)
        if len(self.input_shape) != 4 or self.input_shape[0] != 1:
            raise ValueError('Expected NHWC batch-1 input')
        _, input_zp = scale_1(self.input_tensor)
        input_length = int(np.prod(self.input_shape))
        # Input image defaults to represent real zero (not integer zero).
        self.address[self.input_tid] = self.mem.put(bytes([input_zp & 0xff])*input_length)
        self.logits_tid = None
    def tensor_array(self, idx, dtype):
        t = self.tensors[idx]
        buf = self.model.Buffers(t.Buffer())
        raw = bytes(int(buf.Data(i)) for i in range(buf.DataLength()))
        expected = int(np.prod(tensor_shape(t))) * np.dtype(dtype).itemsize
        if len(raw) != expected:
            raise ValueError(f'Tensor data length mismatch: tensor {idx}, {len(raw)} != {expected}')
        return np.frombuffer(raw,dtype=dtype).reshape(tensor_shape(t))
    def output_addr(self, tid):
        if tid in self.address:
            raise ValueError(f'Output tensor {tid} already allocated')
        t = self.tensors[tid]
        actual_bytes = int(np.prod(tensor_shape(t)))
        addr = self.mem.reserve(align(actual_bytes,4))
        self.address[tid] = addr
        return addr
    def encode(self, opcode, flags=0, m=0,n=0,k=0,a=0,b=0,c=0, sa=0,sb=0,sc=0,param=0):
        if any(int(z) > 0xffffffff or int(z)<0 for z in [a,b,c,param]):
            raise ValueError('Address beyond 32-bit range')
        desc = [0]*DESC_WORDS
        desc[0] = (int(flags)<<8)|int(opcode)
        desc[1:4] = [int(m),int(n),int(k)]
        desc[4:6] = [a & 0xffffffff,a >> 32]
        desc[6:8] = [b & 0xffffffff,b >> 32]
        desc[8:10] = [c & 0xffffffff,c >> 32]
        desc[10:13] = [int(sa),int(sb),int(sc)]
        desc[13:15] = [param & 0xffffffff, param >> 32]
        self.desc.append(desc)
    def compile_conv_or_fc(self, op, kind):
        ids = [int(op.Inputs(i)) for i in range(op.InputsLength())]
        output_id = int(op.Outputs(0))
        src,w_id = ids[:2]
        bias_id = ids[2] if len(ids)>2 else -1
        tx,tw,ty = (self.tensors[i] for i in [src,w_id,output_id])
        input_scale,input_zp = scale_1(tx)
        out_scale,out_zp = scale_1(ty)
        weight = self.tensor_array(w_id,np.int8)
        if kind=='conv':
            ish,osh = tensor_shape(tx),tensor_shape(ty)
            ws = tensor_shape(tw)
            if len(ish)!=4 or len(osh)!=4 or len(ws)!=4:
                raise ValueError('Bad CONV shapes')
            _,hin,win,cin = ish
            _,hout,wout,cout = osh
            wo,kh,kw,wcin=ws
            if wo != cout or wcin != cin:
                raise ValueError('CONV weight shape inconsistent')
            opts=options(op,tflite.Conv2DOptions)
            sh,sw=int(opts.StrideH()),int(opts.StrideW())
            padtype=int(opts.Padding())
            same=(padtype == int(tflite.Padding.SAME))
            if padtype not in (int(tflite.Padding.SAME), int(tflite.Padding.VALID)):
                raise ValueError('Unknown Conv padding')
            if sh not in (1,2) or sw not in (1,2):
                raise ValueError('Hardware supports stride 1/2')
            pad_h=max(0,(hout-1)*sh+kh-hin) if same else 0
            pad_w=max(0,(wout-1)*sw+kw-win) if same else 0
            pt,pl=pad_h//2,pad_w//2
            if any(v>=256 for v in [kh,kw,sh,sw,pt,pl]) or cin>=65536:
                raise ValueError('Conv descriptor geometry overflow')
            m=hout*wout
            n=cout
            k=kh*kw*cin
            flags=1|2|8|(16 if same else 0)
            if fused_relu(op,tflite.Conv2DOptions):
                flags|=4
            sa=(win<<16)|hin
            sb=(kw<<24)|(kh<<16)|cin
            sc=(pl<<24)|(pt<<16)|(sw<<8)|sh
            opcode=OP_CONV
        else:
            ws=tensor_shape(tw)
            if len(ws)!=2 or len(tensor_shape(tx))<2:
                raise ValueError('Unexpected FC dimensions')
            n=int(ws[0]);k=int(ws[1]);m=1
            if int(np.prod(tensor_shape(tx)))!=k:
                raise ValueError('FC K inconsistent')
            flags=1|2|8
            if fused_relu(op,tflite.FullyConnectedOptions):
                flags |=4
            sa=align(k,4);sb=align(k,4);sc=align(n,4)
            opcode=OP_GEMM
        if m%4!=0 and kind=='conv':
            raise ValueError('CONV output positions must multiple of 4')
        sweight,zweight=qscale(tw)
        if any(z!=0 for z in zweight):
            raise ValueError('Only symmetric int8 weights supported')
        if len(sweight) not in (1,n):
            raise ValueError(f'Unexpected per-channel scales count {len(sweight)}')
        if bias_id>=0:
            bias=self.tensor_array(bias_id,np.int32).reshape(-1).astype(np.int64)
            if bias.size!=n:
                raise ValueError('Bias channels mismatch')
        else:
            bias=np.zeros(n,dtype=np.int64)
        qweights=weight.reshape(n,k).astype(np.int64)
        # Centering correction includes padding bytes set to input ZP.
        folded_bias=bias-int(input_zp)*qweights.sum(axis=1)
        if np.any((folded_bias < -2147483648)|(folded_bias > 2147483647)):
            raise OverflowError('Folded INT32 bias overflow')
        padded_n=align(n,4)
        row_stride=align(k,4)
        weightbuf=bytearray(padded_n*row_stride)
        for c in range(n):
            row=weight.reshape(n,k)[c].tobytes()
            weightbuf[c*row_stride:c*row_stride+k]=row
        baddr=self.mem.put(weightbuf)
        parambuf=bytearray(words(0,0,input_zp,out_zp))
        for c in range(padded_n):
            if c<n:
                r=input_scale*sweight[c if len(sweight)>1 else 0]/out_scale
                mul,shift=quant_mr(r)
                biasc=int(folded_bias[c])
            else:
                mul,shift,biasc=0,0,0
            parambuf+=words(biasc,mul,shift)
        paddr=self.mem.put(parambuf)
        caddr=self.output_addr(output_id)
        self.encode(opcode,flags,m,padded_n,k,self.address[src],baddr,caddr,sa,sb,sc,paddr)
        self.layers.append({'opcode':kind.upper(),'input':src,'output':output_id,
                            'shape':tensor_shape(ty),'a':self.address[src],
                            'b':baddr,'c':caddr,'params':paddr,'flags':flags,
                            'input_zp':input_zp,'output_zp':out_zp})
    def compile_add(self,op):
        a,b=int(op.Inputs(0)),int(op.Inputs(1))
        out=int(op.Outputs(0))
        ta,tb,to=(self.tensors[i] for i in (a,b,out))
        if tensor_shape(ta)!=tensor_shape(tb) or tensor_shape(ta)!=tensor_shape(to):
            raise ValueError('No broadcasting supported for ResidualAdd')
        sa,za=scale_1(ta);sb,zb=scale_1(tb);so,zo=scale_1(to)
        ra,rb=sa/so,sb/so

        if not all(math.isfinite(r) and r >= 0 for r in (ra, rb)):
            raise ValueError('Invalid ResidualAdd scale ratio')

        max_multiplier = (1 << 31) - 1
        max_int64 = (1 << 63) - 1

        # Each centered INT8 operand is at most 255 in magnitude.
        max_centered = 255

        for shift in range(62, -1, -1):
            ma = round(ra * (1 << shift))
            mb = round(rb * (1 << shift))

            if not (0 <= ma <= max_multiplier and
                    0 <= mb <= max_multiplier):
                continue

            rounding_offset = (1 << (shift - 1)) if shift else 0

            max_product = max_centered * (ma + mb)

            if max_product + rounding_offset > max_int64:
                continue

            break
        else:
            raise ValueError(
                'No safe ResidualAdd fixed-point representation'
            )
        parambuf=words(za,zb,zo,ma,mb,shift)
        paddr=self.mem.put(parambuf)
        caddr=self.output_addr(out)
        elements=int(np.prod(tensor_shape(to)))
        if elements%4:
            raise ValueError('ResidualAdd tensor elements must be multiple 4')
        flags=1 if fused_relu(op,tflite.AddOptions) else 0
        self.encode(OP_ADD,flags,elements,0,0,self.address[a],self.address[b],caddr,0,0,0,paddr)
        self.layers.append({'opcode':'ADD','input_a':a,'input_b':b,
                            'output':out,'shape':tensor_shape(to),
                            'a':self.address[a],'b':self.address[b],
                            'c':caddr,'params':paddr,'flags':flags})
    def compile_average(self,op):
        src=int(op.Inputs(0));out=int(op.Outputs(0))
        tx,ty=self.tensors[src],self.tensors[out]
        shape=tensor_shape(tx);shape_out=tensor_shape(ty)
        if len(shape)!=4 or len(shape_out)!=4 or shape_out[:3]!=[1,1,1]:
            raise ValueError('Only global average pool supported')
        if scale_1(tx)!=scale_1(ty):
            raise ValueError('TFLite AVG scales/zero points must match')
        _,h,w,c=shape
        if c%4:
            raise ValueError('Global avg channels not multiple 4')
        caddr=self.output_addr(out)
        self.encode(OP_AVG,0,h,w,c,self.address[src],0,caddr)
        self.layers.append({'opcode':'GLOBAL_AVG','input':src,'output':out,
                            'shape':shape_out,'a':self.address[src],'c':caddr})
    def compile(self):
        enum = tflite.BuiltinOperator
        codes={enum.CONV_2D:'conv',enum.ADD:'add',
               enum.AVERAGE_POOL_2D:'avg',enum.FULLY_CONNECTED:'fc',
               enum.RESHAPE:'reshape',enum.SOFTMAX:'softmax'}
        for i in range(self.graph.OperatorsLength()):
            op=self.graph.Operators(i)
            code=int(self.model.OperatorCodes(op.OpcodeIndex()).BuiltinCode())
            name=codes.get(code)
            if name is None:
                raise NotImplementedError(f'Unsupported TFLite operator: index={i} code={code}')
            if name in ('conv','fc'):
                self.compile_conv_or_fc(op,name)
            elif name=='add':
                self.compile_add(op)
            elif name=='avg':
                self.compile_average(op)
            elif name=='reshape':
                a=int(op.Inputs(0));b=int(op.Outputs(0))
                if int(np.prod(tensor_shape(self.tensors[a]))) != int(np.prod(tensor_shape(self.tensors[b]))):
                    raise ValueError('Reshape element count changed')
                self.address[b]=self.address[a]
                self.layers.append({'opcode':'RESHAPE_ALIAS','input':a,'output':b})
            else:  # SOFTMAX argmax is same as logits argmax
                self.logits_tid=int(op.Inputs(0))
                self.layers.append({'opcode':'SOFTMAX_BYPASS_ARGMAX',
                                    'input':self.logits_tid,'output':int(op.Outputs(0))})
        if self.logits_tid is None:
            self.logits_tid=int(self.graph.Outputs(0))
    def save(self,outdir):
        outdir.mkdir(parents=True,exist_ok=True)
        descbytes=b''.join(words(*d) for d in self.desc)
        daddr=self.mem.put(descbytes)
        (outdir/'ddr.bin').write_bytes(self.mem.raw)
        (outdir/'descriptors.bin').write_bytes(descbytes)
        # Hex format for existing 32-bit word model.
        raw=self.mem.raw
        raw+=b'\0'*(align(len(raw),4)-len(raw))
        (outdir/'ddr.hex').write_text(''.join(f'{int.from_bytes(raw[i:i+4],"little"):08x}\n'
                                              for i in range(0,len(raw),4)))
        manifest={'model':'MLPerf Tiny pretrainedResnet_quant.tflite',
                  'input_shape':self.input_shape,'input_scale_zp':scale_1(self.input_tensor),
                  'input_addr':self.address[self.input_tid],
                  'descriptor_addr':daddr,'descriptor_count':len(self.desc),
                  'logits_addr':self.address[self.logits_tid],
                  'logits_shape':tensor_shape(self.tensors[self.logits_tid]),
                  'memory_size':len(raw),'layers':self.layers}
        (outdir/'manifest.json').write_text(json.dumps(manifest,indent=2))
        print(json.dumps({k:v for k,v in manifest.items() if k!='layers'},indent=2))
        print(f'Compiled {len(self.desc)} hardware descriptors; output: {outdir}')

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('model',type=Path)
    ap.add_argument('--output',type=Path,default=Path('build/resnet8_model'))
    ap.add_argument('--input-npy',type=Path,help='Optional CIFAR-10 32x32x3 input, uint8 or quantized int8')
    ns=ap.parse_args()
    compiler=Compiler(ns.model.read_bytes())
    if ns.input_npy is not None:
        raw = np.load(ns.input_npy)
        if raw.shape == tuple(compiler.input_shape):
            raw = raw.reshape(compiler.input_shape[1:])
        if raw.shape != tuple(compiler.input_shape[1:]):
            raise ValueError(f'Input shape {raw.shape} != {compiler.input_shape[1:]}')
        if raw.dtype == np.int8:
            q = raw
        elif raw.dtype == np.uint8:
            scale,zp = scale_1(compiler.input_tensor)
            q = np.clip(np.rint(raw.astype(np.float64)/scale+zp), -128,127).astype(np.int8)
        else:
            raise ValueError('Input dtype must be uint8 image or quantized int8')
        addr = compiler.address[compiler.input_tid]
        compiler.mem.raw[addr:addr+q.size] = q.tobytes()
    compiler.compile()
    compiler.save(ns.output)
