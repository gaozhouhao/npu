"""Frozen-golden copying and strict ablation/provenance admission checks."""

import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import benchmark_resnet50_readpath as benchmark
from run_graph_model import prepare as prepare_reference
from check_graph_compiler import fixture
from graph_compiler import benchmark_quantization, compile_graph, write_package


def report(variant):
    original = {name: benchmark.sha256(('original '+name).encode())
                for name in benchmark.CHANGED_FILES}
    original.update({'rtl/compute/gemm_pe.sv': 'pe', 'sim/filelists/rtl.f': 'filelist',
                     'sim/tb/system/graph_model_npu_tb.sv': 'harness'})
    compiled, patches = dict(original), []
    if variant == 'baseline':
        for name in benchmark.CHANGED_FILES:
            compiled[name] = benchmark.sha256(('baseline '+name).encode())
            diff = '--- a/'+name+'\n+++ b/'+name+'\n@@ -1 +1 @@\n-feature_on\n+feature_off\n'
            patches.append(dict(path=name, unified_diff=diff, sha256=benchmark.sha256(diff.encode()),
                                original_sha256=original[name], compiled_sha256=compiled[name]))
    recipe = dict(schema_version=1, experiment=benchmark.EXPERIMENT, variant=variant,
                  native_operand_read_bits=64,
                  features={name: variant == 'optimized' for name in benchmark.FEATURES},
                  original_sha256={name: original[name] for name in benchmark.CHANGED_FILES},
                  compiled_sha256={name: compiled[name] for name in benchmark.CHANGED_FILES},
                  common_original_source_sha256=original, patches=patches,
                  patches_sha256=benchmark.canonical_hash(patches), helper_sha256='helper',
                  wrapper_sha256='wrapper',
                  changed_files=list(benchmark.CHANGED_FILES) if variant == 'baseline' else [])
    source = dict(resolved_commit=benchmark.PINNED_REF, source_sha256=compiled,
                  source_set_sha256=benchmark.canonical_hash(compiled), readpath_ablation=recipe,
                  read_latency_cycles=20, write_latency_cycles=0, reference_sha256='reference',
                  runner_sha256='runner', makefile_sha256='makefile')
    cycles = 1000 if variant == 'baseline' else 800
    return dict(status='PASS', model_sha256='small-fixture', package_sha256={'ddr.bin': 'image'},
                checked_layers=1, checked_full_ddr_bytes=1024, full_ddr_sha256='result',
                purpose='integer_performance', calibrated=False, checker_sha256='checker',
                accuracy_not_measured=True, experiment=benchmark.EXPERIMENT,
                ablation_checker_sha256='ablation-checker', readpath_ablation=recipe, source=source,
                summary=dict(total_cycles=cycles, read_bytes=512, write_bytes=4,
                             nominal_macs=1800, useful_macs=1600,
                             effective_useful_mac_utilization=1600/(16.0*cycles)),
                layers=[dict(index=0, opcode=1, operation='FullyConnected', tensor='out',
                             logical_bytes=4, nominal_macs=1800, useful_macs=1600,
                             sha256='output', cycles=cycles-100, read_bytes=448, write_bytes=4)])


class ComparisonTests(unittest.TestCase):
    def test_small_graph_compares_features_with_native64_shared(self):
        result = benchmark.compare_reports(report('baseline'), report('optimized'))
        self.assertEqual(result['cycle_reduction_pct'], 20)
        self.assertEqual(result['native_operand_read_bits'], 64)
        self.assertFalse(result['native64_improvement_attributed'])
        self.assertFalse(result['dataset_accuracy_measured'])

    def test_native32_wrong_feature_flags_and_variant_swaps_fail(self):
        for key, value in [('native_operand_read_bits', 32), ('variant', 'optimized')]:
            before = report('baseline')
            before['readpath_ablation'][key] = value
            with self.assertRaises(ValueError):
                benchmark.compare_reports(before, report('optimized'))
        before = report('baseline')
        before['readpath_ablation']['features']['conv_cache'] = True
        with self.assertRaises(ValueError):
            benchmark.compare_reports(before, report('optimized'))

    def test_unexpected_rtl_edits_and_changed_optimized_snapshot_fail(self):
        for variant in ('baseline', 'optimized'):
            before, after = report('baseline'), report('optimized')
            source = (before if variant == 'baseline' else after)['source']
            source['source_sha256']['rtl/compute/gemm_pe.sv'] = 'changed'
            source['source_set_sha256'] = benchmark.canonical_hash(source['source_sha256'])
            with self.assertRaisesRegex(ValueError, 'declared three-file'):
                benchmark.compare_reports(before, after)

    def test_other_revision_wrapper_helper_checker_and_original_sources_fail(self):
        for location, key in [('source', 'resolved_commit'), ('recipe', 'helper_sha256'),
                              ('recipe', 'wrapper_sha256'), ('report', 'ablation_checker_sha256')]:
            after = report('optimized')
            target = {'source': after['source'], 'recipe': after['readpath_ablation'], 'report': after}[location]
            target[key] = 'other'
            with self.assertRaises(ValueError):
                benchmark.compare_reports(report('baseline'), after)
        after = report('optimized')
        after['readpath_ablation']['common_original_source_sha256']['rtl/compute/gemm_pe.sv'] = 'other'
        after['source']['source_sha256']['rtl/compute/gemm_pe.sv'] = 'other'
        after['source']['source_set_sha256'] = benchmark.canonical_hash(after['source']['source_sha256'])
        with self.assertRaisesRegex(ValueError, 'common_original_source'):
            benchmark.compare_reports(report('baseline'), after)

    def test_missing_or_corrupted_patch_evidence_fails(self):
        for field in ('patches', 'changed_files', 'original_sha256', 'compiled_sha256'):
            before = report('baseline')
            before['readpath_ablation'][field] = [] if field in ('patches', 'changed_files') else {}
            with self.assertRaises(ValueError):
                benchmark.compare_reports(before, report('optimized'))
        before = report('baseline')
        before['readpath_ablation']['patches'][0]['unified_diff'] += 'unexpected\n'
        with self.assertRaisesRegex(ValueError, 'patch bytes'):
            benchmark.compare_reports(before, report('optimized'))

    def test_incomplete_run_mismatched_output_false_accuracy_and_missing_r50_layers_fail(self):
        for key, value in [('status', 'RUNNING'), ('checked_layers', 2),
                           ('full_ddr_sha256', 'different'), ('accuracy_not_measured', False)]:
            after = report('optimized')
            after[key] = value
            with self.assertRaises(ValueError):
                benchmark.compare_reports(report('baseline'), after)
        before, after = report('baseline'), report('optimized')
        before['model_sha256'] = after['model_sha256'] = benchmark.RESNET50_SHA256
        with self.assertRaisesRegex(ValueError, 'all 72'):
            benchmark.compare_reports(before, after)


class FrozenReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='readpath-ablation-')
        self.root = Path(self.temporary.name)
        self.package, self.reference, self.output = [self.root / name for name in ('model', 'goldens', 'experiment')]
        graph, cfg, unused, inputs = fixture()
        graph['model_sha256'] = 'a'*64
        plan, image, descriptors = compile_graph(graph, cfg, benchmark_quantization(graph), inputs,
                                                 benchmark_only=True)
        write_package(str(self.package), plan, image, descriptors)
        with contextlib.redirect_stdout(io.StringIO()):
            prepare_reference(self.package, self.reference)

    def tearDown(self):
        self.temporary.cleanup()

    def test_prepare_copies_bytes_and_keeps_original_layer_paths(self):
        before = {name: benchmark.file_hash(self.reference / name) for name in benchmark.GOLDEN_FILES}
        with contextlib.redirect_stdout(io.StringIO()):
            metadata = benchmark.prepare(self.package, self.reference, self.output)
        self.assertEqual(metadata['copied_file_sha256'], before)
        for name in benchmark.GOLDEN_FILES:
            self.assertEqual((self.output / name).read_bytes(), (self.reference / name).read_bytes())
            self.assertEqual(benchmark.file_hash(self.reference / name), before[name])
        copied = json.loads((self.output / 'reference.json').read_text())
        self.assertTrue(all(str(self.reference) in row['expected_hex'] for row in copied['layers']))
        benchmark.load_prepared(self.package, self.reference, self.output)

    def test_original_output_and_existing_different_bytes_fail(self):
        with self.assertRaises(ValueError):
            benchmark.prepare(self.package, self.reference, self.reference)
        self.output.mkdir()
        (self.output / 'reference.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Existing output goldens differ'):
            benchmark.prepare(self.package, self.reference, self.output)

    def test_changed_original_reference_after_prepare_fails(self):
        with contextlib.redirect_stdout(io.StringIO()):
            benchmark.prepare(self.package, self.reference, self.output)
        with (self.reference / 'reference.json').open('a') as handle:
            handle.write(' ')
        with self.assertRaisesRegex(ValueError, 'reference changed after prepare'):
            benchmark.load_prepared(self.package, self.reference, self.output)

    def test_unpinned_rtl_reference_fails(self):
        with mock.patch.object(benchmark.subprocess, 'check_output', return_value=b'othercommit\n'):
            with self.assertRaisesRegex(ValueError, 'pinned common RTL'):
                benchmark.resolve_ref('HEAD')


if __name__ == '__main__':
    unittest.main(verbosity=2)
