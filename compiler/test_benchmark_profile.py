"""Explicit uncalibrated admission and real-weight integer package tests."""
from __future__ import print_function

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from check_graph_compiler import fixture
from compile_onnx import benchmark_input
from graph_compiler import (benchmark_quantization, compile_graph,
                            optimize_graph, resolve_quantization)
from reference_int8 import execute
from test_onnx_frontend import initializer, model, node


class BenchmarkProfileTests(unittest.TestCase):
    def setUp(self):
        self.graph, self.cfg, self.calibrated, self.inputs = fixture()
        self.graph['model_sha256'] = 'a'*64
        self.profile = benchmark_quantization(self.graph)

    def test_benchmark_profile_has_no_calibration_or_accuracy_claim(self):
        self.assertFalse(self.profile['calibrated'])
        self.assertEqual(self.profile['purpose'], 'integer_performance')
        self.assertTrue(self.profile['accuracy_not_measured'])
        self.assertNotIn('calibration', self.profile)
        self.assertEqual(self.profile['model_sha256'], self.graph['model_sha256'])
        self.assertEqual(self.profile['preprocessing']['input_shape'], [5, 7, 3])
        self.assertEqual(self.profile['preprocessing']['input_layout'], 'HWC')
        self.assertEqual(self.profile['tensors']['pool'], dict(shared_with='stem_relu'))
        self.assertEqual(self.profile['tensors']['gap'], dict(shared_with='sum_relu'))

    def test_production_rejects_benchmark_even_if_calibration_is_forged(self):
        for forged in (False, True):
            profile = copy.deepcopy(self.profile)
            if forged:
                profile.update(calibrated=True, calibration=dict(
                    dataset='invented', samples=500, method='invented'))
            with self.assertRaises(ValueError):
                compile_graph(self.graph, self.cfg, profile, self.inputs)
        compile_graph(self.graph, self.cfg, self.profile, self.inputs, benchmark_only=True)

    def test_benchmark_rejects_wrong_identity_shape_mode_and_invalid_scales(self):
        edits = [('schema_version', 2), ('model_sha256', 'b'*64),
                 ('purpose', 'deployment'), ('calibrated', True),
                 ('accuracy_not_measured', False), ('calibration', {})]
        for key, value in edits:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            with self.assertRaises(ValueError):
                compile_graph(self.graph, self.cfg, profile, benchmark_only=True)
        for key, value in [('input_shape', [7, 5, 3]), ('input_layout', 'NCHW')]:
            profile = copy.deepcopy(self.profile)
            profile['preprocessing'][key] = value
            with self.assertRaises(ValueError):
                compile_graph(self.graph, self.cfg, profile, benchmark_only=True)
        for value in (0, -1, float('nan'), float('inf'), None, True):
            with self.assertRaises(ValueError):
                benchmark_quantization(self.graph, value)
            profile = copy.deepcopy(self.profile)
            profile['tensors']['input']['scale'] = value
            with self.assertRaises(ValueError):
                compile_graph(self.graph, self.cfg, profile, benchmark_only=True)
        calibrated = copy.deepcopy(self.calibrated)
        calibrated['model_sha256'] = self.graph['model_sha256']
        with self.assertRaises(ValueError):
            compile_graph(self.graph, self.cfg, calibrated, benchmark_only=True)

    def test_shared_scales_and_full_fixture_use_existing_integer_backend(self):
        quant = resolve_quantization(optimize_graph(self.graph), self.profile, benchmark_only=True)
        self.assertEqual(quant['pool'], quant['stem_relu'])
        self.assertEqual(quant['gap'], quant['sum_relu'])
        plan, image, descriptors = compile_graph(self.graph, self.cfg, self.profile,
                                                  self.inputs, benchmark_only=True)
        memory, traces = execute(image, descriptors)
        self.assertEqual([trace['opcode'] for trace in traces], [2, 2, 3, 2, 2, 5, 4, 1])
        self.assertEqual(len(memory), plan['image_bytes'])
        self.assertEqual(len(traces[-1]['values']), 10)
        self.assertFalse(plan['calibrated'])
        self.assertFalse(plan['deployment_ready'])
        self.assertEqual(plan['purpose'], 'integer_performance')
        self.assertTrue(plan['accuracy_not_measured'])
        self.assertNotIn('calibration', plan)

    def test_nonzero_synthetic_input_is_seeded_and_signed(self):
        first = benchmark_input([224, 224, 3], 1)
        self.assertEqual(first, benchmark_input([224, 224, 3], 1))
        self.assertNotEqual(first, benchmark_input([224, 224, 3], 2))
        self.assertEqual(len(first), 224*224*3)
        values = bytearray(first)
        self.assertNotIn(0, values)
        self.assertTrue(any(value < 128 for value in values))
        self.assertTrue(any(value >= 128 for value in values))


class BenchmarkCLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix='npu-benchmark-profile-')
        self.path = os.path.join(self.directory, 'weights.onnx')
        # Four output channels have distinct scales. With benchmark scale 1/16,
        # input [8,-12,20] has exact expected outputs [8,-8,-24,-10].
        weights = [1., 0., 0., -1., 0., 0., 0., 2., 0., 0., 0., -0.5]
        payload = model([node('Conv', ['input', 'w'], 'out')],
                        [initializer('w', [4, 3, 1, 1], weights)],
                        [1, 3, 1, 1], [('out', [1, 4, 1, 1])])
        with open(self.path, 'wb') as handle:
            handle.write(payload)
        self.sha256 = hashlib.sha256(payload).hexdigest()
        self.out = os.path.join(self.directory, 'package')
        self.command = [sys.executable, os.path.join(os.path.dirname(__file__), 'compile_onnx.py'),
                        'compile', '--model', self.path, '--out', self.out]

    def tearDown(self):
        shutil.rmtree(self.directory)

    def run_cli(self, flags):
        process = subprocess.Popen(self.command+flags, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = process.communicate()
        return process.returncode, stdout.decode('utf-8'), stderr.decode('utf-8')

    def test_cli_requires_explicit_mode_and_emits_reviewable_benchmark_artifacts(self):
        code, stdout, stderr = self.run_cli([])
        self.assertNotEqual(code, 0)
        self.assertIn('real calibration', stderr)
        code, stdout, stderr = self.run_cli(['--benchmark-only', '--input-seed', '42'])
        self.assertEqual(code, 0, stderr)
        self.assertIn('accuracy not measured', stdout)
        profile_path = os.path.join(self.out, 'quantization.benchmark.json')
        with open(profile_path) as handle:
            profile = json.load(handle)
        with open(os.path.join(self.out, 'manifest.json')) as handle:
            plan = json.load(handle)
        with open(os.path.join(self.out, 'input.bin'), 'rb') as handle:
            inputs = handle.read()
        self.assertEqual(profile['model_sha256'], self.sha256)
        self.assertFalse(profile['calibrated'])
        self.assertNotIn('calibration', profile)
        self.assertNotIn('calibration', plan)
        self.assertEqual(inputs, benchmark_input([1, 1, 3], 42))
        code, stdout, stderr = self.run_cli(['--quantization', profile_path])
        self.assertNotEqual(code, 0)
        self.assertIn('benchmark_only', stderr)

    def test_real_weight_payload_matches_independent_scalar_integer_reference(self):
        input_path = os.path.join(self.directory, 'input.bin')
        with open(input_path, 'wb') as handle:
            handle.write(bytearray([8, 244, 20]))
        code, stdout, stderr = self.run_cli(['--benchmark-only', '--input-bin', input_path])
        self.assertEqual(code, 0, stderr)
        with open(os.path.join(self.out, 'ddr.bin'), 'rb') as handle:
            image = handle.read()
        with open(os.path.join(self.out, 'descriptors.bin'), 'rb') as handle:
            descriptors = handle.read()
        with open(os.path.join(self.out, 'manifest.json')) as handle:
            plan = json.load(handle)
        memory, traces = execute(image, descriptors)
        self.assertEqual(traces[-1]['values'], [8, -8, -24, -10])
        self.assertEqual(plan['weight_quantization']['out']['scales'],
                         [1./127, 1./127, 2./127, 0.5/127])
        self.assertEqual(plan['benchmark_input']['source'], 'file')


if __name__ == '__main__':
    unittest.main(verbosity=2)
