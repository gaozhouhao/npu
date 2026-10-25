"""Dependency-free ONNX frontend tests; fixtures are real protobuf messages."""
from __future__ import print_function

import collections
import copy
import hashlib
import json
import os
import struct
import tempfile
import unittest

from onnx_frontend import load_graph


def varint(value):
    value = value if value >= 0 else value+2**64
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result) if not isinstance(b'', str) else str(result)


def field(number, value, integer=False):
    return varint(number*8+(0 if integer else 2))+(varint(value) if integer else varint(len(value))+value)


def text(value):
    return value.encode('utf-8')


def vi(name, shape, dtype=1):
    dims = b''
    for value in shape:
        dim = field(2, text('batch')) if value is None else field(1, value, True)
        dims += field(1, dim)
    return field(1, text(name))+field(2, field(1, field(1, dtype, True)+field(2, dims)))


def initializer(name, shape, values, dtype=1, typed=False):
    dims = b''.join(varint(value) for value in shape)
    payload = field(1, dims)+field(2, dtype, True)+field(8, text(name))
    if dtype == 1:
        raw = struct.pack('<%df' % len(values), *values)
        return payload+field(4 if typed else 9, raw)
    if typed:
        return payload+field(7, b''.join(varint(value) for value in values))
    return payload+field(9, struct.pack('<%dq' % len(values), *values))


def attribute(name, value):
    payload = field(1, text(name))
    if isinstance(value, list):
        payload += field(8, b''.join(varint(x) for x in value))
    elif isinstance(value, str):
        payload += field(4, text(value))
    else:
        payload += field(3, value, True)
    return payload


def node(op, inputs, output, attrs=None):
    payload = b''.join(field(1, text(name)) for name in inputs)
    payload += field(2, text(output))+field(3, text(output))+field(4, text(op))
    for name, value in sorted((attrs or {}).items()):
        payload += field(5, attribute(name, value))
    return payload


def model(nodes, initializers=None, input_shape=None, outputs=None, declarations=None):
    graph = b''.join(field(1, value) for value in nodes)
    graph += b''.join(field(5, value) for value in (initializers or []))
    graph += field(11, vi('input', input_shape or [1, 2, 3, 3]))
    for name, shape in (outputs or [('out', [1, 2, 3, 3])]):
        graph += field(12, vi(name, shape))
    for name, shape in (declarations or []):
        graph += field(13, vi(name, shape))
    return field(1, 7, True)+field(7, graph)+field(8, field(2, 11, True))


class ONNXFrontendTests(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix='.onnx')
        os.close(handle)

    def tearDown(self):
        os.unlink(self.path)

    def load(self, payload, **kwargs):
        with open(self.path, 'wb') as handle:
            handle.write(payload)
        return load_graph(self.path, **kwargs)

    def fixture(self, declarations=None):
        constants = [initializer('conv_w', [2, 2, 2, 2], list(range(16))),
                     initializer('conv_b', [2], [0.5, -1]),
                     initializer('fc_w', [2, 3], list(range(6)), typed=True),
                     initializer('fc_b', [3], [1, 2, 3]),
                     initializer('axes', [2], [2, 3], 7, typed=True)]
        nodes = [node('Conv', ['input', 'conv_w', 'conv_b'], 'conv'),
                 node('Relu', ['conv'], 'relu'),
                 node('MaxPool', ['relu'], 'pool', {'kernel_shape': [2, 2]}),
                 node('Add', ['pool', 'pool'], 'residual'),
                 node('ReduceMean', ['residual', 'axes'], 'gap'),
                 node('Squeeze', ['gap'], 'vector', {'axes': [2, 3]}),
                 node('MatMul', ['vector', 'fc_w'], 'matmul'),
                 node('Add', ['matmul', 'fc_b'], 'logits'),
                 node('Softmax', ['logits'], 'softmax', {'axis': 1}),
                 node('ArgMax', ['logits'], 'argmax', {'axis': 1, 'keepdims': 0})]
        return model(nodes, constants, [None, 2, 3, 3],
                     [('softmax', [1, 3]), ('argmax', [1])], declarations)

    def test_hwc_graph_bias_folding_and_numeric_weight_layout(self):
        graph = self.load(self.fixture())
        self.assertEqual(graph['input'], dict(name='input', shape=[3, 3, 2]))
        self.assertEqual([n['op'] for n in graph['nodes']],
                         ['Conv', 'Relu', 'MaxPool', 'Add', 'GlobalAveragePool', 'FullyConnected'])
        self.assertEqual(graph['output'], 'logits')
        conv, fc = graph['nodes'][0], graph['nodes'][-1]
        self.assertEqual(conv['shape'], [2, 2, 2])
        self.assertEqual(conv['attrs'], dict(kernel=[2, 2], strides=[1, 1], pads=[0, 0, 0, 0], auto_pad='NOTSET'))
        self.assertEqual(conv['weights']['shape'], [2, 8])
        self.assertEqual(list(graph.load_weights(conv)), [0, 4, 1, 5, 2, 6, 3, 7, 8, 12, 9, 13, 10, 14, 11, 15])
        self.assertEqual(list(graph.load_weights(copy.deepcopy(fc))), [0, 3, 1, 4, 2, 5])
        self.assertEqual(fc['weights']['shape'], [3, 2])
        self.assertEqual(fc['inputs'], ['gap'])
        self.assertEqual(graph['aliases'], dict(vector='gap', matmul='logits'))
        self.assertEqual(list(graph.load_tensor(fc['bias']['name'])), [1, 2, 3])
        self.assertNotIn('values', graph['tensors']['conv_w'])
        self.assertNotIn('data', conv['weights'])
        self.assertEqual(graph['model_sha256'], hashlib.sha256(self.fixture()).hexdigest())
        self.assertEqual(graph['source_path'], os.path.abspath(self.path))
        self.assertEqual(graph['source']['model_sha256'], graph['model_sha256'])
        json.dumps(graph)

    def test_explicit_intermediate_boundary_excludes_classifier(self):
        graph = self.load(self.fixture(), output='pool')
        self.assertEqual([n['op'] for n in graph['nodes']], ['Conv', 'Relu', 'MaxPool'])
        self.assertEqual(graph['output'], 'pool')

    def test_same_padding_is_normalized_per_side(self):
        payload = model([node('MaxPool', ['input'], 'out',
                              {'kernel_shape': [3, 3], 'strides': [2, 2], 'auto_pad': 'SAME_LOWER'})],
                        input_shape=[1, 4, 4, 5], outputs=[('out', [1, 4, 2, 3])])
        graph = self.load(payload)
        self.assertEqual(graph['nodes'][0]['attrs']['pads'], [1, 1, 0, 1])
        self.assertEqual(graph['nodes'][0]['shape'], [2, 3, 4])

    def test_rejects_bad_batch_dynamic_spatial_or_declared_shape(self):
        for shape in ([2, 2, 3, 3], [1, 2, None, 3]):
            with self.assertRaises(ValueError):
                self.load(model([node('Relu', ['input'], 'out')], input_shape=shape))
        with self.assertRaises(ValueError):
            self.load(self.fixture([('conv', [1, 2, 5, 5])]))
        with self.assertRaises(ValueError):
            self.load(self.fixture([('logits', [1, 4])]))

    def test_rejects_unsupported_convolution_and_pool_attributes(self):
        weight = initializer('w', [2, 2, 1, 1], [0]*4)
        for attrs in ({'group': 2}, {'dilations': [2, 2]}, {'strides': [3, 1]},
                      {'kernel_shape': [2, 2]}, {'auto_pad': 'SAME_UPPER', 'pads': [1, 0, 0, 0]}):
            with self.assertRaises(ValueError):
                self.load(model([node('Conv', ['input', 'w'], 'out', attrs)], [weight]))
        for attrs in ({'ceil_mode': 1}, {'storage_order': 1}, {'pads': [2, 0, 0, 0]}):
            attrs = dict(attrs, kernel_shape=[2, 2])
            with self.assertRaises(ValueError):
                self.load(model([node('MaxPool', ['input'], 'out', attrs)]))

    def test_rejects_broadcast_residual_and_nonspatial_mean(self):
        payload = model([node('ReduceMean', ['input'], 'one', {'axes': [2, 3]}),
                         node('Add', ['input', 'one'], 'out')])
        with self.assertRaises(ValueError):
            self.load(payload)
        for axes in ([1, 2], [2, 6], [2, 2, 3]):
            with self.assertRaises(ValueError):
                self.load(model([node('ReduceMean', ['input'], 'out', {'axes': axes})]))

    def test_rejects_ambiguous_outputs_and_unknown_ops(self):
        payload = model([node('Relu', ['input'], 'a'), node('Relu', ['a'], 'b')],
                        outputs=[('a', [1, 2, 3, 3]), ('b', [1, 2, 3, 3])])
        with self.assertRaises(ValueError):
            self.load(payload)
        graph = self.load(payload, output='a')
        self.assertEqual(len(graph['nodes']), 1)
        with self.assertRaises(ValueError):
            self.load(model([node('Clip', ['input'], 'out')]))

    def test_rejects_unfoldable_or_mismatched_fc_bias(self):
        # A bias of the wrong width is a malformed broadcast, never an Add command.
        constants = [initializer('fc_w', [2, 3], list(range(6))), initializer('fc_b', [4], [0]*4)]
        nodes = [node('ReduceMean', ['input'], 'gap', {'axes': [2, 3]}),
                 node('Squeeze', ['gap'], 'vector', {'axes': [2, 3]}),
                 node('MatMul', ['vector', 'fc_w'], 'matmul'), node('Add', ['matmul', 'fc_b'], 'out')]
        with self.assertRaises(ValueError):
            self.load(model(nodes, constants, outputs=[('out', [1, 3])]))

    def test_rejects_truncated_protobuf(self):
        with self.assertRaises(ValueError):
            self.load(self.fixture()[:-5])

    def test_real_nvidia_graph_when_present(self):
        path = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'build',
                            'nvidia_reference_models', 'resnet50', 'resnet50_v1.onnx')
        if not os.path.exists(path):
            self.skipTest('Optional NVIDIA model is not downloaded')
        graph = load_graph(path)
        self.assertEqual(collections.Counter(n['op'] for n in graph['nodes']),
                         dict(Conv=53, Relu=49, Add=16, MaxPool=1, GlobalAveragePool=1, FullyConnected=1))
        self.assertEqual(graph['nodes'][-1]['weights']['shape'], [1001, 2048])
        self.assertEqual(graph['nodes'][0]['attrs']['pads'], [3, 3, 3, 3])
        self.assertEqual(graph['nodes'][2]['attrs']['pads'], [0, 0, 1, 1])
        self.assertEqual(len(graph.load_weights(graph['nodes'][0])), 64*3*7*7)
        self.assertFalse(any('values' in meta for meta in graph['tensors'].values() if meta.get('dtype') == 1))


if __name__ == '__main__':
    unittest.main()
