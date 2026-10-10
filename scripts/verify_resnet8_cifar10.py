
#!/usr/bin/env python3
"""CIFAR-10 ResNet-8 RTL vs TFLite golden verification."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

from verify_resnet8 import (
    create_interpreter,
    find_logits_tensor,
    parse_rtl_log,
    prepare_input,
)
from verify_resnet8_layers import (
    COMPUTE_OPS,
    compare_layer,
    load_ddr_hex,
    read_rtl_tensor,
)

ROOT = Path(__file__).resolve().parent.parent

CLASSES = (
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck",
)


def run_command(args, logfile):
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

    logfile.write_text(result.stdout, encoding="utf-8")

    if result.returncode != 0:
        print(result.stdout[-5000:], file=sys.stderr)
        raise RuntimeError(
            f"Command failed ({result.returncode}): {args[0]}"
        )


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--start", type=int, default=0)

    parser.add_argument(
        "--model",
        type=Path,
        default=ROOT / "models/resnet8/pretrainedResnet_quant.tflite",
    )

    parser.add_argument(
        "--binary",
        type=Path,
        default=ROOT / "build/resnet8_tb/Vresnet8_npu_tb",
    )

    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "build/cifar10_verify",
    )

    args = parser.parse_args()

    args.model = args.model.resolve()
    args.binary = args.binary.resolve()
    args.output = args.output.resolve()

    if args.count < 1 or args.start < 0:
        parser.error("Invalid sample range")

    if not args.model.is_file():
        parser.error(f"Model not found: {args.model}")

    if not args.binary.is_file():
        parser.error(
            "Verilator binary not found. Run run_resnet8.sh first."
        )

    import tensorflow as tf

    print("Loading CIFAR-10 test dataset...", flush=True)

    (_, _), (images, labels) = (
        tf.keras.datasets.cifar10.load_data()
    )

    labels = labels.reshape(-1)

    if args.start + args.count > len(images):
        parser.error("Sample range exceeds CIFAR-10 test set")

    # Initialize TFLite once, reuse for all images.
    interpreter = create_interpreter(args.model)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()

    if len(input_details) != 1:
        raise RuntimeError("Expected one TFLite input")

    input_detail = input_details[0]
    input_index = int(input_detail["index"])

    logits_index = find_logits_tensor(args.model)

    tensor_details = {
        int(d["index"]): d
        for d in interpreter.get_tensor_details()
    }

    if logits_index not in tensor_details:
        raise RuntimeError("Logits tensor not found")

    args.output.mkdir(parents=True, exist_ok=True)

    results = []
    layer_stats = {}

    total_layers = 0
    exact_layers = 0
    total_elements = 0
    exact_elements = 0

    rtl_correct = 0
    tflite_correct = 0
    top1_agree = 0

    print()
    print("CIFAR-10 ResNet-8 Verification")
    print("=" * 85)
    print(f"Samples: {args.start} ... {args.start + args.count - 1}")
    print("=" * 85)

    for sample_id in range(
        args.start, args.start + args.count
    ):
        sample_dir = args.output / f"sample_{sample_id:05d}"
        sample_dir.mkdir(parents=True, exist_ok=True)

        image = images[sample_id]
        label = int(labels[sample_id])

        # ------------------------------------------
        # 1. Generate shared INT8 input
        # ------------------------------------------
        input_path = sample_dir / "input.npy"
        np.save(input_path, image)

        input_data = prepare_input(
            input_detail, input_path
        )

        # ------------------------------------------
        # 2. TFLite reference inference
        # ------------------------------------------
        interpreter.set_tensor(input_index, input_data)
        interpreter.invoke()

        golden_logits = interpreter.get_tensor(
            logits_index
        ).reshape(-1).astype(np.int32)

        golden_top1 = int(np.argmax(golden_logits))

        # ------------------------------------------
        # 3. Compile image into NPU DDR image
        # ------------------------------------------
        model_dir = sample_dir / "model"

        run_command(
            [
                sys.executable,
                ROOT / "scripts/compile_resnet8_tflite.py",
                args.model,
                "--output",
                model_dir,
                "--input-npy",
                input_path,
            ],
            sample_dir / "compile.log",
        )

        manifest = json.loads(
            (model_dir / "manifest.json").read_text(
                encoding="utf-8"
            )
        )

        memory_size = int(manifest["memory_size"])

        if memory_size % 4:
            raise RuntimeError("DDR size not word aligned")

        # ------------------------------------------
        # 4. Run RTL simulation
        # ------------------------------------------
        rtl_log = sample_dir / "rtl.log"
        dump_path = sample_dir / "rtl_final_ddr.hex"

        run_command(
            [
                args.binary,
                f"+DDR_HEX={model_dir / 'ddr.hex'}",
                f"+DESC_BASE={int(manifest['descriptor_addr']):x}",
                f"+DESC_COUNT={int(manifest['descriptor_count'])}",
                f"+LOGITS_BASE={int(manifest['logits_addr']):x}",
                f"+DDR_DUMP={dump_path}",
                f"+DUMP_WORDS={memory_size // 4}",
            ],
            rtl_log,
        )

        rtl_logits = parse_rtl_log(rtl_log)

        if not np.array_equal(
            rtl_logits.shape, golden_logits.shape
        ):
            raise RuntimeError(
                f"Sample {sample_id}: logits shape mismatch"
            )

        rtl_top1 = int(np.argmax(rtl_logits))

        # ------------------------------------------
        # 5. Read RTL DDR and verify input
        # ------------------------------------------
        ddr = load_ddr_hex(dump_path, memory_size)

        input_addr = int(manifest["input_addr"])
        input_bytes = input_data.tobytes()

        if (
            ddr[input_addr:input_addr + len(input_bytes)]
            != input_bytes
        ):
            raise RuntimeError(
                f"Sample {sample_id}: RTL input differs "
                "from TFLite input"
            )

        # ------------------------------------------
        # 6. Compare all computational layers
        # ------------------------------------------
        sample_total_layers = 0
        sample_exact_layers = 0
        sample_total_elements = 0
        sample_exact_elements = 0
        first_mismatch = None

        for layer_index, layer in enumerate(
            manifest["layers"]
        ):
            opcode = layer["opcode"]

            if opcode not in COMPUTE_OPS:
                continue

            tensor_id = int(layer["output"])

            if tensor_id not in tensor_details:
                raise RuntimeError(
                    f"Missing TFLite tensor {tensor_id}"
                )

            if (
                np.dtype(tensor_details[tensor_id]["dtype"])
                != np.dtype(np.int8)
            ):
                raise RuntimeError(
                    f"Tensor {tensor_id} is not INT8"
                )

            golden = interpreter.get_tensor(
                tensor_id
            ).astype(np.int32)

            rtl = read_rtl_tensor(ddr, layer)

            result = compare_layer(
                layer_index, layer, golden, rtl
            )

            sample_total_layers += 1
            sample_total_elements += result["total"]
            sample_exact_elements += result["matched"]

            is_exact = result["errors"] == 0

            if is_exact:
                sample_exact_layers += 1
            elif first_mismatch is None:
                first_mismatch = result

            key = str(layer_index)

            if key not in layer_stats:
                layer_stats[key] = {
                    "opcode": opcode,
                    "samples": 0,
                    "exact_samples": 0,
                    "total_elements": 0,
                    "exact_elements": 0,
                }

            stat = layer_stats[key]
            stat["samples"] += 1
            stat["exact_samples"] += int(is_exact)
            stat["total_elements"] += result["total"]
            stat["exact_elements"] += result["matched"]

        if sample_total_layers != int(
            manifest["descriptor_count"]
        ):
            raise RuntimeError(
                f"Unexpected layer count: {sample_total_layers}"
            )

        # Verify that the layer comparison also covers
        # the final FC logits.
        if not np.array_equal(
            rtl_logits,
            np.frombuffer(
                ddr[
                    int(manifest["logits_addr"]):
                    int(manifest["logits_addr"]) +
                    golden_logits.size
                ],
                dtype=np.int8,
            ).astype(np.int32),
        ):
            raise RuntimeError("RTL logits/DDR mismatch")

        # ------------------------------------------
        # 7. Aggregate statistics
        # ------------------------------------------
        agree = rtl_top1 == golden_top1

        rtl_correct += int(rtl_top1 == label)
        tflite_correct += int(golden_top1 == label)
        top1_agree += int(agree)

        total_layers += sample_total_layers
        exact_layers += sample_exact_layers
        total_elements += sample_total_elements
        exact_elements += sample_exact_elements

        result_row = {
            "sample_id": sample_id,
            "label": label,
            "tflite_top1": golden_top1,
            "rtl_top1": rtl_top1,
            "top1_agree": agree,
            "rtl_correct": rtl_top1 == label,
            "tflite_correct": golden_top1 == label,
            "exact_layers": sample_exact_layers,
            "total_layers": sample_total_layers,
            "exact_elements": sample_exact_elements,
            "total_elements": sample_total_elements,
            "golden_logits": golden_logits.tolist(),
            "rtl_logits": rtl_logits.tolist(),
            "first_mismatch": first_mismatch,
        }

        results.append(result_row)

        status = (
            "EXACT"
            if sample_exact_elements == sample_total_elements
            else "MISMATCH"
        )

        print(
            f"Image {sample_id:5d} | "
            f"Label={CLASSES[label]:<10} | "
            f"TFLite={CLASSES[golden_top1]:<10} | "
            f"RTL={CLASSES[rtl_top1]:<10} | "
            f"Layers={sample_exact_layers}/{sample_total_layers} | "
            f"{status}",
            flush=True,
        )

        if first_mismatch is not None:
            print(
                f"  First mismatch: Layer "
                f"{first_mismatch['layer']} "
                f"{first_mismatch['opcode']}"
            )
            print(
                f"  Errors: {first_mismatch['errors']}/"
                f"{first_mismatch['total']}"
            )

            for item in first_mismatch["first_mismatches"][:5]:
                print(
                    f"    coords={item['coords']} "
                    f"TFLite={item['golden']} "
                    f"RTL={item['rtl']} "
                    f"diff={item['diff']:+d}"
                )

    # ----------------------------------------------
    # 8. Final report
    # ----------------------------------------------
    n = len(results)

    report = {
        "samples": n,
        "start": args.start,
        "tflite_accuracy": tflite_correct / n,
        "rtl_accuracy": rtl_correct / n,
        "top1_agreement": top1_agree / n,
        "layer_exact_rate": exact_layers / total_layers,
        "element_exact_rate": exact_elements / total_elements,
        "exact_layers": exact_layers,
        "total_layers": total_layers,
        "exact_elements": exact_elements,
        "total_elements": total_elements,
        "layer_stats": layer_stats,
        "results": results,
    }

    report_path = args.output / "report.json"

    report_path.write_text(
        json.dumps(report, indent=2),
        encoding="utf-8",
    )

    print()
    print("=" * 85)
    print("FINAL REPORT")
    print("=" * 85)

    print(f"Samples             : {n}")

    print(
        f"TFLite Accuracy     : "
        f"{100 * report['tflite_accuracy']:.2f}%"
    )

    print(
        f"RTL Accuracy        : "
        f"{100 * report['rtl_accuracy']:.2f}%"
    )

    print(
        f"Top-1 Agreement     : "
        f"{100 * report['top1_agreement']:.2f}%"
    )

    print(
        f"Layer Exact Match   : "
        f"{exact_layers}/{total_layers} "
        f"({100 * report['layer_exact_rate']:.4f}%)"
    )

    print(
        f"Element Exact Match : "
        f"{exact_elements}/{total_elements} "
        f"({100 * report['element_exact_rate']:.6f}%)"
    )

    print(f"Report              : {report_path}")

    if exact_elements != total_elements:
        print("\nGOLDEN VERIFICATION MISMATCH")
        raise SystemExit(1)

    print("\nGOLDEN VERIFICATION PASS")


if __name__ == "__main__":
    main()
