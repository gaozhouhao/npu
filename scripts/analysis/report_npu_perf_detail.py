#!/usr/bin/env python3
"""Extended frequency-independent NPU performance analysis."""

import csv
import json
from pathlib import Path

BASE = Path("build/resnet8_perf")
LOG = BASE / "perf.log"
CSV_PATH = BASE / "per_layer.csv"
SUMMARY_PATH = BASE / "summary.json"

PE_COUNT = 16


def parse_line(line):
    fields = line.strip().split(",")
    if not fields:
        return None, None

    kind = fields[0]

    if not kind.startswith("PERF_"):
        return None, None

    result = {}

    for part in fields[1:]:
        if "=" not in part:
            continue

        key, value = part.split("=", 1)
        result[key] = int(value)

    return kind, result


def percentage(num, den):
    return 100.0 * num / den if den else 0.0


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def load_detail():
    layers = {}
    total = None
    checks = set()

    for line in LOG.read_text().splitlines():
        kind, rec = parse_line(line)

        if kind is None:
            continue

        if kind == "PERF_DETAIL_LAYER":
            index = rec.pop("index")
            require(
                index not in layers,
                f"Duplicate detailed layer {index}"
            )
            layers[index] = rec

        elif kind == "PERF_DETAIL_TOTAL":
            total = rec

        elif kind.endswith("_CHECK"):
            checks.add(line.strip())

    for expected in (
        "PERF_COUNTER_CHECK,PASS",
        "PERF_COMPUTE_CHECK,PASS",
        "PERF_MEMORY_CHECK,PASS",
        "PERF_DETAIL_CHECK,PASS",
    ):
        require(expected in checks, f"Missing {expected}")

    require(total is not None, "Missing detailed totals")

    return layers, total


def main():
    with CSV_PATH.open(newline="") as f:
        original = list(csv.DictReader(f))

    summary = json.loads(SUMMARY_PATH.read_text())
    details, totals = load_detail()

    require(len(original) == 14, "Expected 14 layers")
    require(len(details) == 14, "Expected 14 detailed records")

    enhanced = []

    for entry in original:
        row = dict(entry)
        idx = int(row["layer"])
        extra = details[idx]

        cycles = int(row["cycles"])
        useful = int(row["useful_mac"])
        executed = int(row["executed_mac"])
        core = int(row["core_cycles"])
        dma = int(row["dma_cycles"])
        overlap = int(row["overlap_cycles"])

        core_only = extra["core_only"]
        dma_only = extra["dma_only"]

        require(
            core_only + overlap == core,
            f"Layer {idx}: core partition mismatch"
        )

        require(
            dma_only + overlap == dma,
            f"Layer {idx}: DMA partition mismatch"
        )

        neither = cycles - (
            core_only + dma_only + overlap
        )

        require(
            neither >= 0,
            f"Layer {idx}: invalid activity classification"
        )

        row.update(extra)

        row.update({
            "peak_mac_per_cycle": PE_COUNT,
            "executed_mac_per_cycle": (
                executed / cycles if cycles else 0
            ),
            "useful_mac_per_cycle": (
                useful / cycles if cycles else 0
            ),
            "layer_peak_efficiency_pct": percentage(
                useful, PE_COUNT * cycles
            ),
            "core_peak_efficiency_pct": percentage(
                useful, PE_COUNT * core
            ),
            "core_only_cycles": core_only,
            "dma_only_cycles": dma_only,
            "core_dma_cycles": overlap,
            "neither_cycles": neither,
            "axi_read_bus_util_pct": percentage(
                extra["axi_r"], cycles
            ),
            "dma_core_overlap_pct": percentage(
                overlap, core
            ),
            "useful_over_executed_pct": percentage(
                useful, executed
            ),
            "padding_or_tail_mac": executed - useful,
        })

        enhanced.append(row)

    # Global activity partition, independent of model shape.
    tcycles = int(summary["total_cycles"])
    core = int(summary["core_cycles"])
    dma = int(summary["dma_busy_cycles"])
    overlap = int(summary["overlap_cycles"])

    core_only = totals["core_only"]
    dma_only = totals["dma_only"]

    require(
        core_only + overlap == core,
        "Global core partition mismatch"
    )
    require(
        dma_only + overlap == dma,
        "Global DMA partition mismatch"
    )

    neither = tcycles - (
        core_only + dma_only + overlap
    )

    require(neither >= 0, "Invalid global partition")

    result = dict(summary)

    result.update({
        "theoretical_peak_mac_per_cycle": PE_COUNT,
        "effective_mac_per_cycle": (
            summary["useful_mac"] / tcycles
        ),
        "executed_mac_per_cycle": (
            summary["executed_mac"] / tcycles
        ),
        "effective_peak_pct": percentage(
            summary["useful_mac"], PE_COUNT * tcycles
        ),
        "core_only_cycles": core_only,
        "dma_only_cycles": dma_only,
        "core_dma_cycles": overlap,
        "neither_cycles": neither,
        "axi_read_transfer_util_pct": percentage(
            totals["axi_r"], tcycles
        ),
        "axi_read_no_fire_cycles": totals["axi_r_no_fire"],
        "axi_first_wait_cycles": totals["axi_first_wait"],
        "axi_read_bytes": totals["axi_r"] * 8,  # External AXI64 read beats.
        "a_load_accept_count": totals["a_load_accept"],
        "b_load_accept_count": totals["b_load_accept"],
        "a_sram_write_cycles": totals["a_sram_write"],
        "b_sram_write_cycles": totals["b_sram_write"],
        "c_sram_read_cycles": totals["c_sram_read"],
        "psum_busy_cycles": totals["psum_busy"],
        "writeback_busy_cycles": totals["writeback_busy"],
        "param_busy_cycles": totals["param_busy"],
        "a_compute_wait_cycles": totals["a_compute_wait"],
        "b_compute_wait_cycles": totals["b_compute_wait"],
        "a_load_wait_cycles": totals["a_load_wait"],
        "b_load_wait_cycles": totals["b_load_wait"],
    })

    output_csv = BASE / "performance_detailed.csv"
    output_json = BASE / "performance_detailed.json"

    with output_csv.open("w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=list(enhanced[0])
        )
        writer.writeheader()
        writer.writerows(enhanced)

    output_json.write_text(
        json.dumps(result, indent=2) + "\n"
    )

    print("\nNPU DETAILED PERFORMANCE")
    print("=" * 72)

    print(
        f"Peak: {PE_COUNT} MAC/cycle\n"
        f"Effective: {result['effective_mac_per_cycle']:.4f} "
        "useful MAC/cycle\n"
        f"Peak efficiency: {result['effective_peak_pct']:.2f}%"
    )

    print("\nGLOBAL CYCLE CLASSIFICATION")
    print("-" * 72)

    for key in (
        "core_only_cycles",
        "dma_only_cycles",
        "core_dma_cycles",
        "neither_cycles",
    ):
        value = result[key]
        print(
            f"{key:<30s} {value:>12d} "
            f"{percentage(value, tcycles):>7.2f}%"
        )

    print("\nPER-LAYER PEAK-NORMALIZED PERFORMANCE")
    print("-" * 72)

    for row in enhanced:
        if int(row["useful_mac"]) == 0:
            continue

        print(
            f"Layer {int(row['layer']):>2d} "
            f"{row['opcode']:<6s} "
            f"Layer={row['layer_peak_efficiency_pct']:6.2f}% "
            f"Core={row['core_peak_efficiency_pct']:6.2f}% "
            f"ReadBus={row['axi_read_bus_util_pct']:6.2f}% "
            f"DMAOverlap={row['dma_core_overlap_pct']:6.2f}%"
        )

    print("\nAXI AND BUFFER EVENTS")
    print("-" * 72)

    for key in (
        "axi_read_transfer_util_pct",
        "axi_read_no_fire_cycles",
        "axi_first_wait_cycles",
        "a_load_accept_count",
        "b_load_accept_count",
        "a_sram_write_cycles",
        "b_sram_write_cycles",
        "c_sram_read_cycles",
        "psum_busy_cycles",
        "writeback_busy_cycles",
        "param_busy_cycles",
        "a_compute_wait_cycles",
        "b_compute_wait_cycles",
        "a_load_wait_cycles",
        "b_load_wait_cycles",
    ):
        print(f"{key:<36s}: {result[key]}")

    print("\nPERFORMANCE DETAIL REPORT PASS")
    print("CSV :", output_csv)
    print("JSON:", output_json)


if __name__ == "__main__":
    main()
