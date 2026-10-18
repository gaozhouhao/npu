#!/usr/bin/env python3
"""Descriptor-level dataflow optimization pass.

Runs after compile_resnet8_tflite.py.

The pass updates:
    descriptors.bin
    ddr.bin
    ddr.hex
    manifest.json

Hardware:
    4x4 systolic array
    K tile size = 256
    A/B double buffering
    A reuse for K=1
    Multi-K A reuse + PSUM
    B reuse for K=1

The cost model is an analytical estimate, not a
cycle-accurate hardware simulation.
"""

import argparse
import json
import math
import os
import struct
from pathlib import Path


OP_GEMM = 1
OP_CONV = 2
OP_AVG = 4
OP_ADD = 5

FLAG_MULTI_K_A_REUSE = 1 << 5
FLAG_B_STATIONARY = 1 << 6

ROWS = 4
COLS = 4
K_TILE_SIZE = 256

DESC_WORDS = 16
DESC_BYTES = DESC_WORDS * 4

SUPPORTED_MODES = ("a", "b", "auto")


def ceil_div(a, b):
    return (a + b - 1) // b


def read_descriptors(path):
    raw = path.read_bytes()

    if len(raw) % DESC_BYTES:
        raise ValueError(
            "Descriptor file size is not a multiple of 64"
        )

    descriptors = []

    for offset in range(0, len(raw), DESC_BYTES):
        values = list(
            struct.unpack_from(
                "<16I", raw, offset
            )
        )

        descriptors.append(values)

    return descriptors


def encode_descriptors(descriptors):
    return b"".join(
        struct.pack("<16I", *descriptor)
        for descriptor in descriptors
    )


def descriptor_opcode(descriptor):
    return descriptor[0] & 0xff


def descriptor_flags(descriptor):
    return (descriptor[0] >> 8) & 0xffffff


def set_descriptor_flags(descriptor, flags):
    opcode = descriptor_opcode(descriptor)

    descriptor[0] = (
        ((flags & 0xffffff) << 8) | opcode
    )


def estimate_k1_cost(
    m,
    n,
    k,
    bandwidth,
    a_overhead,
    b_overhead,
    a_overlap,
    b_overlap,
    conv_a_weight,
    is_conv,
):
    """Estimate operand-loading cost for K_tiles == 1.

    Assumptions:
      A-stationary:
        A loads = M_tiles
        B loads = M_tiles * N_tiles

      B-stationary:
        A loads = M_tiles * N_tiles
        B loads = N_tiles

    Each operand tile contains up to four INT8
    vectors of length K.

    The returned costs represent non-overlapped
    estimated loading cycles. They are proxies;
    compute and writeback costs common to both
    alternatives are excluded.
    """

    mt = ceil_div(m, ROWS)
    nt = ceil_div(n, COLS)

    if k <= 0 or mt <= 0 or nt <= 0:
        raise ValueError("Invalid GEMM dimensions")

    a_tile_bytes = ROWS * k
    b_tile_bytes = COLS * k

    a_load_cost = (
        a_tile_bytes / bandwidth + a_overhead
    )

    b_load_cost = (
        b_tile_bytes / bandwidth + b_overhead
    )

    # Conv activation loading includes patch
    # address generation and gather overhead.
    # This is a configurable approximation.
    if is_conv:
        a_load_cost *= conv_a_weight

    a_stationary_loads = {
        "a": mt,
        "b": mt * nt,
    }

    b_stationary_loads = {
        "a": mt * nt,
        "b": nt,
    }

    a_raw = (
        a_stationary_loads["a"] * a_load_cost
        + a_stationary_loads["b"] * b_load_cost
    )

    b_raw = (
        b_stationary_loads["a"] * a_load_cost
        + b_stationary_loads["b"] * b_load_cost
    )

    a_cost = a_raw * (1.0 - a_overlap)
    b_cost = b_raw * (1.0 - b_overlap)

    return {
        "m_tiles": mt,
        "n_tiles": nt,
        "k_tiles": 1,
        "a_tile_bytes": a_tile_bytes,
        "b_tile_bytes": b_tile_bytes,
        "a_stationary": {
            "a_loads": a_stationary_loads["a"],
            "b_loads": a_stationary_loads["b"],
            "operand_bytes": (
                a_stationary_loads["a"] * a_tile_bytes
                + a_stationary_loads["b"] * b_tile_bytes
            ),
            "estimated_exposed_cycles": round(
                a_cost, 2
            ),
        },
        "b_stationary": {
            "a_loads": b_stationary_loads["a"],
            "b_loads": b_stationary_loads["b"],
            "operand_bytes": (
                b_stationary_loads["a"] * a_tile_bytes
                + b_stationary_loads["b"] * b_tile_bytes
            ),
            "estimated_exposed_cycles": round(
                b_cost, 2
            ),
        },
    }


def select_policy(
    descriptor,
    preference,
    config,
):
    opcode = descriptor_opcode(descriptor)

    m = int(descriptor[1])
    n = int(descriptor[2])
    k = int(descriptor[3])

    mt = ceil_div(m, ROWS)
    nt = ceil_div(n, COLS)
    kt = ceil_div(k, K_TILE_SIZE)

    if min(m, n, k) <= 0:
        raise ValueError(
            f"Invalid GEMM geometry: M={m}, N={n}, K={k}"
        )

    # Preserve the existing multi-K path.
    # B-stationary hardware supports K_tiles=1.
    if kt > 1:
        if nt > 1:
            name = "N_BLOCKED_A_REUSE_PSUM"
            flag = FLAG_MULTI_K_A_REUSE
        else:
            name = "OUTPUT_STATIONARY"
            flag = 0

        return {
            "selected": name,
            "flag": flag,
            "reason": (
                "Multi-K uses existing A-reuse/PSUM path"
            ),
            "cost": {
                "m_tiles": mt,
                "n_tiles": nt,
                "k_tiles": kt,
            },
        }

    cost = estimate_k1_cost(
        m=m,
        n=n,
        k=k,
        bandwidth=config["bandwidth"],
        a_overhead=config["a_overhead"],
        b_overhead=config["b_overhead"],
        a_overlap=config["a_overlap"],
        b_overlap=config["b_overlap"],
        conv_a_weight=config["conv_a_weight"],
        is_conv=(opcode == OP_CONV),
    )

    a_cycles = cost[
        "a_stationary"
    ]["estimated_exposed_cycles"]

    b_cycles = cost[
        "b_stationary"
    ]["estimated_exposed_cycles"]

    if preference == "a":
        use_b = False
        reason = "Forced A mode"

    elif preference == "b":
        use_b = mt > 1

        reason = (
            "Forced B mode"
            if use_b
            else "Single M tile: no B reuse possible"
        )

    else:
        # B must offer a material estimated benefit.
        #
        # Example: margin=0.15 requires B's estimated
        # exposed loading cost to be at least 15%
        # lower than A's.
        threshold = a_cycles * (
            1.0 - config["b_margin"]
        )

        use_b = (
            mt > 1
            and b_cycles < threshold
        )

        reason = (
            "B estimated loading cost exceeds "
            "required improvement margin"
        )

        if use_b:
            reason = (
                "B estimated loading cost is lower "
                "by more than the required margin"
            )

    if use_b:
        name = "B_STATIONARY"
        flag = FLAG_B_STATIONARY
    elif nt > 1:
        name = "OUTPUT_STATIONARY_A_REUSE"
        flag = 0
    else:
        name = "OUTPUT_STATIONARY"
        flag = 0

    return {
        "selected": name,
        "flag": flag,
        "reason": reason,
        "cost": cost,
    }


def optimize(outdir, preference, config):
    manifest_path = outdir / "manifest.json"
    descriptor_path = outdir / "descriptors.bin"
    ddr_path = outdir / "ddr.bin"
    hex_path = outdir / "ddr.hex"

    manifest = json.loads(
        manifest_path.read_text(encoding="utf-8")
    )

    descriptors = read_descriptors(descriptor_path)

    expected_count = manifest["descriptor_count"]

    if len(descriptors) != expected_count:
        raise ValueError(
            "Manifest descriptor_count mismatch"
        )

    layer_desc_index = 0
    decisions = []

    for layer in manifest["layers"]:
        opcode_name = layer["opcode"]

        # RESHAPE and SOFTMAX bypass do not
        # consume hardware descriptors.
        if opcode_name in (
            "RESHAPE_ALIAS",
            "SOFTMAX_BYPASS_ARGMAX",
        ):
            continue

        if layer_desc_index >= len(descriptors):
            raise ValueError(
                "Layer/descriptor count mismatch"
            )

        descriptor = descriptors[layer_desc_index]
        opcode = descriptor_opcode(descriptor)

        if opcode_name in ("CONV", "FC"):
            expected_opcode = (
                OP_CONV
                if opcode_name == "CONV"
                else OP_GEMM
            )

            if opcode != expected_opcode:
                raise ValueError(
                    "Layer and descriptor opcode mismatch "
                    f"at index {layer_desc_index}"
                )

            decision = select_policy(
                descriptor,
                preference,
                config,
            )

            old_flags = descriptor_flags(descriptor)

            new_flags = (
                old_flags
                & ~(
                    FLAG_MULTI_K_A_REUSE
                    | FLAG_B_STATIONARY
                )
            ) | decision["flag"]

            set_descriptor_flags(
                descriptor, new_flags
            )

            layer["flags"] = new_flags
            layer["dataflow"] = decision["selected"]
            layer["dataflow_cost"] = decision["cost"]
            layer["dataflow_reason"] = decision["reason"]

            decisions.append({
                "descriptor_index": layer_desc_index,
                "opcode": opcode_name,
                "m": descriptor[1],
                "n": descriptor[2],
                "k": descriptor[3],
                **decision,
            })

        elif opcode_name == "ADD":
            if opcode != OP_ADD:
                raise ValueError("ADD descriptor mismatch")

        elif opcode_name == "GLOBAL_AVG":
            if opcode != OP_AVG:
                raise ValueError("AVG descriptor mismatch")

        else:
            raise ValueError(
                f"Unknown compiled layer: {opcode_name}"
            )

        layer_desc_index += 1

    if layer_desc_index != len(descriptors):
        raise ValueError(
            "Not all descriptors were consumed"
        )

    # Re-encode all descriptors.
    new_descbytes = encode_descriptors(
        descriptors
    )

    ddr = bytearray(ddr_path.read_bytes())

    daddr = int(manifest["descriptor_addr"])
    dend = daddr + len(new_descbytes)

    if dend > len(ddr):
        raise ValueError(
            "Descriptor address outside DDR image"
        )

    # Ensure the separate descriptor artifact
    # and the DDR-resident copy are synchronized.
    ddr[daddr:dend] = new_descbytes

    # Perform all validation before writing.
    manifest["dataflow_preference"] = preference
    manifest["cost_model"] = {
        "version": 1,
        "description": (
            "Analytical non-overlapped operand "
            "loading cost model"
        ),
        "parameters": config,
        "decisions": decisions,
    }

    descriptor_path.write_bytes(new_descbytes)
    ddr_path.write_bytes(ddr)

    hex_path.write_text(
        "".join(
            f"{int.from_bytes(ddr[i:i+4], 'little'):08x}\n"
            for i in range(0, len(ddr), 4)
        ),
        encoding="utf-8",
    )

    manifest_path.write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )

    print()
    print("DATAFLOW COST MODEL")
    print("=" * 78)
    print(
        f"{'Desc':>4} "
        f"{'M':>7} "
        f"{'N':>5} "
        f"{'K':>6} "
        f"{'TM/TN/TK':>12} "
        f"{'Selected':>25}"
    )

    for item in decisions:
        cost = item["cost"]

        tile_shape = (
            f"{cost['m_tiles']}/"
            f"{cost['n_tiles']}/"
            f"{cost['k_tiles']}"
        )

        print(
            f"{item['descriptor_index']:>4} "
            f"{item['m']:>7} "
            f"{item['n']:>5} "
            f"{item['k']:>6} "
            f"{tile_shape:>12} "
            f"{item['selected']:>25}"
        )

        if "a_stationary" in cost:
            a = cost["a_stationary"]
            b = cost["b_stationary"]

            print(
                "     estimated exposed cycles: "
                f"A={a['estimated_exposed_cycles']}, "
                f"B={b['estimated_exposed_cycles']}; "
                f"operand bytes: "
                f"A={a['operand_bytes']}, "
                f"B={b['operand_bytes']}"
            )

    print("=" * 78)
    print(
        f"Optimized {len(decisions)} GEMM/Conv descriptors"
    )
    print(f"Output: {outdir}")


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Optimize NPU dataflow descriptor flags"
        )
    )

    parser.add_argument(
        "--model-dir",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--dataflow",
        choices=SUPPORTED_MODES,
        default=os.environ.get(
            "NPU_DATAFLOW", "auto"
        ).strip().lower(),
    )

    parser.add_argument(
        "--bandwidth",
        type=float,
        default=4.0,
        help="Nominal operand bandwidth in bytes/cycle",
    )

    parser.add_argument(
        "--a-overhead",
        type=float,
        default=14.0,
        help="Estimated fixed cost per A load",
    )

    parser.add_argument(
        "--b-overhead",
        type=float,
        default=14.0,
        help="Estimated fixed cost per B load",
    )

    parser.add_argument(
        "--a-overlap",
        type=float,
        default=0.65,
        help="Assumed A-mode DMA/compute overlap fraction",
    )

    parser.add_argument(
        "--b-overlap",
        type=float,
        default=0.60,
        help="Assumed B-mode DMA/compute overlap fraction",
    )

    parser.add_argument(
        "--conv-a-weight",
        type=float,
        default=1.25,
        help="Extra cost factor for Conv activation patch loads",
    )

    parser.add_argument(
        "--b-margin",
        type=float,
        default=0.15,
        help=(
            "Required fractional improvement before "
            "auto chooses B"
        ),
    )

    args = parser.parse_args()

    config = {
        "bandwidth": args.bandwidth,
        "a_overhead": args.a_overhead,
        "b_overhead": args.b_overhead,
        "a_overlap": args.a_overlap,
        "b_overlap": args.b_overlap,
        "conv_a_weight": args.conv_a_weight,
        "b_margin": args.b_margin,
    }

    if args.bandwidth <= 0 or not math.isfinite(
        args.bandwidth
    ):
        parser.error("bandwidth must be positive and finite")

    for name in ("a_overhead", "b_overhead"):
        if (
            config[name] < 0
            or not math.isfinite(config[name])
        ):
            parser.error(
                f"{name} must be nonnegative and finite"
            )

    for name in ("a_overlap", "b_overlap", "b_margin"):
        if (
            not math.isfinite(config[name])
            or not 0 <= config[name] < 1
        ):
            parser.error(
                f"{name} must be in [0, 1)"
            )

    if (
        not math.isfinite(args.conv_a_weight)
        or args.conv_a_weight < 1
    ):
        parser.error(
            "conv-a-weight must be >= 1"
        )

    optimize(
        args.model_dir,
        args.dataflow,
        config,
    )


if __name__ == "__main__":
    main()
