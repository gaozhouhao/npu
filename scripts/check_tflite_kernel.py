
#!/usr/bin/env python3
"""Compare TFLite default and reference kernels.

Read-only diagnostic. Does not modify RTL or model files.
"""

import argparse
import json
from pathlib import Path

import numpy as np
import tensorflow as tf


def make_interpreter(model_path, reference):
    kwargs = {
        "model_path": str(model_path),
        "experimental_preserve_all_tensors": True,
        "num_threads": 1,
    }

    if reference:
        resolver = getattr(
            tf.lite.experimental,
            "OpResolverType",
            None,
        )

        if resolver is None or not hasattr(
            resolver, "BUILTIN_REF"
        ):
            raise RuntimeError(
                "This TensorFlow build does not expose "
                "OpResolverType.BUILTIN_REF."
            )

        kwargs["experimental_op_resolver_type"] = (
            resolver.BUILTIN_REF
        )

    interpreter = tf.lite.Interpreter(**kwargs)
    interpreter.allocate_tensors()
    return interpreter


def load_input(sample_dir, input_details):
    path = sample_dir / "input.npy"

    if not path.is_file():
        raise FileNotFoundError(path)

    image = np.load(path)
    expected_shape = tuple(input_details["shape"])

    if image.shape == expected_shape[1:]:
        image = image.reshape(expected_shape)

    if image.shape != expected_shape:
        raise ValueError(
            f"Input shape {image.shape}, "
            f"expected {expected_shape}"
        )

    if image.dtype == np.int8:
        return image

    if image.dtype != np.uint8:
        raise ValueError(
            f"Unsupported input dtype: {image.dtype}"
        )

    scale, zp = input_details["quantization"]

    return np.clip(
        np.rint(image.astype(np.float64) / scale + zp),
        -128,
        127,
    ).astype(np.int8)


def run_model(model_path, sample_dir, tensor_id, coords, reference):
    interpreter = make_interpreter(
        model_path, reference
    )

    input_details = interpreter.get_input_details()[0]

    q = load_input(sample_dir, input_details)
    interpreter.set_tensor(
        int(input_details["index"]), q
    )

    interpreter.invoke()

    tensor_details = {
        int(d["index"]): d
        for d in interpreter.get_tensor_details()
    }

    if tensor_id not in tensor_details:
        raise RuntimeError(
            f"Tensor {tensor_id} not exposed by interpreter"
        )

    output = interpreter.get_tensor(tensor_id)
    value = int(output[coords])

    return value, output


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--sample-dir",
        type=Path,
        default=Path(
            "build/cifar10_verify/sample_00013"
        ),
    )

    parser.add_argument(
        "--model",
        type=Path,
        default=Path(
            "models/resnet8/pretrainedResnet_quant.tflite"
        ),
    )

    parser.add_argument(
        "--layer",
        type=int,
        default=2,
    )

    parser.add_argument(
        "--coords",
        type=int,
        nargs=4,
        default=[0, 30, 26, 2],
    )

    args = parser.parse_args()

    manifest_path = (
        args.sample_dir / "model" / "manifest.json"
    )

    manifest = json.loads(
        manifest_path.read_text()
    )

    layer = manifest["layers"][args.layer]
    tensor_id = int(layer["output"])
    coords = tuple(args.coords)

    print("Sample directory:", args.sample_dir)
    print("Layer:", args.layer, layer["opcode"])
    print("Tensor ID:", tensor_id)
    print("Coordinates:", coords)
    print()

    results = {}

    for name, reference in [
        ("DEFAULT", False),
        ("REFERENCE", True),
    ]:
        try:
            value, output = run_model(
                args.model,
                args.sample_dir,
                tensor_id,
                coords,
                reference,
            )

            results[name] = value

            print(
                f"{name:10s}: value={value:4d}, "
                f"shape={output.shape}, "
                f"dtype={output.dtype}"
            )

        except Exception as exc:
            print(
                f"{name:10s}: ERROR: "
                f"{type(exc).__name__}: {exc}"
            )

    print()
    print("Previously observed RTL   : 53")
    print("Previously observed TFLite: 52")

    if len(results) == 2:
        if results["DEFAULT"] != results["REFERENCE"]:
            print(
                "\nKERNEL DIFFERENCE: "
                "Default and reference kernels disagree."
            )
        else:
            print(
                "\nKERNEL AGREEMENT: "
                "Both interpreter modes give the same value."
            )


if __name__ == "__main__":
    main()
