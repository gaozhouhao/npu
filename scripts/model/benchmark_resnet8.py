#!/usr/bin/env python3
"""Compare two RTL revisions using identical, already serialized ResNet8 models.

No model recompilation, checkout, or worktree is performed. Each RTL revision is
read with ``git show`` into the output directory. Both use one snapshot of the
current testbench/support files and the same DDR read latency. Every run checks
all emitted DDR bytes with the independent integer reference and checks that
the rest of the testbench's 1 MiB DDR stays zero.

Example (use a Python 3 interpreter):
  scripts/model/benchmark_resnet8.py \
    --model-dir zero=build/resnet8-compat/zero \
    --model-dir nonzero=build/resnet8-compat/nonzero \
    --model build/resnet8-compat/pretrainedResnet_quant.tflite \
    --provenance build/resnet8-compat/sources.json \
    --zero-input zero --seeded-input nonzero=8 \
    --baseline-ref 9d3ccce --current-ref 3b233df \
    --output build/resnet8-benchmark

The result measures NPU arithmetic compatibility and simulated cycles/traffic;
it does not measure TFLite bit exactness, dataset accuracy, or silicon latency.
"""

import argparse
import contextlib
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys

from check_legacy_resnet8 import check


ROOT = Path(__file__).resolve().parents[2]
MEM_WORDS = 262144
EXEC_OPS = {"CONV": 2, "FC": 1, "ADD": 5, "GLOBAL_AVG": 4}
COMPILE_FLAGS = ["-full64", "-sverilog", "-timescale=1ns/1ps",
                 "-top", "resnet8_npu_tb", "+define+NPU_PERF_ENABLE"]
FINISH_RE = re.compile(r"RESNET8 NPU FINISHED: top1=(\d+) cycles=(\d+) "
                       r"reads=(\d+) writes=(\d+)\b")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return sha256(Path(path).read_bytes())


def canonical_hash(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git_bytes(*args):
    return subprocess.check_output(["git"] + list(args), cwd=str(ROOT))


def run(command, directory, log):
    with Path(log).open("w") as handle:
        handle.write("Command: " + repr([str(item) for item in command]) + "\n")
        handle.flush()
        subprocess.run([str(item) for item in command], cwd=str(directory),
                       stdout=handle, stderr=subprocess.STDOUT, check=True)


def read_dump(path):
    result = bytearray()
    for line in Path(path).read_text().splitlines():
        if line.strip():
            result.extend(struct.pack("<I", int(line.strip(), 16)))
    return result


def parse_perf(log, descriptor_count, latency):
    """Read accepted external AXI beats, rejecting incomplete/mismatched runs."""
    text = Path(log).read_text()
    require("Fatal:" not in text and "Error-" not in text,
            "Simulator error in %s" % log)
    recorded_latency = re.findall(r"^DDR_READ_LATENCY_CYCLES,(\d+)$", text, re.M)
    require(recorded_latency == [str(latency)], "DDR latency mismatch in %s" % log)
    finishes = FINISH_RE.findall(text)
    require(len(finishes) == 1, "Missing/duplicate completed inference in %s" % log)
    require("PERF_COUNTER_CHECK,PASS" in text, "AXI counter check missing")
    layers, totals = {}, {}
    for line in text.splitlines():
        if not line.startswith(("PERF_LAYER,", "PERF_TOTAL,")):
            continue
        name, *fields = line.split(",")
        record = dict((key, int(value)) for key, value in
                      (field.split("=", 1) for field in fields))
        if name == "PERF_LAYER":
            index = record["index"]
            require(index not in layers, "Duplicate layer %d" % index)
            layers[index] = record
        else:
            require(not totals, "Duplicate PERF_TOTAL")
            totals = record
    require(set(layers) == set(range(descriptor_count)),
            "Incomplete layer performance records")
    require(totals and totals["cycles"] > 0, "Missing total performance counters")
    top1, tb_cycles, reads, writes = map(int, finishes[0])
    require(totals["read_beats"] == reads and totals["write_beats"] == writes,
            "Testbench/monitor AXI beat counts differ")
    # ResNet8 has no output tails on the AXI32 bus. The total popcount(WSTRB)
    # proves all accepted write beats used all four bytes, including per-layer.
    require(totals["written_bytes"] == writes * 4,
            "Partial write strobes require per-layer strobe instrumentation")
    require(sum(layer["write_beats"] for layer in layers.values()) == writes,
            "Write beats outside completed layer records")
    require(sum(layer["read_beats"] for layer in layers.values()) <= reads,
            "Layer read counters exceed total")
    require(sum(layer["cycles"] for layer in layers.values()) <= totals["cycles"],
            "Layer cycles exceed total")
    summary = dict(total_cycles=totals["cycles"], testbench_cycles=tb_cycles,
                   executor_cycles=totals["executor"], pool_cycles=totals["pool"],
                   read_transactions=totals["ar"], write_transactions=totals["aw"],
                   read_beats=reads, write_beats=writes,
                   read_bytes=reads * 8, write_bytes=totals["written_bytes"], top1=top1)
    summary["external_bytes"] = summary["read_bytes"] + summary["write_bytes"]
    summary["cycles_outside_layers"] = totals["cycles"] - sum(
        layer["cycles"] for layer in layers.values())
    summary["read_bytes_outside_layers"] = (reads - sum(
        layer["read_beats"] for layer in layers.values())) * 8
    rows = []
    for index in range(descriptor_count):
        layer = layers[index]
        rows.append(dict(index=index, opcode=layer["opcode"], cycles=layer["cycles"],
                         executor_cycles=layer["executor"], pool_cycles=layer["pool"],
                         read_bytes=layer["read_beats"] * 8,
                         write_bytes=layer["write_beats"] * 4))
    return summary, rows


def snapshot_shared(output):
    directory = output / "shared"
    names = ["sim/tb/system/resnet8_npu_tb.sv"]
    names += [str(path.relative_to(ROOT)) for path in
              sorted((ROOT / "sim/tb/support").glob("*.sv"))]
    hashes = {}
    for name in names:
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
        hashes[name] = file_hash(target)
    return [directory / name for name in names], hashes


def build_revision(output, label, revision, shared, vcs):
    commit = git_bytes("rev-parse", "--verify", revision + "^{commit}").decode().strip()
    directory = output / label
    source = directory / "source"
    source.mkdir(parents=True, exist_ok=True)
    filelist = git_bytes("show", commit + ":sim/filelists/rtl.f")
    names = [name.strip() for name in filelist.decode().splitlines() if name.strip()]
    hashes = {"sim/filelists/rtl.f": sha256(filelist)}
    paths = []
    for name in names:
        require(name.startswith("rtl/") and ".." not in Path(name).parts,
                "Unsupported source file list entry: %s" % name)
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git_bytes("show", commit + ":" + name))
        hashes[name] = file_hash(target)
        paths.append(target)
    (source / "rtl.f").write_bytes(filelist)
    command = [vcs] + COMPILE_FLAGS + paths + shared + [
        "-Mdir=" + str(directory / "csrc"), "-o", directory / "simv"]
    print("Building %s %s" % (label, commit[:12]), flush=True)
    run(command, directory, directory / "compile.log")
    require((directory / "simv").is_file(), "VCS did not create simv")
    return dict(commit=commit, source_sha256=hashes,
                source_set_sha256=canonical_hash(hashes), executable=str(directory / "simv"))


def prepare_model(spec, directory):
    name, path = spec.split("=", 1)
    require(re.fullmatch(r"[A-Za-z0-9_-]+", name), "Invalid model label")
    original = Path(path).resolve()
    directory = directory / name
    directory.mkdir(parents=True, exist_ok=True)
    # Snapshot the inputs once, so the two revisions cannot see different data.
    for filename in ("manifest.json", "ddr.bin", "descriptors.bin"):
        (directory / filename).write_bytes((original / filename).read_bytes())
    manifest = json.loads((directory / "manifest.json").read_text())
    image = (directory / "ddr.bin").read_bytes()
    descriptors = (directory / "descriptors.bin").read_bytes()
    require(len(image) == manifest["memory_size"] and len(image) <= MEM_WORDS * 4,
            "Model image size differs from manifest or exceeds TB DDR")
    require(len(image) % 4 == 0, "DDR image must contain complete words")
    require(len(descriptors) == manifest["descriptor_count"] * 64,
            "Descriptor count differs from manifest")
    offset = manifest["descriptor_addr"]
    require(image[offset:offset + len(descriptors)] == descriptors,
            "DDR descriptor copy differs from descriptors.bin")
    operations = [layer for layer in manifest["layers"] if layer["opcode"] in EXEC_OPS]
    require(len(operations) == manifest["descriptor_count"] == 14,
            "This benchmark expects the 14-operation legacy ResNet8")
    for index, layer in enumerate(operations):
        word = struct.unpack_from("<I", descriptors, index * 64)[0]
        require(word & 255 == EXEC_OPS[layer["opcode"]], "Manifest opcode mismatch")
        require(not (word >> 8 & 128), "Fused MaxPool is outside legacy ResNet8 scope")
    # Generate the simulator text from the authoritative ddr.bin snapshot and
    # also reject a stale compiler-produced ddr.hex if supplied.
    words = ["%08x\n" % item[0] for item in struct.iter_unpack("<I", image)]
    hex_path = directory / "ddr.hex"
    hex_path.write_text("".join(words))
    if (original / "ddr.hex").is_file():
        require(read_dump(original / "ddr.hex") == image, "ddr.hex differs from ddr.bin")
    input_count = 1
    for size in manifest["input_shape"]:
        input_count *= size
    address = manifest["input_addr"]
    input_bytes = image[address:address + input_count]
    require(len(input_bytes) == input_count, "Input outside DDR image")
    hashes = dict((filename, file_hash(directory / filename)) for filename in
                  ("manifest.json", "ddr.bin", "descriptors.bin", "ddr.hex"))
    return dict(label=name, original_directory=str(original), directory=str(directory),
                manifest=manifest, operations=operations, hashes=hashes,
                input_sha256=sha256(input_bytes), input_byte_count=input_count,
                input_distinct_values=len(set(input_bytes)), maxpool_descriptor_count=0)


def simulate(output, label, revision, model, latency, model_path):
    directory = output / label / model["label"]
    directory.mkdir(parents=True, exist_ok=True)
    manifest = model["manifest"]
    dump, log = directory / "ddr_dump.hex", directory / "simulation.log"
    command = [revision["executable"], "+DDR_HEX=" + str(Path(model["directory"]) / "ddr.hex"),
               "+DESC_BASE=%x" % manifest["descriptor_addr"],
               "+DESC_COUNT=%d" % manifest["descriptor_count"],
               "+LOGITS_BASE=%x" % manifest["logits_addr"],
               "+DDR_RD_LATENCY=%d" % latency, "+DDR_DUMP=" + str(dump),
               "+DUMP_WORDS=%d" % MEM_WORDS]
    print("Running %s/%s" % (label, model["label"]), flush=True)
    run(command, directory, log)
    summary, rows = parse_perf(log, manifest["descriptor_count"], latency)
    with (directory / "reference.log").open("w") as handle, contextlib.redirect_stdout(handle):
        correctness = check(model["directory"], str(dump), str(log), model_path)
    actual = read_dump(dump)
    require(len(actual) == MEM_WORDS * 4, "DDR dump does not cover the full TB memory")
    tail = actual[manifest["memory_size"]:]
    require(not any(tail), "RTL modified DDR outside the emitted model image")
    correctness["checked_full_ddr_bytes"] = len(actual)
    correctness["checked_zero_tail_bytes"] = len(tail)
    correctness["full_ddr_sha256"] = sha256(actual)
    require(correctness["top1"] == summary["top1"], "RTL/reference top1 differs")
    for row, layer in zip(rows, model["operations"]):
        require(row["opcode"] == EXEC_OPS[layer["opcode"]], "Perf opcode mismatch")
        row["operation"] = layer["opcode"]
    result = dict(summary=summary, layers=rows, correctness=correctness,
                  simulation_log_sha256=file_hash(log))
    write_json(directory / "report.json", result)
    return result


def comparison(before, after):
    baseline, current = before["summary"], after["summary"]
    require(before["correctness"]["full_ddr_sha256"] ==
            after["correctness"]["full_ddr_sha256"], "RTL revisions produced different DDR")
    cycles_saved = baseline["total_cycles"] - current["total_cycles"]
    return dict(baseline_cycles=baseline["total_cycles"], current_cycles=current["total_cycles"],
                cycles_saved=cycles_saved,
                cycle_reduction_pct=100.0 * cycles_saved / baseline["total_cycles"],
                speedup=baseline["total_cycles"] / current["total_cycles"],
                baseline_read_bytes=baseline["read_bytes"], current_read_bytes=current["read_bytes"],
                baseline_write_bytes=baseline["write_bytes"], current_write_bytes=current["write_bytes"],
                read_bytes_saved=baseline["read_bytes"] - current["read_bytes"],
                write_bytes_saved=baseline["write_bytes"] - current["write_bytes"],
                full_ddr_identical=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-dir", action="append", required=True, metavar="LABEL=PATH")
    parser.add_argument("--baseline-ref", default="9d3ccce")
    parser.add_argument("--current-ref", default="HEAD")
    parser.add_argument("--ddr-read-latency", type=int, default=20)
    parser.add_argument("--output", type=Path, default=ROOT / "build/resnet8-benchmark")
    parser.add_argument("--vcs", default="vcs")
    parser.add_argument("--model", help="Original TFLite file, for provenance hashing only")
    parser.add_argument("--provenance", type=Path, help="Saved model/input provenance JSON")
    parser.add_argument("--zero-input", action="append", default=[], metavar="LABEL",
                        help="Require this input to equal the manifest's quantized real zero")
    parser.add_argument("--seeded-input", action="append", default=[], metavar="LABEL=SEED",
                        help="Verify saved INT8 input using numpy.random.RandomState(SEED)")
    args = parser.parse_args(argv)
    require(args.ddr_read_latency >= 0, "DDR read latency cannot be negative")
    require(all("=" in spec for spec in args.model_dir), "Use --model-dir LABEL=PATH")
    require(len({spec.split("=", 1)[0] for spec in args.model_dir}) == len(args.model_dir),
            "Model labels must be unique")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Clear any old PASS before validation or compilation can fail on a rerun.
    write_json(output / "comparison.json", dict(status="RUNNING"))
    vcs = shutil.which(args.vcs)
    require(vcs, "VCS executable not found: %s" % args.vcs)
    models = [prepare_model(spec, output / "models") for spec in args.model_dir]
    model_labels = {model["label"]: model for model in models}
    for name in args.zero_input:
        require(name in model_labels, "Unknown zero-input model: %s" % name)
        model = model_labels[name]
        manifest = model["manifest"]
        value = int(manifest["input_scale_zp"][1]) & 255
        image = (Path(model["directory"]) / "ddr.bin").read_bytes()
        address = manifest["input_addr"]
        require(image[address:address + model["input_byte_count"]] ==
                bytes([value]) * model["input_byte_count"], "Input is not quantized real zero")
        model["input_generation"] = "quantized real zero"
    for spec in args.seeded_input:
        require("=" in spec, "Use --seeded-input LABEL=SEED")
        name, seed = spec.split("=", 1)
        require(name in model_labels and name not in args.zero_input,
                "Unknown or conflicting seeded-input model: %s" % name)
        import numpy as np
        model = model_labels[name]
        shape = model["manifest"]["input_shape"]
        seeded = np.random.RandomState(int(seed)).randint(-128, 128, size=shape).astype(np.int8)
        require(sha256(seeded.tobytes()) == model["input_sha256"], "Saved input does not match seed")
        model["input_generation"] = "numpy.random.RandomState(%d).randint(-128,128).astype(int8)" % int(seed)
    shared, shared_hashes = snapshot_shared(output)
    config = dict(ddr_read_latency_cycles=args.ddr_read_latency,
                  ddr_memory_bytes=MEM_WORDS * 4, external_read_beat_bytes=8,
                  external_write_beat_bytes=4, compile_flags=COMPILE_FLAGS,
                  benchmark_script_sha256=file_hash(Path(__file__)),
                  shared_source_sha256=shared_hashes,
                  reference_source_sha256=dict((str(path.relative_to(ROOT)), file_hash(path)) for path in
                      [ROOT / "compiler/reference_int8.py", ROOT / "scripts/model/check_legacy_resnet8.py"]),
                  model_hashes=dict((model["label"], model["hashes"]) for model in models))
    config["verified_inputs"] = dict((model["label"], model["input_generation"])
                                     for model in models if "input_generation" in model)
    if args.model:
        args.model = str(Path(args.model).resolve())
        config["tflite_sha256"] = file_hash(args.model)
    provenance = None
    if args.provenance:
        provenance = json.loads(args.provenance.read_text())
        config["provenance_sha256"] = file_hash(args.provenance)
        if args.model and "model_sha256" in provenance:
            require(provenance["model_sha256"] == config["tflite_sha256"], "Provenance model hash differs")
    revisions, runs = {}, {}
    # A failed rerun must not leave a previous successful comparison as its
    # apparent result. Per-run logs remain useful when investigating failure.
    write_json(output / "comparison.json", dict(status="RUNNING", config=config))
    for label, revision in [("baseline", args.baseline_ref), ("current", args.current_ref)]:
        revisions[label] = build_revision(output, label, revision, shared, vcs)
        runs[label] = dict((model["label"], simulate(output, label, revisions[label], model,
                            args.ddr_read_latency, args.model)) for model in models)
    comparisons = dict((model["label"], comparison(runs["baseline"][model["label"]],
                                                runs["current"][model["label"]])) for model in models)
    report = dict(status="PASS", config=config, config_sha256=canonical_hash(config),
                  revisions=revisions, runs=runs, comparison=comparisons,
                  inputs=[dict((key, model[key]) for key in ("label", "original_directory", "hashes",
                      "input_sha256", "input_byte_count", "input_distinct_values", "maxpool_descriptor_count"))
                      for model in models], provenance=provenance,
                  dataset_accuracy_measured=False, tflite_bit_exact=False,
                  interpretation="ResNet8 has no MaxPool descriptors; the pool-output FIFO may have zero effect.")
    write_json(output / "comparison.json", report)
    fields = ["input", "index", "operation", "baseline_cycles", "current_cycles", "cycles_saved",
              "baseline_read_bytes", "current_read_bytes", "baseline_write_bytes", "current_write_bytes"]
    with (output / "per_layer.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for model in models:
            name = model["label"]
            for before, after in zip(runs["baseline"][name]["layers"], runs["current"][name]["layers"]):
                row = dict(input=name, index=before["index"], operation=before["operation"],
                           cycles_saved=before["cycles"] - after["cycles"])
                for side, layer in [("baseline", before), ("current", after)]:
                    for metric in ("cycles", "read_bytes", "write_bytes"):
                        row[side + "_" + metric] = layer[metric]
                writer.writerow(row)
    for name, result in comparisons.items():
        print("%s: cycles %d -> %d; saved %.4f%%; reads %d -> %d bytes; writes %d -> %d bytes" % (
            name, result["baseline_cycles"], result["current_cycles"], result["cycle_reduction_pct"],
            result["baseline_read_bytes"], result["current_read_bytes"],
            result["baseline_write_bytes"], result["current_write_bytes"]))
    print("PASS: " + str(output / "comparison.json"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit("Benchmark failed: %s" % error)
