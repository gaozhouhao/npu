#!/usr/bin/env python3
"""Check ablation scope, source identity, no-op behavior and fail-closed guards."""

import hashlib
from pathlib import Path
import tempfile
import unittest

from readpath_variants import FILES, REPLACEMENTS, ROOT, apply_variant


class ReadpathVariantTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="readpath-variant-")
        self.source = Path(self.temporary.name) / "source"
        for name in FILES:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())

    def tearDown(self):
        self.temporary.cleanup()

    def content(self):
        return dict((name, (self.source / name).read_bytes()) for name in FILES)

    def test_baseline_changes_only_three_files_and_keeps_native64_and_tag_match(self):
        sentinel = self.source / "untouched.txt"
        sentinel.write_text("preserve unrelated files\n")
        before = self.content()
        metadata = apply_variant(self.source, "baseline")
        self.assertEqual(metadata["changed_files"], list(FILES))
        self.assertEqual(metadata["native_operand_read_bits"], 64)
        self.assertTrue(all(not value for value in metadata["features"].values()))
        self.assertEqual(sentinel.read_text(), "preserve unrelated files\n")
        self.assertIn(".OPERAND_WORD_WIDTH(64)", (self.source / FILES[0]).read_text())
        scheduler = (self.source / FILES[2]).read_text()
        self.assertIn("(resident_b_n_q == compute_n_q)", scheduler)
        self.assertIn("(!b_stationary_q || !resident_b_valid_q)", scheduler)
        self.assertNotIn("((compute_state == CP_IDLE) && ready_valid_q)", scheduler)
        for name in FILES:
            self.assertEqual(metadata["original_sha256"][name], hashlib.sha256(before[name]).hexdigest())
            self.assertEqual(metadata["compiled_sha256"][name],
                             hashlib.sha256((self.source / name).read_bytes()).hexdigest())
        self.assertTrue(all(patch["unified_diff"].startswith("--- original/")
                            for patch in metadata["patches"]))

    def test_optimized_is_a_true_noop_including_mtime(self):
        before = self.content()
        mtimes = dict((name, (self.source / name).stat().st_mtime_ns) for name in FILES)
        metadata = apply_variant(self.source, "optimized")
        self.assertEqual(self.content(), before)
        self.assertEqual(metadata["patches"], [])
        self.assertEqual(metadata["changed_files"], [])
        self.assertEqual(metadata["original_sha256"], metadata["compiled_sha256"])
        self.assertTrue(all(metadata["features"].values()))
        self.assertEqual(mtimes, dict((name, (self.source / name).stat().st_mtime_ns) for name in FILES))

    def test_changed_last_file_rejects_before_any_first_file_write(self):
        path = self.source / FILES[-1]
        path.write_text(path.read_text().replace("!b_reuse_q;", "!b_reuse_q /* changed */;", 1))
        before = self.content()
        with self.assertRaisesRegex(ValueError, "anchor"):
            apply_variant(self.source, "baseline")
        self.assertEqual(self.content(), before)

    def test_duplicate_anchor_is_rejected(self):
        path = self.source / FILES[0]
        path.write_text(path.read_text() + REPLACEMENTS[FILES[0]][0][0])
        before = self.content()
        with self.assertRaisesRegex(ValueError, "got 2"):
            apply_variant(self.source, "baseline")
        self.assertEqual(self.content(), before)

    def test_reapplying_baseline_rejects_without_writes(self):
        apply_variant(self.source, "baseline")
        before = self.content()
        with self.assertRaisesRegex(ValueError, "anchor"):
            apply_variant(self.source, "baseline")
        self.assertEqual(self.content(), before)

    def test_native32_drift_is_rejected_before_writes(self):
        path = self.source / FILES[0]
        path.write_text(path.read_text().replace(".OPERAND_WORD_WIDTH(64)", ".OPERAND_WORD_WIDTH(32)", 1))
        before = self.content()
        with self.assertRaisesRegex(ValueError, "native64"):
            apply_variant(self.source, "baseline")
        self.assertEqual(self.content(), before)

    def test_invalid_variant_and_production_root_are_rejected(self):
        before = self.content()
        with self.assertRaisesRegex(ValueError, "variant"):
            apply_variant(self.source, "unknown")
        with self.assertRaisesRegex(ValueError, "isolated snapshot"):
            apply_variant(ROOT, "baseline")
        self.assertEqual(self.content(), before)

    def test_symlink_outside_snapshot_is_rejected(self):
        path = self.source / FILES[0]
        outside = Path(self.temporary.name) / "outside.sv"
        outside.write_bytes(path.read_bytes())
        before = outside.read_bytes()
        path.unlink()
        path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes snapshot"):
            apply_variant(self.source, "baseline")
        self.assertEqual(outside.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
