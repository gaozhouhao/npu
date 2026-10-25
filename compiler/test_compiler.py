"""ABI regression and negative tests; no RTL testbench is generated."""
import copy
import json
import shutil
import struct
import tempfile
import unittest
from pathlib import Path
import numpy as np
from compile_model import FUSE_MAXPOOL, fuse_conv_pool
from target import (HERE, REPO, encode, decode, load_target, MemoryPlan,
                    validate_descriptor, digest, MODEL_HEADER, pack_pool_config,
                    unpack_pool_config, pool_output_shape, pool_line_words,
                    pack_pool_padding, unpack_pool_padding, pool_fusion_buffer_plan)
from verify_model import rtl_requant, verify_files, execute, compare_rtl_dump, max_pool_valid


class CompilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg,_=load_target(HERE/'npu_config.json')
        cls.out=REPO/'artifacts/npu'
        cls.report=json.loads((cls.out/'compilation_report.json').read_text())

    def test_literal_descriptor_abi(self):
        d=copy.deepcopy(self.report['descriptors'][0])
        raw=encode(d)
        self.assertEqual(raw[:16],struct.pack('<4I',0x702,784,8,9))
        self.assertEqual(raw[40:52],struct.pack('<3I',0x001c001c,0x03030001,0x01010101))
        d['a']=0x1234567800001000
        self.assertEqual(encode(d)[16:24],bytes.fromhex('0010000078563412'))
        self.assertEqual(decode(encode(d)),d)

    def test_pool_config_abi_and_legacy_compatibility(self):
        d = copy.deepcopy(self.report['descriptors'][1])
        self.assertEqual(encode(d)[60:64], b'\0'*4)
        self.assertNotIn('pool_config', decode(encode(d)))
        self.assertEqual(unpack_pool_config(0), (2, 2, 2, 2))
        d['pool_config'] = pack_pool_config(3, 2, 5, 1)
        self.assertEqual(d['pool_config'], 0x01050203)
        self.assertEqual(encode(d)[60:64], bytes.fromhex('03020501'))
        self.assertEqual(decode(encode(d)), d)
        validate_descriptor(d, self.cfg)

    def test_pool_config_validation(self):
        pool = copy.deepcopy(self.report['descriptors'][1])
        for shift in (0, 8, 16, 24):
            invalid = dict(pool, pool_config=pack_pool_config() & ~(255 << shift))
            with self.assertRaisesRegex(ValueError, 'zero'):
                validate_descriptor(invalid, self.cfg)
        for fields in ((0, 2, 2, 2), (2, 256, 2, 2), (2, 2, -1, 2)):
            with self.assertRaisesRegex(ValueError, '1..255'):
                pack_pool_config(*fields)
        for index in (0, 4):
            invalid = dict(self.report['descriptors'][index], pool_config=pack_pool_config())
            with self.assertRaisesRegex(ValueError, 'requires MaxPool'):
                validate_descriptor(invalid, self.cfg)
        invalid = dict(pool, pool_config=pack_pool_config(29, 2, 1, 1))
        with self.assertRaisesRegex(ValueError, 'exceeds input'):
            validate_descriptor(invalid, self.cfg)
        tiny = dict(pool, m=1, n=1, pool_config=pack_pool_config(1, 1, 255, 255))
        validate_descriptor(tiny, self.cfg)
        self.assertEqual(pool_output_shape(1, 1, tiny['pool_config']), (1, 1))

    def test_pool_reference_arbitrary_strides_and_axes(self):
        value = ((np.arange(11*14*4).reshape(11, 14, 4)*19 % 251)-125).astype('i1')
        for sh, sw in ((1, 1), (3, 3), (5, 5), (2, 5), (5, 1)):
            config = pack_pool_config(3, 2, sh, sw)
            oh, ow = pool_output_shape(11, 14, config)
            expected = np.array([[[max(int(value[y*sh+ky, x*sw+kx, c])
                                      for ky in range(3) for kx in range(2))
                                   for c in range(4)] for x in range(ow)]
                                 for y in range(oh)], dtype='i1')
            np.testing.assert_array_equal(max_pool_valid(np, value, config), expected)
        odd = value[:5, :7]
        legacy = odd[:4, :6].reshape(2, 2, 3, 2, 4).max(axis=(1, 3))
        np.testing.assert_array_equal(max_pool_valid(np, odd), legacy)

    def test_pool_padding_descriptor_and_resnet_shape(self):
        pool = copy.deepcopy(self.report['descriptors'][1])
        pool.update(m=112, n=112, pool_config=pack_pool_config(3, 3, 2, 2))
        padding = pack_pool_padding(bottom=1, right=1)
        self.assertEqual(padding, 0x01010000)
        self.assertEqual(unpack_pool_padding(padding), (0, 0, 1, 1))
        pool['words10_12'] = [padding, 0, 0]
        self.assertEqual(encode(pool)[40:52], bytes.fromhex('000001010000000000000000'))
        self.assertEqual(decode(encode(pool)), pool)
        validate_descriptor(pool, self.cfg)
        self.assertEqual(pool_output_shape(112, 112, pool['pool_config']), (55, 55))
        self.assertEqual(pool_output_shape(112, 112, pool['pool_config'], padding), (56, 56))
        for index in (1, 2):
            invalid = copy.deepcopy(pool)
            invalid['words10_12'][index] = 1
            with self.assertRaisesRegex(ValueError, 'pooling descriptor'):
                validate_descriptor(invalid, self.cfg)

    def test_pool_padding_admission(self):
        config = pack_pool_config(3, 3, 2, 2)
        for fields in ((-1, 0, 0, 0), (0, 256, 0, 0)):
            with self.assertRaisesRegex(ValueError, '0..255'):
                pack_pool_padding(*fields)
        for raw in (-1, 2**32):
            with self.assertRaisesRegex(ValueError, 'unsigned 32'):
                unpack_pool_padding(raw)
        for fields in ((3, 0, 0, 0), (0, 3, 0, 0),
                       (0, 0, 3, 0), (0, 0, 0, 3)):
            with self.assertRaisesRegex(ValueError, 'smaller than'):
                pool_output_shape(4, 4, config, pack_pool_padding(*fields))
        for h, w in ((0, 4), (4, 0), (2**32, 4)):
            with self.assertRaisesRegex(ValueError, 'positive unsigned 32'):
                pool_output_shape(h, w, config)
        with self.assertRaisesRegex(ValueError, 'output shape'):
            pool_output_shape(2**32-1, 4, pack_pool_config(2, 2, 1, 1),
                              pack_pool_padding(top=1, bottom=1))
        self.assertEqual(pool_output_shape(1, 1, config, pack_pool_padding(1, 1, 1, 1)),
                         (1, 1))
        with self.assertRaisesRegex(ValueError, 'does not support padding'):
            pool_line_words(112, 112, 64, config, pack_pool_padding(bottom=1, right=1))

    def test_pool_padding_reference_ignores_invalid_negative_samples(self):
        value = (-1-(np.arange(5*7*8).reshape(5, 7, 8) % 128)).astype('i1')
        for geometry, pads in (((3, 3, 2, 2), (0, 0, 1, 1)),
                               ((3, 3, 1, 1), (1, 1, 1, 1)),
                               ((3, 2, 2, 3), (2, 1, 0, 1))):
            config, padding = pack_pool_config(*geometry), pack_pool_padding(*pads)
            kh, kw, sh, sw = geometry
            pt, pl, _, _ = pads
            oh, ow = pool_output_shape(5, 7, config, padding)
            expected = np.empty((oh, ow, 8), dtype='i1')
            for y in range(oh):
                for x in range(ow):
                    for c in range(8):
                        valid = [int(value[iy, ix, c])
                                 for iy in range(y*sh-pt, y*sh-pt+kh)
                                 for ix in range(x*sw-pl, x*sw-pl+kw)
                                 if 0 <= iy < 5 and 0 <= ix < 7]
                        expected[y, x, c] = max(valid)
            actual = max_pool_valid(np, value, config, padding)
            np.testing.assert_array_equal(actual, expected)
            self.assertTrue(np.all(actual < 0))
        single = np.full((1, 1, 4), -128, dtype='i1')
        np.testing.assert_array_equal(
            max_pool_valid(np, single, pack_pool_config(3, 3, 1, 1),
                           pack_pool_padding(1, 1, 1, 1)), single)

    def test_gemm_logical_tail_admission(self):
        d=copy.deepcopy(self.report['descriptors'][4])
        for rows, cols in ((4, 4), (4, 8), (8, 4)):
            cfg = dict(self.cfg, pe_rows=rows, pe_cols=cols)
            for m in (1, rows-1, rows, rows+1):
                for n in (1, cols-1, cols, cols+1):
                    tail = dict(d, m=m, n=n)
                    tail['words10_12'] = [784, 784, ((n*4+3)//4)*4]
                    validate_descriptor(tail, cfg)
                    tail['flags'] |= 2
                    tail['words10_12'][2] = ((n+3)//4)*4
                    validate_descriptor(tail, cfg)

    def test_conv_logical_tail_admission(self):
        d = copy.deepcopy(self.report['descriptors'][0])
        d.update(m=49, n=5, k=1)
        d['words10_12'] = [(7 << 16) | 7, 0x01010001, 0x00000101]
        for rows, cols in ((4, 4), (4, 8), (8, 4)):
            validate_descriptor(d, dict(self.cfg, pe_rows=rows, pe_cols=cols))
        # Logical M continues to match geometry; rounding the descriptor is wrong.
        with self.assertRaisesRegex(ValueError, 'geometry'):
            validate_descriptor(dict(d, m=52), self.cfg)
        with self.assertRaisesRegex(ValueError, 'four-channel groups'):
            validate_descriptor(dict(d, flags=d['flags'] | FUSE_MAXPOOL), self.cfg)
        cols8 = dict(self.cfg, pe_cols=8)
        with self.assertRaisesRegex(ValueError, 'complete output-channel tiles'):
            validate_descriptor(dict(d, n=4, flags=d['flags'] | FUSE_MAXPOOL), cols8)

    def test_tile_count_boundaries(self):
        d = copy.deepcopy(self.report['descriptors'][4])
        cfg = dict(self.cfg, pe_rows=4, pe_cols=8, tile_count_width=3, k_tile_size=16)
        d.update(m=28, n=56, k=112)
        d['words10_12'] = [112, 112, 224]
        validate_descriptor(d, cfg)
        for axis, size in (('m', 29), ('n', 57), ('k', 113)):
            with self.assertRaisesRegex(ValueError, 'counter overflow'):
                validate_descriptor(dict(d, **{axis: size}), cfg)
        # Widen before ceil: values near UINT32_MAX must reach the count check.
        d.update(m=1, n=1, k=2**32-8)
        d['words10_12'] = [2**32-8, 2**32-8, 4]
        wide = dict(cfg, tile_count_width=32, k_tile_size=256)
        validate_descriptor(d, wide)
        for size in (0, -1, 2**32):
            with self.assertRaisesRegex(ValueError, 'unsigned 32-bit dimension'):
                validate_descriptor(dict(d, m=size), wide)

    def test_byte_stride_alignment(self):
        d=copy.deepcopy(self.report['descriptors'][4])
        for stride in (783,780):
            d['words10_12'][1]=stride
            with self.assertRaises(ValueError):
                validate_descriptor(d,self.cfg)

    def test_pool_flags_rejected(self):
        d=copy.deepcopy(self.report['descriptors'][1])
        d['flags']=1
        with self.assertRaisesRegex(ValueError,'pooling'):
            validate_descriptor(d,self.cfg)

    def test_conv_geometry_rejected(self):
        d=copy.deepcopy(self.report['descriptors'][0])
        d['k']=12
        with self.assertRaisesRegex(ValueError,'geometry'):
            validate_descriptor(d,self.cfg)

    def test_config_mismatch_rejected(self):
        cfg=dict(self.cfg,pe_rows=8)
        with tempfile.TemporaryDirectory(dir=HERE, prefix='test_config_') as td:
            path=Path(td)/'config.json'
            path.write_text(json.dumps(cfg))
            with self.assertRaisesRegex(ValueError,'pe_rows'):
                load_target(path)

    def test_capacity_and_dma_bounds(self):
        p=MemoryPlan(dict(self.cfg,ddr_capacity_bytes=16))
        p.allocate('row',12,[12],'i1','row')
        with self.assertRaisesRegex(ValueError,'capacity'):
            p.allocate('overflow',8,[8],'i1','row')
        with self.assertRaisesRegex(ValueError,'escapes'):
            p.validate_access(8,8,'row')

    def test_rounding_and_saturation(self):
        values=np.array([-1000,-255,-7,-1,0,1,7,255,1000])
        np.testing.assert_array_equal(rtl_requant(np,values,1,1,False),[-128,-128,-4,-1,0,1,4,127,127])
        np.testing.assert_array_equal(rtl_requant(np,values,1,0),np.clip(values,0,127))
        with self.assertRaises(ValueError):
            rtl_requant(np,values,2**31,30)

    def test_all_serialized_images(self):
        results=verify_files(np,self.out)
        self.assertEqual([x['predicted'] for x in results],[7,2,1,0])

    def test_dump_comparator_detects_corruption(self):
        plan=json.loads((self.out/'memory_map.json').read_text())
        _,memory=execute(np,(self.out/'ddr/image_0000.bin').read_bytes(),(self.out/'commands.bin').read_bytes(),plan)
        with tempfile.TemporaryDirectory(dir=HERE, prefix='test_dump_') as td:
            dump=Path(td)/'dump.bin'
            dump.write_bytes(memory)
            compare_rtl_dump(np,self.out,dump,'image_0000')
            memory[plan['regions']['fc_output']['address']]^=1
            dump.write_bytes(memory)
            with self.assertRaisesRegex(ValueError,'fc: first mismatch'):
                compare_rtl_dump(np,self.out,dump,'image_0000')

    def fused_commands(self, descriptors=None, cfg=None):
        return fuse_conv_pool(copy.deepcopy(descriptors or self.report['descriptors']),
                              copy.deepcopy(self.report['layers']), cfg or self.cfg)

    def test_fused_descriptor_abi_and_destinations(self):
        original = copy.deepcopy(self.report['descriptors'])
        descriptors, names, fusion = self.fused_commands()
        self.assertEqual(fusion['fused_pair_count'], 2)
        self.assertEqual(fusion['descriptor_count'], 3)
        self.assertEqual(names, [['conv1', 'pool1'], ['conv2', 'pool2'], ['fc']])
        self.assertEqual([pair['avoided_intermediate_bytes'] for pair in fusion['fused_pairs']],
                         [2*28*28*8, 2*14*14*16])
        for old_index, new_index in ((0, 0), (2, 1)):
            d = descriptors[new_index]
            self.assertEqual(d['flags'], original[old_index]['flags'] | FUSE_MAXPOOL)
            self.assertEqual(d['c'], original[old_index+1]['c'])
            self.assertEqual((d['m'], d['n'], d['k']),
                             tuple(original[old_index][key] for key in ('m', 'n', 'k')))
            self.assertEqual(d['words10_12'], original[old_index]['words10_12'])
            self.assertEqual(decode(encode(d)), d)
            validate_descriptor(d, self.cfg)
        self.assertEqual(struct.unpack_from('<I', encode(descriptors[0]))[0], 0x8702)
        self.assertEqual(self.report['descriptors'], original)

    def test_fusion_preserves_other_consumers(self):
        descriptors = copy.deepcopy(self.report['descriptors'])
        # A later reader starts inside the intermediate, not at its base.
        descriptors[-1]['a'] = descriptors[0]['c'] + 8
        fused, _, report = self.fused_commands(descriptors)
        self.assertEqual(fused[0], descriptors[0])
        self.assertIn('another consumer', report['skipped_pairs'][0]['reason'])

    def test_fusion_preserves_parameter_consumers(self):
        for flags in (1, 2):
            descriptors = copy.deepcopy(self.report['descriptors'])
            descriptors[-1]['flags'] = flags
            descriptors[-1]['param'] = descriptors[0]['c'] + 8
            fused, _, report = self.fused_commands(descriptors)
            self.assertEqual(fused[0], descriptors[0])
            self.assertIn('another consumer', report['skipped_pairs'][0]['reason'])

    def test_fusion_does_not_overwrite_live_conv_reads(self):
        for source in ('a', 'b', 'param'):
            descriptors = copy.deepcopy(self.report['descriptors'])
            # Pool formerly wrote only after Conv completed. Streaming that
            # same output into a still-live Conv source would introduce a race.
            descriptors[1]['c'] = descriptors[0][source] + 8
            fused, _, report = self.fused_commands(descriptors)
            self.assertEqual(fused[0], descriptors[0])
            self.assertIn('live Conv', report['skipped_pairs'][0]['reason'])

    def test_fusion_falls_back_for_capacity_or_precision(self):
        fused, _, report = self.fused_commands(cfg=dict(self.cfg, pool_line_words=1))
        self.assertEqual(len(fused), 5)
        self.assertEqual(report['fused_pair_count'], 0)
        self.assertTrue(all('capacity' in pair['reason'] for pair in report['skipped_pairs']))
        descriptors = copy.deepcopy(self.report['descriptors'])
        descriptors[0]['flags'] = 1
        fused, _, report = self.fused_commands(descriptors)
        self.assertEqual(fused[0], descriptors[0])
        self.assertIn('INT8', report['skipped_pairs'][0]['reason'])

    def test_fusion_preserves_padded_standalone_pool(self):
        descriptors = copy.deepcopy(self.report['descriptors'][:2])
        descriptors[1]['pool_config'] = pack_pool_config(3, 3, 2, 2)
        descriptors[1]['words10_12'] = [pack_pool_padding(bottom=1, right=1), 0, 0]
        validate_descriptor(descriptors[1], self.cfg)
        fallback, names, report = fuse_conv_pool(descriptors, self.report['layers'][:2], self.cfg)
        self.assertEqual(fallback, descriptors)
        self.assertEqual(names, [['conv1'], ['pool1']])
        self.assertEqual(report['fused_pair_count'], 0)
        self.assertIn('standalone', report['skipped_pairs'][0]['reason'])
        self.assertIn('padding', report['skipped_pairs'][0]['reason'])

    def test_fused_admission_rejects_invalid_configurations(self):
        descriptors, _, _ = self.fused_commands()
        d = descriptors[0]
        with self.assertRaisesRegex(ValueError, 'capacity'):
            validate_descriptor(d, dict(self.cfg, pool_line_words=1))
        invalid = dict(d, flags=FUSE_MAXPOOL | 1)
        with self.assertRaisesRegex(ValueError, 'INT8'):
            validate_descriptor(invalid, self.cfg)
        with self.assertRaisesRegex(ValueError, 'four-channel'):
            validate_descriptor(d, dict(self.cfg, pe_cols=2))
        invalid = dict(d, opcode=1)
        # Fused FC exists, but Conv geometry words are not legal FC strides.
        with self.assertRaises(ValueError):
            validate_descriptor(invalid, self.cfg)

    def test_fusion_accepts_odd_output_with_complete_source_tiles(self):
        descriptors = copy.deepcopy(self.report['descriptors'])
        descriptors[0]['words10_12'][0] = (27 << 16) | 28
        descriptors[0]['m'] = 27*28
        descriptors[1]['n'] = 27
        fused, _, report = self.fused_commands(descriptors)
        self.assertTrue(fused[0]['flags'] & FUSE_MAXPOOL)
        self.assertEqual(report['fused_pair_count'], 2)
        validate_descriptor(fused[0], self.cfg)

    def test_fusion_accepts_spatial_tail_but_requires_complete_channels(self):
        descriptors = copy.deepcopy(self.report['descriptors'][:2])
        descriptors[0].update(m=7*7, n=8)
        descriptors[0]['words10_12'][0] = (7 << 16) | 7
        descriptors[1].update(m=7, n=7, k=8)
        layers = self.report['layers'][:2]
        for cols in (4, 8):
            cfg = dict(self.cfg, pe_cols=cols)
            fused, _, report = fuse_conv_pool(descriptors, layers, cfg)
            self.assertEqual(len(fused), 1)
            self.assertEqual(fused[0]['m'], 49)
            self.assertEqual(report['fused_pair_count'], 1)
            validate_descriptor(fused[0], cfg)
        descriptors[0]['n'] = descriptors[1]['k'] = 4
        fallback, _, report = fuse_conv_pool(descriptors, layers, dict(self.cfg, pe_cols=8))
        self.assertEqual(fallback, descriptors)
        self.assertIn('complete groups', report['skipped_pairs'][0]['reason'])

    def test_fusion_runtime_geometry_and_exact_capacity(self):
        layers = self.report['layers'][:2]
        for fields in ((3, 2, 1, 1), (5, 3, 3, 3), (2, 3, 5, 5), (5, 2, 2, 5)):
            descriptors = copy.deepcopy(self.report['descriptors'][:2])
            config = pack_pool_config(*fields)
            descriptors[1]['pool_config'] = config
            words = pool_line_words(28, 28, 8, config)
            cfg = dict(self.cfg, pool_line_words=words)
            fused, names, report = fuse_conv_pool(descriptors, layers, cfg)
            self.assertEqual(len(fused), 1)
            self.assertEqual(fused[0]['pool_config'], config)
            self.assertEqual(names, [['conv1', 'pool1']])
            pooled_h, pooled_w = pool_output_shape(28, 28, config)
            read_bytes = pooled_h*pooled_w*fields[0]*fields[1]*8
            pair = report['fused_pairs'][0]
            self.assertEqual(pair['avoided_intermediate_write_bytes'], 28*28*8)
            self.assertEqual(pair['avoided_pool_input_read_bytes'], read_bytes)
            self.assertEqual(pair['avoided_intermediate_bytes'], 28*28*8+read_bytes)
            self.assertFalse(pair['channel_tiled'])
            self.assertEqual(pair['pool_active_line_words'], words)
            validate_descriptor(fused[0], cfg)
            minimum = pool_line_words(28, 28, self.cfg['pe_cols'], config)
            tiled_cfg = dict(cfg, pool_line_words=words-1)
            tiled, names, tiled_report = fuse_conv_pool(descriptors, layers, tiled_cfg)
            self.assertEqual(tiled, fused)
            self.assertEqual(names, [['conv1', 'pool1']])
            self.assertTrue(tiled_report['fused_pairs'][0]['channel_tiled'])
            self.assertEqual(tiled_report['fused_pairs'][0]['pool_active_line_words'], minimum)
            validate_descriptor(tiled[0], tiled_cfg)
            validate_descriptor(tiled[0], dict(cfg, pool_line_words=minimum))
            with self.assertRaisesRegex(ValueError, 'capacity'):
                validate_descriptor(fused[0], dict(cfg, pool_line_words=minimum-1))
            fallback, names, report = fuse_conv_pool(descriptors, layers,
                                                      dict(cfg, pool_line_words=minimum-1))
            self.assertEqual(fallback, descriptors)
            self.assertEqual(fallback[1]['pool_config'], config)
            self.assertEqual(names, [['conv1'], ['pool1']])
            self.assertIn('capacity', report['skipped_pairs'][0]['reason'])

    def test_pool_fusion_buffer_plan(self):
        config = pack_pool_config(2, 2, 1, 1)
        self.assertEqual(pool_line_words(8, 8, 16, config), 64)
        # Raw input capacity follows KH and input width, independent of
        # output width, overlap, and stride gaps.
        self.assertEqual(pool_line_words(8, 8, 16), 64)
        self.assertEqual(pool_line_words(
            8, 8, 16, pack_pool_config(2, 7, 5, 3)), 64)
        full = pool_fusion_buffer_plan(8, 8, 16, 4, 64, config)
        self.assertTrue(full['fits'])
        self.assertFalse(full['channel_tiled'])
        self.assertEqual((full['full_words'], full['active_words'],
                          full['channel_block_channels']), (64, 64, 16))
        for capacity in (16, 63):
            tiled = pool_fusion_buffer_plan(8, 8, 16, 4, capacity, config)
            self.assertTrue(tiled['fits'])
            self.assertTrue(tiled['channel_tiled'])
            self.assertEqual((tiled['full_words'], tiled['active_words'],
                              tiled['channel_block_channels']), (64, 16, 4))
        self.assertFalse(pool_fusion_buffer_plan(8, 8, 16, 4, 15, config)['fits'])
        wide = pool_fusion_buffer_plan(8, 8, 16, 8, 32, config)
        self.assertTrue(wide['fits'])
        self.assertEqual((wide['active_words'], wide['channel_block_channels']), (32, 8))
        for channels, cols, capacity in ((16, 2, 64), (12, 8, 64), (16, 4, 0)):
            with self.assertRaises(ValueError):
                pool_fusion_buffer_plan(8, 8, channels, cols, capacity, config)
        with self.assertRaisesRegex(ValueError, 'padding'):
            pool_fusion_buffer_plan(8, 8, 16, 4, 56, config,
                                    pack_pool_padding(bottom=1))

    def test_fusion_channel_tiling_keeps_abi_and_layout(self):
        descriptors = copy.deepcopy(self.report['descriptors'][:2])
        layers = self.report['layers'][:2]
        minimum = pool_line_words(28, 28, self.cfg['pe_cols'])
        full_words = pool_line_words(28, 28, descriptors[0]['n'])
        cfg = dict(self.cfg, pool_line_words=minimum)
        fused, names, report = fuse_conv_pool(descriptors, layers, cfg)
        self.assertEqual(len(fused), 1)
        self.assertEqual(names, [['conv1', 'pool1']])
        expected = dict(descriptors[0], flags=descriptors[0]['flags'] | FUSE_MAXPOOL,
                        c=descriptors[1]['c'])
        self.assertEqual(fused[0], expected)
        self.assertEqual(decode(encode(fused[0])), expected)
        pair = report['fused_pairs'][0]
        self.assertTrue(pair['channel_tiled'])
        self.assertEqual((pair['pool_full_line_words'], pair['pool_active_line_words'],
                          pair['pool_channel_block_channels']),
                         (full_words, minimum, self.cfg['pe_cols']))
        validate_descriptor(fused[0], cfg)

    def test_fusion_uses_configured_output_footprint_for_alias_checks(self):
        config = pack_pool_config(2, 2, 1, 1)
        conv = dict(opcode=2, flags=2, m=64, n=4, k=4, a=0x1000,
                    b=0x2000, c=0x4000, param=0x3000,
                    words10_12=[0x00080008, 0x01010004, 0x00000101])
        output_bytes = 7*7*4
        pool = dict(opcode=3, flags=0, m=8, n=8, k=4, a=conv['c'], b=0,
                    c=conv['a']-output_bytes+4, param=0,
                    words10_12=[0, 0, 0], pool_config=config)
        layers = [dict(name='conv', c_region='conv_output'),
                  dict(name='pool', c_region='pool_output')]
        fallback, _, report = fuse_conv_pool([conv, pool], layers, self.cfg)
        self.assertEqual(fallback, [conv, pool])
        self.assertIn('live Conv', report['skipped_pairs'][0]['reason'])
        pool['c'] -= 4  # Exactly adjacent to the Conv input is safe.
        fused, _, _ = fuse_conv_pool([conv, pool], layers, self.cfg)
        self.assertEqual(len(fused), 1)

    def test_pool_reader_protection_covers_entire_input(self):
        descriptors = copy.deepcopy(self.report['descriptors'])
        conv = descriptors[0]
        descriptors[-1] = dict(opcode=3, flags=0, m=1, n=1, k=4,
                               a=conv['c']+28*28*8-4, b=0, c=0x100000,
                               param=0, words10_12=[0, 0, 0],
                               pool_config=pack_pool_config(1, 1, 5, 3))
        fused, _, report = self.fused_commands(descriptors)
        self.assertEqual(fused[0], conv)
        self.assertIn('another consumer', report['skipped_pairs'][0]['reason'])

    def test_fused_interpreter_matches_chain_without_intermediate_writes(self):
        plan = json.loads((self.out/'memory_map.json').read_text())
        descriptors, names, report = self.fused_commands()
        fused_plan = dict(plan, desc_count=len(descriptors), descriptor_layers=names,
                          elided_intermediate_regions=[pair['intermediate_region']
                                                       for pair in report['fused_pairs']])
        commands = b''.join(encode(d) for d in descriptors)
        for image in range(4):
            data = (self.out/f'ddr/image_{image:04d}.bin').read_bytes()
            expected, baseline_memory = execute(np, data, (self.out/'commands.bin').read_bytes(), plan)
            actual, fused_memory = execute(np, data, commands, fused_plan)
            for name, values in expected.items():
                np.testing.assert_array_equal(actual[name], values, err_msg=name)
            for region in fused_plan['elided_intermediate_regions']:
                r = plan['regions'][region]
                start, end = r['address'], r['address']+r['bytes']
                self.assertEqual(fused_memory[start:end], data[start:end])
            for region in ('pool1_output', 'pool2_output_fc_input', 'fc_output'):
                r = plan['regions'][region]
                start, end = r['address'], r['address']+r['bytes']
                self.assertEqual(fused_memory[start:end], baseline_memory[start:end])

    def test_runtime_pool_geometry_matches_fused_and_standalone_execution(self):
        plan = json.loads((self.out/'memory_map.json').read_text())
        data = (self.out/'ddr/image_0000.bin').read_bytes()
        for fields in ((15, 15, 1, 1), (3, 2, 3, 5), (2, 3, 5, 3)):
            descriptors = copy.deepcopy(self.report['descriptors'])
            descriptors[1]['pool_config'] = pack_pool_config(*fields)
            expected, _ = execute(np, data, b''.join(encode(d) for d in descriptors), plan)
            fused, names, _ = self.fused_commands(descriptors)
            actual, _ = execute(np, data, b''.join(encode(d) for d in fused),
                                dict(plan, descriptor_layers=names))
            for name, values in expected.items():
                np.testing.assert_array_equal(actual[name], values, err_msg=name)

    def test_fused_serialized_artifacts_and_dump_comparison(self):
        descriptors, names, fusion = self.fused_commands()
        commands = b''.join(encode(d) for d in descriptors)
        with tempfile.TemporaryDirectory(dir=HERE, prefix='test_fused_') as td:
            out = Path(td)/'artifacts'
            shutil.copytree(self.out, out)
            plan = json.loads((out/'memory_map.json').read_text())
            plan.update(desc_count=len(descriptors), descriptor_layers=names,
                        elided_intermediate_regions=[pair['intermediate_region']
                                                     for pair in fusion['fused_pairs']])
            start = plan['regions']['commands']['address']
            capacity = plan['regions']['commands']['bytes']

            def replace_commands(payload):
                payload = bytearray(payload)
                payload[start:start+capacity] = bytes(capacity)
                payload[start:start+len(commands)] = commands
                return bytes(payload)

            model = (out/'model.bin').read_bytes()
            fields = list(MODEL_HEADER.unpack_from(model))
            fields[-1] = len(descriptors)
            (out/'model.bin').write_bytes(MODEL_HEADER.pack(*fields)+
                                         replace_commands(model[MODEL_HEADER.size:]))
            for path in (out/'ddr').glob('image_*.bin'):
                path.write_bytes(replace_commands(path.read_bytes()))
            (out/'commands.bin').write_bytes(commands)
            (out/'memory_map.json').write_text(json.dumps(plan))
            report = copy.deepcopy(self.report)
            report.update(descriptors=descriptors, descriptor_layers=names, fusion=fusion,
                          hardware_config=self.cfg)
            (out/'compilation_report.json').write_text(json.dumps(report))
            manifest = json.loads((out/'manifest.json').read_text())
            manifest['files']['commands.bin']['shape'] = [len(descriptors), 16]
            for name, entry in manifest['files'].items():
                path = out/name
                entry.update(bytes=path.stat().st_size, sha256=digest(path))
                if name.endswith(('/conv1.bin', '/conv2.bin')):
                    entry.pop('load_address', None)
            (out/'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual([item['predicted'] for item in verify_files(np, out)], [7, 2, 1, 0])
            _, memory = execute(np, (out/'ddr/image_0000.bin').read_bytes(), commands, plan)
            dump = Path(td)/'dump.bin'
            dump.write_bytes(memory)
            result = compare_rtl_dump(np, out, dump, 'image_0000')
            self.assertEqual(result['compared_outputs'], ['pool1', 'pool2', 'fc'])


if __name__=='__main__':
    unittest.main(verbosity=2)
