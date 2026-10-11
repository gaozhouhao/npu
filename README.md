# INT8 NPU

SystemVerilog 4x4 INT8 systolic-array NPU with Verilator simulation. The
current execution path supports tiled GEMM/Conv2D, bias and per-channel
requantization, pooling/global average pooling, residual ADD, and fully
connected layers. The repository also retains the PSUM and multi-K A-reuse
experiments and their focused regressions.

## Repository layout

```text
rtl/compute/   PE array, matrix engine, postprocess and pooling
rtl/core/      command, scheduling, GEMM execution and performance monitor
rtl/dma/       AXI masters and operand/parameter/writeback data paths
rtl/memory/    scratchpads, operand buffers and PSUM SRAM
sim/tb/        module, integration, experiment and end-to-end testbenches
sim/golden/    small software golden models
compiler/      MNIST model compiler and artifact verification
scripts/       ResNet-8 compilation, verification and regression entrypoints
artifacts/     checked-in MNIST deployment images and golden tensors
models/        local pretrained model inputs (binary models are ignored)
build/         generated Verilator outputs, logs, dumps and waveforms
```

Generated build products, logs, waveforms, local datasets, Python virtual
environments and pretrained binary models are intentionally excluded from
Git. Do not use `make clean` when experiment logs or waveforms under `build/`
must be retained.

## Main regressions

The default regression compiles with Verilator `-Wall` and runs the top-level,
Conv patch, Conv2D and Conv+Pool tests:

```bash
make regression
```

The parameter-slot/PSUM/A-reuse stress test runs all three configurations:

```bash
bash scripts/run_param_slot_stress.sh
```

Additional focused testbenches under `sim/tb/` cover the PE, matrix engine,
GEMM core/executor, DMA path, scheduler, postprocess, pooling, per-channel
parameters and experimental dataflows. They are independent verification
entrypoints even when they are not part of the default Make target.

## ResNet-8 end-to-end flow

Place the quantized model at
`models/resnet8/pretrainedResnet_quant.tflite`, then run:

```bash
bash scripts/run_resnet8.sh
```

The compiler emits the DDR image and descriptor manifest below `build/`, and
the testbench executes the complete quantized graph: Conv, residual ADD,
global average pooling and FC. It can also dump final DDR for layer-by-layer
comparison with TFLite.

For the performance regression:

```bash
bash scripts/run_resnet8_perf.sh
python3 scripts/report_resnet8_perf.py
```

`NPU_PERF_ENABLE` connects the synthesizable total/layer and AXI counters and
enables testbench-only PE utilization and core/DMA overlap probes. Performance
reports are generated from `build/resnet8_perf/perf.log`; the reporting script
does not alter RTL behavior.

The current reference input produces:

| Metric | Baseline |
|---|---:|
| Top-1 | 0 |
| Total cycles | 1,828,229 |
| Matrix tiles | 6,659 |
| Executed MACs | 12,504,064 |
| AXI read beats | 1,279,718 |
| AXI write beats | 28,700 |

These values are regression guards for accidental behavior changes, not a
constraint on deliberate future optimization.

## Model and quantization tools

- `scripts/compile_resnet8_tflite.py` compiles the supported quantized TFLite
  graph into descriptors, weights, parameters and a DDR image.
- `scripts/verify_resnet8.py`, `verify_resnet8_layers.py` and
  `verify_resnet8_cifar10.py` compare RTL results with the TFLite reference.
- `scripts/audit_resnet8_quant.py`, `check_tflite_kernel.py` and
  `experiment_requant_precision.py` are standalone quantization/debug tools.
- `compiler/` contains the earlier MNIST compiler, contract checks and Python
  regression suite; see `compiler/README.md` for its artifact ABI.

The ResNet-8 flow requires Python packages `numpy` and `tflite`; scripts that
compare against a live TFLite interpreter additionally require TensorFlow.
