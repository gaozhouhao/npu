"""Standard-library FC/reshape/pool ABI tests for Python 2.7 and Python 3."""
from __future__ import print_function

import copy
import os
import struct
import unittest

from fc_layout import (plan_fc_layout, pack_fc_input, pack_fc_weights,
                       pack_fc_params, make_fc_descriptor)
from fc_pool import (plan_fc_pool_layout, pack_fc_pool_params,
                     make_fc_pool_descriptor)


# target.py also owns Python-3-only deployment utilities. Extract the actual
# pure production policy, without substituting a duplicate implementation.
with open(os.path.join(os.path.dirname(__file__), 'target.py')) as handle:
    _target_source = handle.read()
_policy = dict(struct=struct)
for _begin, _end in [('def require(', 'def digest('),
                     ('def align(', 'class MemoryPlan:')]:
    _source = _target_source[_target_source.index(_begin):_target_source.index(_end)]
    eval(compile(_source, 'target.production-policy', 'exec'), _policy)
validate_descriptor = _policy['validate_descriptor']
pack_pool_config = _policy['pack_pool_config']


class FCPoolTests(unittest.TestCase):
    cfg = dict(pe_rows=4, pe_cols=4, pool_line_words=1024)

    def make_descriptor(self, plan, **kwargs):
        args = dict(a=4096, b=8192, c=12288, param=16384)
        args.update(kwargs)
        return make_fc_pool_descriptor(plan, **args)

    def test_explicit_shape_and_pooled_allocation(self):
        plan = plan_fc_pool_layout(9, (4, 6, 8))
        fc = plan['fc_layout']
        self.assertEqual((fc['logical_m'], fc['physical_m'], fc['logical_n']), (1, 4, 192))
        self.assertEqual(plan['pool_output_shape'], [2, 3, 8])
        self.assertEqual(plan['pool_required_line_words'], 24)
        self.assertEqual((plan['a_bytes'], plan['b_bytes'], plan['c_bytes']), (64, 3072, 48))
        self.assertEqual(fc['c_bytes'], 768)
        self.assertEqual(len(pack_fc_input(b'\0'*9, fc)), plan['a_bytes'])
        self.assertEqual(len(pack_fc_weights(b'\0'*(192*9), fc)), plan['b_bytes'])

    def test_literal_descriptor_words_and_round_trip(self):
        plan = plan_fc_pool_layout(9, (4, 6, 8))
        desc = self.make_descriptor(plan)
        validate_descriptor(desc, self.cfg)
        words = struct.unpack('<16I', _policy['encode'](desc))
        self.assertEqual(words, (0x8b01, 4, 192, 9, 4096, 0, 8192, 0,
                                 12288, 0, 16, 16, 192, 16384, 0, 0))
        decoded = _policy['decode'](_policy['encode'](desc))
        self.assertEqual(decoded, dict((k, v) for k, v in desc.items() if k != 'pool_config'))
        custom = plan_fc_pool_layout(9, (4, 6, 8),
                                     pool_config=pack_pool_config(3, 2, 2, 1))
        self.assertEqual(struct.unpack('<16I', _policy['encode'](
            self.make_descriptor(custom)))[15], 0x01020203)

    def test_extended_header_preserves_channel_records_and_bias_folding(self):
        plan = plan_fc_pool_layout(3, (2, 2, 4))
        weights = struct.pack('3b', 2, -1, 3)*16
        bias = list(range(16))
        pairs = [(c+1, 3) for c in range(16)]
        ordinary = pack_fc_params(weights, bias, plan['fc_layout'], -5, 13, pairs)
        fused = pack_fc_pool_params(weights, bias, plan, -5, 13, pairs)
        self.assertEqual(len(fused), 32+16*12)
        self.assertEqual(fused[:16], ordinary[:16])
        self.assertEqual(struct.unpack_from('<4I', fused, 16), (2, 2, 4, 1))
        self.assertEqual(fused[32:], ordinary[16:])
        self.assertEqual(struct.unpack_from('<iII', fused, 32), (20, 1, 3))
        self.assertEqual(struct.unpack_from('<iII', fused, 32+15*12), (35, 16, 3))

    def test_global_requantization_header_and_bias_only_records(self):
        plan = plan_fc_pool_layout(3, (2, 2, 4), per_channel=False)
        weights = struct.pack('3b', 2, -1, 3)*16
        params = pack_fc_pool_params(weights, list(range(16)), plan,
                                     input_zero_point=-5, output_zero_point=-7,
                                     global_requant=(3, 2))
        self.assertEqual(len(params), 32+16*4)
        self.assertEqual(struct.unpack_from('<4i', params, 0), (3, 2, -5, -7))
        self.assertEqual(struct.unpack_from('<4I', params, 16), (2, 2, 4, 1))
        self.assertEqual(struct.unpack_from('<16i', params, 32), tuple(range(20, 36)))
        desc = self.make_descriptor(plan, relu=True)
        self.assertEqual(desc['flags'], 0x87)
        validate_descriptor(desc, self.cfg)

    def test_complete_state_required_even_when_one_channel_tile_fits(self):
        # Raw input rows need 48 words; a COLS=4 tile needs 16 words.
        for capacity in (16, 47):
            with self.assertRaises(ValueError):
                plan_fc_pool_layout(3, (8, 8, 12), pool_line_words=capacity)
        plan = plan_fc_pool_layout(3, (8, 8, 12), pool_line_words=48)
        self.assertEqual(plan['pool_required_line_words'], 48)

    def test_default_output_tile_count_boundary(self):
        # Use 1x1 pooling and enough state so only the 16-bit scheduler count
        # distinguishes these shapes. No large tensors need to be allocated.
        config = pack_pool_config(1, 1, 1, 1)
        plan = plan_fc_pool_layout(1, (1, 65535, 4), pool_config=config,
                                   pool_line_words=65536)
        self.assertEqual(plan['n_tile_count'], 65535)
        self.assertEqual(plan['fc_layout']['physical_n'], 262140)
        self.assertEqual(self.make_descriptor(plan)['n'], 262140)
        with self.assertRaises(ValueError) as error:
            plan_fc_pool_layout(1, (1, 65536, 4), pool_config=config,
                                pool_line_words=65536)
        self.assertIn('tile count', str(error.exception))

    def test_configured_output_counter_and_channel_group_boundary(self):
        config = pack_pool_config(1, 1, 1, 1)
        for cols in (4, 8, 12):
            plan = plan_fc_pool_layout(1, (1, 7, cols), cols=cols,
                                       pool_config=config, pool_line_words=24,
                                       tile_count_width=3)
            self.assertEqual((plan['tile_count_width'], plan['n_tile_count']), (3, 7))
            self.make_descriptor(plan)
            with self.assertRaises(ValueError) as error:
                plan_fc_pool_layout(1, (1, 8, cols), cols=cols,
                                    pool_config=config, pool_line_words=24,
                                    tile_count_width=3)
            self.assertIn('tile count', str(error.exception))
        for width in (0, 33, True, 16.0):
            with self.assertRaises(ValueError):
                plan_fc_pool_layout(1, (2, 2, 4), tile_count_width=width)

    def test_shape_product_and_stride_unsigned_boundaries(self):
        config = pack_pool_config(1, 1, 1, 1)
        # Every dimension fits uint32 individually; their HWC product does not.
        with self.assertRaises(ValueError) as error:
            plan_fc_pool_layout(1, (2**30, 1, 4), pool_config=config,
                                tile_count_width=32)
        self.assertIn('reshape element count', str(error.exception))
        # The largest aligned K stride fits; the next K rounds past uint32.
        layout = plan_fc_layout(1, 16, 2**32-8, output_element_bytes=1)
        self.assertEqual(layout['a_stride_bytes'], 2**32-8)
        with self.assertRaises(ValueError):
            plan_fc_layout(1, 16, 2**32-7, output_element_bytes=1)
        plan = plan_fc_pool_layout(2**32-8, (2, 2, 4), tile_count_width=32)
        self.assertEqual(plan['k_tile_count'], 2**24)
        self.assertEqual(plan['fc_layout']['a_stride_bytes'], 2**32-8)

    def test_k_tile_count_boundary_and_configured_size(self):
        plan = plan_fc_pool_layout(65535*256, (2, 2, 4))
        self.assertEqual((plan['k_tile_size'], plan['k_tile_count']), (256, 65535))
        self.make_descriptor(plan)
        with self.assertRaises(ValueError) as error:
            plan_fc_pool_layout(65535*256+1, (2, 2, 4))
        self.assertIn('K tile count', str(error.exception))
        for k_tile_size in (8, 24, 64):
            plan = plan_fc_pool_layout(7*k_tile_size, (2, 2, 4),
                                       tile_count_width=3, k_tile_size=k_tile_size)
            self.assertEqual(plan['k_tile_count'], 7)
            with self.assertRaises(ValueError) as error:
                plan_fc_pool_layout(7*k_tile_size+1, (2, 2, 4),
                                    tile_count_width=3, k_tile_size=k_tile_size)
            self.assertIn('K tile count', str(error.exception))
        for invalid in (0, 4, 9, True, 256.0):
            with self.assertRaises(ValueError):
                plan_fc_pool_layout(1, (2, 2, 4), k_tile_size=invalid)

    def test_shape_batch_padding_and_channel_constraints(self):
        invalid = [dict(reshape_shape=None), dict(reshape_shape=(2, 2)),
                   dict(reshape_shape=(2, 2, 4, 1)), dict(reshape_shape=(0, 2, 4)),
                   dict(reshape_shape=(2, 2, 3)), dict(reshape_shape=(2, 2, 6)),
                   dict(reshape_shape=(1, 2, 4)), dict(reshape_shape=(2, 2, True)),
                   dict(reshape_shape=(2, 2, 4.0)), dict(logical_batch=2),
                   dict(logical_batch=0), dict(pool_padding=1), dict(cols=2),
                   dict(cols=6), dict(rows=0), dict(k=0), dict(pool_config=0x01010002),
                   dict(reshape_shape=(2**31, 2, 4), pool_line_words=2**32-1)]
        for change in invalid:
            kwargs = dict(k=3, reshape_shape=(2, 2, 4))
            kwargs.update(change)
            with self.assertRaises(ValueError):
                plan_fc_pool_layout(**kwargs)

    def test_geometry_matches_production_pool_policy(self):
        for fields in ((1, 1, 1, 1), (2, 2, 2, 2), (3, 2, 2, 1),
                       (2, 3, 5, 3), (3, 3, 1, 1)):
            config = pack_pool_config(*fields)
            for cols in (4, 8, 12):
                channels = 2*cols
                words = _policy['pool_line_words'](8, 9, channels, config)
                plan = plan_fc_pool_layout(9, (8, 9, channels), cols=cols,
                                           pool_config=config, pool_line_words=words)
                self.assertEqual(plan['pool_required_line_words'], words)
                oh, ow = _policy['pool_output_shape'](8, 9, config)
                self.assertEqual(plan['c_bytes'], oh*ow*channels)
                validate_descriptor(self.make_descriptor(plan),
                                    dict(self.cfg, pe_cols=cols, pool_line_words=words))

    def test_static_admission_rejects_invalid_fc_modes(self):
        desc = self.make_descriptor(plan_fc_pool_layout(3, (4, 4, 4)))
        for change in (dict(m=8), dict(flags=0x81), dict(flags=0x89),
                       dict(words10_12=[8, 8, desc['n']+4]),
                       dict(pool_config=0x01010002), dict(opcode=3)):
            bad = copy.deepcopy(desc)
            bad.update(change)
            with self.assertRaises(ValueError):
                validate_descriptor(bad, self.cfg)
        with self.assertRaises(ValueError):
            validate_descriptor(desc, dict(self.cfg, pe_cols=2))

    def test_final_output_address_uses_pooled_size(self):
        plan = plan_fc_pool_layout(3, (4, 4, 4))
        self.assertEqual((plan['c_bytes'], plan['fc_layout']['c_bytes']), (16, 256))
        # A full FC allocation would overflow here; the fused 16-byte output fits.
        validate_descriptor(self.make_descriptor(plan, c=2**64-16), self.cfg)
        with self.assertRaises(ValueError):
            self.make_descriptor(plan, c=2**64-12)
        for key in ('a', 'b', 'c', 'param'):
            with self.assertRaises(ValueError):
                self.make_descriptor(plan, **{key: 4097})
        with self.assertRaises(ValueError):
            self.make_descriptor(plan, param=2**64-4)

    def test_all_address_regions_check_exact_unsigned_endpoint(self):
        plan = plan_fc_pool_layout(9, (4, 4, 4))
        for address_key, size_key, alignment in (
                ('a', 'a_bytes', 8), ('b', 'b_bytes', 8),
                ('c', 'c_bytes', 4), ('param', 'param_bytes', 4)):
            last_base = 2**64-plan[size_key]
            self.assertEqual(last_base % alignment, 0)
            self.make_descriptor(plan, **{address_key: last_base})
            with self.assertRaises(ValueError) as error:
                self.make_descriptor(plan, **{address_key: last_base+alignment})
            self.assertIn('allocation exceeds address range', str(error.exception))
            for invalid in (-alignment, 2**64):
                with self.assertRaises(ValueError):
                    self.make_descriptor(plan, **{address_key: invalid})

    def test_requantization_and_plan_mismatches_rejected(self):
        plan = plan_fc_pool_layout(1, (2, 2, 4))
        base = dict(weight_data=b'\1'*16, bias=[0]*16, plan=plan,
                    requant=[(1, 0)]*16)
        invalid = [dict(requant=None), dict(requant=[(1, 0)]*15),
                   dict(requant=[(2**31, 0)]*16), dict(requant=[(1, 63)]*16),
                   dict(requant=[(2**31-1, 62)]*16), dict(bias=[0]*15),
                   dict(global_requant=(1, 0)), dict(input_zero_point=128)]
        for change in invalid:
            kwargs = dict(base)
            kwargs.update(change)
            with self.assertRaises(ValueError):
                pack_fc_pool_params(**kwargs)
        for field, value in (('c_bytes', plan['c_bytes']*4), ('logical_batch', 2)):
            bad = copy.deepcopy(plan)
            bad[field] = value
            with self.assertRaises(ValueError):
                self.make_descriptor(bad)
        global_plan = plan_fc_pool_layout(1, (2, 2, 4), per_channel=False)
        with self.assertRaises(ValueError):
            pack_fc_pool_params(b'\1'*16, [0]*16, global_plan, requant=[(1, 0)]*16)

    def test_quantized_fc_values_follow_explicit_hwc_reshape(self):
        config = pack_pool_config(2, 2, 1, 1)
        plan = plan_fc_pool_layout(3, (3, 4, 4), pool_config=config)
        n = 48
        weight_rows = [((i % 7)-3, (i % 5)-2, (i % 3)-1) for i in range(n)]
        weights = struct.pack(str(n*3)+'b', *[v for row in weight_rows for v in row])
        biases = [i-20 for i in range(n)]
        params = pack_fc_pool_params(weights, biases, plan, input_zero_point=-3,
                                     output_zero_point=5, requant=[(1, 0)]*n)
        inputs = (-4, 3, 10)
        actual, expected = [], []
        for i, row in enumerate(weight_rows):
            bias, multiplier, shift = struct.unpack_from('<iII', params, 32+12*i)
            value = sum(x*w for x, w in zip(inputs, row))+bias
            actual.append(max(-128, min(127, value*multiplier+5)))
            centered = sum((x+3)*w for x, w in zip(inputs, row))+biases[i]
            expected.append(max(-128, min(127, centered+5)))
            self.assertEqual(shift, 0)
        self.assertEqual(actual, expected)
        pooled = [max(actual[((y+ky)*4+x+kx)*4+c]
                      for ky in range(2) for kx in range(2))
                  for y in range(2) for x in range(3) for c in range(4)]
        self.assertEqual(len(pooled), plan['c_bytes'])
        self.assertEqual(plan['pool_output_shape'], [2, 3, 4])
        self.assertEqual(self.make_descriptor(plan)['m'], 4)
        self.assertEqual(len(pooled), 24)  # Dummy M rows never add output rows.

    def test_ordinary_fc_header_and_descriptor_unchanged(self):
        layout = plan_fc_layout(1, 16, 3, output_element_bytes=1)
        params = pack_fc_params(b'\1'*48, [0]*16, layout, requant=[(1, 0)]*16)
        self.assertEqual(len(params), 16+16*12)
        self.assertEqual(struct.unpack_from('<iII', params, 16), (0, 1, 0))
        desc = make_fc_descriptor(layout, 4096, 8192, 12288, 16384, requantized=True)
        self.assertEqual(desc['flags'], 11)
        self.assertNotIn('pool_config', desc)
        validate_descriptor(desc, self.cfg)

    def test_conv_fusion_protects_extended_fc_parameter_reads(self):
        with open(os.path.join(os.path.dirname(__file__), 'compile_model.py')) as handle:
            source = handle.read()
        namespace = dict(_policy, copy=copy, FUSE_MAXPOOL=128)
        source = source[source.index('def fuse_conv_pool('):source.index('def main(')]
        eval(compile(source, 'compile_model.production-fuser', 'exec'), namespace)
        conv = dict(opcode=2, flags=3, m=16, n=4, k=1, a=0x10000, b=0x20000,
                    c=0x40000, param=0x30000,
                    words10_12=[(4 << 16) | 4, 0x01010001, 0x00000101])
        pool = dict(opcode=3, flags=0, m=4, n=4, k=4, a=conv['c'], b=0,
                    c=0x60000, param=0, words10_12=[0, 0, 0])
        layers = [dict(name='conv', c_region='conv_output'),
                  dict(name='pool', c_region='pool_output'), dict(name='fc')]
        for per_channel in (False, True):
            plan = plan_fc_pool_layout(3, (2, 2, 4), per_channel=per_channel)
            old_bytes = 16+16*(12 if per_channel else 4)
            # Only the extra 16-byte header extent overlaps the Conv output.
            fc = self.make_descriptor(plan, a=0x70000, b=0x80000, c=0x90000,
                                      param=conv['c']-old_bytes)
            emitted, _, report = namespace['fuse_conv_pool']([conv, pool, fc], layers, self.cfg)
            self.assertEqual(emitted, [conv, pool, fc])
            self.assertEqual(report['fused_pair_count'], 0)
            self.assertIn('another consumer', report['skipped_pairs'][0]['reason'])

    def test_smallcnn_interpreter_explicitly_rejects_new_mode(self):
        with open(os.path.join(os.path.dirname(__file__), 'verify_model.py')) as handle:
            source = handle.read()
        # Execute the actual admission prefix before any numerical operation.
        # This also avoids parsing the later Python-3 matrix operator on Py2.
        source = source[source.index('def execute('):
                        source.index('        require((len(names)')]
        source += '    return None\n'
        namespace = dict(_policy)
        eval(compile(source, 'verify_model.production-admission', 'exec'), namespace)
        desc = self.make_descriptor(plan_fc_pool_layout(3, (2, 2, 4)))
        commands = _policy['encode'](desc)*5
        with self.assertRaises(ValueError) as error:
            namespace['execute'](None, b'', commands, {})
        self.assertIn('does not support FC reshape/pool', str(error.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
