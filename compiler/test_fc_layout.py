"""Standard-library FC packing tests; runnable with Python 2.7 or Python 3."""
from __future__ import print_function

import struct
import unittest

from fc_layout import (plan_fc_layout, pack_fc_input, pack_fc_weights,
                       pack_fc_params, make_fc_descriptor,
                       extract_fc_output, fc_argmax)


class FCLayoutTests(unittest.TestCase):
    def test_crop_each_row_before_argmax(self):
        layout = plan_fc_layout(3, 5, 9)
        values = []
        for row in range(4):
            # Padding is deliberately greater than every valid score.
            values.extend([-20-row*10+col for col in range(5)]+[999999]*3)
        physical = struct.pack('<32i', *values)
        logical = struct.unpack('<15i', extract_fc_output(physical, layout))
        self.assertEqual(logical, tuple(value for row in range(3)
                                        for value in values[row*8:row*8+5]))
        self.assertEqual(fc_argmax(physical, layout), [4, 4, 4])
        self.assertEqual(layout['a_stride_bytes'], 16)
        self.assertEqual(layout['c_bytes'], 128)

    def test_nonzero_input_zero_point_and_folded_bias(self):
        layout = plan_fc_layout(1, 1, 3)
        data = struct.pack('3b', -7, -4, -6)
        weights = struct.pack('3b', 2, -1, 3)
        padded = bytearray(pack_fc_input(data, layout, input_zero_point=-5))
        self.assertEqual(list(padded[3:]), [251]*(layout['a_bytes']-3))
        params = pack_fc_params(weights, [17], layout, input_zero_point=-5)
        folded = struct.unpack_from('<i', params, 16)[0]
        raw = sum(x*w for x, w in zip((-7, -4, -6), (2, -1, 3)))+folded
        centered = sum((x+5)*w for x, w in zip((-7, -4, -6), (2, -1, 3)))+17
        self.assertEqual(raw, centered)
        # Dummy input rows encode real zero, hence real channels retain bias.
        self.assertEqual(-5*sum((2, -1, 3))+folded, 17)
        self.assertEqual(struct.unpack_from('<3i', params, 20), (0, 0, 0))

    def test_quantized_dummy_columns_have_zero_parameters(self):
        layout = plan_fc_layout(1, 5, 1, output_element_bytes=1)
        params = pack_fc_params(struct.pack('5b', 1, 2, -3, 4, 5),
                                [1, 2, 3, 4, 5], layout,
                                input_zero_point=-7, output_zero_point=13,
                                requant=[(1, 0)]*5)
        self.assertEqual(len(params), 16+8*12)
        self.assertEqual(struct.unpack_from('<3i', params, 16+5*12), (0, 0, 0))
        self.assertEqual(struct.unpack_from('<i', params, 12)[0], 13)
        desc = make_fc_descriptor(layout, 4096, 8192, 12288, 16384,
                                  requantized=True)
        self.assertEqual((desc['m'], desc['n'], desc['k']), (4, 8, 1))
        self.assertEqual(desc['flags'], 11)
        self.assertEqual(desc['words10_12'], [8, 8, 8])

    def test_bad_data_and_layout_are_rejected(self):
        layout = plan_fc_layout(1, 5, 3)
        with self.assertRaises(ValueError):
            pack_fc_input(b'\0'*2, layout)
        with self.assertRaises(ValueError):
            pack_fc_weights(b'\0'*14, layout)
        with self.assertRaises(ValueError):
            extract_fc_output(b'\0'*(layout['c_bytes']-1), layout)
        with self.assertRaises(ValueError):
            make_fc_descriptor(layout, 4097, 8192, 12288, 16384)
        bad = dict(layout, c_stride_bytes=5)
        with self.assertRaises(ValueError):
            pack_fc_weights(b'\0'*15, bad)
        with self.assertRaises(ValueError):
            pack_fc_params(b'\1'*15, [2**31-1]*5, layout, input_zero_point=-1)


if __name__ == '__main__':
    unittest.main()
