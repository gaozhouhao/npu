
#!/usr/bin/env python3
"""Generate frequency-independent ResNet-8 NPU performance report.

Inputs:
  build/resnet8_perf/perf.log
  build/resnet8_perf/model/manifest.json
  build/resnet8_perf/model/descriptors.bin

Outputs:
  build/resnet8_perf/per_layer.csv
  build/resnet8_perf/summary.json

Useful MAC excludes convolution padding and padded matrix lanes.
"""

import argparse
import csv
import json
import struct
from pathlib import Path


EXEC_OPS = {"CONV", "FC", "ADD", "GLOBAL_AVG"}


def parse_record(line):
    line = line.strip()
    if not line.startswith("PERF_"):
        return None, None

    parts = line.split(",")
    name = parts[0]
    result = {}

    for item in parts[1:]:
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        result[key] = int(value)

    return name, result


def read_log(path):
    layers = {}
    compute = {}
    memory = {}
    totals = {}

    for line in path.read_text().splitlines():
        name, rec = parse_record(line)

        if name == "PERF_LAYER":
            layers[rec["index"]] = rec
        elif name == "PERF_COMPUTE_LAYER":
            compute[rec["index"]] = rec
        elif name == "PERF_MEMORY_LAYER":
            memory[rec["index"]] = rec
        elif name in (
            "PERF_TOTAL",
            "PERF_COMPUTE_TOTAL",
            "PERF_MEMORY_TOTAL",
        ):
            totals[name] = rec

    if len(layers) != 14:
        raise ValueError(
            f"Expected 14 layer records, got {len(layers)}"
        )

    if set(layers) != set(compute) or set(layers) != set(memory):
        raise ValueError("Layer indices differ between monitors")

    if len(totals) != 3:
        raise ValueError("Missing performance totals")

    return layers, compute, memory, totals


def conv_macs(layer, desc):
    output_shape = layer["shape"]
    _, hout, wout, cout = output_shape

    k = desc[3]

    sa = desc[10]
    sb = desc[11]
    sc = desc[12]

    hin = sa & 0xffff
    win = (sa >> 16) & 0xffff

    cin = sb & 0xffff
    kh = (sb >> 16) & 0xff
    kw = (sb >> 24) & 0xff

    sh = sc & 0xff
    sw = (sc >> 8) & 0xff
    pt = (sc >> 16) & 0xff
    pl = (sc >> 24) & 0xff

    if k != cin * kh * kw:
        raise ValueError("Conv K geometry mismatch")

    dense_mac = hout * wout * cout * k

    useful_kernel_positions = 0

    for oy in range(hout):
        for ox in range(wout):
            for ky in range(kh):
                iy = oy * sh + ky - pt

                if iy < 0 or iy >= hin:
                    continue

                for kx in range(kw):
                    ix = ox * sw + kx - pl

                    if 0 <= ix < win:
                        useful_kernel_positions += 1

    useful_mac = useful_kernel_positions * cin * cout

    return useful_mac, dense_mac


def get_work(layer, desc):
    opcode = layer["opcode"]

    if opcode == "CONV":
        return conv_macs(layer, desc)

    if opcode == "FC":
        m = 1
        n = layer["shape"][-1]
        k = desc[3]

        macs = m * n * k
        return macs, macs

    return 0, 0


def percent(numer, denom):
    return round(
        100.0 * numer / denom, 4
    ) if denom else 0.0


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--dir",
        type=Path,
        default=Path("build/resnet8_perf"),
    )

    args = parser.parse_args()
    base = args.dir

    manifest = json.loads(
        (base / "model/manifest.json").read_text()
    )

    descriptor_data = (
        base / "model/descriptors.bin"
    ).read_bytes()

    layers, compute, memory, totals = read_log(
        base / "perf.log"
    )

    operations = [
        item for item in manifest["layers"]
        if item["opcode"] in EXEC_OPS
    ]

    if len(operations) != 14:
        raise ValueError(
            f"Expected 14 operations, got {len(operations)}"
        )

    if len(descriptor_data) != 14 * 64:
        raise ValueError("Unexpected descriptor size")

    rows = []

    for index, layer in enumerate(operations):
        desc = struct.unpack_from(
            "<16I", descriptor_data, index * 64
        )

        work, dense = get_work(layer, desc)

        pc = layers[index]
        cc = compute[index]
        mm = memory[index]

        executed = cc["mac"]
        core = mm["core"]
        cycles = pc["cycles"]

        if executed < work:
            raise ValueError(
                f"Layer {index}: hardware MAC < useful MAC"
            )

        if cc["tile_starts"] != cc["tile_dones"]:
            raise ValueError(
                f"Layer {index}: tile mismatch"
            )

        if executed > 16 * core:
            raise ValueError(
                f"Layer {index}: MAC capacity exceeded"
            )

        rows.append({
            "layer": index,
            "opcode": layer["opcode"],
            "cycles": cycles,
            "core_cycles": core,
            "dma_cycles": mm["dma"],
            "overlap_cycles": mm["overlap"],
            "executed_mac": executed,
            "dense_mac": dense,
            "useful_mac": work,
            "useful_over_executed_pct": percent(work, executed),
            "pe_core_occupancy_pct": percent(
                executed, 16 * core
            ),
            "useful_pe_core_pct": percent(
                work, 16 * core
            ),
            "read_bytes": pc["read_beats"] * 4,
            "write_bytes": pc["write_beats"] * 4,
            "tile_count": cc["tile_dones"],
        })

    total = totals["PERF_TOTAL"]
    ct = totals["PERF_COMPUTE_TOTAL"]
    mt = totals["PERF_MEMORY_TOTAL"]

    executed_sum = sum(r["executed_mac"] for r in rows)
    useful_sum = sum(r["useful_mac"] for r in rows)

    if executed_sum != ct["mac"]:
        raise ValueError("Global MAC sum mismatch")

    if sum(r["core_cycles"] for r in rows) != mt["core"]:
        raise ValueError("Global core cycles mismatch")

    if sum(r["tile_count"] for r in rows) != ct["tile_dones"]:
        raise ValueError("Global tile count mismatch")

    read_bytes = total["read_beats"] * 4
    write_bytes = total["written_bytes"]

    summary = {
        "total_cycles": total["cycles"],
        "core_cycles": mt["core"],
        "dma_busy_cycles": mt["dma"],
        "overlap_cycles": mt["overlap"],
        "executed_mac": ct["mac"],
        "useful_mac": useful_sum,
        "tiles": ct["tile_dones"],
        "pe_count": 16,
        "core_pe_occupancy_pct": percent(
            ct["mac"], 16 * mt["core"]
        ),
        "e2e_pe_occupancy_pct": percent(
            ct["mac"], 16 * total["cycles"]
        ),
        "useful_compute_ratio_pct": percent(
            useful_sum, ct["mac"]
        ),
        "useful_e2e_pe_util_pct": percent(
            useful_sum, 16 * total["cycles"]
        ),
        "read_bytes": read_bytes,
        "write_bytes": write_bytes,
        "external_bytes": read_bytes + write_bytes,
        "arithmetic_intensity_mac_per_byte": (
            useful_sum / (read_bytes + write_bytes)
        ),
        "core_dma_overlap_pct": percent(
            mt["overlap"], mt["core"]
        ),
        "a_compute_wait": mt["a_compute_wait"],
        "b_compute_wait": mt["b_compute_wait"],
        "a_load_wait": mt["a_load_wait"],
        "b_load_wait": mt["b_load_wait"],
    }

    with (base / "per_layer.csv").open(
        "w", newline=""
    ) as f:
        writer = csv.DictWriter(
            f, fieldnames=list(rows[0])
        )
        writer.writeheader()
        writer.writerows(rows)

    (base / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )

    print("\nNPU PERFORMANCE SUMMARY")
    print("=" * 60)

    for name, value in summary.items():
        print(f"{name:38s}: {value}")

    print("\nPER-LAYER TABLE")
    print("=" * 90)

    for row in rows:
        print(
            f"{row['layer']:2d} "
            f"{row['opcode']:<10s} "
            f"cycles={row['cycles']:>7d} "
            f"mac={row['executed_mac']:>9d} "
            f"useful={row['useful_mac']:>9d} "
            f"core_util={row['pe_core_occupancy_pct']:>6.2f}%"
        )

    print("\nPERFORMANCE REPORT PASS")
    print("Saved:", base / "per_layer.csv")
    print("Saved:", base / "summary.json")


if __name__ == "__main__":
    main()
