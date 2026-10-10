
#!/usr/bin/env python3
"""Audit quantization parameters and a Conv mismatch.

Read-only: does not modify compiler, RTL, or DDR images.
"""

import argparse
import json
import math
import struct
from pathlib import Path

import numpy as np
import tflite

from verify_resnet8_layers import load_ddr_hex


OPS = {"CONV", "FC"}
MAX_M = (1 << 31) - 1
MAX_I64 = (1 << 63) - 1


def shape(t):
    return tuple(
        int(t.Shape(i)) for i in range(t.ShapeLength())
    )


def scale(t, channel=0):
    q = t.Quantization()
    return float(q.Scale(channel))


def model_graph(path):
    raw = bytearray(path.read_bytes())
    model = tflite.Model.GetRootAsModel(raw, 0)
    return model, model.Subgraphs(0)


def producer_map(model, graph):
    result = {}

    for i in range(graph.OperatorsLength()):
        op = graph.Operators(i)
        code = int(
            model.OperatorCodes(
                op.OpcodeIndex()
            ).BuiltinCode()
        )

        for j in range(op.OutputsLength()):
            result[int(op.Outputs(j))] = (op, code)

    return result


def round_away(product, shift):
    if shift == 0:
        return product

    magnitude = abs(product)
    value = (magnitude + (1 << (shift - 1))) >> shift
    return -value if product < 0 else value


def requant(acc, m, shift, zp, relu):
    product = acc * m

    if not -(1 << 63) <= product < (1 << 63):
        raise OverflowError("Signed INT64 multiplication overflow")

    value = round_away(product, shift) + zp

    if relu:
        value = max(value, zp)

    return min(127, max(-128, value))


def read_layer_ratio(graph, producers, layer, channel):
    tid = int(layer["output"])
    op, code = producers[tid]

    if code not in (
        int(tflite.BuiltinOperator.CONV_2D),
        int(tflite.BuiltinOperator.FULLY_CONNECTED),
    ):
        raise ValueError("Expected Conv/FC")

    tx = graph.Tensors(int(op.Inputs(0)))
    tw = graph.Tensors(int(op.Inputs(1)))
    ty = graph.Tensors(tid)

    nq = tw.Quantization().ScaleLength()
    wc = channel if nq > 1 else 0

    return scale(tx) * scale(tw, wc) / scale(ty)


def read_params(ddr, layer, channel):
    addr = int(layer["params"]) + 16 + 12 * channel
    return struct.unpack_from("<iII", ddr, addr)


def check_model(manifest, ddr, graph, producers):
    print("\nFULL MODEL QUANTIZATION AUDIT")
    print("=" * 85)

    channels = 0
    max_abs_ratio_error = 0.0
    max_rel_ratio_error = 0.0
    shifts = []

    for idx, layer in enumerate(manifest["layers"]):
        if layer["opcode"] not in OPS:
            continue

        output_shape = tuple(layer["shape"])
        n = output_shape[-1]

        layer_max_error = 0.0
        layer_shifts = []

        for channel in range(n):
            ratio = read_layer_ratio(
                graph, producers, layer, channel
            )

            bias, m, shift = read_params(
                ddr, layer, channel
            )

            if not (0 <= m <= MAX_M):
                raise ValueError(
                    f"Layer {idx} channel {channel}: bad M"
                )

            if not (0 <= shift <= 62):
                raise ValueError(
                    f"Layer {idx} channel {channel}: bad Shift"
                )

            # Conservative bound for 33-bit adjusted accumulator.
            max_acc = (1 << 32) - 1
            half = (1 << (shift - 1)) if shift else 0

            if max_acc * m + half > MAX_I64:
                raise ValueError(
                    f"Layer {idx} channel {channel}: "
                    "possible INT64 overflow"
                )

            hardware_ratio = m / (1 << shift)
            error = abs(hardware_ratio - ratio)
            relative = error / ratio if ratio else 0.0

            max_abs_ratio_error = max(
                max_abs_ratio_error, error
            )
            max_rel_ratio_error = max(
                max_rel_ratio_error, relative
            )
            layer_max_error = max(layer_max_error, error)

            channels += 1
            shifts.append(shift)
            layer_shifts.append(shift)

        print(
            f"Layer {idx:2d} {layer['opcode']:<5} "
            f"channels={n:3d} "
            f"shift=[{min(layer_shifts):2d},"
            f"{max(layer_shifts):2d}] "
            f"max_scale_error={layer_max_error:.4e}"
        )

    print("-" * 85)
    print("Audited channels      :", channels)
    print("Minimum Shift         :", min(shifts))
    print("Maximum Shift         :", max(shifts))
    print("Maximum abs ratio err :", max_abs_ratio_error)
    print("Maximum rel ratio err :", max_rel_ratio_error)
    print("Conv/FC range audit   : PASS")


def inspect_conv(
    manifest, ddr, desc_data, graph, producers,
    layer_idx, coords, golden, observed
):
    layer = manifest["layers"][layer_idx]

    if layer["opcode"] != "CONV":
        raise ValueError("Target must be a Conv layer")

    batch, oy, ox, channel = coords

    input_tid = int(layer["input"])
    input_shape = shape(graph.Tensors(input_tid))
    input_addr = int(layer["a"])
    input_size = math.prod(input_shape)

    x = np.frombuffer(
        ddr[input_addr:input_addr + input_size],
        dtype=np.int8,
    ).reshape(input_shape).astype(np.int64)

    executable = {
        "CONV", "FC", "ADD", "GLOBAL_AVG"
    }

    desc_idx = sum(
        item["opcode"] in executable
        for item in manifest["layers"][:layer_idx]
    )

    desc = struct.unpack_from(
        "<16I", desc_data, desc_idx * 64
    )

    cin = desc[11] & 0xffff
    kh = (desc[11] >> 16) & 0xff
    kw = (desc[11] >> 24) & 0xff

    sh = desc[12] & 0xff
    sw = (desc[12] >> 8) & 0xff
    pt = (desc[12] >> 16) & 0xff
    pl = (desc[12] >> 24) & 0xff

    if batch != 0 or cin != input_shape[-1]:
        raise ValueError("Unexpected tensor layout")

    k = kh * kw * cin
    row_stride = ((k + 3) // 4) * 4

    weight_addr = (
        int(layer["b"]) + channel * row_stride
    )

    weights = np.frombuffer(
        ddr[weight_addr:weight_addr + k],
        dtype=np.int8,
    ).astype(np.int64).reshape(kh, kw, cin)

    zp_in = int(layer["input_zp"])
    zp_out = int(layer["output_zp"])

    mac = 0

    for ky in range(kh):
        for kx in range(kw):
            iy = oy * sh + ky - pt
            ix = ox * sw + kx - pl

            if (
                0 <= iy < input_shape[1]
                and 0 <= ix < input_shape[2]
            ):
                a = x[0, iy, ix, :]
            else:
                a = np.full(
                    cin, zp_in, dtype=np.int64
                )

            mac += int(np.sum(
                a * weights[ky, kx, :]
            ))

    bias, m, shift = read_params(
        ddr, layer, channel
    )

    acc = mac + bias
    ratio = read_layer_ratio(
        graph, producers, layer, channel
    )

    relu = bool(int(layer["flags"]) & 4)

    predicted = requant(
        acc, m, shift, zp_out, relu
    )

    print("\nTARGET MISMATCH ANALYSIS")
    print("=" * 85)
    print("Layer              :", layer_idx)
    print("Coordinates        :", coords)
    print("MAC                :", mac)
    print("Folded Bias        :", bias)
    print("Adjusted ACC       :", acc)
    print("Multiplier         :", m)
    print("Shift              :", shift)
    print("Original Ratio     :", repr(ratio))
    print("Hardware Ratio     :", repr(m / (1 << shift)))
    print("Original scaled    :", repr(acc * ratio))
    print("Hardware scaled    :", repr(acc * m / (1 << shift)))
    print("TFLite output      :", golden)
    print("Observed RTL       :", observed)
    print("Reconstructed RTL  :", predicted)

    if predicted != observed:
        print(
            "RESULT: MAC/parameter reconstruction does "
            "not match RTL. Investigate datapath."
        )
        return

    # Mathematical reference, not an exact TFLite kernel model.
    original_rounded = round_away(
        round(acc * ratio * (1 << 48)), 48
    )
    original_output = max(
        -128,
        min(
            127,
            max(original_rounded + zp_out, zp_out)
            if relu else original_rounded + zp_out
        )
    )

    print("High-precision math :", original_output)

    if original_output == golden:
        print(
            "RESULT: multiplier approximation is a "
            "plausible cause; TFLite integer rounding "
            "still needs independent confirmation."
        )
    else:
        print(
            "RESULT: original-ratio arithmetic also "
            "differs from TFLite. Investigate TFLite "
            "fixed-point rounding semantics."
        )


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--sample-dir",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--model",
        type=Path,
        default=Path(
            "models/resnet8/pretrainedResnet_quant.tflite"
        ),
    )

    parser.add_argument("--layer", type=int, default=2)
    parser.add_argument(
        "--coords", type=int, nargs=4,
        default=[0, 30, 26, 2]
    )
    parser.add_argument("--golden", type=int, default=52)
    parser.add_argument("--rtl", type=int, default=53)

    args = parser.parse_args()

    model, graph = model_graph(args.model)
    producers = producer_map(model, graph)

    model_dir = args.sample_dir / "model"

    manifest = json.loads(
        (model_dir / "manifest.json").read_text()
    )

    ddr = load_ddr_hex(
        args.sample_dir / "rtl_final_ddr.hex",
        int(manifest["memory_size"])
    )

    desc_data = (
        model_dir / "descriptors.bin"
    ).read_bytes()

    check_model(
        manifest, ddr, graph, producers
    )

    inspect_conv(
        manifest,
        ddr,
        desc_data,
        graph,
        producers,
        args.layer,
        tuple(args.coords),
        args.golden,
        args.rtl,
    )


if __name__ == "__main__":
    main()
