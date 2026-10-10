
#!/usr/bin/env python3
"""Experiment with fixed-point requantization precision.

Reconstruct the first two known mismatches using RTL DDR data.
No RTL or compiler modifications.
"""

import json
import struct
from pathlib import Path

import numpy as np
import tflite

from verify_resnet8_layers import load_ddr_hex


ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models/resnet8/pretrainedResnet_quant.tflite"

CASES = [
    (4, 0, (0, 20, 27, 2), -98, -97),
    (0, 10, (0, 7, 2, 30), 16, 17),
]

SHIFTS = (28, 30, 32, 34, 36, 38, 40, 42)
MAX_MULTIPLIER = (1 << 31) - 1


def load_model():
    blob = bytearray(MODEL.read_bytes())
    model = tflite.Model.GetRootAsModel(blob, 0)
    graph = model.Subgraphs(0)
    return model, graph


def get_scales(graph, output_tid, channel):
    """Find the Conv operator producing the requested tensor."""
    model = MODEL_OBJ

    for i in range(graph.OperatorsLength()):
        op = graph.Operators(i)

        if int(op.Outputs(0)) != output_tid:
            continue

        code = int(
            model.OperatorCodes(
                op.OpcodeIndex()
            ).BuiltinCode()
        )

        if code != int(tflite.BuiltinOperator.CONV_2D):
            raise ValueError("Expected Conv2D operator")

        tx = graph.Tensors(int(op.Inputs(0)))
        tw = graph.Tensors(int(op.Inputs(1)))
        ty = graph.Tensors(int(op.Outputs(0)))

        si = float(tx.Quantization().Scale(0))
        sw = float(tw.Quantization().Scale(channel))
        so = float(ty.Quantization().Scale(0))

        return si, sw, so

    raise ValueError(f"Output tensor {output_tid} not found")


def tensor_shape(graph, tensor_id):
    t = graph.Tensors(tensor_id)
    return tuple(
        int(t.Shape(i)) for i in range(t.ShapeLength())
    )


def round_away(numerator, shift):
    """Same rounding arithmetic as postprocess_unit.sv."""
    denominator = 1 << shift
    magnitude = abs(numerator)

    rounded = (
        magnitude + (denominator >> 1)
    ) // denominator

    return -rounded if numerator < 0 else rounded


def requant(acc, multiplier, shift, output_zp, relu):
    product = acc * multiplier
    rounded = round_away(product, shift)
    value = rounded + output_zp

    if relu:
        value = max(value, output_zp)

    return max(-128, min(127, value))


def reconstruct(sample, layer_index, coords):
    sample_dir = (
        ROOT / "build/cifar10_verify"
        / f"sample_{sample:05d}"
    )
    model_dir = sample_dir / "model"

    manifest = json.loads(
        (model_dir / "manifest.json").read_text()
    )

    layers = manifest["layers"]
    layer = layers[layer_index]

    if layer["opcode"] != "CONV":
        raise ValueError("Expected CONV layer")

    ddr = load_ddr_hex(
        sample_dir / "rtl_final_ddr.hex",
        int(manifest["memory_size"]),
    )

    input_tid = int(layer["input"])
    input_shape = tensor_shape(GRAPH, input_tid)

    input_addr = int(layer["a"])
    input_size = int(np.prod(input_shape))

    x = np.frombuffer(
        ddr[input_addr:input_addr + input_size],
        dtype=np.int8,
    ).reshape(input_shape).astype(np.int64)

    descriptor_index = sum(
        item["opcode"] in {"CONV", "FC", "ADD", "GLOBAL_AVG"}
        for item in layers[:layer_index]
    )

    desc_data = (
        model_dir / "descriptors.bin"
    ).read_bytes()

    desc = struct.unpack_from(
        "<16I",
        desc_data,
        descriptor_index * 64,
    )

    cin = desc[11] & 0xffff
    kh = (desc[11] >> 16) & 0xff
    kw = (desc[11] >> 24) & 0xff

    stride_h = desc[12] & 0xff
    stride_w = (desc[12] >> 8) & 0xff
    pad_top = (desc[12] >> 16) & 0xff
    pad_left = (desc[12] >> 24) & 0xff

    batch, oy, ox, channel = coords

    if batch != 0 or input_shape[3] != cin:
        raise ValueError("Unexpected input layout")

    k = kh * kw * cin
    row_stride = ((k + 3) // 4) * 4

    weight_addr = (
        int(layer["b"]) + channel * row_stride
    )

    weights = np.frombuffer(
        ddr[weight_addr:weight_addr + k],
        dtype=np.int8,
    ).astype(np.int64).reshape(kh, kw, cin)

    input_zp = int(layer["input_zp"])
    output_zp = int(layer["output_zp"])

    mac = 0

    for ky in range(kh):
        for kx in range(kw):
            iy = oy * stride_h + ky - pad_top
            ix = ox * stride_w + kx - pad_left

            if (
                0 <= iy < input_shape[1]
                and 0 <= ix < input_shape[2]
            ):
                values = x[0, iy, ix, :]
            else:
                values = np.full(
                    cin, input_zp, dtype=np.int64
                )

            mac += int(np.sum(
                values * weights[ky, kx]
            ))

    param_addr = (
        int(layer["params"]) + 16 + 12 * channel
    )

    bias, stored_m, stored_shift = struct.unpack_from(
        "<iII", ddr, param_addr
    )

    acc = mac + bias
    relu = bool(int(layer["flags"]) & 4)

    si, sw, so = get_scales(
        GRAPH,
        int(layer["output"]),
        channel,
    )

    return {
        "mac": mac,
        "bias": bias,
        "acc": acc,
        "stored_m": stored_m,
        "stored_shift": stored_shift,
        "ratio": si * sw / so,
        "output_zp": output_zp,
        "relu": relu,
    }


def experiment(case):
    sample, layer_idx, coords, golden, observed = case
    info = reconstruct(sample, layer_idx, coords)

    acc = info["acc"]
    ratio = info["ratio"]
    zp = info["output_zp"]

    print()
    print("=" * 85)
    print(
        f"Sample {sample}, Layer {layer_idx}, "
        f"coords={coords}"
    )
    print("=" * 85)

    print("MAC             :", info["mac"])
    print("Folded Bias     :", info["bias"])
    print("Adjusted ACC    :", acc)
    print("Original Ratio  :", repr(ratio))
    print("Original Scaled :", repr(acc * ratio))
    print("Output ZP       :", zp)
    print("TFLite          :", golden)
    print("Observed RTL    :", observed)

    stored_result = requant(
        acc,
        info["stored_m"],
        info["stored_shift"],
        zp,
        info["relu"],
    )

    print("Stored M        :", info["stored_m"])
    print("Stored Shift    :", info["stored_shift"])
    print("Reconstructed   :", stored_result)

    if stored_result != observed:
        raise RuntimeError(
            "Reconstructed RTL differs from observed RTL. "
            "Do not interpret precision scan."
        )

    print()
    print(
        f"{'Shift':>5} {'Multiplier':>12} "
        f"{'Scaled':>18} {'INT8':>6} "
        f"{'TFLite':>8} {'Status':>10}"
    )

    for shift in SHIFTS:
        multiplier = round(ratio * (1 << shift))

        if multiplier > MAX_MULTIPLIER:
            print(
                f"{shift:5d} "
                f"{'OUT OF RANGE':>12}"
            )
            continue

        scaled = acc * multiplier / (1 << shift)

        output = requant(
            acc,
            multiplier,
            shift,
            zp,
            info["relu"],
        )

        status = (
            "MATCH" if output == golden else "DIFF"
        )

        print(
            f"{shift:5d} "
            f"{multiplier:12d} "
            f"{scaled:18.12f} "
            f"{output:6d} "
            f"{golden:8d} "
            f"{status:>10}"
        )


MODEL_OBJ, GRAPH = load_model()

for case in CASES:
    experiment(case)
