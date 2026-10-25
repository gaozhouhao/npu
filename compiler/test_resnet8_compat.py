#!/usr/bin/env python
"""Exercise actual legacy compiler methods without NumPy/FlatBuffers.

A small array test double supplies only weight/bias storage. Descriptor emission,
channel padding, parameter packing, allocation and dataflow use production code.
This is an ABI/layout check; it does not claim TFLite numerical equivalence.
"""
from __future__ import print_function
import math
import os
import re
import struct
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'compiler'))
from fc_layout import plan_fc_layout, pack_fc_weights, pack_fc_params


class Vector(object):
    def __init__(self, values):
        self.values = list(values)
        self.size = len(self.values)

    def astype(self, dtype):
        return self

    def reshape(self, *shape):
        return self

    def tobytes(self):
        return struct.pack('<' + str(len(self.values)) + 'b', *self.values)

    def tolist(self):
        return list(self.values)

    def __getitem__(self, index):
        return self.values[index]

    def __sub__(self, other):
        return Vector(a-b for a, b in zip(self.values, other.values))

    def __rmul__(self, value):
        return Vector(value*a for a in self.values)

    def __lt__(self, value):
        return Vector(a < value for a in self.values)

    def __gt__(self, value):
        return Vector(a > value for a in self.values)

    def __or__(self, other):
        return Vector(a or b for a, b in zip(self.values, other.values))


class Matrix(Vector):
    def __init__(self, values, rows, columns):
        Vector.__init__(self, values)
        self.rows, self.columns = rows, columns

    def __getitem__(self, row):
        return Vector(self.values[row*self.columns:(row+1)*self.columns])

    def sum(self, axis):
        assert axis == 1
        return Vector(sum(self[row].values) for row in range(self.rows))


class ArrayStorage(object):
    int8, int32, int64 = 'i1', 'i4', 'i8'

    @staticmethod
    def zeros(count, dtype):
        return Vector([0]*count)

    @staticmethod
    def any(value):
        return any(value.values)

    @staticmethod
    def prod(shape):
        result = 1
        for value in shape:
            result *= value
        return result


class Tensor(object):
    def __init__(self, shape, scale=1.0, zero_point=0):
        self.shape = shape
        self.scales, self.zero_points = [scale], [zero_point]


class Padding(object):
    SAME, VALID = 0, 1


class TFLite(object):
    Padding = Padding
    Conv2DOptions, FullyConnectedOptions = 'conv', 'fc'
    Pool2DOptions = 'pool'


class Options(object):
    def __init__(self, stride=1, same=False, relu=False,
                 dilation=1, kernel_h=1, kernel_w=1):
        self.stride, self.same, self.relu = stride, same, relu
        self.dilation, self.kernel_h, self.kernel_w = dilation, kernel_h, kernel_w

    def StrideH(self):
        return self.stride

    def StrideW(self):
        return self.stride

    def Padding(self):
        return Padding.SAME if self.same else Padding.VALID

    def FusedActivationFunction(self):
        return 1 if self.relu else 0

    def DilationHFactor(self):
        return self.dilation

    def DilationWFactor(self):
        return self.dilation

    def FilterHeight(self):
        return self.kernel_h

    def FilterWidth(self):
        return self.kernel_w


class Operator(object):
    def __init__(self, options):
        self.options = options

    def InputsLength(self):
        return 2

    def Inputs(self, index):
        return (0, 1)[index]

    def Outputs(self, index):
        return 2


with open(os.path.join(ROOT, 'scripts/model/compile_resnet8_tflite.py')) as handle:
    SOURCE = handle.read()


def run_source(source, name, namespace):
    # Only diagnostic f-strings need spelling changes on the Python 2 host.
    source = source.replace('f"Invalid scale ratio: {ratio}"',
                            '"Invalid scale ratio: {}".format(ratio)')
    source = source.replace('f"No safe fixed-point representation for ratio={ratio}"',
                            '"No safe fixed-point representation for ratio={}".format(ratio)')
    source = source.replace('f"Fused activation {act} not supported"',
                            '"Fused activation {} not supported".format(act)')
    source = source.replace('f"Unexpected per-channel scales "',
                            '"Unexpected per-channel scales "')
    source = source.replace('f"count {len(sweight)}"',
                            '"count {}".format(len(sweight))')
    source = source.replace('f"Output tensor {output_id} already allocated"',
                            '"Output tensor {} already allocated".format(output_id)')
    source = source.replace('f"Output tensor {tid} already allocated"',
                            '"Output tensor {} already allocated".format(tid)')
    eval(compile(source, name, 'exec'), namespace)


# quant_mr uses math.isfinite, which appeared after Python 2.
if not hasattr(math, 'isfinite'):
    math.isfinite = lambda value: not math.isinf(value) and not math.isnan(value)

NS = dict(struct=struct, math=math, np=ArrayStorage(), tflite=TFLite,
          PE_ROWS=4, PE_COLS=4, K_TILE_SIZE=256,
          FLAG_MULTI_K_A_REUSE=32, FLAG_B_STATIONARY=64,
          OP_GEMM=1, OP_CONV=2, OP_AVG=4, DESC_WORDS=16,
          plan_fc_layout=plan_fc_layout, pack_fc_weights=pack_fc_weights,
          pack_fc_params=pack_fc_params,
          qscale=lambda tensor: (tensor.scales, tensor.zero_points),
          scale_1=lambda tensor: (tensor.scales[0], tensor.zero_points[0]),
          tensor_shape=lambda tensor: tensor.shape,
          options=lambda op, cls: op.options)
for name in ('align', 'words', 'quant_mr', 'fused_relu', 'select_dataflow'):
    match = re.search(r'^def ' + name + r'\(.*?(?=^def |^class |\Z)', SOURCE, re.M | re.S)
    run_source(match.group(0), name, NS)
run_source(SOURCE[SOURCE.index('class DDR:'):SOURCE.index('class Compiler:')], 'DDR', NS)
body = 'class CompilerProbe(object):\n'
for name in ('output_addr', 'encode', 'compile_conv_or_fc', 'compile_average'):
    match = re.search(r'^    def ' + name + r'\(.*?(?=^    (?:def |@staticmethod)|^if __name__|\Z)',
                      SOURCE, re.M | re.S)
    body += match.group(0)
run_source(body, 'CompilerProbe', NS)
Probe = NS['CompilerProbe']
Probe.select_dataflow = staticmethod(NS['select_dataflow'])


def compile_layer(kind, height, width, channels, cols=4, rows=4, k=3, stride=1,
                  same=False, dilation=1):
    NS['PE_ROWS'], NS['PE_COLS'] = rows, cols
    compiler = Probe()
    compiler.mem, compiler.address = NS['DDR'](), {0: 0x1000}
    compiler.desc, compiler.layers, compiler.fc_layouts = [], [], {}
    compiler.dataflow = 'auto'
    if kind == 'conv':
        kh = kw = 1
        oh = (height+stride-1)//stride if same else (height-kh)//stride+1
        ow = (width+stride-1)//stride if same else (width-kw)//stride+1
        shape_in, shape_out = [1, height, width, k], [1, oh, ow, channels]
        shape_weight = [channels, kh, kw, k]
    else:
        shape_in, shape_out, shape_weight = [1, k], [1, channels], [channels, k]
    compiler.tensors = [Tensor(shape_in), Tensor(shape_weight), Tensor(shape_out)]
    weights = Matrix([((i*3) % 7)-3 for i in range(channels*k)], channels, k)
    compiler.tensor_array = lambda idx, dtype: weights
    compiler.compile_conv_or_fc(Operator(Options(stride=stride, same=same,
                                                dilation=dilation)), kind)
    return compiler


def compile_average(height, width, opts, output_channels=4):
    compiler = Probe()
    compiler.mem, compiler.address = NS['DDR'](), {0: 0x1000}
    compiler.desc, compiler.layers, compiler.fc_layouts = [], [], {}
    compiler.tensors = [Tensor([1, height, width, 4]), Tensor([1]),
                        Tensor([1, 1, 1, output_channels])]
    compiler.compile_average(Operator(opts))
    return compiler


class LegacyCompatibilityTests(unittest.TestCase):
    def test_conv_spatial_and_channel_tails_use_logical_hwc(self):
        for cols in (4, 8):
            for height, width in ((1, 1), (3, 5), (7, 7)):
                for channels in range(1, 2*cols+1):
                    compiler = compile_layer('conv', height, width, channels, cols)
                    d = compiler.desc[0]
                    self.assertEqual(d[1:4], [height*width, channels, 3])
                    self.assertEqual(d[8], compiler.address[2])
                    self.assertEqual(compiler.mem.cursor-d[8],
                                     NS['align'](height*width*channels, 8))
                    # Weight/parameter padding can remain physical. Output N is logical.
                    padded = NS['align'](channels, cols)
                    self.assertEqual(d[13]-d[6], NS['align'](padded*8, 64))
                    self.assertEqual(compiler.layers[0]['shape'], [1, height, width, channels])

    def test_original_complete_conv_layout_is_preserved(self):
        compiler = compile_layer('conv', 32, 32, 16)
        d = compiler.desc[0]
        self.assertEqual(d[1:4], [1024, 16, 3])
        self.assertEqual(d[10:13], [(32 << 16) | 32, 0x01010003, 0x00000101])
        self.assertEqual(compiler.layers[0]['opcode'], 'CONV')
        self.assertEqual(compiler.layers[0]['shape'], [1, 32, 32, 16])

    def test_fc_physical_layout_and_artifact_fields_are_preserved(self):
        for cols in (4, 8):
            for classes in (1, 10, 1001):
                compiler = compile_layer('fc', 1, 1, classes, cols=cols, k=7)
                d, layer = compiler.desc[0], compiler.layers[0]
                layout = plan_fc_layout(1, classes, 7, rows=4, cols=cols,
                                        output_element_bytes=1)
                self.assertEqual(d[1:4], [4, layout['physical_n'], 7])
                self.assertEqual(d[10:13], [0, 8, layout['c_stride_bytes']])
                self.assertEqual(layer['fc_layout'], layout)
                self.assertEqual(layer['logical_output_bytes'], classes)
                self.assertEqual(layer['physical_output_bytes'], layout['c_bytes'])
                self.assertEqual(compiler.mem.cursor-d[8], layout['c_bytes'])

    def test_same_stride_keeps_ceil_output_and_flag(self):
        compiler = compile_layer('conv', 7, 7, 5, stride=2, same=True)
        d = compiler.desc[0]
        self.assertEqual(d[1:4], [16, 5, 3])
        self.assertEqual(d[0] & (16 << 8), 16 << 8)

    def test_dilated_conv_rejected_before_emitting_descriptor(self):
        with self.assertRaises(NotImplementedError):
            compile_layer('conv', 7, 7, 4, dilation=2)

    def test_global_average_preserves_original_valid_descriptor(self):
        compiler = compile_average(8, 8, Options(kernel_h=8, kernel_w=8))
        self.assertEqual(compiler.desc[0][0:4], [4, 8, 8, 4])
        self.assertEqual(compiler.desc[0][10:13], [0, 0, 0])
        self.assertEqual(compiler.layers[0]['shape'], [1, 1, 1, 4])
        compiler = compile_average(3, 3, Options(stride=3, same=True,
                                                kernel_h=3, kernel_w=3))
        self.assertEqual(compiler.desc[0][0:4], [4, 3, 3, 4])

    def test_local_pool_or_fused_activation_is_not_silently_lowered_as_gap(self):
        # VALID 2x2/stride2 on 3x3 also produces 1x1, but omits five pixels.
        with self.assertRaises(ValueError):
            compile_average(3, 3, Options(stride=2, kernel_h=2, kernel_w=2))
        with self.assertRaises(NotImplementedError):
            compile_average(3, 3, Options(relu=True, kernel_h=3, kernel_w=3))
        with self.assertRaises(ValueError):
            compile_average(3, 3, Options(kernel_h=3, kernel_w=3), output_channels=8)
        with self.assertRaises(ValueError):
            compile_average(3, 3, Options(same=True, kernel_h=3, kernel_w=3))


if __name__ == '__main__':
    unittest.main(verbosity=2)
