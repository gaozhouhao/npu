"""Compare the accelerated serialized-DDR interpreter against the scalar oracle."""
from __future__ import print_function

import glob
import os
import random
import struct
import unittest

import numpy as np

from reference_int8 import execute as scalar_execute
from reference_numpy import execute
from test_reference_int8 import channel_params, command, store


class NumpyReferenceTests(unittest.TestCase):
    def compare(self, image, commands, workspace=256):
        expected = scalar_execute(image, commands)
        actual = execute(image, commands, max_workspace_bytes=workspace)
        self.assertEqual(actual, expected)
        return actual

    def test_compiled_residual_fixture_and_streamed_traces(self):
        from check_graph_compiler import fixture
        from graph_compiler import compile_graph
        graph, cfg, profile, inputs = fixture()
        _, image, commands = compile_graph(graph, cfg, profile, inputs)
        expected_memory, expected_traces = self.compare(image, commands)
        observed = []
        memory, traces = execute(image, commands, trace_callback=observed.append,
                                 retain_traces=False, max_workspace_bytes=128)
        self.assertEqual(memory, expected_memory)
        self.assertEqual(traces, [])
        self.assertEqual(observed, expected_traces)

    def test_smallcnn_existing_golden_without_fused_pooling(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        base = os.path.join(root, 'artifacts', 'npu')
        with open(os.path.join(base, 'commands.bin'), 'rb') as handle:
            commands = handle.read()
        images = sorted(glob.glob(os.path.join(base, 'ddr', 'image_*.bin')))
        self.assertEqual(len(images), 4)
        for path in images:
            with open(path, 'rb') as handle:
                image = handle.read()
            _, traces = self.compare(image, commands, workspace=1024)
            image_name = os.path.splitext(os.path.basename(path))[0]
            for index, (name, trace) in enumerate(zip(('conv1', 'pool1', 'conv2', 'pool2', 'fc'), traces)):
                flags = struct.unpack_from('<I', commands, index*64)[0] >> 8
                dtype = '<i4' if trace['opcode'] in (1, 2) and not flags & 2 else 'i1'
                actual = np.asarray(trace['values'], dtype=dtype).tobytes()
                with open(os.path.join(base, 'golden', image_name, name+'.bin'), 'rb') as handle:
                    self.assertEqual(actual, handle.read(), image_name+'/'+name)

    def test_signed_gemm_tails_strides_zero_points_and_half_ties(self):
        image = bytearray([0x55])*2048
        store(image, 64, [-3, -1, 1])
        store(image, 80, [3, 1, -1])
        for channel in range(5):
            store(image, 128+channel*8, [channel+1, 0, 0])
        channel_params(image, [(0, 1, 1)]*5, input_zp=-7, output_zp=3)
        _, traces = self.compare(image, command(1, 11, m=2, n=5, k=3, words=(16, 8, 8)))
        self.assertEqual(traces[0]['values'], [1, 0, -2, -3, -5, 5, 6, 8, 9, 11])
        self.compare(image, command(1, 15, m=3, n=5, k=3, words=(0, 8, 8)))

    def test_randomized_convolution_padding_tails_relu_and_chunk_boundaries(self):
        rng = random.Random(84509)
        for same in (False, True):
            for relu in (False, True):
                height, width, channels, outputs = 4, 5, 3, 5
                kh, kw, sh, sw = 3, 3, 2, 2
                pt, pl = (0, 1) if same else (1, 1)
                oh = (height+sh-1)//sh if same else (height+2*pt-kh)//sh+1
                ow = (width+sw-1)//sw if same else (width+2*pl-kw)//sw+1
                k = kh*kw*channels
                image = bytearray([0x55])*4096
                store(image, 64, [rng.randint(-128, 127) for _ in range(height*width*channels)])
                for channel in range(outputs):
                    store(image, 256+channel*32, [rng.randint(-128, 127) for _ in range(k)])
                params = [(rng.randint(-20000, 20000), channel+1, channel+8)
                          for channel in range(outputs)]
                channel_params(image, params, input_zp=-17, output_zp=11, param=512)
                geometry = (height | width << 16, channels | kh << 16 | kw << 24,
                            sh | sw << 8 | pt << 16 | pl << 24)
                desc = command(2, 11 | (16 if same else 0) | (4 if relu else 0),
                               m=oh*ow, n=outputs, k=k, b=256, c=1024,
                               words=geometry, param=512)
                self.compare(image, desc, workspace=64)
                self.compare(image, desc, workspace=1024*1024)

    def test_randomized_gemm_global_and_per_channel_numeric_modes(self):
        rng = random.Random(933501)
        for flags in (0, 1, 2, 3, 6, 7, 10, 11, 14, 15):
            for _ in range(5):
                m, n, k = rng.randint(1, 5), rng.randint(1, 7), rng.randint(1, 11)
                astride, bstride = (k+7)//8*8, (k+7)//8*8
                cstride = ((n*(1 if flags & 2 else 4)+7)//8)*8
                image = bytearray([0x55])*4096
                for row in range(m):
                    store(image, 64+row*astride, [rng.randint(-128, 127) for _ in range(k)])
                for channel in range(n):
                    store(image, 256+channel*bstride, [rng.randint(-128, 127) for _ in range(k)])
                if flags & 8:
                    params = [(rng.randint(-2**31, 2**31-1), rng.randint(0, 2**31-1),
                               rng.choice((0, 1, 31, 62))) for _ in range(n)]
                    channel_params(image, params, input_zp=rng.randint(-128, 127),
                                   output_zp=rng.randint(-128, 127), param=512)
                else:
                    struct.pack_into('<4I', image, 512, rng.randint(0, 2**31-1),
                                     rng.choice((0, 1, 31, 62)), 0, 0)
                    for channel in range(n):
                        struct.pack_into('<i', image, 528+channel*4,
                                         rng.randint(-2**31, 2**31-1))
                self.compare(image, command(1, flags, m=m, n=n, k=k, b=256, c=1024,
                                            words=(astride, bstride, cstride), param=512))

    def test_gemm_int32_wrap_and_33bit_bias_signed64_rounding(self):
        k = 140000
        image = bytearray(2*k+4096)
        a, b, param, c = 64, k+128, 2*k+512, 2*k+1024
        store(image, a, [127]*k)
        store(image, b, [127]*k)
        channel_params(image, [(2147483647, 2147483647, 62)], param=param)
        self.compare(image, command(1, 11, m=1, n=1, k=k, a=a, b=b, c=c,
                                    words=(k, k, 4), param=param))
        # Products near either INT64 limit must not overflow while adding half.
        self.compare(image, command(1, 11, k=133000, a=a, b=b, c=c,
                                    words=(k, k, 4), param=param))
        store(image, a, [-128]*131072)
        store(image, b, [-128]*131072)
        channel_params(image, [(-2147483648, 2147483647, 62)], param=param)
        self.compare(image, command(1, 11, k=131072, a=a, b=b, c=c,
                                    words=(k, k, 4), param=param))
        struct.pack_into('<4I', image, param, 1, 0, 0, 0)
        struct.pack_into('<i', image, param+16, 2147483647)
        store(image, a, [1])
        store(image, b, [1])
        self.compare(image, command(1, 3, a=a, b=b, c=c,
                                    words=(8, 8, 4), param=param))
        _, traces = self.compare(image, command(1, 1, a=a, b=b, c=c,
                                                words=(8, 8, 4), param=param))
        self.assertEqual(traces[0]['values'], [-2147483648])

    def test_residual_add_independent_zero_points_saturation_and_relu(self):
        image = bytearray(2048)
        store(image, 64, [-128, -1, 2, 127])
        store(image, 128, [127, -3, 1, -128])
        struct.pack_into('<6I', image, 256, 2, (-1) & 0xffffffff, 5, 3, 1, 1)
        _, traces = self.compare(image, command(5, 0, m=4, n=0, k=0))
        self.assertEqual(traces[0]['values'], [-126, -1, 6, 127])
        self.compare(image, command(5, 1, m=4, n=0, k=0))

    def test_maxpool_all_sides_negative_padding_and_gap_half_ties(self):
        image = bytearray(2048)
        store(image, 64, [-9, -8, -7, -6, -5, -4, -3, -2,
                          -13, -12, -11, -10, -1, -2, -3, -4])
        pool = 3 | 3 << 8 | 2 << 16 | 2 << 24
        for padding in (1 | 1 << 8 | 1 << 16 | 1 << 24, 1 << 16 | 1 << 24):
            self.compare(image, command(3, m=2, n=2, k=4, b=0, param=0,
                                        words=(padding, 0, 0), pool=pool))
        self.compare(image, command(3, m=2, n=2, k=4, b=0, param=0))
        store(image, 64, [-1, 1, -3, 3, 0, 0, 0, 0])
        _, traces = self.compare(image, command(4, m=1, n=2, k=4, b=0, param=0))
        self.assertEqual(traces[0]['values'], [-1, 1, -2, 2])

    def test_command_sequence_reads_prior_ddr_and_leaves_padding_untouched(self):
        image = bytearray([0x55])*2048
        store(image, 64, [1, 2, 3, 4, 3, 4, 5, 6])
        store(image, 128, [1, 1, 1, 1])
        struct.pack_into('<6I', image, 256, 0, 0, 0, 1, 1, 0)
        commands = command(4, m=1, n=2, k=4, b=0, param=0)
        commands += command(5, m=4, n=0, k=0, a=512, c=600)
        memory, _ = self.compare(image, commands)
        self.assertEqual(memory[604:], image[604:])

    def test_invalid_access_parameters_and_fused_commands_fail(self):
        for image, desc in ((bytearray(1024), b'bad'),
                            (bytearray(1024), command(1, words=(8, 8, 4), a=1024)),
                            (bytearray(1024), command(1, 139, words=(8, 8, 4)))):
            with self.assertRaises(ValueError):
                execute(image, desc)
        image = bytearray(1024)
        channel_params(image, [(0, 1, 63)])
        with self.assertRaises(ValueError):
            execute(image, command(1, 11, words=(8, 8, 4)))
        with self.assertRaises(ValueError):
            execute(image, command(1, words=(8, 8, 4)), max_workspace_bytes=0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
