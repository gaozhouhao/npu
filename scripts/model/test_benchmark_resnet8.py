#!/usr/bin/env python3
"""Regression checks for benchmark measurements and comparison validation."""

from pathlib import Path
import tempfile
import unittest

from benchmark_resnet8 import comparison, parse_perf


LOG = """DDR_READ_LATENCY_CYCLES,20
PERF_LAYER,index=0,opcode=2,cycles=100,executor=90,pool=0,ar=2,read_beats=8,aw=1,write_beats=4
PERF_TOTAL,cycles=110,executor=90,pool=0,ar=3,read_beats=16,aw=1,write_beats=4,written_bytes=16
PERF_COUNTER_CHECK,PASS
RESNET8 NPU FINISHED: top1=0 cycles=111 reads=16 writes=4 busy=0 acc00=0
"""


class PerformanceParsingTest(unittest.TestCase):
    def parse(self, text, latency=20):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "simulation.log"
            log.write_text(text)
            return parse_perf(log, 1, latency)

    def test_external_axi64_reads_and_axi32_strobes(self):
        total, layers = self.parse(LOG)
        self.assertEqual(total["read_bytes"], 128)
        self.assertEqual(total["write_bytes"], 16)
        self.assertEqual(total["testbench_cycles"], 111)
        self.assertEqual(total["total_cycles"], 110)
        self.assertEqual(total["read_bytes_outside_layers"], 64)
        self.assertEqual(total["cycles_outside_layers"], 10)
        self.assertEqual(layers[0]["read_bytes"], 64)

    def test_rejects_latency_mismatch(self):
        with self.assertRaisesRegex(ValueError, "latency mismatch"):
            self.parse(LOG, latency=0)

    def test_rejects_partial_write_strobes(self):
        with self.assertRaisesRegex(ValueError, "Partial write strobes"):
            self.parse(LOG.replace("written_bytes=16", "written_bytes=15"))

    def test_rejects_missing_layer(self):
        text = "\n".join(line for line in LOG.splitlines() if not line.startswith("PERF_LAYER,"))
        with self.assertRaisesRegex(ValueError, "Incomplete layer"):
            self.parse(text)

    def test_rejects_duplicate_layer(self):
        with self.assertRaisesRegex(ValueError, "Duplicate layer"):
            self.parse(LOG + LOG.splitlines()[1] + "\n")

    def test_rejects_unfinished_simulation(self):
        text = "\n".join(line for line in LOG.splitlines() if "NPU FINISHED" not in line)
        with self.assertRaisesRegex(ValueError, "completed inference"):
            self.parse(text)

    def test_rejects_disagreeing_axi_monitor(self):
        with self.assertRaisesRegex(ValueError, "beat counts differ"):
            self.parse(LOG.replace("reads=16", "reads=15"))

    def test_identical_cycles_report_zero_gain(self):
        summary, _ = self.parse(LOG)
        run = dict(summary=summary, correctness=dict(full_ddr_sha256="same"))
        result = comparison(run, run)
        self.assertEqual(result["speedup"], 1.0)
        self.assertEqual(result["cycle_reduction_pct"], 0.0)
        self.assertEqual(result["read_bytes_saved"], 0)

    def test_rejects_different_ddr(self):
        summary, _ = self.parse(LOG)
        before = dict(summary=summary, correctness=dict(full_ddr_sha256="before"))
        after = dict(summary=summary, correctness=dict(full_ddr_sha256="after"))
        with self.assertRaisesRegex(ValueError, "different DDR"):
            comparison(before, after)


if __name__ == "__main__":
    unittest.main()
