#!/usr/bin/env python
"""Strict, dependency-free ONNX frontend for the NPU's ResNet graph operators.

``load_graph(path, output=None)`` normalizes batch-one NCHW activations into HWC
metadata. Initializers are indexed by file offsets, rather than expanded into
Python float lists. ``graph.load_tensor(name)`` reads one initializer and
``graph.load_weights(node)`` also converts OIHW/MatMul weights into [N, K].
The returned Graph is a dict, so its metadata can be written directly as JSON.
This module does not quantize FP32 tensors or claim ONNX numerical equivalence.
"""
from __future__ import print_function

import array
import collections
import hashlib
import imp
import os
import struct
import sys

_AUDIT_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           'scripts', 'model', 'audit_onnx.py')
_audit = imp.load_source('_npu_onnx_audit', _AUDIT_PATH)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _read_varint(handle, end):
    value = 0
    for shift in range(0, 70, 7):
        _require(handle.tell() < end, 'Truncated protobuf varint')
        byte = handle.read(1)
        _require(bool(byte), 'Truncated protobuf varint')
        byte = ord(byte)
        value |= (byte & 127) << shift
        if byte < 128:
            _require(value < 2**64, 'Protobuf varint exceeds 64 bits')
            return value
    raise ValueError('Protobuf varint exceeds 64 bits')


def _file_fields(handle, end):
    """Yield (number, wire, value-or-file-offset, byte-count), skipping payloads."""
    while handle.tell() < end:
        tag = _read_varint(handle, end)
        number, wire = tag >> 3, tag & 7
        _require(number > 0, 'Invalid protobuf field zero')
        if wire == 0:
            yield number, wire, _read_varint(handle, end), 0
            continue
        _require(wire in (1, 2, 5), 'Unsupported protobuf wire type %d' % wire)
        size = _read_varint(handle, end) if wire == 2 else (8 if wire == 1 else 4)
        offset = handle.tell()
        _require(size <= end-offset, 'Truncated protobuf payload')
        yield number, wire, offset, size
        handle.seek(offset+size)
    _require(handle.tell() == end, 'Invalid protobuf message boundary')


def _payload(handle, offset, size):
    handle.seek(offset)
    value = handle.read(size)
    _require(len(value) == size, 'Truncated ONNX file')
    return value


def _initializer(handle, end):
    meta = dict(name='', shape=[], dtype=0)
    source = dict(segments=[])
    for number, wire, value, size in _file_fields(handle, end):
        if number == 1:
            meta['shape'].extend(_audit.integers(wire, value if wire == 0 else _payload(handle, value, size)))
        elif number == 2:
            meta['dtype'] = value
        elif number == 8:
            meta['name'] = _audit.string(_payload(handle, value, size))
        elif number == 9:
            _require('raw' not in source, 'Initializer has duplicate raw_data')
            source['raw'] = [value, size]
        elif number in (4, 5, 7, 10, 11):
            source['segments'].append([number, wire, value, size])
        elif number == 13 or (number == 14 and value != 0):
            raise ValueError('External ONNX initializer data is not supported')
    _require(bool(meta['name']), 'Initializer has no name')
    _require(_audit.product(meta['shape']) is not None, 'Initializer has an invalid shape')
    _require(not ('raw' in source and source['segments']),
             'Initializer mixes raw_data and typed data: '+meta['name'])
    return meta, source


def _array_code(dtype):
    codes = {1: ('f', 4), 2: ('B', 1), 3: ('b', 1), 4: ('H', 2),
             5: ('h', 2), 6: ('i', 4), 9: ('B', 1), 11: ('d', 8), 12: ('I', 4)}
    if dtype in (7, 13):
        candidates = ('l', 'q') if dtype == 7 else ('L', 'Q')
        for code in candidates:
            try:
                if array.array(code).itemsize == 8:
                    return code
            except ValueError:
                pass
        raise ValueError('This Python has no 64-bit integer array type')
    _require(dtype in codes, 'Unsupported ONNX initializer dtype %s' % dtype)
    code, width = codes[dtype]
    _require(array.array(code).itemsize == width, 'Nonstandard host array element width')
    return code


class Graph(dict):
    """JSON-compatible graph metadata with lazy initializer access methods."""
    def __init__(self, path, sources, *args, **kwargs):
        dict.__init__(self, *args, **kwargs)
        self.path = os.path.abspath(path)
        self._sources = sources

    def load_tensor(self, name):
        _require(name in self._sources, 'Unknown ONNX initializer: '+name)
        meta = self['tensors'][name]
        source = self._sources[name]
        code = _array_code(meta['dtype'])
        result = array.array(code)
        count = _audit.product(meta['shape'])
        with open(self.path, 'rb') as handle:
            if 'raw' in source:
                offset, size = source['raw']
                _require(size == count*result.itemsize,
                         'Initializer raw_data length does not match shape: '+name)
                handle.seek(offset)
                result.fromfile(handle, count)
                if sys.byteorder != 'little' and result.itemsize > 1:
                    result.byteswap()
            else:
                for field, wire, value, size in source['segments']:
                    expected = {1: 4, 11: 10, 7: 7, 13: 11}.get(meta['dtype'], 5)
                    _require(field == expected, 'Initializer typed data does not match dtype: '+name)
                    if field in (4, 10):
                        _require(wire in ((2, 5) if field == 4 else (1, 2)),
                                 'Invalid float initializer encoding')
                        raw = _payload(handle, value, size)
                        _require(len(raw) % result.itemsize == 0, 'Invalid float initializer length')
                        values = array.array(code)
                        values.fromstring(raw) if hasattr(values, 'fromstring') else values.frombytes(raw)
                        if sys.byteorder != 'little':
                            values.byteswap()
                        result.extend(values)
                    else:
                        values = _audit.integers(wire, value if wire == 0 else _payload(handle, value, size))
                        if meta['dtype'] == 13:
                            values = [x if x >= 0 else x+2**64 for x in values]
                        result.extend(values)
        _require(len(result) == count, 'Initializer element count does not match shape: '+name)
        return result

    def load_weights(self, node):
        spec = node['weights']
        values = self.load_tensor(spec['name'])
        source_shape = self['tensors'][spec['name']]['shape']
        if spec['layout'] == 'OIHW_to_NK':
            outputs, channels, kh, kw = source_shape
            if kh == 1 and kw == 1:
                return values
            result = array.array(values.typecode, [0])*len(values)
            for output in range(outputs):
                src_base, dst_base = output*channels*kh*kw, output*channels*kh*kw
                for y in range(kh):
                    for x in range(kw):
                        dst = dst_base+(y*kw+x)*channels
                        for channel in range(channels):
                            result[dst+channel] = values[src_base+(channel*kh+y)*kw+x]
            return result
        _require(spec['layout'] == 'KN_to_NK', 'Unknown weight transformation')
        depth, outputs = source_shape
        result = array.array(values.typecode, [0])*len(values)
        for output in range(outputs):
            for index in range(depth):
                result[output*depth+index] = values[index*outputs+output]
        return result


def _read_index(path):
    model = dict(nodes=[], constants={}, tensors={}, inputs=[], outputs=[], opsets=[])
    sources = {}
    size = os.path.getsize(path)
    with open(path, 'rb') as handle:
        for number, wire, value, length in _file_fields(handle, size):
            if number == 7:
                for field, _, item, count in _file_fields(handle, value+length):
                    if field == 1:
                        model['nodes'].append(_audit.node(_payload(handle, item, count)))
                    elif field == 5:
                        meta, source = _initializer(handle, item+count)
                        name = meta['name']
                        _require(name not in sources, 'Duplicate initializer: '+name)
                        model['constants'][name] = meta
                        model['tensors'][name] = meta
                        sources[name] = source
                    elif field in (11, 12, 13):
                        name, meta = _audit.value_info(_payload(handle, item, count))
                        if name not in model['constants']:
                            model['tensors'][name] = meta
                        if field != 13:
                            model['inputs' if field == 11 else 'outputs'].append(name)
            elif number == 8:
                opset = dict(domain='', version=0)
                for field, _, item in _audit.fields(_payload(handle, value, length)):
                    if field == 1:
                        opset['domain'] = _audit.string(item)
                    elif field == 2:
                        opset['version'] = item
                model['opsets'].append(opset)
    # Shape/axis constants are small; numerical weight data stays on disk.
    graph = Graph(path, sources, tensors=model['tensors'])
    for name, meta in model['constants'].items():
        if meta['dtype'] in (6, 7, 9, 12, 13) and _audit.product(meta['shape']) <= 64:
            meta['values'] = list(graph.load_tensor(name))
    return model, sources


def _positive_shape(shape, name):
    _require(shape is not None and all(isinstance(x, _audit.integer_types) and x > 0 for x in shape),
             'A static positive shape is required: '+name)
    return list(shape)


def _activation_shape(shape, name):
    shape = _positive_shape(shape, name)
    _require(shape[0] == 1, 'Only batch one is supported: '+name)
    if len(shape) == 4:
        return [shape[2], shape[3], shape[1]]
    _require(len(shape) == 2, 'Expected NCHW or batch-one vector: '+name)
    return [shape[1]]


def _attributes(attrs, allowed, name):
    unknown = sorted(set(attrs)-set(allowed))
    _require(not unknown, 'Unsupported attributes on %s: %s' % (name, ', '.join(unknown)))


def _spatial(attrs, input_shape, kernel, name):
    strides = attrs.get('strides', [1, 1])
    _require(len(kernel) == len(strides) == 2 and all(x > 0 and x <= 255 for x in kernel+strides),
             'Invalid kernel or stride on '+name)
    _require(attrs.get('dilations', [1, 1]) == [1, 1], 'Dilated operators are not supported: '+name)
    pads = attrs.get('pads', [0, 0, 0, 0])
    _require(len(pads) == 4 and all(0 <= x <= 255 for x in pads), 'Invalid padding on '+name)
    auto = attrs.get('auto_pad', 'NOTSET')
    _require(auto in ('NOTSET', 'VALID', 'SAME_UPPER', 'SAME_LOWER'), 'Unsupported auto_pad on '+name)
    if auto != 'NOTSET':
        _require(not any(pads), 'auto_pad cannot be combined with explicit padding: '+name)
        pads = [0, 0, 0, 0]
        if auto.startswith('SAME_'):
            for index, size in enumerate(input_shape[2:]):
                total = max(0, ((size+strides[index]-1)//strides[index]-1)*strides[index]+kernel[index]-size)
                before = total//2 if auto == 'SAME_UPPER' else (total+1)//2
                pads[index], pads[index+2] = before, total-before
    output = [(input_shape[index+2]+pads[index]+pads[index+2]-kernel[index])//strides[index]+1
              for index in range(2)]
    _require(all(x > 0 for x in output), 'Spatial output is empty: '+name)
    return dict(kernel=list(kernel), strides=list(strides), pads=list(pads), auto_pad=auto), output


def _model_sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        while True:
            chunk = handle.read(1024*1024)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def load_graph(path, output=None):
    """Read supported inference ancestors of logits, with strict shape validation.

    Without an explicit output, every graph output must resolve through trailing
    Softmax/ArgMax nodes to the same logits tensor. Unsupported operators outside
    the selected output's ancestors are ignored. Squeeze/Identity become aliases.
    """
    model, sources = _read_index(path)
    producers, consumers = {}, collections.defaultdict(list)
    for node in model['nodes']:
        for name in node['outputs']:
            _require(name not in producers and name not in sources, 'Duplicate ONNX tensor producer: '+name)
            producers[name] = node
        for name in node['inputs']:
            consumers[name].append(node)

    def strip(name):
        seen = set()
        while name in producers and producers[name]['op'] in ('Softmax', 'ArgMax'):
            _require(name not in seen, 'Cycle in ONNX output graph')
            seen.add(name)
            node = producers[name]
            _require(node['domain'] in ('', 'ai.onnx') and len(node['inputs']) == len(node['outputs']) == 1,
                     'Invalid classification output node')
            name = node['inputs'][0]
        return name

    boundaries = [strip(name) for name in ([output] if output else model['outputs'])]
    _require(bool(boundaries) and len(set(boundaries)) == 1,
             'Select one output boundary; graph outputs do not share logits')
    boundary = boundaries[0]
    selected, visiting, runtime_inputs, ordered = set(), set(), set(), []

    def visit(name):
        if name in sources:
            return
        if name in model['inputs']:
            runtime_inputs.add(name)
            return
        _require(name in producers, 'Unknown tensor: '+name)
        node = producers[name]
        key = id(node)
        _require(key not in visiting, 'Cycle in ONNX graph')
        if key in selected:
            return
        visiting.add(key)
        for source in node['inputs']:
            if source:
                visit(source)
        visiting.remove(key)
        selected.add(key)
        ordered.append(node)

    visit(boundary)
    _require(len(runtime_inputs) == 1, 'Exactly one runtime graph input is required')
    input_name = next(iter(runtime_inputs))
    input_meta = model['tensors'].get(input_name, {})
    input_shape = input_meta.get('shape')
    if input_shape is not None:
        input_shape = list(input_shape)
        if input_shape and input_shape[0] is None:
            input_shape[0] = 1  # Explicit batch-one specialization; spatial dimensions stay strict.
    input_shape = _positive_shape(input_shape, input_name)
    _require(len(input_shape) == 4 and input_shape[0] == 1, 'Input must be batch-one NCHW')
    _require(input_meta.get('dtype') == 1, 'Input must be FP32 before quantization')
    shapes = dict((name, meta.get('shape')) for name, meta in model['tensors'].items())
    shapes[input_name] = input_shape
    aliases, result, emitted = {}, [], {}

    def canonical(name):
        while name in aliases:
            name = aliases[name]
        return name

    def constant(name, expected_shape=None):
        _require(name in sources, 'Weights/bias must be constant initializers: '+name)
        meta = model['constants'][name]
        _require(meta['dtype'] == 1, 'Weights/bias must be FP32: '+name)
        shape = _positive_shape(meta['shape'], name)
        if expected_shape is not None:
            _require(shape == expected_shape, 'Initializer shape mismatch: '+name)
        return dict(name=name, shape=shape)

    skip = set()
    for node in ordered:
        name, op, attrs = node['name'] or node['outputs'][0], node['op'], node['attributes']
        _require(node['domain'] in ('', 'ai.onnx'), 'Unsupported ONNX domain on '+name)
        _require(len(node['outputs']) == 1, 'Multiple outputs are unsupported: '+name)
        if id(node) in skip:
            continue
        source_shapes = [shapes.get(source) for source in node['inputs']]
        inferred = _audit.infer(node, shapes, model['constants'])
        _require(inferred is not None, 'Cannot infer shape for '+name)
        inferred = _positive_shape(inferred, name)
        original_output = node['outputs'][0]
        output_dtype = model['tensors'].get(original_output, {}).get('dtype')
        _require(output_dtype in (None, 1), 'Runtime tensors must stay FP32 before quantization: '+name)
        declared = shapes.get(original_output)
        if declared is not None:
            _require(len(declared) == len(inferred) and all(x is None or x == y for x, y in zip(declared, inferred)),
                     'Declared output shape disagrees with operator: '+name)
        shapes[original_output] = inferred
        out = dict(name=name, op=op, inputs=[canonical(source) for source in node['inputs'] if source and source not in sources],
                   output=original_output, shape=_activation_shape(inferred, name), attrs={})
        if op == 'Conv':
            _attributes(attrs, ('kernel_shape', 'strides', 'pads', 'auto_pad', 'group', 'dilations'), name)
            _require(len(node['inputs']) in (2, 3) and len(source_shapes[0]) == 4,
                     'Conv requires NCHW input and constant OIHW weights: '+name)
            weight = constant(node['inputs'][1])
            ws = weight['shape']
            _require(len(ws) == 4 and ws[1] == source_shapes[0][1] and attrs.get('group', 1) == 1,
                     'Grouped/channel-mismatched convolution is unsupported: '+name)
            kernel = attrs.get('kernel_shape', ws[2:])
            _require(kernel == ws[2:], 'Conv kernel_shape disagrees with OIHW weights: '+name)
            spatial, size = _spatial(attrs, source_shapes[0], kernel, name)
            _require(all(x in (1, 2) for x in spatial['strides']), 'Conv stride must be 1 or 2: '+name)
            _require(inferred == [1, ws[0]]+size, 'Conv output shape mismatch: '+name)
            weight.update(shape=[ws[0], _audit.product(ws[1:])], layout='OIHW_to_NK')
            out.update(attrs=spatial, weights=weight)
            if len(node['inputs']) == 3 and node['inputs'][2]:
                out['bias'] = constant(node['inputs'][2], [ws[0]])
        elif op == 'Relu':
            _attributes(attrs, (), name)
            _require(len(node['inputs']) == 1, 'Relu requires one input: '+name)
        elif op == 'MaxPool':
            _attributes(attrs, ('kernel_shape', 'strides', 'pads', 'auto_pad', 'ceil_mode', 'dilations', 'storage_order'), name)
            _require(len(node['inputs']) == 1 and len(source_shapes[0]) == 4, 'MaxPool requires NCHW input: '+name)
            _require(not attrs.get('ceil_mode', 0) and not attrs.get('storage_order', 0),
                     'MaxPool ceil_mode/storage_order is unsupported: '+name)
            _require('kernel_shape' in attrs, 'MaxPool requires kernel_shape: '+name)
            spatial, size = _spatial(attrs, source_shapes[0], attrs['kernel_shape'], name)
            _require(all(p < spatial['kernel'][index % 2] for index, p in enumerate(spatial['pads'])),
                     'MaxPool padding must be smaller than its kernel: '+name)
            _require(inferred == source_shapes[0][:2]+size, 'MaxPool output shape mismatch: '+name)
            out['attrs'] = spatial
        elif op in ('ReduceMean', 'GlobalAveragePool'):
            allowed = ('axes', 'keepdims', 'noop_with_empty_axes') if op == 'ReduceMean' else ()
            _attributes(attrs, allowed, name)
            _require(len(source_shapes[0]) == 4, 'Global average requires NCHW input: '+name)
            if op == 'ReduceMean':
                _require(len(node['inputs']) in (1, 2) and not
                         (len(node['inputs']) == 2 and 'axes' in attrs), 'Invalid ReduceMean inputs: '+name)
                axes = attrs.get('axes')
                if axes is None and len(node['inputs']) == 2:
                    axes = model['constants'].get(node['inputs'][1], {}).get('values')
                _require(axes is not None and all(-4 <= x < 4 for x in axes) and
                         sorted(x % 4 for x in axes) == [2, 3], 'ReduceMean must reduce both spatial axes: '+name)
                _require(attrs.get('keepdims', 1) in (0, 1) and not attrs.get('noop_with_empty_axes', 0),
                         'Unsupported ReduceMean options: '+name)
            else:
                _require(len(node['inputs']) == 1, 'GlobalAveragePool requires one input: '+name)
            out.update(op='GlobalAveragePool', inputs=[canonical(node['inputs'][0])],
                       attrs=dict(input_shape=_activation_shape(source_shapes[0], name)))
        elif op in ('Squeeze', 'Identity'):
            if op == 'Identity':
                _attributes(attrs, (), name)
                _require(len(node['inputs']) == 1, 'Identity requires one input: '+name)
            else:
                _attributes(attrs, ('axes',), name)
                _require(len(node['inputs']) in (1, 2) and not
                         (len(node['inputs']) == 2 and 'axes' in attrs), 'Invalid Squeeze inputs: '+name)
                axes = attrs.get('axes')
                if axes is None and len(node['inputs']) == 2:
                    axes = model['constants'].get(node['inputs'][1], {}).get('values')
                _require(source_shapes[0] is not None and len(source_shapes[0]) == 4 and
                         source_shapes[0][2:] == [1, 1] and axes is not None and
                         all(-4 <= x < 4 for x in axes) and sorted(x % 4 for x in axes) == [2, 3],
                         'Only spatial singleton Squeeze is supported: '+name)
            aliases[original_output] = canonical(node['inputs'][0])
            continue
        elif op == 'MatMul':
            _attributes(attrs, (), name)
            _require(len(node['inputs']) == 2 and len(source_shapes[0]) == 2 and source_shapes[0][0] == 1,
                     'MatMul supports a batch-one vector only: '+name)
            weight = constant(node['inputs'][1])
            ws = weight['shape']
            _require(len(ws) == 2 and ws[0] == source_shapes[0][1], 'MatMul weight shape mismatch: '+name)
            weight.update(shape=[ws[1], ws[0]], layout='KN_to_NK')
            out.update(op='FullyConnected', weights=weight)
            followers = [item for item in consumers[original_output] if id(item) in selected]
            if len(followers) == 1 and followers[0]['op'] == 'Add':
                add = followers[0]
                other = [item for item in add['inputs'] if item != original_output]
                if len(other) == 1 and other[0] in sources:
                    _require(len(add['inputs']) == 2 and len(add['outputs']) == 1 and not add['attributes'] and
                             add['domain'] in ('', 'ai.onnx'), 'Invalid FC bias Add')
                    bias = constant(other[0])
                    _require(bias['shape'] in ([ws[1]], [1, ws[1]]), 'FC bias must broadcast over output channels')
                    bias['shape'] = [ws[1]]
                    out['bias'] = bias
                    out['output'] = add['outputs'][0]
                    aliases[original_output] = out['output']
                    bias_output_shape = shapes.get(out['output'])
                    _require(bias_output_shape is None or
                             (len(bias_output_shape) == len(inferred) and
                              all(x is None or x == y for x, y in zip(bias_output_shape, inferred))),
                             'Declared FC bias output shape disagrees with MatMul')
                    shapes[out['output']] = inferred
                    skip.add(id(add))
        elif op == 'Add':
            _attributes(attrs, (), name)
            _require(len(node['inputs']) == 2 and all(source not in sources for source in node['inputs']),
                     'Only residual Add or foldable MatMul bias Add is supported: '+name)
            _require(source_shapes[0] == source_shapes[1] == inferred,
                     'Residual Add broadcasting is unsupported: '+name)
        else:
            raise ValueError('Unsupported ONNX operator %s on %s' % (op, name))
        result.append(out)
        emitted[out['output']] = out
    for name in aliases:
        aliases[name] = canonical(aliases[name])
    model_sha256 = _model_sha256(path)
    graph = Graph(path, sources, input=dict(name=input_name, shape=_activation_shape(input_shape, input_name)),
                  nodes=result, output=canonical(boundary), aliases=aliases,
                  tensors=model['tensors'], model_sha256=model_sha256, source_path=os.path.abspath(path),
                  source=dict(path=os.path.abspath(path), model_sha256=model_sha256, opsets=model['opsets'],
                                                        activation_layout='NCHW', dtype='float32', batch=1))
    _require(graph['output'] in emitted or graph['output'] == input_name, 'Output has no normalized producer')
    return graph
