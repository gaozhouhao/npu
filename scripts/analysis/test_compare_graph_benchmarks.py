import copy
import unittest

from compare_graph_benchmarks import compare


def report():
    return dict(status='PASS', model_sha256='model', package_sha256={'ddr.bin': 'image'},
                checked_layers=1, checked_full_ddr_bytes=1024, full_ddr_sha256='result',
                purpose='integer_performance', calibrated=False, checker_sha256='checker',
                source=dict(resolved_commit='revision', read_latency_cycles=20,
                            write_latency_cycles=0, reference_sha256='reference',
                            runner_sha256='runner', makefile_sha256='makefile',
                            source_sha256={'sim/tb/system/graph_model_npu_tb.sv': 'harness',
                                           'rtl/npu_top.sv': 'rtl'}),
                summary=dict(total_cycles=1000, read_bytes=512, write_bytes=4,
                             nominal_macs=1800, useful_macs=1600, effective_useful_mac_utilization=0.1),
                layers=[dict(index=0, opcode=1, operation='FullyConnected', tensor='out',
                             logical_bytes=4, nominal_macs=1800, useful_macs=1600, sha256='out', cycles=900,
                             read_bytes=448, write_bytes=4)])


class ComparisonTests(unittest.TestCase):
    def test_identical_full_run_measures_zero_gain(self):
        result = compare(report(), report())
        self.assertEqual(result['cycle_reduction_pct'], 0)
        self.assertEqual(result['speedup'], 1)

    def test_measured_reduction_uses_cycles_not_cpu_wall_time(self):
        before, after = report(), report()
        after['summary']['total_cycles'] = 800
        after['layers'][0]['cycles'] = 700
        after['source']['source_sha256']['rtl/npu_top.sv'] = 'changed'
        result = compare(before, after)
        self.assertEqual(result['cycle_reduction_pct'], 20)
        self.assertEqual(result['speedup'], 1.25)

    def test_different_input_or_model_is_rejected(self):
        for key, value in [('package_sha256', {'ddr.bin': 'other'}),
                           ('model_sha256', 'other'), ('full_ddr_sha256', 'other')]:
            other = report()
            other[key] = value
            with self.assertRaises(ValueError):
                compare(report(), other)

    def test_different_latency_or_harness_is_rejected(self):
        for key in ('read_latency_cycles', 'write_latency_cycles'):
            other = report()
            other['source'][key] += 1
            with self.assertRaises(ValueError):
                compare(report(), other)
        other = report()
        other['source']['source_sha256']['sim/tb/system/graph_model_npu_tb.sv'] = 'other'
        with self.assertRaises(ValueError):
            compare(report(), other)

    def test_different_runner_or_build_rules_are_rejected(self):
        for key in ('runner_sha256', 'makefile_sha256'):
            other = report()
            other['source'][key] = 'other'
            with self.assertRaises(ValueError):
                compare(report(), other)
        other = report()
        other['checker_sha256'] = 'other'
        with self.assertRaises(ValueError):
            compare(report(), other)

    def test_incomplete_run_and_missing_layer_are_rejected(self):
        for key, value in [('status', 'RUNNING'), ('layers', []), ('checked_layers', 2)]:
            other = report()
            other[key] = value
            with self.assertRaises(ValueError):
                compare(report(), other)

    def test_changed_layer_results_are_rejected(self):
        for key in ('sha256', 'tensor', 'logical_bytes', 'opcode', 'nominal_macs', 'useful_macs'):
            other = copy.deepcopy(report())
            other['layers'][0][key] = 'other'
            with self.assertRaises(ValueError):
                compare(report(), other)


if __name__ == '__main__':
    unittest.main()
