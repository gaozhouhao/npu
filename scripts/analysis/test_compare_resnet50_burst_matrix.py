#!/usr/bin/env python3
"""Reject invalid matrix comparisons using copied real five-layer evidence."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import compare_resnet50_burst_matrix as matrix

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/resnet50-burst-matrix/verification/comparison-tests'


class MatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reports = [json.loads((ROOT / name).read_text()) for name in (
            'build/resnet50-burst-matrix/smoke-cpp/burst_serial-report.json',
            'build/resnet50-burst-matrix/smoke-cpp/burst_double-report.json',
            'build/resnet50-serial-baseline/multik-cpp/current-report.json')]
        cls.logs = [Path(report['source']['run_command'][0]).parent.parent / 'simulation.log'
                    for report in cls.reports]
        OUT.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.reports = deepcopy(type(self).reports)
        self.logs = list(type(self).logs)
        self.temporary = tempfile.TemporaryDirectory(prefix='case-', dir=OUT)
        self.addCleanup(self.temporary.cleanup)

    def run_compare(self):
        return matrix.compare_matrix(self.reports, self.logs, 5, 59072)

    def replace_log(self, index, transform):
        path = Path(self.temporary.name) / ('%d.log' % index)
        raw = transform(self.logs[index].read_text()).encode()
        path.write_bytes(raw)
        self.reports[index]['simulation_log_sha256'] = hashlib.sha256(raw).hexdigest()
        self.logs[index] = path

    def test_real_smoke_passes(self):
        result = self.run_compare()
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['comparisons']['serial_to_optimized']['baseline_cycles'], 291453)
        self.assertEqual(result['comparisons']['serial_to_optimized']['current_cycles'], 131770)
        self.assertEqual(result['runtime_checks']['serial']['aggregate']['overlap_cycles'], 0)
        self.assertGreater(result['runtime_checks']['double']['aggregate']['read_overlap'], 0)

    def test_missing_compiled_guard(self):
        del self.reports[0]['source']['compiled_source_sha256'][matrix.GUARD_PATH]
        with self.assertRaisesRegex(ValueError, 'Runtime guard is absent'):
            self.run_compare()

    def test_different_input(self):
        self.reports[0]['package_sha256']['ddr.bin'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'package_sha256'):
            self.run_compare()

    def test_different_toolchain(self):
        self.reports[2]['source']['compiler_binary_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'toolchain/driver condition'):
            self.run_compare()

    def test_different_compile_options(self):
        command = self.reports[2]['source']['command']
        command[command.index('-CFLAGS') + 1] = '-std=c++20 -O2 -pthread'
        with self.assertRaisesRegex(ValueError, 'Compilation flags disagree'):
            self.run_compare()

    def test_disabled_burst(self):
        self.reports[0]['source']['measurement_parameters']['conv_burst'] = False
        with self.assertRaisesRegex(ValueError, 'feature configuration'):
            self.run_compare()

    def test_replaced_common_burst_loader(self):
        for report in self.reports[:2]:
            for key in ('compiled_source_sha256', 'source_sha256'):
                report['source'][key][matrix.BURST_PATH] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'historical Burst loader'):
            self.run_compare()

    def test_unrelated_rtl_difference(self):
        for key in ('compiled_source_sha256', 'source_sha256'):
            self.reports[0]['source'][key]['rtl/compute/pe.sv'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'SV differences exceed'):
            self.run_compare()

    def test_common_pe_change_even_with_recomputed_set_hash(self):
        for report in self.reports[:2]:
            for key in ('compiled_source_sha256', 'source_sha256'):
                report['source'][key]['rtl/compute/pe.sv'] = '0' * 64
            report['source']['source_set_sha256'] = matrix.sha(
                json.dumps(report['source']['source_sha256'], sort_keys=True).encode())
        with self.assertRaisesRegex(ValueError, 'Pinned source-set hash'):
            self.run_compare()

    def test_fake_source_set_hash(self):
        self.reports[0]['source']['source_set_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'Pinned source-set hash'):
            self.run_compare()

    def test_changed_optimized_source_set(self):
        source = self.reports[2]['source']
        for key in ('compiled_source_sha256', 'source_sha256'):
            source[key]['rtl/compute/pe.sv'] = '0' * 64
        source['source_set_sha256'] = matrix.sha(json.dumps(source['source_sha256'], sort_keys=True).encode())
        with self.assertRaisesRegex(ValueError, 'Pinned source-set hash'):
            self.run_compare()

    def test_common_missing_compiled_pe(self):
        for report in self.reports[:2]:
            del report['source']['compiled_source_sha256']['rtl/compute/pe.sv']
        with self.assertRaisesRegex(ValueError, 'Compiled SV set differs'):
            self.run_compare()

    def test_unexpected_source_exclusion(self):
        self.reports[2]['source']['excluded_verification_sources'].append('rtl/compute/pe.sv')
        with self.assertRaisesRegex(ValueError, 'Unexpected compiled-source exclusions'):
            self.run_compare()

    def test_common_fake_latency_metadata(self):
        for report in self.reports:
            report['source']['read_latency_cycles'] = 0
        with self.assertRaisesRegex(ValueError, 'Run command/source read latency differs'):
            self.run_compare()

    def test_common_fake_latency_metadata_and_run_arguments(self):
        for report in self.reports:
            report['source']['read_latency_cycles'] = 0
            command = report['source']['run_command']
            command[command.index('+DDR_RD_LATENCY=20')] = '+DDR_RD_LATENCY=0'
        with self.assertRaisesRegex(ValueError, 'Raw log/source read latency differs'):
            self.run_compare()

    def test_wrong_run_command_layer_count(self):
        command = self.reports[0]['source']['run_command']
        command[command.index('+DESC_COUNT=5')] = '+DESC_COUNT=4'
        with self.assertRaisesRegex(ValueError, 'Run command layer count/DDR size/cycle limit'):
            self.run_compare()

    def test_wrong_raw_model_config(self):
        self.replace_log(0, lambda text: text.replace('descriptor_count=5', 'descriptor_count=4'))
        with self.assertRaisesRegex(ValueError, 'MODEL_CONFIG differs'):
            self.run_compare()

    def test_wrong_raw_finished_cycles(self):
        self.replace_log(0, lambda text: text.replace('MODEL_NPU FINISHED: cycles=291453',
                                                    'MODEL_NPU FINISHED: cycles=291454'))
        with self.assertRaisesRegex(ValueError, 'MODEL_NPU FINISHED differs'):
            self.run_compare()

    def test_real_full_current_source_and_log_pass(self):
        report = json.loads((ROOT / 'build/resnet50-rollback-compare/cpp-full/current-report.json').read_text())
        matrix.matched_sources(self.reports[0], self.reports[1], report)
        path = Path(report['source']['run_command'][0]).parent.parent / 'simulation.log'
        self.assertEqual(matrix.check_log(report, path)['sha256'], report['simulation_log_sha256'])

    def test_missing_runtime_guard(self):
        self.replace_log(0, lambda text: '\n'.join(line for line in text.splitlines()
                         if not line.startswith('BURST_PREFETCH_CHECK,PASS,')) + '\n')
        with self.assertRaisesRegex(ValueError, 'runtime guard records'):
            self.run_compare()

    def test_fake_runtime_dimensions(self):
        self.replace_log(0, lambda text: text.replace('conv=1,m=49,n=32,k=288',
                                                    'conv=1,m=48,n=32,k=288'))
        with self.assertRaisesRegex(ValueError, 'dimensions/tile count'):
            self.run_compare()

    def test_serial_overlap(self):
        self.replace_log(0, lambda text: text.replace('overlap_cycles=0,a_start_overlap=0',
                                                    'overlap_cycles=1,a_start_overlap=0'))
        with self.assertRaisesRegex(ValueError, 'Serial run overlaps'):
            self.run_compare()

    def test_no_real_burst_runtime(self):
        self.replace_log(0, lambda text: text.replace('conv_max_beats=24,conv_multibeat_requests=1352',
                                                    'conv_max_beats=1,conv_multibeat_requests=0'))
        with self.assertRaisesRegex(ValueError, 'does not demonstrate accepted multiword'):
            self.run_compare()

    def test_no_double_bank_read_overlap(self):
        self.replace_log(1, lambda text: text.replace('read_overlap=6970', 'read_overlap=0'))
        with self.assertRaisesRegex(ValueError, 'did not demonstrate prefetch'):
            self.run_compare()

    def test_partial_network(self):
        self.reports[0]['status'] = 'RUNNING'
        with self.assertRaisesRegex(ValueError, 'Both full runs must pass'):
            self.run_compare()

    def test_full_network_requirement_rejects_smoke(self):
        with self.assertRaisesRegex(ValueError, 'complete layer count/full DDR size'):
            matrix.compare_matrix(self.reports, self.logs)


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(MatrixTests)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    report = dict(passed=result.wasSuccessful(), tests_run=result.testsRun,
                  errors=[name.id() for name, _ in result.errors],
                  failures=[name.id() for name, _ in result.failures],
                  comparison_script_sha256=matrix.sha(Path(matrix.__file__).read_bytes()))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
