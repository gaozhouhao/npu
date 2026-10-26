#!/usr/bin/env python3
"""Guard the provenance and no-overwrite boundary of serial source preparation."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_resnet50_rollback as rollback
import prepare_resnet50_serial_baseline as serial


class SerialPreparationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix='npu-serial-fixture-')
        cls.base = Path(cls.shared.name) / 'legacy00'
        source = cls.base / 'source'
        source.mkdir(parents=True)
        outputs, _ = rollback.assemble(serial.ROOT, serial.RECIPES, ('legacy00',))
        recipe = json.loads((serial.RECIPES / 'legacy00.json').read_text())
        paths = sorted(p for p in recipe['compiled_rtl_sha256'] if p.startswith('rtl/'))
        paths += sorted(p for p in recipe['compiled_rtl_sha256'] if p.startswith('compat/'))
        hashes = {}
        for name in paths:
            key = 'legacy00/source/' + name if name.startswith('rtl/') else name
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(outputs[key])
            hashes[name] = serial.digest(outputs[key])
        for name in serial.COMMON_TESTBENCHES:
            data = serial.git_bytes(serial.ROOT, serial.COMMON_COMMIT, name)
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            hashes[name] = serial.digest(data)
        listing = ('\n'.join(paths) + '\n').encode()
        (source / 'rtl.f').write_bytes(listing)
        hashes['sim/filelists/rtl.f'] = serial.digest(listing)
        metadata = dict(source_ref=serial.CNN_COMMIT, resolved_commit=serial.CNN_COMMIT,
            variant='legacy00', functional_compatibility=True, source_sha256=hashes,
            source_set_sha256=serial.digest(json.dumps(hashes, sort_keys=True).encode()),
            common_external_read_bits=64, legacy_internal_operand_bits=32,
            runner_sha256=serial.digest((serial.ROOT / 'scripts/model/run_graph_model.py').read_bytes()),
            makefile_sha256=serial.digest((serial.ROOT / 'Makefile').read_bytes()),
            rollback_runner_sha256=serial.digest((serial.ROOT / 'scripts/model/benchmark_resnet50_rollback.py').read_bytes()))
        (cls.base / 'source.json').write_bytes(serial.json_bytes(metadata))

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='npu-serial-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.output = self.directory / 'serial'

    def clone(self):
        base = self.directory / 'base'
        shutil.copytree(self.base, base)
        return base

    def test_exact_pinned_result_and_base_unchanged(self):
        before = {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        result = serial.prepare(serial.ROOT, self.base / 'source.json', self.output)
        self.assertEqual(result['source_set_sha256'], serial.FINAL_SOURCE_SET_SHA256)
        self.assertEqual((self.output / 'source/rtl/core/tile_scheduler.sv').read_bytes(),
                         serial.git_bytes(serial.ROOT, serial.SERIAL_COMMIT, 'rtl/core/tile_scheduler.sv'))
        self.assertEqual(result['measurement_parameters']['A_BUFFER_COUNT'], 1)
        self.assertEqual(result['measurement_parameters']['B_BUFFER_COUNT'], 1)
        self.assertEqual(len(result['changes']), 3)
        after = {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_existing_directory_is_preserved(self):
        self.output.mkdir()
        (self.output / 'keep').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            serial.prepare(serial.ROOT, self.base / 'source.json', self.output)
        self.assertEqual((self.output / 'keep').read_bytes(), b'keep')

    def test_dangling_output_symlink_is_rejected(self):
        target = self.directory / 'not-created'
        self.output.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            serial.prepare(serial.ROOT, self.base / 'source.json', self.output)
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())

    def test_destination_inside_base_is_rejected(self):
        base = self.clone()
        with self.assertRaisesRegex(ValueError, 'outside the base'):
            serial.prepare(serial.ROOT, base / 'source.json', base / 'new')
        self.assertFalse((base / 'new').exists())

    def test_changed_base_byte_is_rejected_before_output(self):
        base = self.clone()
        target = base / 'source/rtl/core/gemm_core.sv'
        target.write_bytes(target.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'frozen source SHA256 differs'):
            serial.prepare(serial.ROOT, base / 'source.json', self.output)
        self.assertFalse(self.output.exists())

    def test_self_consistent_modified_base_is_still_rejected(self):
        base = self.clone()
        name = 'rtl/core/gemm_core.sv'
        target = base / 'source' / name
        target.write_bytes(target.read_bytes() + b'\n')
        metadata = json.loads((base / 'source.json').read_text())
        metadata['source_sha256'][name] = serial.digest(target.read_bytes())
        metadata['source_set_sha256'] = serial.digest(json.dumps(metadata['source_sha256'], sort_keys=True).encode())
        (base / 'source.json').write_bytes(serial.json_bytes(metadata))
        with self.assertRaisesRegex(ValueError, 'validated legacy00 recipe'):
            serial.prepare(serial.ROOT, base / 'source.json', self.output)
        self.assertFalse(self.output.exists())

    def test_modified_guard_is_rejected_before_output(self):
        guard = self.directory / 'guard.sv'
        guard.write_bytes((serial.RECIPES / 'serial_schedule_guard.sv').read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'guard SHA256 differs'):
            serial.prepare(serial.ROOT, self.base / 'source.json', self.output, guard)
        self.assertFalse(self.output.exists())

    def test_serial_bridge_refuses_missing_context(self):
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            serial.bridge_executor(b'module gemm_executor; endmodule\n')

    def test_failed_write_removes_only_new_destination(self):
        def failing_write(output, files):
            (output / 'partial').write_bytes(b'incomplete')
            raise OSError('injected write failure')
        with mock.patch.object(serial, 'write_outputs', side_effect=failing_write):
            with self.assertRaisesRegex(OSError, 'injected write failure'):
                serial.prepare(serial.ROOT, self.base / 'source.json', self.output)
        self.assertFalse(self.output.exists())
        self.assertTrue((self.base / 'source.json').exists())


if __name__ == '__main__':
    unittest.main()
