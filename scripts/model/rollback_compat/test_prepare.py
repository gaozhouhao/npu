#!/usr/bin/env python3
"""Guard checks for historical source preparation; no RTL simulation needed."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_resnet50_rollback as prep


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.outputs, cls.manifest = prep.assemble(prep.ROOT, prep.RECIPE_DIR, prep.VARIANTS)

    def test_exact_recipe_rtl_files_and_checksums(self):
        for variant,recipe in self.manifest['variants'].items():
            compiled = {}
            for name,data in self.outputs.items():
                if name.startswith(variant+'/source/rtl/') and name.endswith('.sv'):
                    compiled[name[len(variant+'/source/'):]] = prep.digest(data)
                elif name.startswith('compat/') and name.endswith('.sv'):
                    compiled[name] = prep.digest(data)
            self.assertEqual(compiled, recipe['compiled_rtl_sha256'])
            for path in ('rtl/core/tile_scheduler.sv', 'rtl/dma/conv_patch_loader.sv',
                         'rtl/dma/gemm_read_path.sv', 'rtl/dma/strided_read_engine.sv'):
                item = next(f for f in recipe['files'] if f['path'] == path)
                self.assertEqual(item['classification'], 'historical_unchanged')
                self.assertEqual(item['original_sha256'], item['compiled_sha256'])

    def test_existing_output_is_never_changed(self):
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'existing'; output.mkdir()
            sentinel=output/'sentinel'; sentinel.write_text('keep')
            with self.assertRaisesRegex(ValueError, 'already exists'):
                prep.prepare(prep.ROOT, output)
            self.assertEqual(sentinel.read_text(), 'keep')
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_original_hash_mismatch_creates_no_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'new'
            with mock.patch.object(prep, 'git_bytes', return_value=b'changed original\n'):
                with self.assertRaisesRegex(ValueError, 'Original Git SHA256 differs'):
                    prep.prepare(prep.ROOT, output, ('legacy00',))
            self.assertFalse(output.exists())

    def test_patch_hash_mismatch_creates_no_output(self):
        original_reader=prep.recipe_bytes
        def corrupted(directory, name):
            data=original_reader(directory,name)
            return data+b'changed\n' if name.endswith('.patch') else data
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'new'
            with mock.patch.object(prep, 'recipe_bytes', side_effect=corrupted):
                with self.assertRaisesRegex(ValueError, 'patch SHA256 differs'):
                    prep.prepare(prep.ROOT, output, ('legacy00',))
            self.assertFalse(output.exists())

    def test_unified_patch_context_and_counts_are_exact(self):
        original=b'alpha\nbeta\ngamma\n'
        patch=b'--- a/file.sv\n+++ b/file.sv\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+delta\n gamma\n'
        self.assertEqual(prep.apply_patch(original,patch,'file.sv'),b'alpha\ndelta\ngamma\n')
        for bad in (patch.replace(b' alpha\n',b' wrong\n'),
                    patch.replace(b'@@ -1,3',b'@@ -1,2'),
                    patch.replace(b'--- a/file.sv',b'--- a/other.sv')):
            with self.assertRaises(ValueError):
                prep.apply_patch(original,bad,'file.sv')

    def test_paths_reject_escape_and_absolute_targets(self):
        for path in ('../file', '/tmp/file', 'rtl/../file', 'rtl//file', './file'):
            with self.assertRaises(ValueError):
                prep.relative_path(path)

    def test_fresh_output_contains_all_expected_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'fresh'
            with mock.patch.object(prep, 'assemble', return_value=(self.outputs,self.manifest)):
                prep.prepare(prep.ROOT,output)
            actual={str(p.relative_to(output)):p.read_bytes() for p in output.rglob('*') if p.is_file()}
            self.assertEqual(actual,self.outputs)


if __name__=='__main__':
    unittest.main(verbosity=2)
