#!/usr/bin/env python
"""Independent descriptor/value tests, requiring only the standard library."""
from __future__ import print_function
import struct
import glob
import os
import unittest
from reference_int8 import execute


def command(op, flags=0, m=1, n=1, k=1, a=64, b=128, c=512,
            words=(0, 0, 0), param=256, pool=0):
    return struct.pack('<16I', op | (flags << 8), m, n, k,
                       a, 0, b, 0, c, 0, words[0], words[1], words[2], param, 0, pool)


def store(memory, address, values):
    memory[address:address+len(values)] = bytearray(value & 255 for value in values)


def channel_params(memory, records, input_zp=0, output_zp=0, param=256):
    struct.pack_into('<4I', memory, param, 0, 0,
                     input_zp & 0xffffffff, output_zp & 0xffffffff)
    for channel, (bias, multiplier, shift) in enumerate(records):
        struct.pack_into('<iII', memory, param+16+12*channel, bias, multiplier, shift)


class DescriptorReferenceTests(unittest.TestCase):
    def test_original_smallcnn_images_match_existing_golden(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        artifact = os.path.join(root, 'artifacts', 'npu')
        with open(os.path.join(artifact, 'commands.bin'), 'rb') as handle:
            commands = handle.read()
        names = ('conv1', 'pool1', 'conv2', 'pool2', 'fc')
        images = sorted(glob.glob(os.path.join(artifact, 'ddr', 'image_*.bin')))
        self.assertEqual(len(images), 4)
        for path in images:
            with open(path, 'rb') as handle:
                image = handle.read()
            _, traces = execute(image, commands)
            self.assertEqual(len(traces), len(names))
            image_name = os.path.splitext(os.path.basename(path))[0]
            for index, (name, trace) in enumerate(zip(names, traces)):
                flags = struct.unpack_from('<I', commands, index*64)[0] >> 8
                code = 'i' if trace['opcode'] in (1, 2) and not flags & 2 else 'b'
                actual = struct.pack('<' + str(len(trace['values'])) + code, *trace['values'])
                with open(os.path.join(artifact, 'golden', image_name, name+'.bin'), 'rb') as handle:
                    self.assertEqual(actual, handle.read(), image_name+'/'+name)

    def test_gemm_logical_tails_strides_and_per_channel_rounding(self):
        image = bytearray([0x55])*1024
        store(image, 64, [-3, -1, 1])
        store(image, 80, [3, 1, -1])
        for channel in range(5):
            store(image, 128+channel*8, [channel+1, 0, 0])
        channel_params(image, [(0, 1, 1)]*5, output_zp=3)
        data, traces = execute(image, command(1, 11, m=2, n=5, k=3, words=(16, 8, 8)))
        expected = [1, 0, -2, -3, -5, 5, 6, 8, 9, 11]
        self.assertEqual(traces[0]['values'], expected)
        self.assertEqual(traces[0]['shape'], [2, 5])
        for row in range(2):
            self.assertEqual(list(data[512+row*8:517+row*8]),
                             [v & 255 for v in expected[row*5:(row+1)*5]])
            self.assertEqual(data[517+row*8:520+row*8], bytearray([0x55])*3)
        self.assertEqual(data[:512], image[:512])
        self.assertEqual(data[528:], image[528:])

    def test_conv_padding_uses_input_zero_point_and_tight_tail_channels(self):
        image = bytearray([0x55])*1024
        store(image, 64, [3, 4, 5, 6])
        for channel in range(5):
            store(image, 128+channel*16, [channel+1]*9)
        channel_params(image, [(-27*(c+1), 1, 1) for c in range(5)],
                       input_zp=3, output_zp=-2)
        geometry = ((2 << 16) | 2, 0x03030001, 0x01010101)
        data, traces = execute(image, command(2, 11, m=4, n=5, k=9, words=geometry))
        expected = [1, 4, 7, 10, 13]*4
        self.assertEqual(traces[0]['values'], expected)
        self.assertEqual(traces[0]['shape'], [2, 2, 5])
        self.assertEqual(list(data[512:532]), expected)
        self.assertEqual(data[532:], image[532:])

    def test_same_asymmetric_padding_geometry(self):
        image = bytearray(1024)
        store(image, 64, range(1, 17))
        store(image, 128, [1]*9)
        channel_params(image, [(-9, 1, 0)], input_zp=1)
        geometry = ((4 << 16) | 4, 0x03030001, 0x00000202)
        _, traces = execute(image, command(2, 27, m=4, n=1, k=9, words=geometry))
        self.assertEqual(traces[0]['shape'], [2, 2, 1])
        self.assertEqual(traces[0]['values'], [45, 39, 66, 50])

    def test_bias_33bit_global_quant_and_int32_output(self):
        image = bytearray(1024)
        store(image, 64, [1])
        store(image, 128, [1])
        struct.pack_into('<II', image, 256, 1, 0)
        struct.pack_into('<i', image, 272, 2147483647)
        _, traces = execute(image, command(1, 3, words=(8, 8, 4)))
        self.assertEqual(traces[0]['values'], [127])
        data, traces = execute(image, command(1, 1, words=(8, 8, 4)))
        self.assertEqual(traces[0]['values'], [-2147483648])
        self.assertEqual(struct.unpack_from('<i', data, 512)[0], -2147483648)

    def test_add_independent_quantization_relu_and_saturation(self):
        image = bytearray(1024)
        store(image, 64, [-128, -1, 2, 127])
        store(image, 128, [127, -3, 1, -128])
        struct.pack_into('<6I', image, 256, 2, (-1) & 0xffffffff, 5, 3, 1, 1)
        _, traces = execute(image, command(5, 0, m=4, n=0, k=0))
        self.assertEqual(traces[0]['values'], [-126, -1, 6, 127])
        _, traces = execute(image, command(5, 1, m=4, n=0, k=0))
        self.assertEqual(traces[0]['values'], [5, 5, 6, 127])

    def test_maxpool_negative_padding_and_gap_rounding(self):
        image = bytearray(1024)
        store(image, 64, [-9, -8, -7, -6, -5, -4, -3, -2,
                          -13, -12, -11, -10, -1, -2, -3, -4])
        geometry = 3 | (3 << 8) | (2 << 16) | (2 << 24)
        padding = 1 | (1 << 8) | (1 << 16) | (1 << 24)
        _, traces = execute(image, command(3, m=2, n=2, k=4, b=0, param=0,
                                          words=(padding, 0, 0), pool=geometry))
        self.assertEqual(traces[0]['values'], [-1, -2, -3, -2])
        store(image, 64, [-1, 1, -3, 3, 0, 0, 0, 0])
        _, traces = execute(image, command(4, m=1, n=2, k=4, b=0, param=0))
        self.assertEqual(traces[0]['values'], [-1, 1, -2, 2])

    def test_serialized_command_sequence_reads_prior_output(self):
        image = bytearray(1024)
        store(image, 64, [1, 2, 3, 4, 3, 4, 5, 6])
        store(image, 128, [1, 1, 1, 1])
        struct.pack_into('<6I', image, 256, 0, 0, 0, 1, 1, 0)
        commands = command(4, m=1, n=2, k=4, b=0, param=0)
        commands += command(5, m=4, n=0, k=0, a=512, c=600)
        _, traces = execute(image, commands)
        self.assertEqual(traces[0]['values'], [2, 3, 4, 5])
        self.assertEqual(traces[1]['values'], [3, 4, 5, 6])

    def test_fused_conv_and_batch_one_fc_pool_reshape(self):
        image = bytearray(1024)
        store(image, 64, [1, 2, 3, 4])
        for channel in range(4):
            store(image, 128+channel*8, [channel+1])
        channel_params(image, [(0, 1, 0)]*4)
        geometry = ((2 << 16) | 2, 0x01010001, 0x00000101)
        _, traces = execute(image, command(2, 139, m=4, n=4, k=1, words=geometry))
        self.assertEqual(traces[0]['shape'], [1, 1, 4])
        self.assertEqual(traces[0]['values'], [4, 8, 12, 16])
        # FC physical rows repeat one real vector; only row 0 enters pooling.
        image = bytearray(2048)
        store(image, 64, [1])
        for channel in range(16):
            store(image, 128+channel*8, [channel+1])
        struct.pack_into('<8I', image, 512, 0, 0, 0, 0, 2, 2, 4, 1)
        for channel in range(16):
            struct.pack_into('<iII', image, 544+channel*12, 0, 1, 0)
        _, traces = execute(image, command(1, 139, m=4, n=16, k=1,
                                          words=(0, 8, 16), param=512, c=1024))
        self.assertEqual(traces[0]['shape'], [1, 1, 4])
        self.assertEqual(traces[0]['values'], [13, 14, 15, 16])

    def test_out_of_bounds_or_invalid_parameters_fail(self):
        with self.assertRaises(ValueError):
            execute(bytearray(1024), b'bad')
        with self.assertRaises(ValueError):
            execute(bytearray(1024), command(1, words=(8, 8, 4), a=1024))
        image = bytearray(1024)
        channel_params(image, [(0, 1, 63)])
        with self.assertRaises(ValueError):
            execute(image, command(1, 11, words=(8, 8, 4)))
        struct.pack_into('<6I', image, 256, 0, 0, 0, 1 << 31, 1, 0)
        with self.assertRaises(ValueError):
            execute(image, command(5, m=4, n=0, k=0))


if __name__ == '__main__':
    unittest.main(verbosity=2)
