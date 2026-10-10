
#!/usr/bin/env python3
"""Compare TFLite pre-Softmax INT8 logits with RTL NPU output."""

import argparse
import re
from pathlib import Path

import numpy as np
import tflite


def create_interpreter(model_path):
    # Preserve intermediate tensors for pre-Softmax inspection.
    try:
        import tensorflow as tf
        cls = tf.lite.Interpreter
    except ImportError:
        try:
            from tflite_runtime.interpreter import Interpreter as cls
        except ImportError as exc:
            raise RuntimeError(
                "Install tensorflow or tflite-runtime"
            ) from exc

    try:
        return cls(
            model_path=str(model_path),
            experimental_preserve_all_tensors=True,
            num_threads=1,
        )
    except TypeError as exc:
        raise RuntimeError(
            "Interpreter does not support intermediate tensor "
            "preservation. Use a compatible TensorFlow version."
        ) from exc


def find_logits_tensor(model_path):
    """Read the FlatBuffer to locate the Softmax input tensor."""
    blob = model_path.read_bytes()
    model = tflite.Model.GetRootAsModel(
        bytearray(blob), 0
    )

    if model.SubgraphsLength() != 1:
        raise ValueError("Expected one TFLite subgraph")

    graph = model.Subgraphs(0)
    codes = tflite.BuiltinOperator

    fc_outputs = []
    softmax_inputs = []

    for i in range(graph.OperatorsLength()):
        op = graph.Operators(i)
        opcode = model.OperatorCodes(op.OpcodeIndex())
        code = int(opcode.BuiltinCode())

        if code == int(codes.FULLY_CONNECTED):
            fc_outputs.append(int(op.Outputs(0)))

        if code == int(codes.SOFTMAX):
            softmax_inputs.append(int(op.Inputs(0)))

    if len(fc_outputs) != 1:
        raise ValueError(
            f"Expected one FC, found {len(fc_outputs)}"
        )

    if len(softmax_inputs) != 1:
        raise ValueError(
            f"Expected one Softmax, found {len(softmax_inputs)}"
        )

    if fc_outputs[0] != softmax_inputs[0]:
        raise ValueError(
            "Softmax input does not match FC output"
        )

    return fc_outputs[0]


def prepare_input(detail, input_path):
    """Replicate compiler input conversion."""
    shape = tuple(int(x) for x in detail["shape"])
    dtype = np.dtype(detail["dtype"])

    if dtype != np.dtype(np.int8):
        raise ValueError(
            f"Expected INT8 model input, got {dtype}"
        )

    scales, zero_points = detail["quantization"]
    scale = float(scales)
    zp = int(zero_points)

    if scale <= 0:
        raise ValueError("Invalid input quantization scale")

    if input_path is None:
        # Default compiler input represents real zero.
        return np.full(shape, zp, dtype=np.int8)

    raw = np.load(input_path, allow_pickle=False)

    if raw.shape == shape[1:]:
        raw = raw.reshape(shape)

    if raw.shape != shape:
        raise ValueError(
            f"Input shape mismatch: {raw.shape} != {shape}"
        )

    if raw.dtype == np.int8:
        return raw.copy()

    if raw.dtype == np.uint8:
        values = np.rint(
            raw.astype(np.float64) / scale + zp
        )
        return np.clip(
            values, -128, 127
        ).astype(np.int8)

    raise ValueError(
        f"Unsupported input dtype: {raw.dtype}"
    )


def run_tflite(model_path, input_path):
    interpreter = create_interpreter(model_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()

    if len(input_details) != 1:
        raise ValueError("Expected exactly one model input")

    input_detail = input_details[0]
    input_data = prepare_input(
        input_detail, input_path
    )

    interpreter.set_tensor(
        input_detail["index"], input_data
    )
    interpreter.invoke()

    logits_index = find_logits_tensor(model_path)

    tensors = {
        int(d["index"]): d
        for d in interpreter.get_tensor_details()
    }

    if logits_index not in tensors:
        raise ValueError(
            f"Logits tensor {logits_index} not found"
        )

    detail = tensors[logits_index]

    if np.dtype(detail["dtype"]) != np.dtype(np.int8):
        raise ValueError("FC logits are not INT8")

    logits = interpreter.get_tensor(
        logits_index
    ).reshape(-1).astype(np.int32)

    return logits, detail, input_data


def parse_rtl_log(path):
    pattern = re.compile(
        r"^\s*logit\[(\d+)\]\s*=\s*(-?\d+)\s*$",
        re.MULTILINE,
    )

    contents = path.read_text(
        encoding="utf-8", errors="replace"
    )

    if "RESNET8 NPU FINISHED:" not in contents:
        raise ValueError(
            "RTL log has no successful completion marker"
        )

    matches = pattern.findall(contents)

    if not matches:
        raise ValueError("No RTL logits found")

    result = {}

    for index_text, value_text in matches:
        index = int(index_text)
        value = int(value_text)

        if index in result:
            raise ValueError(
                f"Duplicate RTL logit index {index}"
            )

        if not -128 <= value <= 127:
            raise ValueError(
                f"Logit {index} outside INT8 range"
            )

        result[index] = value

    expected = set(range(len(result)))

    if set(result) != expected:
        raise ValueError(
            f"Non-contiguous RTL indices: {sorted(result)}"
        )

    return np.array(
        [result[i] for i in range(len(result))],
        dtype=np.int32,
    )


def compare(golden, rtl, detail):
    if golden.shape != rtl.shape:
        raise ValueError(
            f"Shape mismatch: {golden.shape} vs {rtl.shape}"
        )

    diff = rtl - golden
    abs_diff = np.abs(diff)

    print()
    print("ResNet-8 FC Logits Golden Verification")
    print("=" * 58)
    print(
        f"{'Class':>5} "
        f"{'TFLite':>10} "
        f"{'RTL':>10} "
        f"{'Diff':>10} "
        f"{'Match':>8}"
    )

    for i in range(golden.size):
        matched = diff[i] == 0
        print(
            f"{i:5d} "
            f"{golden[i]:10d} "
            f"{rtl[i]:10d} "
            f"{diff[i]:+10d} "
            f"{'YES' if matched else 'NO':>8}"
        )

    print("-" * 58)

    exact = int(np.count_nonzero(diff == 0))
    total = int(golden.size)

    golden_top1 = int(np.argmax(golden))
    rtl_top1 = int(np.argmax(rtl))

    scale, zp = detail["quantization"]

    print(f"Output scale       : {scale}")
    print(f"Output zero point  : {zp}")
    print(f"Exact matches      : {exact}/{total}")
    print(f"Max absolute error : {int(abs_diff.max())}")
    print(f"Mean absolute error: {float(abs_diff.mean()):.4f}")
    print(f"TFLite Top-1       : {golden_top1}")
    print(f"RTL Top-1          : {rtl_top1}")
    print(
        "Top-1 agreement    : "
        + ("YES" if golden_top1 == rtl_top1 else "NO")
    )

    if exact == total:
        print("\nGOLDEN VERIFICATION PASS")
        return True

    print("\nGOLDEN VERIFICATION MISMATCH")
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--rtl-log",
        type=Path,
        required=True,
    )
    parser.add_argument(
        "--input-npy",
        type=Path,
        default=None,
    )

    args = parser.parse_args()

    if not args.model.is_file():
        parser.error("TFLite model not found")

    if not args.rtl_log.is_file():
        parser.error("RTL log not found")

    golden, detail, input_data = run_tflite(
        args.model, args.input_npy
    )
    rtl = parse_rtl_log(args.rtl_log)

    print(
        f"Input shape: {input_data.shape}, "
        f"dtype: {input_data.dtype}"
    )
    print(
        f"Logits tensor index: {int(detail['index'])}"
    )

    passed = compare(golden, rtl, detail)

    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
