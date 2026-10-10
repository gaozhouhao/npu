
#!/usr/bin/env python3
"""Layer-by-layer INT8 comparison: TFLite vs RTL DDR."""

import argparse
import json
from pathlib import Path

import numpy as np

from verify_resnet8 import (
    create_interpreter,
    prepare_input,
)


COMPUTE_OPS = {
    "CONV",
    "FC",
    "ADD",
    "GLOBAL_AVG",
}


def load_ddr_hex(path, expected_bytes):
    """Decode 32-bit little-endian DDR word dump."""
    raw = bytearray()

    with path.open("r", encoding="utf-8") as f:
        for line_number, line in enumerate(f, 1):
            word = line.strip()

            if len(word) != 8:
                raise ValueError(
                    f"Invalid DDR word at line {line_number}"
                )

            value = int(word, 16)
            raw.extend(value.to_bytes(4, "little"))

    if len(raw) != expected_bytes:
        raise ValueError(
            f"DDR dump size {len(raw)} != "
            f"manifest memory_size {expected_bytes}"
        )

    return bytes(raw)


def get_tflite_tensors(model_path, input_path):
    interpreter = create_interpreter(model_path)
    interpreter.allocate_tensors()

    inputs = interpreter.get_input_details()

    if len(inputs) != 1:
        raise ValueError("Expected one model input")

    input_data = prepare_input(inputs[0], input_path)

    interpreter.set_tensor(
        inputs[0]["index"], input_data
    )
    interpreter.invoke()

    details = {
        int(d["index"]): d
        for d in interpreter.get_tensor_details()
    }

    return interpreter, details, input_data


def read_rtl_tensor(ddr, layer):
    addr = int(layer["c"])
    shape = tuple(int(x) for x in layer["shape"])
    elements = int(np.prod(shape))

    if addr < 0 or addr + elements > len(ddr):
        raise ValueError(
            f"Invalid DDR range: {addr}, {elements}"
        )

    # Manifest outputs are INT8 tensors.
    raw = ddr[addr:addr + elements]

    return (
        np.frombuffer(raw, dtype=np.int8)
        .reshape(shape)
        .astype(np.int32)
    )


def compare_layer(index, layer, golden, rtl):
    if golden.shape != rtl.shape:
        raise ValueError(
            f"Layer {index}: shape mismatch "
            f"{golden.shape} vs {rtl.shape}"
        )

    golden64 = golden.astype(np.int64)
    rtl64 = rtl.astype(np.int64)

    diff = rtl64 - golden64
    absolute = np.abs(diff)

    total = diff.size
    matched = int(np.count_nonzero(diff == 0))
    errors = total - matched

    result = {
        "layer": index,
        "opcode": layer["opcode"],
        "tensor_id": int(layer["output"]),
        "shape": list(golden.shape),
        "matched": matched,
        "total": total,
        "errors": errors,
        "max_abs": int(absolute.max()),
        "mean_abs": float(absolute.mean()),
        "first_mismatches": [],
    }

    mismatch_positions = np.flatnonzero(
        diff.reshape(-1) != 0
    )

    for pos in mismatch_positions[:10]:
        p = int(pos)

        result["first_mismatches"].append({
            "flat_index": p,
            "coords": list(
                np.unravel_index(p, golden.shape)
            ),
            "golden": int(golden64.flat[p]),
            "rtl": int(rtl64.flat[p]),
            "diff": int(diff.flat[p]),
        })

    return result


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--model", type=Path, required=True
    )
    parser.add_argument(
        "--manifest", type=Path, required=True
    )
    parser.add_argument(
        "--ddr-dump", type=Path, required=True
    )
    parser.add_argument(
        "--input-npy", type=Path, default=None
    )

    args = parser.parse_args()

    manifest = json.loads(
        args.manifest.read_text(encoding="utf-8")
    )

    ddr = load_ddr_hex(
        args.ddr_dump,
        int(manifest["memory_size"]),
    )

    interpreter, details, input_data = get_tflite_tensors(
        args.model, args.input_npy
    )

    # Verify the DDR image was generated for the same input.
    input_addr = int(manifest["input_addr"])
    input_bytes = input_data.tobytes()
    actual_input = ddr[
        input_addr:input_addr + len(input_bytes)
    ]

    if actual_input != input_bytes:
        raise ValueError(
            "RTL DDR input differs from TFLite input. "
            "Recompile DDR with matching --input-npy."
        )

    print("ResNet-8 Layer-by-Layer Golden Verification")
    print("=" * 83)
    print(
        f"{'Layer':>5} {'Operator':<12} "
        f"{'Tensor':>6} {'Elements':>9} "
        f"{'Exact':>9} {'MaxErr':>7} "
        f"{'MeanErr':>9} {'Status':>8}"
    )

    results = []

    for index, layer in enumerate(manifest["layers"]):
        opcode = layer["opcode"]

        # Reshape is an alias, and Softmax is bypassed.
        if opcode not in COMPUTE_OPS:
            continue

        tensor_id = int(layer["output"])

        if tensor_id not in details:
            raise ValueError(
                f"Missing TFLite tensor {tensor_id}"
            )

        tensor_detail = details[tensor_id]

        if np.dtype(tensor_detail["dtype"]) != np.int8:
            raise ValueError(
                f"Tensor {tensor_id} is not INT8"
            )

        golden = interpreter.get_tensor(
            tensor_id
        ).astype(np.int32)

        rtl = read_rtl_tensor(ddr, layer)

        result = compare_layer(
            index, layer, golden, rtl
        )

        results.append(result)

        status = (
            "PASS" if result["errors"] == 0
            else "MISMATCH"
        )

        print(
            f"{index:5d} "
            f"{opcode:<12} "
            f"{tensor_id:6d} "
            f"{result['total']:9d} "
            f"{result['matched']:9d} "
            f"{result['max_abs']:7d} "
            f"{result['mean_abs']:9.4f} "
            f"{status:>8}"
        )

    if not results:
        raise ValueError("No computational layers found")

    failing = [
        x for x in results if x["errors"] != 0
    ]

    print("-" * 83)
    print(f"Compared layers: {len(results)}")
    print(f"Exact layers   : {len(results) - len(failing)}")
    print(f"Mismatch layers: {len(failing)}")

    if failing:
        first = failing[0]

        print()
        print("FIRST MISMATCH")
        print(
            f"Layer {first['layer']} "
            f"({first['opcode']}), "
            f"Tensor {first['tensor_id']}"
        )

        print(
            f"Errors: {first['errors']}/"
            f"{first['total']}"
        )

        for item in first["first_mismatches"]:
            print(
                f"  coords={item['coords']} "
                f"TFLite={item['golden']} "
                f"RTL={item['rtl']} "
                f"diff={item['diff']:+d}"
            )

        print("\nLAYER GOLDEN VERIFICATION MISMATCH")
        raise SystemExit(1)

    print("\nLAYER GOLDEN VERIFICATION PASS")


if __name__ == "__main__":
    main()
