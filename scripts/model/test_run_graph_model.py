#!/usr/bin/env python3
"""Reject corrupt packages, incomplete simulations and incorrect full DDR."""

import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

from run_graph_model import (ROOT, check, descriptor_mac_counts, file_hash, load_package, parse_perf,
                             prepare, write_hex, write_json)
from check_graph_compiler import fixture
from graph_compiler import benchmark_quantization, compile_graph, write_package
from reference_int8 import execute


def valid_log(reference):
    """Synthetic counter records used only to exercise validation failures."""
    lines = ['DDR_READ_LATENCY_CYCLES,20', 'DDR_WRITE_LATENCY_CYCLES,0']
    cycles, writes, written = 5, 0, 0
    for layer in reference['layers']:
        index, count = layer['index'], layer['logical_bytes']
        beats = (count+3)//4
        cycles += 100+index
        writes += beats
        written += count
        lines.append('LAYER_CHECK PASS index=%d opcode=%d checked_bytes=%d' %
                     (index, layer['opcode'], count))
        lines.append('PERF_LAYER,index=%d,opcode=%d,cycles=%d,executor=80,pool=0,'
                     'ar=2,read_beats=8,aw=1,write_beats=%d,written_bytes=%d' %
                     (index, layer['opcode'], 100+index, beats, count))
    count = reference['descriptor_count']
    lines.append('PERF_TOTAL,cycles=%d,executor=%d,pool=0,ar=%d,read_beats=%d,'
                 'aw=%d,write_beats=%d,written_bytes=%d' %
                 (cycles, count*80, count*2+1, count*8+8, count, writes, written))
    lines.append('PERF_COUNTER_CHECK,PASS')
    lines.append('MODEL_NPU FINISHED: cycles=%d read_beats=%d write_beats=%d '
                 'written_bytes=%d logits_count=10 top1=0 descriptors=%d layers=%d' %
                 (cycles, count*8+8, writes, written, count, count))
    return '\n'.join(lines)+'\n'


class GraphRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='graph-runner-test-')
        self.directory = Path(self.temporary.name)
        self.package = self.directory / 'package'
        self.output = self.directory / 'check'
        self.graph, cfg, unused_profile, inputs = fixture()
        self.graph['model_sha256'] = 'a'*64
        self.plan, self.image, self.descriptors = compile_graph(
            self.graph, cfg, benchmark_quantization(self.graph), inputs, benchmark_only=True)
        write_package(str(self.package), self.plan, self.image, self.descriptors)
        self.reference = prepare(self.package, self.output)

    def tearDown(self):
        self.temporary.cleanup()

    def log_path(self, text):
        path = self.directory / 'simulation.log'
        path.write_text(text)
        return path

    def install_simulation(self):
        directory = self.output / 'current-rtl'
        directory.mkdir()
        (directory / 'simulation.log').write_text(valid_log(self.reference))
        write_hex(directory / 'ddr.hex', (self.output / 'expected.bin').read_bytes())
        write_json(directory / 'source.json', dict(
            status='FINISHED', returncode=0, package_sha256=self.reference['package_sha256'],
            reference_sha256=file_hash(self.output / 'reference.json'),
            read_latency_cycles=20, write_latency_cycles=0, source_ref='synthetic parser test'))
        return directory

    def test_prepared_reference_matches_independent_scalar_all_ddr_and_alias_boundaries(self):
        expected, traces = execute(self.image, self.descriptors)
        self.assertEqual((self.output / 'expected.bin').read_bytes(), expected)
        self.assertEqual(self.reference['descriptor_count'], 8)
        self.assertFalse(self.reference['dataset_accuracy_measured'])
        self.assertFalse(self.reference['calibrated'])
        self.assertEqual(self.reference['purpose'], 'integer_performance')
        self.assertEqual(len((self.output / 'layers.txt').read_text().splitlines()), 8)
        self.assertEqual(self.reference['nominal_macs'],
                         sum(command['m']*command['n']*command['k'] for command in self.plan['commands']
                             if command['opcode'] in (1, 2)))
        self.assertLess(self.reference['useful_macs'], self.reference['nominal_macs'])
        self.assertNotIn('values', self.reference['layers'][0])
        # The final ten-byte tensor has a zero-padded storage word, but the
        # checker metadata exposes only its ten logical bytes.
        last = self.reference['layers'][-1]
        self.assertEqual(last['logical_bytes'], 10)
        self.assertEqual(len(Path(last['expected_hex']).read_text().splitlines()), 3)
        self.assertEqual(Path(last['expected_hex']).read_text().splitlines()[-1][:4], '0000')

    def test_rejects_corrupted_embedded_descriptor_copy(self):
        corrupt = bytearray(self.descriptors)
        corrupt[0] ^= 1
        (self.package / 'descriptors.bin').write_bytes(corrupt)
        with self.assertRaisesRegex(ValueError, 'Embedded DDR descriptors'):
            load_package(self.package)

    def test_rejects_corrupt_image_hash_or_descriptor_count(self):
        manifest_path = self.package / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['ddr_sha256'] = 'b'*64
        write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            load_package(self.package)
        manifest['ddr_sha256'] = self.plan['ddr_sha256']
        manifest['descriptor_count'] += 1
        write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, 'Descriptor count'):
            load_package(self.package)

    def test_valid_counters_keep_partial_write_strobes_and_useful_mac_denominator(self):
        summary, rows = parse_perf(self.log_path(valid_log(self.reference)), self.reference)
        self.assertEqual(rows[-1]['write_bytes'], 10)
        self.assertLess(summary['write_bytes'], summary['write_beats']*4)
        self.assertEqual(summary['cycles_outside_layers'], 5)
        self.assertEqual(summary['effective_useful_mac_utilization'],
                         self.reference['useful_macs']/(16.0*summary['total_cycles']))

    def test_rejects_missing_layer_checks_counts_finish_and_disagreeing_counters(self):
        original = valid_log(self.reference)
        variants = [
            '\n'.join(line for line in original.splitlines() if 'LAYER_CHECK PASS index=2 ' not in line),
            '\n'.join(line for line in original.splitlines() if not line.startswith('PERF_LAYER,index=2,')),
            '\n'.join(line for line in original.splitlines() if not line.startswith('MODEL_NPU FINISHED')),
            original.replace('descriptors=8 layers=8', 'descriptors=7 layers=8'),
            original.replace('DDR_READ_LATENCY_CYCLES,20', 'DDR_READ_LATENCY_CYCLES,0'),
            original.replace('DDR_WRITE_LATENCY_CYCLES,0', 'DDR_WRITE_LATENCY_CYCLES,7'),
            original.replace('checked_bytes=10', 'checked_bytes=12'),
            original+'LAYER_CHECK PASS index=0 opcode=2 checked_bytes=175\n',
            original+'Error: simulator failure\n',
            original.replace('PERF_COUNTER_CHECK,PASS', ''),
            original.replace('MODEL_NPU FINISHED: cycles=', 'MODEL_NPU FINISHED: read_beats=1 cycles='),
        ]
        for text in variants:
            with self.assertRaises(ValueError):
                parse_perf(self.log_path(text), self.reference)

    def test_full_dump_pass_report_and_corrupted_byte_rejection(self):
        directory = self.install_simulation()
        report = check(self.package, self.output)
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(report['checked_full_ddr_bytes'], self.plan['image_bytes'])
        self.assertEqual(report['checked_layers'], 8)
        self.assertFalse(report['dataset_accuracy_measured'])
        self.assertFalse(report['calibrated'])
        self.assertEqual(report['checker_sha256'], file_hash(ROOT / 'scripts/model/run_graph_model.py'))
        self.assertTrue((self.output / 'per_layer.csv').exists())
        bad = bytearray((self.output / 'expected.bin').read_bytes())
        bad[0] ^= 1
        write_hex(directory / 'ddr.hex', bad)
        with self.assertRaisesRegex(ValueError, 'Final DDR differs at byte 0'):
            check(self.package, self.output)

    def test_reference_mutation_and_short_dump_are_rejected(self):
        directory = self.install_simulation()
        write_hex(directory / 'ddr.hex', b'\0'*4)
        with self.assertRaisesRegex(ValueError, 'dump size differs'):
            check(self.package, self.output)
        path = Path(self.reference['layers'][0]['expected_hex'])
        path.write_text('00000000\n')
        with self.assertRaisesRegex(ValueError, 'Expected layer image was modified'):
            check(self.package, self.output)


    def test_check_recomputes_old_mac_metadata_without_modifying_immutable_goldens(self):
        # Model an older prepared reference, whose useful count included all
        # kernel padding. Its file hash remains the exact run provenance.
        reference = copy.deepcopy(self.reference)
        reference.pop('nominal_macs')
        reference['useful_macs'] = self.reference['nominal_macs']
        for layer in reference['layers']:
            layer['useful_macs'] = layer.pop('nominal_macs')
        write_json(self.output / 'reference.json', reference)
        self.install_simulation()
        before = (self.output / 'reference.json').read_bytes()
        report = check(self.package, self.output)
        self.assertEqual((self.output / 'reference.json').read_bytes(), before)
        self.assertEqual(report['summary']['nominal_macs'], self.reference['nominal_macs'])
        self.assertEqual(report['summary']['useful_macs'], self.reference['useful_macs'])
        self.assertEqual([row['useful_macs'] for row in report['layers']],
                         [row['useful_macs'] for row in self.reference['layers']])
        self.assertEqual(report['summary']['effective_useful_mac_utilization'],
                         self.reference['useful_macs']/(16.0*report['summary']['total_cycles']))


class MACGeometryTests(unittest.TestCase):
    @staticmethod
    def conv(height, width, channels, outputs, kernel, strides, top_left, output_hw, same_upper=False):
        kh, kw = kernel
        sh, sw = strides
        pt, pl = top_left
        words = [0]*16
        words[0] = 2 | ((16 if same_upper else 0) << 8)
        words[1:4] = [output_hw[0]*output_hw[1], outputs, channels*kh*kw]
        words[10:13] = [height | width << 16, channels | kh << 16 | kw << 24,
                        sh | sw << 8 | pt << 16 | pl << 24]
        return struct.pack('<16I', *words)

    def test_padded_conv_uses_real_input_coordinates(self):
        descriptor = self.conv(3, 3, 2, 3, (3, 3), (1, 1), (1, 1), (3, 3))
        # Four corners see4 cells, four edges6 and the center9:49 valid
        # spatial pairs, each with2 input and3 output channels.
        self.assertEqual(descriptor_mac_counts(descriptor),
                         [dict(nominal_macs=486, useful_macs=294)])

    def test_strided_padding_and_same_upper_asymmetry_have_distinct_counts(self):
        symmetric = self.conv(4, 5, 2, 5, (3, 3), (2, 2), (1, 1), (2, 3))
        asymmetric = self.conv(4, 6, 2, 5, (3, 3), (2, 2), (0, 0), (2, 3), True)
        rectangular = self.conv(2, 5, 3, 7, (2, 3), (1, 2), (0, 1), (2, 3), True)
        # Symmetric windows contain4,6,4 /6,9,6 cells; SAME_UPPER
        # windows contain9,9,6 /6,6,4 cells.
        self.assertEqual(descriptor_mac_counts(symmetric+asymmetric+rectangular), [
            dict(nominal_macs=540, useful_macs=350),
            dict(nominal_macs=540, useful_macs=400),
            dict(nominal_macs=756, useful_macs=441)])

    def test_unpadded_conv_and_fc_ignore_physical_tail_alignment(self):
        convolution = self.conv(5, 6, 1, 2, (3, 2), (2, 2), (0, 0), (2, 3))
        fc, pool = [0]*16, [0]*16
        fc[:4] = [1, 3, 5, 7]
        fc[10:13] = [8, 8, 8]  # Physical strides do not change logical MACs.
        pool[:4] = [3, 4, 4, 8]
        self.assertEqual(descriptor_mac_counts(convolution+struct.pack('<16I', *fc)+
                                               struct.pack('<16I', *pool)), [
            dict(nominal_macs=72, useful_macs=72),
            dict(nominal_macs=105, useful_macs=105),
            dict(nominal_macs=0, useful_macs=0)])


if __name__ == '__main__':
    unittest.main(verbosity=2)
