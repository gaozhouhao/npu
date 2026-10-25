#!/usr/bin/env python
"""Graph lowering, calibration admission and residual lifetime tests."""
import copy
import os
import struct
import unittest
from check_graph_compiler import fixture
from graph_compiler import (plan_graph, compile_graph, fixed_point, optimize_graph,
                            resolve_quantization, quantization_template)
from target import decode, encode, validate_descriptor


class GraphCompilerTests(unittest.TestCase):
    def setUp(self):
        self.graph, self.cfg, self.profile, self.inputs = fixture()

    def test_compile_uses_real_abi_logical_tails_and_all_operations(self):
        plan, image, commands = compile_graph(self.graph, self.cfg, self.profile, self.inputs)
        self.assertEqual([d['opcode'] for d in plan['commands']], [2, 2, 3, 2, 2, 5, 4, 1])
        self.assertEqual((plan['commands'][0]['m'], plan['commands'][0]['n']), (35, 5))
        self.assertEqual(plan['commands'][3]['k'], 288)
        self.assertTrue(plan['commands'][3]['flags'] & 32)
        self.assertEqual(plan['commands'][-1]['words10_12'], [0, 8, 12])
        self.assertEqual(plan['commands'][-1]['n'], 10)
        for index, desc in enumerate(plan['commands']):
            validate_descriptor(desc, self.cfg)
            self.assertEqual(encode(decode(commands[index*64:(index+1)*64])), encode(desc))
        self.assertEqual(len(image), plan['image_bytes'])
        self.assertFalse(plan['deployment_ready'])

    def test_all_overlapping_lifetimes_have_disjoint_allocations(self):
        plan = plan_graph(self.graph, self.cfg)
        regions = list(plan['regions'].values())
        for index, a in enumerate(regions):
            for b in regions[index+1:]:
                alive = max(a['born'], b['born']) <= min(a['last_use'], b['last_use'])
                overlaps = a['address'] < b['address']+b['bytes'] and b['address'] < a['address']+a['bytes']
                self.assertFalse(alive and overlaps)
        self.assertLess(plan['activation_arena_bytes'], sum(r['bytes'] for r in regions))
        self.assertEqual(plan['regions']['pool']['last_use'], 4)

    def test_missing_or_cyclic_or_wrong_pool_scales_are_rejected(self):
        template = quantization_template(self.graph)
        with self.assertRaises(ValueError):
            compile_graph(self.graph, self.cfg, template)
        for edit in ('missing', 'cycle', 'pool'):
            profile = copy.deepcopy(self.profile)
            if edit == 'missing':
                del profile['tensors']['main']
            elif edit == 'cycle':
                profile['tensors']['main'] = dict(shared_with='main')
            else:
                profile['tensors']['pool'] = dict(scale=1.0, zero_point=0)
            with self.assertRaises(ValueError):
                compile_graph(self.graph, self.cfg, profile)

    def test_relu_with_other_consumers_never_silently_changes_graph(self):
        graph = copy.deepcopy(self.graph)
        graph['nodes'][2]['inputs'] = ['compact']
        with self.assertRaises(ValueError):
            optimize_graph(graph)

    def test_memory_capacity_and_input_length_checked(self):
        cfg = dict(self.cfg, ddr_capacity_bytes=32768)
        # Fixture is small; require a capacity that definitely cannot contain it.
        cfg['ddr_capacity_bytes'] = 1024
        with self.assertRaises(ValueError):
            plan_graph(self.graph, cfg)
        with self.assertRaises(ValueError):
            compile_graph(self.graph, self.cfg, self.profile, b'bad')

    def test_conv_same_upper_and_eight_column_target(self):
        graph = copy.deepcopy(self.graph)
        graph['nodes'] = graph['nodes'][:1]
        node = graph['nodes'][0]
        node.update(shape=[3, 4, 5])
        node['attrs'].update(kernel=[3, 3], strides=[2, 2], pads=[1, 1, 1, 1])
        node['weights']['shape'] = [5, 27]
        graph['output'] = node['output']
        plan = plan_graph(graph, dict(self.cfg, pe_cols=8))
        self.assertEqual(plan['commands'][0]['m'], 12)
        # Even input creates asymmetric SAME_UPPER padding.
        graph['input']['shape'] = [6, 8, 3]
        node['attrs']['pads'] = [0, 0, 1, 1]
        plan = plan_graph(graph, self.cfg)
        self.assertTrue(plan['commands'][0]['flags'] & 16)
        node['attrs']['pads'] = [1, 0, 0, 1]
        with self.assertRaises(ValueError):
            plan_graph(graph, self.cfg)

    def test_fixed_point_rejects_overflow_and_retains_precision(self):
        multipliers, shift = fixed_point([0.1, 0.3], 255)
        for ratio, multiplier in zip((0.1, 0.3), multipliers):
            self.assertLess(abs(float(multiplier)/(1 << shift)-ratio), 1e-8)
        with self.assertRaises(ValueError):
            fixed_point([float('nan')], 255)
        with self.assertRaises(ValueError):
            fixed_point([1e30], 255)

    def test_profile_bound_to_model_and_target_config_checked(self):
        graph = copy.deepcopy(self.graph)
        graph['model_sha256'] = 'a'*64
        profile = copy.deepcopy(self.profile)
        with self.assertRaises(ValueError):
            compile_graph(graph, self.cfg, profile)
        profile['model_sha256'] = 'a'*64
        compile_graph(graph, self.cfg, profile)
        for cfg in (dict(self.cfg, ddr_base=8), dict(self.cfg, k_tile_size=7),
                    dict(self.cfg, pe_cols=0), dict(self.cfg, alignment_bytes=3)):
            with self.assertRaises(ValueError):
                plan_graph(graph, cfg)
        aligned = plan_graph(graph, dict(self.cfg, alignment_bytes=64))
        self.assertTrue(all(r['address'] % 64 == 0 for r in aligned['regions'].values()))
        self.assertTrue(all(d['param'] % 64 == 0 and d['b'] % 64 == 0
                            for d in aligned['commands']))
        for field, value in (('input_layout', 'NCHW'), ('input_shape', [7, 5, 3])):
            wrong = copy.deepcopy(profile)
            wrong['preprocessing'][field] = value
            with self.assertRaises(ValueError):
                compile_graph(graph, self.cfg, wrong)

    def test_scale_underflow_fails_as_a_compile_error(self):
        profile = copy.deepcopy(self.profile)
        profile['tensors']['input']['scale'] = 1e-323
        with self.assertRaises(ValueError):
            compile_graph(self.graph, self.cfg, profile)


if __name__ == '__main__':
    unittest.main(verbosity=2)
