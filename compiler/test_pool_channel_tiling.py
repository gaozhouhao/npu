#!/usr/bin/env python
"""Run production pooling admission/fusion tests without NumPy or Python 3.

The normal compiler suite still requires Python 3 and NumPy. This runner reads
the real pure functions and selected real test methods verbatim, so its results
cover descriptor policy, not execution of the full model compiler or RTL.
"""
from __future__ import print_function
import binascii
import copy
import json
import os
import re
import struct
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def execute(source, filename, namespace):
    eval(compile('# coding: utf-8\n' + source, filename, 'exec'), namespace)


def read(path):
    with open(os.path.join(ROOT, path)) as handle:
        return handle.read()


namespace = dict(struct=struct, copy=copy, binascii=binascii, unittest=unittest)
source = read('compiler/target.py')
execute(source[source.index('def require('):source.index('def digest(')],
        'target.require', namespace)
execute(source[source.index('def align('):source.index('class MemoryPlan:')],
        'target.pure-functions', namespace)
source = read('compiler/compile_model.py')
namespace['FUSE_MAXPOOL'] = 128
execute(source[source.index('def fuse_conv_pool('):source.index('def main(')],
        'compile_model.fuse_conv_pool', namespace)

names = [
    'fused_commands', 'test_literal_descriptor_abi',
    'test_pool_config_abi_and_legacy_compatibility', 'test_pool_config_validation',
    'test_pool_padding_descriptor_and_resnet_shape', 'test_pool_padding_admission',
    'test_gemm_logical_tail_admission', 'test_conv_logical_tail_admission',
    'test_tile_count_boundaries', 'test_byte_stride_alignment', 'test_pool_flags_rejected',
    'test_conv_geometry_rejected', 'test_fused_descriptor_abi_and_destinations',
    'test_fusion_preserves_other_consumers', 'test_fusion_preserves_parameter_consumers',
    'test_fusion_does_not_overwrite_live_conv_reads',
    'test_fusion_falls_back_for_capacity_or_precision',
    'test_fusion_preserves_padded_standalone_pool',
    'test_fused_admission_rejects_invalid_configurations',
    'test_fusion_accepts_odd_output_with_complete_source_tiles',
    'test_fusion_accepts_spatial_tail_but_requires_complete_channels',
    'test_fusion_runtime_geometry_and_exact_capacity',
    'test_pool_fusion_buffer_plan', 'test_fusion_channel_tiling_keeps_abi_and_layout',
    'test_fusion_uses_configured_output_footprint_for_alias_checks',
    'test_pool_reader_protection_covers_entire_input',
]
body = 'class ProductionPolicyTests(unittest.TestCase):\n'
source = read('compiler/test_compiler.py')
for name in names:
    match = re.search(r'^    def ' + name + r'\(.*?(?=^    def |^if __name__)',
                      source, re.M | re.S)
    if not match:
        raise AssertionError('Missing production test ' + name)
    body += match.group(0).replace('bytes.fromhex(', 'binascii.unhexlify(')
execute(body, 'compiler.production-policy-tests', namespace)
ProductionPolicyTests = namespace['ProductionPolicyTests']
if not hasattr(ProductionPolicyTests, 'assertRaisesRegex'):
    ProductionPolicyTests.assertRaisesRegex = ProductionPolicyTests.assertRaisesRegexp
with open(os.path.join(ROOT, 'artifacts/npu/compilation_report.json')) as handle:
    ProductionPolicyTests.report = json.load(handle)
ProductionPolicyTests.cfg = dict(ProductionPolicyTests.report['hardware_config'],
                                 pool_line_words=1024)


class GeneratedCapacityTests(unittest.TestCase):
    def test_fusion_capacity_boundaries_across_geometry_and_pe_widths(self):
        pack = namespace['pack_pool_config']
        words = namespace['pool_line_words']
        fuse = namespace['fuse_conv_pool']
        validate = namespace['validate_descriptor']
        cases = 0
        for cols in (4, 8, 12):
            for channels in (cols, cols*2, cols*5):
                for fields in ((2, 2, 1, 1), (3, 2, 2, 1), (2, 3, 5, 3)):
                    config = pack(*fields)
                    conv = dict(opcode=2, flags=2, m=12*16, n=channels, k=1,
                                a=0x10000, b=0x20000, c=0x40000, param=0x30000,
                                words10_12=[(16 << 16) | 12, 0x01010001, 0x00000101])
                    pool = dict(opcode=3, flags=0, m=12, n=16, k=channels,
                                a=conv['c'], b=0, c=0x60000, param=0,
                                words10_12=[0, 0, 0], pool_config=config)
                    layers = [dict(name='conv', c_region='conv_output'),
                              dict(name='pool', c_region='pool_output')]
                    full, minimum = words(12, 16, channels, config), words(12, 16, cols, config)
                    for capacity in sorted(set((minimum-1, minimum, full-1, full))):
                        cfg = dict(pe_rows=4, pe_cols=cols, pool_line_words=capacity)
                        emitted, names, report = fuse([conv, pool], layers, cfg)
                        if capacity < minimum:
                            self.assertEqual(emitted, [conv, pool])
                            self.assertEqual(report['fused_pair_count'], 0)
                            self.assertIn('capacity', report['skipped_pairs'][0]['reason'])
                        else:
                            self.assertEqual(len(emitted), 1)
                            self.assertEqual(names, [['conv', 'pool']])
                            self.assertEqual(emitted[0]['n'], channels)
                            self.assertEqual(emitted[0]['c'], pool['c'])
                            self.assertEqual(emitted[0]['words10_12'], conv['words10_12'])
                            self.assertEqual(emitted[0]['pool_config'], config)
                            record = report['fused_pairs'][0]
                            self.assertEqual(record['channel_tiled'], capacity < full)
                            self.assertEqual(record['pool_active_line_words'],
                                             minimum if capacity < full else full)
                            validate(emitted[0], cfg)
                        cases += 1
        self.assertGreater(cases, 80)


if __name__ == '__main__':
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    suite.addTests(loader.loadTestsFromTestCase(ProductionPolicyTests))
    suite.addTests(loader.loadTestsFromTestCase(GeneratedCapacityTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print('LIMITATION: full Python 3/NumPy compiler and numerical model tests are not run.')
    sys.exit(0 if result.wasSuccessful() else 1)
