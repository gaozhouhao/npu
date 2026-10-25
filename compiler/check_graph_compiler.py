#!/usr/bin/env python
"""Small deterministic ResNet-shaped compiler/RTL fixture; no accuracy claim."""
from __future__ import print_function
import argparse
import json
import os
import struct

from target import hardware_defaults
from graph_compiler import (binary, compile_graph, optimize_graph,
                            quantization_template, write_package)


class FixtureGraph(dict):
    def load_weights(self, node):
        n, k = node['weights']['shape']
        return [(((channel*3+index*2) % 7)-3)*(channel % 3+1)*0.01
                for channel in range(n) for index in range(k)]

    def load_tensor(self, name):
        return self.biases[name]


def fixture():
    nodes = []
    biases = {}

    def conv(name, source, shape, cin, kernel):
        nodes.append(dict(name=name, op='Conv', inputs=[source], output=name,
                          shape=shape, attrs=dict(kernel=[kernel]*2, strides=[1, 1],
                                                 pads=[kernel//2]*4),
                          weights=dict(name=name+'.w', shape=[shape[-1], kernel*kernel*cin]),
                          bias=dict(name=name+'.b', shape=[shape[-1]])))
        biases[name+'.b'] = [(i % 5-2)*0.03 for i in range(shape[-1])]

    def relu(name, source, shape):
        nodes.append(dict(name=name, op='Relu', inputs=[source], output=name, shape=shape))

    conv('compact', 'input', [5, 7, 5], 3, 1)
    relu('compact_relu', 'compact', [5, 7, 5])
    conv('stem', 'compact_relu', [5, 7, 32], 5, 3)
    relu('stem_relu', 'stem', [5, 7, 32])
    nodes.append(dict(name='pool', op='MaxPool', inputs=['stem_relu'], output='pool',
                      shape=[2, 3, 32], attrs=dict(kernel=[3, 3], strides=[2, 2], pads=[0, 0, 1, 1])))
    conv('main', 'pool', [2, 3, 8], 32, 3)
    conv('skip', 'pool', [2, 3, 8], 32, 1)
    nodes.append(dict(name='sum', op='Add', inputs=['main', 'skip'], output='sum', shape=[2, 3, 8]))
    relu('sum_relu', 'sum', [2, 3, 8])
    nodes.append(dict(name='gap', op='GlobalAveragePool', inputs=['sum_relu'], output='gap', shape=[1, 1, 8]))
    nodes.append(dict(name='fc', op='FullyConnected', inputs=['gap'], output='logits', shape=[10],
                      weights=dict(name='fc.w', shape=[10, 8]), bias=dict(name='fc.b', shape=[10])))
    biases['fc.b'] = [(i-5)*0.07 for i in range(10)]
    graph = FixtureGraph(input=dict(name='input', shape=[5, 7, 3]), nodes=nodes, output='logits')
    graph.biases = biases
    profile = quantization_template(graph)
    profile.update(calibrated=True, calibration=dict(dataset='deterministic synthetic unit fixture',
                                                     samples=1, method='fixed test scales; not model calibration'),
                   preprocessing=dict(description='Synthetic signed INT8 HWC; no images',
                                      input_layout='HWC', input_shape=[5, 7, 3]))
    settings = {'input': (0.1, -7), 'compact_relu': (0.02, -9), 'stem_relu': (0.015, -12),
                'main': (0.008, 11), 'skip': (0.01, -13), 'sum_relu': (0.012, -5),
                'logits': (0.01, 3)}
    for name, (scale, zp) in settings.items():
        profile['tensors'][name] = dict(scale=scale, zero_point=zp)
    inputs = binary(bytearray((i % 21-17) & 255 for i in range(5*7*3)))
    cfg = hardware_defaults()
    cfg.update(ddr_capacity_bytes=1024*1024, ddr_base=0, alignment_bytes=8, activation_layout='HWC')
    return graph, cfg, profile, inputs


def generate(directory):
    from reference_int8 import execute
    graph, cfg, profile, inputs = fixture()
    plan, image, descriptors = compile_graph(graph, cfg, profile, inputs)
    expected, traces = execute(image, descriptors)
    write_package(directory, plan, image, descriptors)
    with open(os.path.join(directory, 'expected.bin'), 'wb') as handle:
        handle.write(binary(expected))
    with open(os.path.join(directory, 'traces.json'), 'w') as handle:
        json.dump(traces, handle, indent=2)
    print('GRAPH FIXTURE GENERATED commands=%d bytes=%d' % (len(plan['commands']), len(image)))


def check(directory):
    with open(os.path.join(directory, 'expected.bin'), 'rb') as handle:
        expected = handle.read()
    with open(os.path.join(directory, 'rtl.hex')) as handle:
        actual = b''.join(struct.pack('<I', int(line.strip(), 16)) for line in handle if line.strip())
    if actual != expected:
        lhs, rhs = bytearray(actual), bytearray(expected)
        for index in range(min(len(lhs), len(rhs))):
            if lhs[index] != rhs[index]:
                raise AssertionError('RTL differs from reference at DDR byte %d: %d != %d' %
                                     (index, lhs[index], rhs[index]))
        raise AssertionError('RTL DDR dump length differs')
    print('PASS: compiled residual graph RTL matches all %d DDR bytes' % len(expected))


def rtl_args(directory):
    with open(os.path.join(directory, 'manifest.json')) as handle:
        plan = json.load(handle)
    directory = os.path.abspath(directory)
    print('+DDR_HEX=%s/ddr.hex +DESC_BASE=%x +DESC_COUNT=%d +LOGITS_BASE=%x '
          '+DDR_DUMP=%s/rtl.hex +DUMP_WORDS=%d +DDR_RD_LATENCY=2' %
          (directory, plan['descriptor_base'], plan['descriptor_count'],
           plan['regions'][plan['output']]['address'], directory, plan['image_bytes']//4))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['generate', 'check', 'rtl-args'])
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    {'generate': generate, 'check': check, 'rtl-args': rtl_args}[args.action](args.out)
