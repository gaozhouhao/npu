#!/usr/bin/env python
"""Execute production FC/pool packing against independent integer golden data."""
from __future__ import print_function

import argparse
import json
import os
import struct
import sys

from check_fc_alignment import (REPO, align, binary, signed_bytes, write_binary,
                                write_hex, descriptor_bytes, reference_requant)
from fc_layout import pack_fc_input, pack_fc_weights
from fc_pool import plan_fc_pool_layout, pack_fc_pool_params, make_fc_pool_descriptor


def generate(out, case):
    if not os.path.isdir(out):
        os.makedirs(out)
    per_channel = case != 'per-tensor'
    h, w, channels, k, config = ((3, 3, 12, 73, 0x01010202)
                               if case == 'overlap' else (2, 2, 4, 260, 0))
    input_zp, output_zp = -3, 5
    plan = plan_fc_pool_layout(k, (h, w, channels), pool_config=config,
                               per_channel=per_channel)
    fc = plan['fc_layout']
    n = h*w*channels
    x = [(i*7) % 17-8 for i in range(k)]
    weights = [[(c*5+i*3) % 9-4 for i in range(k)] for c in range(n)]
    bias = [(c % 7-3)*7 for c in range(n)]
    pairs = [(1+c % 3, 3+c % 2) if per_channel else (3, 4) for c in range(n)]
    raw_weights = signed_bytes([v for row in weights for v in row])
    packed_a = pack_fc_input(signed_bytes(x), fc, input_zp)
    packed_b = pack_fc_weights(raw_weights, fc)
    packed_p = pack_fc_pool_params(raw_weights, bias, plan, input_zp, output_zp,
                                  requant=pairs if per_channel else None,
                                  global_requant=None if per_channel else pairs[0])
    # The reference uses logical tensors and centered inputs, independently of
    # physical padding, parameter offsets and the RTL coordinate converter.
    values = []
    for c in range(n):
        acc = bias[c]+sum((x[i]-input_zp)*weights[c][i] for i in range(k))
        values.append(reference_requant(acc, pairs[c][0], pairs[c][1], output_zp))
    kh, kw, sh, sw = (2, 2, 1, 1) if config else (2, 2, 2, 2)
    golden = []
    for y in range((h-kh)//sh+1):
        for x_pos in range((w-kw)//sw+1):
            for c in range(channels):
                golden.append(max(values[((y*sh+dy)*w+x_pos*sw+dx)*channels+c]
                                  for dy in range(kh) for dx in range(kw)))
    expected = signed_bytes(golden)
    desc_base, a = 0x100, 0x1000
    b = align(a+len(packed_a))
    params = align(b+len(packed_b))
    c_base = align(params+len(packed_p))
    desc = make_fc_pool_descriptor(plan, a, b, c_base, params)
    image = bytearray([0x5a])*align(c_base+plan['c_bytes']+64)
    for address, payload in ((desc_base, descriptor_bytes(desc)), (a, packed_a),
                             (b, packed_b), (params, packed_p)):
        image[address:address+len(payload)] = payload
    write_hex(os.path.join(out, 'ddr.hex'), binary(image))
    write_hex(os.path.join(out, 'expected.hex'), expected)
    write_binary(os.path.join(out, 'expected.bin'), expected)
    with open(os.path.join(out, 'case.cfg'), 'w') as handle:
        handle.write('%d %d %d %d\n' % (len(image)//4, desc_base, c_base, len(expected)))
    with open(os.path.join(out, 'case.json'), 'w') as handle:
        json.dump(dict(case=case, plan=plan, descriptor=desc, input_zero_point=input_zp,
                       output_zero_point=output_zp), handle, indent=2, sort_keys=True)
    print('FC POOL FIXTURE PASS case=%s shape=%s K=%d output_bytes=%d' %
          (case, plan['reshape_shape'], k, len(expected)))


def check(out):
    with open(os.path.join(out, 'expected.bin'), 'rb') as handle:
        expected = handle.read()
    with open(os.path.join(out, 'c_dump.bin'), 'rb') as handle:
        actual = handle.read()
    if actual != expected:
        raise AssertionError('FC pooled output differs from logical integer reference')
    print('FC POOL COMPILER/RTL OUTPUT PASS bytes=%d' % len(expected))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('generate', 'check'))
    parser.add_argument('--out', required=True)
    parser.add_argument('--case', choices=('per-channel', 'per-tensor', 'overlap'),
                        default='per-channel')
    args = parser.parse_args()
    if args.action == 'generate':
        generate(args.out, args.case)
    else:
        check(args.out)
