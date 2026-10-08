"""Functional DDR/descriptor interpreter. Does NOT simulate RTL cycles."""
import argparse
import json
import struct
import sys
from pathlib import Path
from target import decode, require, digest, align, MODEL_HEADER, MODEL_MAGIC, validate_descriptor


def rtl_requant(np, acc, multiplier, shift, relu=True):
    require(0 <= multiplier < 2**31 and 0 <= shift <= 62, 'Invalid RTL requant parameter')
    values = acc.astype(np.int64)
    max_abs = max(abs(int(values.min())), abs(int(values.max())))
    half = (1 << (shift-1)) if shift else 0
    require(max_abs * multiplier + half < 2**63, 'Requant intermediate exceeds INT64')
    product = values * multiplier
    scaled = product if not shift else np.where(product < 0, -1, 1) * ((np.abs(product) + half) >> shift)
    return np.clip(scaled, 0 if relu else -128, 127).astype(np.int8)


def execute(np, image, commands, plan):
    """Read actual serialized bytes; direct HWC convolution, no full im2col."""
    mem = bytearray(image)
    traces = {}

    def tensor(addr, shape, dtype):
        count = int(np.prod(shape))
        size = count*np.dtype(dtype).itemsize
        require(0 <= addr and addr+size <= len(mem), 'DDR read out of bounds')
        return np.frombuffer(mem, dtype=dtype, count=count, offset=addr).reshape(shape).copy()

    def write(addr, value):
        data = np.ascontiguousarray(value).tobytes()
        require(0 <= addr and addr+len(data) <= len(mem), 'DDR write out of bounds')
        mem[addr:addr+len(data)] = data

    require(len(commands) == 5*64, 'SmallCNN requires exactly five descriptors')
    for idx, name in enumerate(('conv1', 'pool1', 'conv2', 'pool2', 'fc')):
        d = decode(commands[idx*64:(idx+1)*64])
        m, n, k = d['m'], d['n'], d['k']
        flags = d['flags']
        if d['opcode'] == 3:
            x = tensor(d['a'], (m, n, k), 'i1')
            z = x[:m//2*2, :n//2*2].reshape(m//2, 2, n//2, 2, k).max(axis=(1, 3))
            write(d['c'], z)
            traces[name] = z
            continue
        require(d['opcode'] in (1, 2), 'Unsupported opcode')
        if d['opcode'] == 2:
            geometry, kernel, spatial = d['words10_12']
            h, width = geometry & 65535, geometry >> 16
            ci, kh, kw = kernel & 65535, (kernel >> 16) & 255, kernel >> 24
            sh, sw, pt, pl = (spatial >> (i*8) & 255 for i in range(4))
            oh, ow = (h+2*pt-kh)//sh+1, (width+2*pl-kw)//sw+1
            require(m == oh*ow and k == kh*kw*ci, 'Conv descriptor shape mismatch')
            x = tensor(d['a'], (h, width, ci), 'i1').astype(np.int64)
            w = tensor(d['b'], (n, align(k)), 'i1')[:, :k].reshape(n, kh, kw, ci).astype(np.int64)
            x = np.pad(x, ((pt, pt), (pl, pl), (0, 0)))
            raw = np.zeros((oh, ow, n), dtype=np.int64)
            for y in range(kh):
                for xx in range(kw):
                    raw += x[y:y+oh*sh:sh, xx:xx+ow*sw:sw] @ w[:, y, xx, :].T
            c_stride = n*(1 if flags & 2 else 4)
        else:
            a_stride, b_stride, c_stride = d['words10_12']
            x = tensor(d['a'], (m, a_stride), 'i1')[:, :k].astype(np.int64)
            w = tensor(d['b'], (n, b_stride), 'i1')[:, :k].astype(np.int64)
            raw = x @ w.T
        require(np.max(np.abs(raw)) < 2**31, 'MAC accumulator overflow')
        traces[name+'.mac'] = raw.astype('<i4')
        bias = tensor(d['param']+16, (n,), '<i4') if flags & 1 else 0
        adjusted = raw+bias
        require(np.max(np.abs(adjusted)) < 2**31, 'Bias addition overflow')
        traces[name+'.acc'] = adjusted.astype('<i4')
        if flags & 2:
            multiplier, shift = struct.unpack_from('<II', mem, d['param'])
            z = rtl_requant(np, adjusted, multiplier, shift, bool(flags & 4))
        else:
            z = adjusted.astype('<i4')
        traces[name] = z
        for row, data in enumerate(z.reshape(m, n)):
            write(d['c'] + row*c_stride, data)
    # Pool2 may overwrite only the first FC row; zero rows must survive the chain.
    r = plan['regions']['pool2_output_fc_input']
    padding = mem[r['address']+784:r['address']+r['bytes']]
    require(not any(padding), 'Pool2 overwrote FC padded input rows')
    return traces, mem


def verify_files(np, out):
    manifest = json.loads((out / 'manifest.json').read_text())
    for name, entry in manifest['files'].items():
        path = out/name
        require(path.stat().st_size == entry['bytes'], f'Length mismatch: {name}')
        require(digest(path) == entry['sha256'], f'SHA256 mismatch: {name}')
        if 'shape' in entry:
            a = np.fromfile(path, dtype=entry['dtype']).reshape(entry['shape'])
            require(a.tobytes() == path.read_bytes(), f'Tensor roundtrip failed: {name}')
    plan = json.loads((out/'memory_map.json').read_text())
    report = json.loads((out/'compilation_report.json').read_text())
    commands = (out/'commands.bin').read_bytes()
    previous_end=0
    for region in sorted(plan['regions'].values(),key=lambda x:x['address']):
        require(region['address']>=previous_end and region['address']%4==0,'Overlapping/unaligned memory map')
        previous_end=region['address']+region['bytes']
    require(previous_end<=plan['ddr_capacity_bytes'],'Memory map exceeds DDR capacity')
    for idx in range(5):
        d=decode(commands[idx*64:(idx+1)*64])
        validate_descriptor(d,report['hardware_config'])
        require(d==report['descriptors'][idx],'Serialized descriptor differs from compilation report')
    model = (out/'model.bin').read_bytes()
    magic, version, header_len, load_base, payload_len, desc_base, count = MODEL_HEADER.unpack_from(model)
    require(magic == MODEL_MAGIC and version == 1 and header_len == MODEL_HEADER.size, 'Bad model header')
    require(load_base == 0 and payload_len == len(model)-header_len and count == 5, 'Bad model lengths')
    require(desc_base == plan['regions']['commands']['address'], 'Bad model descriptor base')
    template = model[header_len:]
    require(template[desc_base:desc_base+len(commands)] == commands, 'Model descriptor mismatch')
    for bundle in ('weights', 'params'):
        spec = plan['bundles'][bundle]
        require(template[spec['address']:spec['address']+spec['bytes']] == (out/f'{bundle}.bin').read_bytes(),
                f'{bundle} aggregate mismatch')
    results = []
    for image_path in sorted((out/'ddr').glob('image_*.bin')):
        image_id = image_path.stem
        image = image_path.read_bytes()
        expected_image = bytearray(template)
        inp = (out/'inputs'/f'{image_id}.bin').read_bytes()
        input_addr = plan['regions']['input']['address']
        expected_image[input_addr:input_addr+len(inp)] = inp
        require(image == expected_image, f'Unexpected initialization/padding: {image_id}')
        traces, _ = execute(np, image, commands, plan)
        for name, value in traces.items():
            reference = (out/'golden'/image_id/f'{name}.bin').read_bytes()
            require(value.tobytes() == reference, f'Golden mismatch: {image_id}/{name}')
        results.append(dict(image=image_id, predicted=int(traces['fc'][0, :10].argmax())))
    return results


def compare_rtl_dump(np, out, dump, image_id):
    """Compare a raw DDR snapshot AFTER RTL completion; does not run RTL."""
    plan=json.loads((out/'memory_map.json').read_text())
    memory=Path(dump).read_bytes()
    require(len(memory)>=plan['image_bytes'],'DDR dump too short; dump starts at address zero')
    compared=[]
    for layer,region_name in [('conv1','conv1_output'),('pool1','pool1_output'),('conv2','conv2_output'),
                              ('pool2','pool2_output_fc_input'),('fc','fc_output')]:
        expected=(out/'golden'/image_id/f'{layer}.bin').read_bytes()
        base=plan['regions'][region_name]['address']
        actual=memory[base:base+len(expected)]
        if actual!=expected:
            offset=next(i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b)
            raise ValueError(f'{layer}: first mismatch DDR byte 0x{base+offset:x}, actual={actual[offset]:02x}, expected={expected[offset]:02x}')
        compared.append(layer)
    return dict(rtl_dump=str(dump),compared_outputs=compared)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1]/'artifacts/npu')
    parser.add_argument('--ddr-dump',type=Path,help='Optional zero-based raw DDR dump produced by your RTL simulation')
    parser.add_argument('--image',default='image_0000')
    args = parser.parse_args()
    import numpy as np
    print(json.dumps(verify_files(np, args.out), indent=2))
    if args.ddr_dump:
        print(json.dumps(compare_rtl_dump(np,args.out,args.ddr_dump,args.image),indent=2))
