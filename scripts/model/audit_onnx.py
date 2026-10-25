#!/usr/bin/env python
"""Inspect ONNX operator/shape compatibility without installing a model runtime.

This is a static compatibility report, not a compiler, ONNX checker, quantizer, or numerical
validator. Only the protobuf fields needed for inspection are decoded; unsupported
operators and unknown shapes remain explicit. Works with Python 2.7 and Python 3.
"""
from __future__ import print_function

import argparse
import collections
import hashlib
import json
import math
import struct

try:
    integer_types = (int, long)
except NameError:
    integer_types = (int,)


def varint(data, pos):
    result = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError('Truncated protobuf varint')
        byte = data[pos]
        byte = byte if isinstance(byte, int) else ord(byte)
        pos += 1
        result |= (byte & 127) << shift
        if byte < 128:
            return result, pos
    raise ValueError('Protobuf varint exceeds 64 bits')


def fields(data):
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if number == 0:
            raise ValueError('Invalid protobuf field zero')
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, pos = varint(data, pos)
            else:
                size = 8 if wire == 1 else 4
            if size > len(data) - pos:
                raise ValueError('Truncated protobuf payload')
            value, pos = data[pos:pos+size], pos+size
        else:
            raise ValueError('Unsupported protobuf wire type %d' % wire)
        yield number, wire, value


def integers(wire, value):
    if wire == 0:
        return [value if value < 2**63 else value - 2**64]
    values, pos = [], 0
    while pos < len(value):
        item, pos = varint(value, pos)
        values.append(item if item < 2**63 else item - 2**64)
    return values


def string(value):
    return value.decode('utf-8')


def product(shape):
    if shape is None or any(not isinstance(x, integer_types) or x < 0 for x in shape):
        return None
    size = 1
    for value in shape:
        size *= value
    return size


def tensor(data):
    result = dict(name='', shape=[], dtype=0)
    raw, values = None, []
    for number, wire, value in fields(data):
        if number == 1:
            result['shape'].extend(integers(wire, value))
        elif number == 2:
            result['dtype'] = value
        elif number == 8:
            result['name'] = string(value)
        elif number == 9:
            result['raw_bytes'] = len(value)
            if len(value) <= 512:
                raw = value
        elif number in (5, 7, 11):
            values.extend(integers(wire, value))
        elif number in (4, 10):
            fmt, width = ('f', 4) if number == 4 else ('d', 8)
            if len(value) % width:
                raise ValueError('Invalid floating-point tensor payload')
            # Only small constants are needed for shape/attribute inspection.
            if len(value) <= 512:
                values.extend(struct.unpack('<' + str(len(value)//width) + fmt, value))
        elif number == 14:
            result['external_data'] = value != 0
    count = product(result['shape'])
    if count is not None and count <= 64:
        formats = {1: 'f', 2: 'B', 3: 'b', 6: 'i', 7: 'q', 9: '?', 11: 'd'}
        fmt = formats.get(result['dtype'])
        if raw is not None and fmt and len(raw) == count*struct.calcsize(fmt):
            result['values'] = list(struct.unpack('<' + str(count) + fmt, raw))
        elif values and len(values) == count:
            result['values'] = values
    return result


def attribute(data):
    name, value = '', None
    for number, wire, item in fields(data):
        if number == 1:
            name = string(item)
        elif number == 2:
            value = struct.unpack('<f', item)[0]
        elif number == 3:
            value = integers(wire, item)[0]
        elif number == 4:
            value = string(item)
        elif number == 5:
            value = tensor(item)
        elif number == 8:
            if value is None:
                value = []
            value.extend(integers(wire, item))
    return name, value


def node(data):
    result = dict(name='', op='', domain='', inputs=[], outputs=[], attributes={})
    for number, _, value in fields(data):
        if number in (1, 2):
            result['inputs' if number == 1 else 'outputs'].append(string(value))
        elif number in (3, 4, 7):
            result[{3: 'name', 4: 'op', 7: 'domain'}[number]] = string(value)
        elif number == 5:
            name, item = attribute(value)
            result['attributes'][name] = item
    return result


def value_info(data):
    name, shape, dtype = '', None, None
    for number, _, value in fields(data):
        if number == 1:
            name = string(value)
        elif number == 2:
            for type_number, _, type_value in fields(value):
                if type_number != 1:
                    continue
                for tensor_number, _, tensor_value in fields(type_value):
                    if tensor_number == 1:
                        dtype = tensor_value
                    elif tensor_number == 2:
                        shape = []
                        for _, _, dim in fields(tensor_value):
                            dimension = None
                            for dim_number, _, dim_value in fields(dim):
                                if dim_number == 1:
                                    dimension = dim_value
                            shape.append(dimension)
    return name, dict(shape=shape, dtype=dtype)


def read_model(path):
    with open(path, 'rb') as handle:
        payload = handle.read()
    result = dict(nodes=[], constants={}, tensors={}, inputs=[], outputs=[], opsets=[])
    result['file_bytes'] = len(payload)
    result['sha256'] = hashlib.sha256(payload).hexdigest()
    result['md5'] = hashlib.md5(payload).hexdigest()
    for number, _, value in fields(payload):
        if number == 1:
            result['ir_version'] = value
        elif number == 2:
            result['producer'] = string(value)
        elif number == 8:
            entry = dict(domain='', version=0)
            for item_number, _, item in fields(value):
                if item_number == 1:
                    entry['domain'] = string(item)
                elif item_number == 2:
                    entry['version'] = item
            result['opsets'].append(entry)
        elif number == 7:
            for graph_number, _, item in fields(value):
                if graph_number == 1:
                    result['nodes'].append(node(item))
                elif graph_number == 5:
                    entry = tensor(item)
                    result['constants'][entry['name']] = entry
                    result['tensors'][entry['name']] = entry
                elif graph_number in (11, 12, 13):
                    name, entry = value_info(item)
                    result['tensors'][name] = entry
                    if graph_number != 13:
                        result['inputs' if graph_number == 11 else 'outputs'].append(name)
    for item in result['nodes']:
        if item['op'] == 'Constant' and 'value' in item['attributes']:
            result['constants'][item['outputs'][0]] = item['attributes']['value']
            result['tensors'][item['outputs'][0]] = item['attributes']['value']
    return result


def broadcast(a, b):
    if a is None or b is None:
        return None
    result = []
    for x, y in zip([1]*max(0, len(b)-len(a))+a, [1]*max(0, len(a)-len(b))+b):
        if x is None or y is None or (x != y and x != 1 and y != 1):
            return None
        result.append(max(x, y))
    return result


def infer(item, shapes, constants):
    ins = [shapes.get(name) for name in item['inputs']]
    a = ins[0] if ins else None
    attrs, op = item['attributes'], item['op']
    if op in ('Relu', 'Identity', 'BatchNormalization', 'Softmax', 'Cast', 'Clip'):
        return a
    if op in ('Add', 'Mul', 'Sub', 'Div'):
        return broadcast(ins[0], ins[1])
    if op == 'Constant':
        return constants.get(item['outputs'][0], {}).get('shape')
    if op == 'Transpose' and a is not None:
        return [a[x] for x in attrs.get('perm', list(reversed(range(len(a)))))]
    if op == 'Pad' and a is not None:
        pads = attrs.get('pads')
        if pads is None and len(item['inputs']) > 1:
            pads = constants.get(item['inputs'][1], {}).get('values')
        if pads is not None:
            return [d+pads[i]+pads[i+len(a)] if d is not None else None
                    for i, d in enumerate(a)]
    if op in ('Conv', 'MaxPool', 'AveragePool') and a is not None and len(a) == 4:
        if any(x is None for x in a[1:]):
            return None
        weights = ins[1] if op == 'Conv' else None
        kernel = attrs.get('kernel_shape', weights[2:] if weights else None)
        if kernel is None:
            return None
        pads, strides = attrs.get('pads', [0]*4), attrs.get('strides', [1, 1])
        dilations, spatial = attrs.get('dilations', [1, 1]), []
        for i, size in enumerate(a[2:]):
            if attrs.get('auto_pad') in ('SAME_UPPER', 'SAME_LOWER'):
                out = (size+strides[i]-1)//strides[i]
            else:
                numerator = size+pads[i]+pads[i+2]-(kernel[i]-1)*dilations[i]-1
                if attrs.get('ceil_mode', 0):
                    out = int(math.ceil(float(numerator)/strides[i]))+1
                    if (out-1)*strides[i] >= size+pads[i]:
                        out -= 1
                else:
                    out = numerator//strides[i]+1
            spatial.append(out)
        return [a[0], weights[0] if weights else a[1]]+spatial
    if op == 'GlobalAveragePool' and a is not None:
        return a[:2]+[1]*(len(a)-2)
    if op == 'ReduceMean' and a is not None:
        axes = attrs.get('axes')
        if axes is None and len(item['inputs']) > 1:
            axes = constants.get(item['inputs'][1], {}).get('values')
            if axes is None:
                return None
        if axes is None:
            if attrs.get('noop_with_empty_axes', 0):
                return a
            axes = list(range(len(a)))
        axes = [x % len(a) for x in axes]
        return [1 if i in axes else v for i, v in enumerate(a)] if attrs.get('keepdims', 1) else [v for i, v in enumerate(a) if i not in axes]
    if op in ('Squeeze', 'Unsqueeze') and a is not None:
        axes = attrs.get('axes')
        if axes is None and len(item['inputs']) > 1:
            axes = constants.get(item['inputs'][1], {}).get('values')
        if op == 'Squeeze':
            axes = [i for i, v in enumerate(a) if v == 1] if axes is None else [x % len(a) for x in axes]
            if any(a[x] != 1 for x in axes):
                return None
            return [v for i, v in enumerate(a) if i not in axes]
        if axes is None:
            return None
        result = list(a)
        for axis in sorted(x % (len(a)+len(axes)) for x in axes):
            result.insert(axis, 1)
        return result
    if op == 'MatMul' and all(x is not None for x in ins) and len(ins[0]) == len(ins[1]) == 2:
        return [ins[0][0], ins[1][1]] if ins[0][1] == ins[1][0] else None
    if op == 'Gemm' and all(x is not None for x in ins[:2]):
        return [ins[0][1] if attrs.get('transA', 0) else ins[0][0],
                ins[1][0] if attrs.get('transB', 0) else ins[1][1]]
    if op == 'Flatten' and a is not None:
        axis = attrs.get('axis', 1)
        return [product(a[:axis]), product(a[axis:])]
    if op == 'ArgMax' and a is not None:
        axis = attrs.get('axis', 0) % len(a)
        return [1 if i == axis else v for i, v in enumerate(a)] if attrs.get('keepdims', 1) else [v for i, v in enumerate(a) if i != axis]
    if op == 'Reshape' and a is not None and len(item['inputs']) > 1:
        target = constants.get(item['inputs'][1], {}).get('values')
        if target is not None:
            result = [a[i] if value == 0 else value for i, value in enumerate(target)]
            if -1 in result and product(a) is not None:
                denom = -product(result)
                if denom > 0 and product(a) % denom == 0:
                    result[result.index(-1)] = product(a)//denom
            return result
    return None


def audit(model, rows, cols, batch, boundary_input, boundary_output, pool_line_words=1024):
    shapes = {name: entry.get('shape') for name, entry in model['tensors'].items()}
    for name in model['inputs']:
        if name not in model['constants'] and shapes.get(name):
            shapes[name] = [batch]+shapes[name][1:]
    producers = {name: item for item in model['nodes'] for name in item['outputs']}
    selected = set()

    def visit(name):
        if name == boundary_input or name in model['constants']:
            return
        item = producers.get(name)
        if item is None:
            if name not in model['inputs']:
                raise ValueError('Unknown tensor at graph boundary: '+name)
            return
        key = id(item)
        if key in selected:
            return
        selected.add(key)
        for inp in item['inputs']:
            if inp:
                visit(inp)

    if boundary_input and boundary_input not in shapes and boundary_input not in producers:
        raise ValueError('Unknown input boundary: '+boundary_input)
    for output in ([boundary_output] if boundary_output else model['outputs']):
        visit(output)
    records, workloads = [], []
    for item in model['nodes']:
        if id(item) not in selected:
            continue
        inferred = infer(item, shapes, model['constants'])
        if inferred is not None:
            for output in item['outputs'][:1]:
                shapes[output] = inferred
        out = shapes.get(item['outputs'][0]) if item['outputs'] else None
        attrs, op = item['attributes'], item['op']
        rec = dict(item)
        rec.update(input_shapes=[shapes.get(x) for x in item['inputs']],
                   output_shape=out, status='lowering_required', issues=[])
        if item['domain'] not in ('', 'ai.onnx'):
            rec['issues'].append('Custom operator domain is not supported')
        if op == 'Conv':
            weights = rec['input_shapes'][1]
            if not weights or len(weights) != 4:
                rec['issues'].append('Unknown convolution weight shape')
            elif out and len(out) == 4 and product(out) is not None:
                m, n, k = out[2]*out[3], out[1], product(weights[1:])
                rec['mnk'] = [m, n, k]
                rec['macs_per_sample'] = m*n*k
                rec['tile_counts_m_n'] = [(m+rows-1)//rows, (n+cols-1)//cols]
                rec['last_tile_valid_rows'] = (m-1) % rows+1
                rec['last_tile_valid_cols'] = (n-1) % cols+1
                rec['lowering'] = 'Keep logical M/N; hardware masks partial rows and channels, preserving compact HWC output'
            else:
                rec['issues'].append('Convolution output shape is unknown')
            if attrs.get('group', 1) != 1:
                rec['issues'].append('Grouped/depthwise convolution is not implemented')
            if attrs.get('dilations', [1, 1]) != [1, 1]:
                rec['issues'].append('Dilated convolution is not implemented')
            if any(x not in (1, 2) for x in attrs.get('strides', [1, 1])):
                rec['issues'].append('Convolution stride must be 1 or 2')
            pads = attrs.get('pads', [0]*4)
            if attrs.get('auto_pad', 'NOTSET') == 'NOTSET' and (pads[0] != pads[2] or pads[1] != pads[3]):
                rec['issues'].append('Explicit asymmetric padding needs compiler SAME-mode analysis')
            workloads.append(rec)
        elif op == 'MaxPool':
            pads = attrs.get('pads', [0]*4)
            if attrs.get('auto_pad', 'NOTSET') not in ('NOTSET', 'VALID'):
                rec['issues'].append('Normalize automatic MaxPool padding to explicit per-side fields')
            if attrs.get('ceil_mode', 0):
                rec['issues'].append('MaxPool ceil_mode needs explicit output-boundary lowering')
            if attrs.get('dilations', [1, 1]) != [1, 1]:
                rec['issues'].append('Dilated MaxPool is not implemented')
            if len(item['outputs']) != 1:
                rec['issues'].append('MaxPool indices output is not implemented')
            if not out or len(out) != 4 or out[1] is None or out[1] % 4:
                rec['issues'].append('MaxPool requires a known channel count divisible by four')
            kernel, stride = attrs.get('kernel_shape'), attrs.get('strides', [1, 1])
            if not kernel or any(x < 1 or x > 255 for x in kernel+stride):
                rec['issues'].append('MaxPool kernel/stride fields must be in 1..255')
            elif len(pads) != 4 or any(p < 0 or p > 255 or p >= kernel[i % 2]
                                      for i, p in enumerate(pads)):
                rec['issues'].append('MaxPool padding must fit a byte and be smaller than its kernel dimension')
            else:
                inp = rec['input_shapes'][0]
                if inp and len(inp) == 4 and product(inp) is not None and inp[1] % 4 == 0:
                    words = kernel[0]*inp[3]*(inp[1]//4)
                    minimum = kernel[0]*inp[3]*(cols//4)
                    tiled = words > pool_line_words
                    active = minimum if tiled else words
                    complete_groups = cols >= 4 and cols % 4 == 0 and inp[1] % cols == 0
                    rec['fusion_buffer_estimate'] = dict(
                        words=words, bytes=4*words, minimum_words=minimum,
                        active_words=active, channel_tiled=tiled,
                        available_words=pool_line_words,
                        fits=complete_groups and active <= pool_line_words,
                        scope='KH times input W times C/4 raw-input words; capacity only, padding and graph eligibility still need checking')
            rec['lowering'] = 'Standalone MaxPool: word 10 packs top/left/bottom/right padding; word 15 packs kernel/stride'
            if any(pads):
                rec['fusion_supported'] = False
                rec['fusion_limitation'] = 'Padded pooling stays on the standalone path; streaming fusion supports VALID only'
        elif op in ('AveragePool', 'ReduceMean', 'GlobalAveragePool'):
            inp = rec['input_shapes'][0]
            spatial_only = bool(inp and len(inp) == 4 and out == inp[:2]+[1, 1])
            if op == 'AveragePool':
                spatial_only = spatial_only and attrs.get('kernel_shape') == inp[2:] and not any(attrs.get('pads', [0]*4)) and attrs.get('auto_pad', 'NOTSET') in ('NOTSET', 'VALID') and not attrs.get('ceil_mode', 0)
            elif op == 'ReduceMean' and inp:
                axes = attrs.get('axes')
                if axes is None and len(item['inputs']) > 1:
                    axes = model['constants'].get(item['inputs'][1], {}).get('values')
                spatial_only = spatial_only and axes is not None and sorted(x % len(inp) for x in axes) == [2, 3] and attrs.get('keepdims', 1) == 1
            if not spatial_only:
                rec['issues'].append('Only full spatial global average is implemented')
        elif op in ('MatMul', 'Gemm'):
            rec['lowering'] = 'Use GEMM; allocate and zero-pad FC rows/columns, then keep only logical output elements'
            rec['alignment_backend'] = 'compiler/fc_layout.py'
            if out and len(out) == 2 and product(out) is not None:
                m, n = out
                rec['padded_output_shape'] = [((m+rows-1)//rows)*rows, ((n+cols-1)//cols)*cols]
                rec['alignment_status'] = 'Physical packing, parameters and logical output extraction implemented; ONNX graph lowering still required'
        elif op == 'Add':
            const_inputs = [x for x in item['inputs'] if x in model['constants']]
            if const_inputs:
                rec['lowering'] = 'Fold constant bias into producer or FC parameters where legal'
            elif len(rec['input_shapes']) != 2 or rec['input_shapes'][0] != rec['input_shapes'][1]:
                rec['issues'].append('Residual ADD requires equal tensor shapes')
        elif op == 'Relu':
            rec['lowering'] = 'Fuse into Conv/GEMM/ADD when graph consumer rules permit'
        elif op == 'BatchNormalization':
            if attrs.get('training_mode', 0) or any(x not in model['constants'] for x in item['inputs'][1:]):
                rec['issues'].append('Only constant inference batch normalization can be folded')
            rec['lowering'] = 'Fold static inference parameters into Conv before quantization'
        elif op in ('Identity', 'Reshape', 'Squeeze', 'Unsqueeze', 'Transpose', 'Constant'):
            rec['lowering'] = 'Compiler layout/alias/constant handling; not a standalone NPU opcode'
        elif op in ('Mul', 'Sub', 'Div'):
            rec['issues'].append('Affine operator needs proven constant folding or a new lowering')
        elif op in ('ArgMax', 'Softmax'):
            rec['issues'].append('Host classification postprocessing; not a native NPU opcode')
        else:
            rec['issues'].append('No audited NPU lowering for '+op)
        if out is None:
            rec['issues'].append('Output shape is unknown')
        if rec['issues']:
            rec['status'] = 'needs_adaptation'
        records.append(rec)
    issues = [dict(name=x['name'], op=x['op'], issues=x['issues']) for x in records if x['issues']]
    float_weights = any(x.get('dtype') in (1, 10, 11, 16) for x in model['constants'].values())
    return dict(schema_version=1, model_sha256=model['sha256'], model_md5=model['md5'],
                model_bytes=model['file_bytes'], producer=model.get('producer'),
                ir_version=model.get('ir_version'), opsets=model['opsets'],
                original_node_count=len(model['nodes']), selected_node_count=len(records),
                selected_input=boundary_input, selected_output=boundary_output,
                batch=batch, rows=rows, cols=cols, pool_line_words=pool_line_words,
                operator_counts=dict(collections.Counter(x['op'] for x in records)),
                original_operator_counts=dict(collections.Counter(x['op'] for x in model['nodes'])),
                constant_count=len(model['constants']),
                constant_elements=sum(product(x.get('shape')) or 0 for x in model['constants'].values()),
                floating_point_weights=float_weights, deployment_ready=False,
                requirements=['An ONNX-to-local-descriptor backend is required',
                              'Validate INT8 quantization and local rounding semantics',
                              'Validate transformed graph numerically before RTL deployment'],
                issues=issues, layers=records, convolution_workloads=workloads,
                conv_macs_per_sample=sum(x.get('macs_per_sample', 0) for x in workloads),
                scope='Static metadata/shape audit only; no ONNX execution, compilation or accuracy claim')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model')
    parser.add_argument('--report', required=True)
    parser.add_argument('--summary', help='Optional compact report without every layer')
    parser.add_argument('--input', default=None, help='Optional input tensor boundary')
    parser.add_argument('--output', default=None, help='Optional output tensor boundary')
    parser.add_argument('--batch', type=int, default=1)
    parser.add_argument('--rows', type=int, default=4)
    parser.add_argument('--cols', type=int, default=4)
    parser.add_argument('--pool-line-words', type=int, default=1024,
                        help='Target 32-bit raw-input pool line capacity (default 1024)')
    args = parser.parse_args()
    if min(args.batch, args.rows, args.cols, args.pool_line_words) <= 0:
        parser.error('Batch, rows, cols and pool line words must be positive')
    result = audit(read_model(args.model), args.rows, args.cols, args.batch, args.input, args.output, args.pool_line_words)
    with open(args.report, 'w') as handle:
        json.dump(result, handle, indent=2, sort_keys=True, separators=(',', ': '))
        handle.write('\n')
    if args.summary:
        summary = {key: value for key, value in result.items()
                   if key not in ('layers', 'convolution_workloads')}
        summary['convolution_output_spatial_counts'] = dict(collections.Counter(
            '%dx%d' % tuple(x['output_shape'][2:])
            for x in result['convolution_workloads']
            if x.get('output_shape') and len(x['output_shape']) == 4))
        summary['special_layers'] = [x for x in result['layers']
                                     if x['op'] in ('MaxPool', 'ReduceMean', 'MatMul', 'Gemm')]
        with open(args.summary, 'w') as handle:
            json.dump(summary, handle, indent=2, sort_keys=True, separators=(',', ': '))
            handle.write('\n')
    print(json.dumps({key: result[key] for key in (
        'model_bytes', 'model_md5', 'original_node_count', 'selected_node_count',
        'operator_counts', 'floating_point_weights', 'deployment_ready', 'conv_macs_per_sample')},
        indent=2, sort_keys=True))
    print('Needs-adaptation nodes: %d; report: %s' % (len(result['issues']), args.report))


if __name__ == '__main__':
    main()
