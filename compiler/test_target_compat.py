#!/usr/bin/env python
"""Shared descriptor ABI tests runnable with Python 2.7 or Python 3."""
from __future__ import print_function
import json
import struct
import unittest

from target import (HERE, REPO, MemoryPlan, decode, digest, encode,
                    hardware_defaults, load_target, pack_pool_config,
                    validate_descriptor)


class TargetCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg, _ = load_target(HERE / 'npu_config.json')

    def gemm(self, **extra):
        result = dict(opcode=1, flags=3, m=4, n=5, k=9,
                      a=0x1000, b=0x2000, c=0x3000, param=0x4000,
                      words10_12=[16, 16, 8])
        result.update(extra)
        return result

    def conv(self, **extra):
        result = dict(opcode=2, flags=3, m=16, n=5, k=27,
                      a=0x1000, b=0x2000, c=0x3000, param=0x4000,
                      words10_12=[(4 << 16) | 4, (3 << 24) | (3 << 16) | 3,
                                   (1 << 24) | (1 << 16) | (1 << 8) | 1])
        result.update(extra)
        return result

    def pool(self, **extra):
        result = dict(opcode=4, flags=0, m=7, n=7, k=2048,
                      a=0x1000, b=0, c=0x3000, param=0,
                      words10_12=[0, 0, 0])
        result.update(extra)
        return result

    def add(self, **extra):
        result = dict(opcode=5, flags=0, m=56*56*256, n=0, k=0,
                      a=0x1000, b=0x2000, c=0x3000, param=0x4000,
                      words10_12=[0, 0, 0])
        result.update(extra)
        return result

    def assert_invalid(self, descriptor, cfg=None):
        with self.assertRaises(ValueError):
            validate_descriptor(descriptor, cfg or self.cfg)

    def test_original_smallcnn_descriptors_are_byte_identical(self):
        artifact = REPO / 'artifacts/npu'
        report = json.loads((artifact / 'compilation_report.json').read_text())
        commands = (artifact / 'commands.bin').read_bytes()
        self.assertEqual(len(commands), 64*len(report['descriptors']))
        for index, descriptor in enumerate(report['descriptors']):
            validate_descriptor(descriptor, self.cfg)
            raw = commands[index*64:(index+1)*64]
            self.assertEqual(encode(descriptor), raw)
            self.assertEqual(decode(raw), descriptor)

    def test_path_defaults_digest_and_memory_plan(self):
        self.assertEqual(hardware_defaults()['pe_cols'], 4)
        self.assertEqual(str(HERE.parent), str(REPO))
        self.assertEqual(len(digest(HERE / 'npu_config.json')), 64)
        plan = MemoryPlan(dict(self.cfg, ddr_capacity_bytes=32))
        self.assertEqual(plan.allocate('a', 9, [9], 'i1', 'HWC'), 0)
        self.assertEqual(plan.allocate('b', 8, [8], 'i1', 'HWC'), 16)
        plan.validate_access(16, 8, 'b')
        with self.assertRaises(ValueError):
            plan.validate_access(16, 9, 'b')

    def test_gemm_broadcast_tail_and_dataflows(self):
        for flags in (3, 3 | 32, 3 | 64):
            descriptor = self.gemm(flags=flags, m=1, n=1001,
                                   words10_12=[0, 16, 1004])
            validate_descriptor(descriptor, self.cfg)
            self.assertEqual(decode(encode(descriptor)), descriptor)
        # Original batch-one FC packs one physical M tile and broadcasts A.
        validate_descriptor(self.gemm(words10_12=[0, 16, 8]), self.cfg)
        self.assert_invalid(self.gemm(flags=3 | 32 | 64))
        self.assert_invalid(self.gemm(flags=3 | 16))
        self.assert_invalid(self.gemm(flags=3 | 64, k=257,
                                      words10_12=[264, 264, 8]))
        for stride in (4, 8, 15):
            self.assert_invalid(self.gemm(words10_12=[stride, 16, 8]))
        self.assert_invalid(self.gemm(words10_12=[0, 8, 8]))
        self.assert_invalid(self.gemm(words10_12=[0, 16, 4]))

    def test_same_conv_uses_ceiling_output_and_explicit_padding(self):
        # 4x4 / stride 2 / 3x3 SAME has one trailing pad and top/left zero.
        # Symmetric zero padding would produce only 1x1, not 2x2.
        descriptor = self.conv(flags=3 | 16 | 32, m=4,
                               words10_12=[0x00040004, 0x03030003, 0x00000202])
        validate_descriptor(descriptor, self.cfg)
        self.assertEqual(encode(descriptor)[40:52],
                         struct.pack('<3I', 0x00040004, 0x03030003, 0x00000202))
        self.assert_invalid(dict(descriptor, flags=3, m=4))
        self.assert_invalid(dict(descriptor, m=1))
        for flags in (3 | 16, 3 | 16 | 64):
            validate_descriptor(dict(descriptor, flags=flags), self.cfg)

    def test_global_average_pooling_admission(self):
        descriptor = self.pool()
        validate_descriptor(descriptor, self.cfg)
        self.assertEqual(decode(encode(descriptor)), descriptor)
        # The accumulator's documented pixel-count maximum is inclusive.
        validate_descriptor(self.pool(m=16777215, n=1, k=4), self.cfg)
        for override in (dict(flags=1), dict(k=1001), dict(m=0), dict(n=0),
                         dict(b=4), dict(param=4), dict(words10_12=[1, 0, 0]),
                         dict(words10_12=[0, 1, 0]),
                         dict(pool_config=pack_pool_config()),
                         dict(m=16777216, n=1)):
            self.assert_invalid(self.pool(**override))
        self.assert_invalid(self.pool(a=2**64-4))
        self.assert_invalid(self.pool(c=2**64-4))

    def test_residual_add_admission_and_abi(self):
        for flags in (0, 1):
            descriptor = self.add(flags=flags)
            validate_descriptor(descriptor, self.cfg)
            self.assertEqual(decode(encode(descriptor)), descriptor)
            self.assertEqual(encode(descriptor)[:16],
                             struct.pack('<4I', 5 | flags << 8, 56*56*256, 0, 0))
        # ADD always reads its parameter block, independent of its ReLU flag.
        validate_descriptor(self.add(flags=0, param=0), self.cfg)
        for override in (dict(flags=2), dict(flags=32), dict(m=0), dict(m=5),
                         dict(n=1), dict(k=1), dict(words10_12=[4, 0, 0]),
                         dict(words10_12=[0, 0, 4]), dict(param=2),
                         dict(pool_config=pack_pool_config())):
            self.assert_invalid(self.add(**override))
        for key in ('a', 'b', 'c', 'param'):
            self.assert_invalid(self.add(**{key: 2**64-4}))

    def test_bad_fields_and_flags_rejected(self):
        for override in (dict(opcode=0), dict(opcode=6), dict(flags=256),
                         dict(flags=-1), dict(flags=4), dict(flags=8),
                         dict(m=-1), dict(n=2**32), dict(k=0),
                         dict(a=-4), dict(b=2**64), dict(c=2),
                         dict(words10_12=[0, 0]),
                         dict(words10_12=[16, -8, 8]),
                         dict(words10_12=[16, 16, 2**32])):
            self.assert_invalid(self.gemm(**override))

    def test_logical_tails_and_counter_overflow_preserved(self):
        for cols in (4, 8):
            cfg = dict(self.cfg, pe_cols=cols)
            for m, n in ((1, 1), (3, 5), (49, 1001)):
                validate_descriptor(self.gemm(m=m, n=n,
                                              words10_12=[16, 16, (n+3)//4*4]), cfg)
            self.assert_invalid(self.gemm(m=4*65535+1), cfg)
        validate_descriptor(self.conv(m=49, n=5, k=1,
                                      words10_12=[0x00070007, 0x01010001, 0x00000101]),
                            self.cfg)


if __name__ == '__main__':
    unittest.main(verbosity=2)
