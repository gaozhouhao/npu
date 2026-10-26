#!/usr/bin/env python3
"""Validate Burst matrix provenance and immutable-snapshot boundaries."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_resnet50_burst_matrix as matrix
import test_serial_prepare as fixture


class BurstMatrixPreparationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture.SerialPreparationTest.setUpClass()
        cls.base = fixture.SerialPreparationTest.base

    @classmethod
    def tearDownClass(cls):
        fixture.SerialPreparationTest.tearDownClass()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='npu-burst-matrix-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.output = self.directory / 'matrix'

    def test_matched_variants_have_exact_git_burst_and_original_control(self):
        before = {str(p.relative_to(self.base)): p.read_bytes()
                  for p in self.base.rglob('*') if p.is_file()}
        result = matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output)
        burst = matrix.git_bytes(matrix.ROOT, matrix.BURST_COMMIT, matrix.BURST_PATH)
        for variant, banks, schedule in (
                ('burst_serial', 1, matrix.serial.SERIAL_COMMIT),
                ('burst_double', 2, matrix.serial.CNN_COMMIT)):
            metadata = json.loads((self.output / variant / 'source.json').read_text())
            self.assertEqual((self.output / variant / 'source' / matrix.BURST_PATH).read_bytes(), burst)
            self.assertEqual(metadata['measurement_parameters']['A_BUFFER_COUNT'], banks)
            self.assertEqual(metadata['measurement_parameters']['B_BUFFER_COUNT'], banks)
            self.assertEqual(metadata['schedule_source_ref'], schedule)
            self.assertEqual(metadata['cnn_functional_source_ref'], matrix.serial.CNN_COMMIT)
            self.assertEqual(metadata['burst_loader_source_ref'], matrix.BURST_COMMIT)
            self.assertTrue(metadata['mixed_source'])
            self.assertFalse(metadata['measurement_parameters']['A_reuse'])
            self.assertEqual(metadata['source_set_sha256'],
                             result['variants'][variant]['source_set_sha256'])
            self.assertTrue((self.output / variant / 'source' / matrix.GUARD_PATH).read_bytes().startswith(
                ('`define BURST_PREFETCH_EXPECT_BANKS %d\n' % banks).encode()))
        for name in matrix.SCHEDULE_PATHS:
            self.assertEqual((self.output / 'burst_double/source' / name).read_bytes(),
                             (self.base / 'source' / name).read_bytes())
        self.assertEqual((self.output / 'burst_serial/source/rtl/core/tile_scheduler.sv').read_bytes(),
                         matrix.git_bytes(matrix.ROOT, matrix.serial.SERIAL_COMMIT,
                                          'rtl/core/tile_scheduler.sv'))
        after = {str(p.relative_to(self.base)): p.read_bytes()
                 for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_existing_destination_is_preserved(self):
        self.output.mkdir()
        (self.output / 'keep').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output)
        self.assertEqual((self.output / 'keep').read_bytes(), b'keep')

    def test_output_symlink_is_rejected(self):
        target = self.directory / 'not-created'
        self.output.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output)
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())

    def test_changed_burst_original_is_rejected_before_writing(self):
        original_git_bytes = matrix.git_bytes

        def changed_burst(repo, commit, name):
            data = original_git_bytes(repo, commit, name)
            return data + b'\n' if commit == matrix.BURST_COMMIT else data

        with mock.patch.object(matrix, 'git_bytes', side_effect=changed_burst):
            with self.assertRaisesRegex(ValueError, 'Burst loader SHA256 differs'):
                matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output)
        self.assertFalse(self.output.exists())

    def test_changed_base_is_rejected(self):
        base = self.directory / 'base'
        shutil.copytree(self.base, base)
        path = base / 'source/rtl/core/gemm_core.sv'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'frozen source SHA256 differs'):
            matrix.prepare(matrix.ROOT, base / 'source.json', self.output)
        self.assertFalse(self.output.exists())

    def test_modified_observation_guard_is_rejected(self):
        guard = self.directory / 'guard.sv'
        guard.write_bytes((matrix.serial.RECIPES / 'burst_prefetch_guard.sv').read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'Burst observation guard SHA256 differs'):
            matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output, guard)
        self.assertFalse(self.output.exists())

    def test_partial_output_is_cleaned_after_write_failure(self):
        def fail(output, files):
            (output / 'partial').write_bytes(b'incomplete')
            raise OSError('injected matrix write failure')

        with mock.patch.object(matrix.serial, 'write_outputs', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'injected matrix write failure'):
                matrix.prepare(matrix.ROOT, self.base / 'source.json', self.output)
        self.assertFalse(self.output.exists())
        self.assertTrue((self.base / 'source.json').exists())


if __name__ == '__main__':
    unittest.main()
