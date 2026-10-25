#!/usr/bin/env python
"""Generate and check deterministic FC alignment fixtures (Python 2.7/3).

The resnet50 case uses the real classifier dimensions, not trained model data.
Fixtures use the shared compiler layout/packing/descriptor implementation. Golden
values are independently calculated from logical integer tensors.
"""
from __future__ import print_function

import argparse
import json
import os
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, 'compiler'))
from fc_layout import (plan_fc_layout, pack_fc_input, pack_fc_weights,
                       pack_fc_params, make_fc_descriptor,
                       extract_fc_output, fc_argmax)


def align(value, boundary=64):
    return (value+boundary-1)//boundary*boundary


def binary(value):
    return bytes(value) if sys.version_info[0] >= 3 else str(value)


def signed_bytes(values):
    return b''.join(struct.pack('b', value) for value in values)


def write_binary(path, data):
    with open(path, 'wb') as handle:
        handle.write(data)


def write_hex(path, data):
    assert len(data) % 4 == 0
    with open(path, 'w') as handle:
        handle.write(''.join('%08x\n' % struct.unpack_from('<I', data, pos)[0]
                             for pos in range(0, len(data), 4)))


def descriptor_bytes(desc):
    words = [desc['opcode'] | (desc['flags'] << 8), desc['m'], desc['n'], desc['k']]
    for name in ('a', 'b', 'c'):
        words.extend([desc[name] & 0xffffffff, desc[name] >> 32])
    words.extend(desc['words10_12'])
    words.extend([desc['param'] & 0xffffffff, desc['param'] >> 32,
                  desc.get('pool_config', 0)])
    return struct.pack('<16I', *words)


def reference_requant(value, multiplier, shift, output_zp):
    product = value*multiplier
    if shift:
        magnitude = (abs(product)+(1 << (shift-1))) >> shift
        product = -magnitude if product < 0 else magnitude
    return max(-128, min(127, product+output_zp))


def generate(out, case):
    if not os.path.isdir(out):
        os.makedirs(out)
    repeat_row = case == 'resnet50-repeat'
    if case.startswith('resnet50'):
        m, n, k, input_zp, output_zp, element_bytes = 1, 1001, 2048, -5, 0, 4
        activation = [[input_zp+(i % 5)-2 for i in range(k)]]
        weights = [[(c % 7)-3]*k for c in range(n)]
        bias = [-1000000+c*16 for c in range(n)]
        requant = None
    else:
        m, n, k, input_zp, output_zp, element_bytes = 3, 5, 9, -7, 13, 1
        activation = [[input_zp+((row*3+i) % 7)-3 for i in range(k)]
                      for row in range(m)]
        weights = [[((c+2*i) % 7)-3 for i in range(k)] for c in range(n)]
        bias = [c-2 for c in range(n)]
        requant = [(1, 0)]*n
    layout = plan_fc_layout(m, n, k, rows=4, cols=4,
                            output_element_bytes=element_bytes)
    a_raw = signed_bytes(v for row in activation for v in row)
    b_raw = signed_bytes(v for row in weights for v in row)
    a_data = pack_fc_input(a_raw, layout, input_zero_point=input_zp)
    if repeat_row:
        a_data = a_data[:layout['a_stride_bytes']]
    b_data = pack_fc_weights(b_raw, layout)
    p_data = pack_fc_params(b_raw, bias, layout,
                            input_zero_point=input_zp, output_zero_point=output_zp,
                            requant=requant)
    descriptor_base = 256
    cursor = 4096
    regions = {}
    for name, payload in [('a', a_data), ('b', b_data), ('param', p_data)]:
        cursor = align(cursor)
        regions[name] = dict(address=cursor, bytes=len(payload))
        cursor += len(payload)
    output_base = align(cursor)
    regions['c'] = dict(address=output_base, bytes=layout['c_bytes'])
    image_size = align(output_base+layout['c_bytes']+64)
    image = bytearray(b'\x5a'*image_size)
    for name, payload in [('a', a_data), ('b', b_data), ('param', p_data)]:
        start = regions[name]['address']
        image[start:start+len(payload)] = payload
    desc = make_fc_descriptor(layout, regions['a']['address'], regions['b']['address'],
                              output_base, regions['param']['address'],
                              requantized=requant is not None)
    if repeat_row:
        desc['words10_12'][0] = 0
    image[descriptor_base:descriptor_base+64] = descriptor_bytes(desc)

    expected = bytearray(b'\x5a'*layout['c_bytes'])
    logical = []
    logical_rows = []
    for row in range(layout['physical_m']):
        scores = []
        for c in range(layout['physical_n']):
            acc = bias[c] if c < n else 0
            if (row < m or repeat_row) and c < n:
                source_row = 0 if repeat_row else row
                acc += sum((activation[source_row][i]-input_zp)*weights[c][i]
                           for i in range(k))
            value = acc
            if requant is not None:
                mul, shift = requant[c] if c < n else (0, 0)
                value = reference_requant(acc, mul, shift, output_zp)
            encoded = struct.pack('<i' if element_bytes == 4 else 'b', value)
            offset = row*layout['c_stride_bytes']+c*element_bytes
            expected[offset:offset+element_bytes] = encoded
            if row < m and c < n:
                logical.append(encoded)
                scores.append(value)
        if row < m:
            logical_rows.append(scores)
    expected = binary(expected)
    expected_argmax = [max(range(n), key=lambda col: scores[col])
                       for scores in logical_rows]
    if case.startswith('resnet50'):
        assert all(v < 0 for v in logical_rows[0])
        assert layout['physical_n'] == 1004 and layout['physical_m'] == 4
        # Zero padding wins if a classifier accidentally inspects all columns.
        assert max(logical_rows[0]+[0]*3) == 0
    write_binary(os.path.join(out, 'ddr.bin'), binary(image))
    write_hex(os.path.join(out, 'ddr.hex'), binary(image))
    write_binary(os.path.join(out, 'expected.bin'), expected)
    write_hex(os.path.join(out, 'expected.hex'), expected)
    write_binary(os.path.join(out, 'logical_expected.bin'), b''.join(logical))
    with open(os.path.join(out, 'case.cfg'), 'w') as handle:
        handle.write('%d %d %d %d\n' %
                     (image_size//4, descriptor_base, output_base, layout['c_bytes']))
    manifest = dict(case=case, scope='Deterministic integer fixture; no trained-model accuracy claim',
                    layout=layout, regions=regions, descriptor=desc,
                    input_zero_point=input_zp, output_zero_point=output_zp,
                    expected_argmax=expected_argmax, image_bytes=image_size)
    manifest['input_row_policy'] = 'repeat_logical_row' if repeat_row else 'zero_point_padding'
    manifest['actual_a_stride_bytes'] = desc['words10_12'][0]
    with open(os.path.join(out, 'manifest.json'), 'w') as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True, separators=(',', ': '))
        handle.write('\n')
    assert extract_fc_output(expected, layout) == b''.join(logical)
    assert fc_argmax(expected, layout) == expected_argmax
    print('FC FIXTURE %s GENERATED logical=%dx%d K=%d physical=%dx%d strides=%s' %
          (case, m, n, k, layout['physical_m'], layout['physical_n'],
           [layout[name] for name in ('a_stride_bytes', 'b_stride_bytes', 'c_stride_bytes')]))


def check(out):
    with open(os.path.join(out, 'manifest.json')) as handle:
        manifest = json.load(handle)
    with open(os.path.join(out, 'c_dump.bin'), 'rb') as handle:
        actual = handle.read()
    with open(os.path.join(out, 'expected.bin'), 'rb') as handle:
        expected = handle.read()
    with open(os.path.join(out, 'logical_expected.bin'), 'rb') as handle:
        logical = handle.read()
    assert actual == expected, 'Physical FC output differs from independent golden'
    layout = manifest['layout']
    assert extract_fc_output(actual, layout) == logical, 'Logical FC crop differs'
    predicted = fc_argmax(actual, layout)
    assert predicted == manifest['expected_argmax'], 'Argmax included padding or wrong rows'
    if manifest['case'].startswith('resnet50'):
        values = struct.unpack('<%di' % layout['physical_n'], actual[:layout['c_stride_bytes']])
        bad_prediction = max(range(len(values)), key=lambda col: values[col])
        assert bad_prediction >= layout['logical_n'], 'Fixture did not expose untrimmed argmax'
        assert predicted[0] < layout['logical_n']
        print('Untrimmed argmax=%d (invalid); cropped argmax=%d (valid)' %
              (bad_prediction, predicted[0]))
    print('FC ALIGNMENT %s HARDWARE DUMP / LOGICAL CROP / ARGMAX PASS' % manifest['case'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('generate', 'check'))
    parser.add_argument('--out', required=True)
    parser.add_argument('--case', choices=('resnet50', 'resnet50-repeat', 'small-int8'), default='resnet50')
    args = parser.parse_args()
    if args.action == 'generate':
        generate(args.out, args.case)
    else:
        check(args.out)


if __name__ == '__main__':
    main()
