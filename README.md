# INT8 NPU

SystemVerilog 4x4 INT8 systolic-array NPU with Verilator and VCS simulation. The
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
sim/tb/unit/   unit tests grouped by compute/core/memory/dma
sim/tb/integration/ GEMM, tiling and operand-path tests
sim/tb/system/ end-to-end NPU and network tests
sim/tb/support/ reusable verification monitors
sim/filelists/ shared RTL list and per-test VCS input lists
sim/verdi/     Verdi command scripts
sim/golden/    small software golden models
compiler/      MNIST model compiler and artifact verification
scripts/sim/   simulation entrypoints
scripts/model/ model compilation, quantization and verification
scripts/analysis/ performance reports
docs/          EDA notes, repair report and layout reference
artifacts/     checked-in MNIST deployment images and golden tensors
models/        local pretrained model inputs (binary models are ignored)
build/         generated Verilator outputs, logs, dumps and waveforms
```

Generated build products, logs, waveforms, local datasets, Python virtual
environments and pretrained binary models are intentionally excluded from
Git. `make clean` removes only object/dependency files; it preserves logs, executables,
source snapshots and waveforms.

## Main regressions

The default regression compiles with Verilator `-Wall` and runs the top-level,
Conv patch, Conv2D and Conv+Pool tests:

```bash
make regression
```

The parameter-slot/PSUM/A-reuse stress test runs all three configurations:

```bash
bash scripts/sim/run_param_slot_stress.sh
```

Additional focused testbenches under `sim/tb/` cover the PE, matrix engine,
GEMM core/executor, DMA path, scheduler, postprocess, pooling, per-channel
parameters and experimental dataflows. They are independent verification
entrypoints even when they are not part of the default Make target.

## ResNet-8 end-to-end flow

Place the quantized model at
`models/resnet8/pretrainedResnet_quant.tflite`, then run:

```bash
bash scripts/sim/run_resnet8.sh
```

The compiler emits the DDR image and descriptor manifest below `build/`, and
the testbench executes the complete quantized graph: Conv, residual ADD,
global average pooling and FC. It can also dump final DDR for layer-by-layer
comparison with TFLite.

For the performance regression:

```bash
bash scripts/sim/run_resnet8_perf.sh
python3 scripts/analysis/report_resnet8_perf.py
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

- `scripts/model/compile_resnet8_tflite.py` compiles the supported quantized TFLite
  graph into descriptors, weights, parameters and a DDR image.
- `scripts/model/verify_resnet8.py`, `verify_resnet8_layers.py` and
  `verify_resnet8_cifar10.py` compare RTL results with the TFLite reference.
- `scripts/model/audit_resnet8_quant.py`, `check_tflite_kernel.py` and
  `experiment_requant_precision.py` are standalone quantization/debug tools.
- `compiler/` contains the earlier MNIST compiler, contract checks and Python
  regression suite; see `compiler/README.md` for its artifact ABI.

The ResNet-8 flow requires Python packages `numpy` and `tflite`; scripts that
compare against a live TFLite interpreter additionally require TensorFlow.

## VCS learning and repair regression

Run these commands from the repository root:

```bash
make vcs-pe
make vcs-pe-wave
bash scripts/sim/run_vcs.sh gemm_core_tb
make vcs-regression
```

`run_vcs.sh` reads the selected test's filelist, compiles it, then runs `simv`.
For example, `gemm_core_tb` uses `sim/filelists/vcs/gemm_core_tb.f`. Shared RTL
is listed in `sim/filelists/rtl.f`; the PE and GEMM Core examples list their
smaller inputs directly. PE waveform options and Verdi PLI paths are in
`sim/filelists/vcs/pe_wave_tb.f`.

Each run writes `compile.log` and `simulation.log` under
`build/vcs/<top>/<YYYYMMDD_HHMMSS>/`. Read the testbench's results in
`simulation.log`. Optional arguments after the top name are passed to VCS,
for example `-pvalue+gemm_core_tb.ROWS=2`.

The current GEMM datapath supports signed INT8 inputs and INT32 accumulators;
unsupported width overrides fail explicitly. Rectangular arrays and independent
A/B buffer counts have focused tests, while the model compiler remains restricted
to its audited default NPU configuration.

See [layout and naming](docs/reference/project_layout.md),
[path migration map](docs/reference/path_migration.json),
[retired scripts](docs/reference/retired_scripts.md),
[repair status](docs/code_audit.md), and
[EDA learning notes](docs/eda_learning_notes.md). Historical results under `build/`
are retained; their recorded source paths describe the original run.

## Output-buffer experiment

The output result buffer uses a fixed ping-pong order with two bank pointers,
without a separate ready FIFO or free-bank search. Its 103-line implementation
keeps the earlier double-buffer cycle counts in the measured cases.
See [the performance comparison and manual commands](docs/validation/output_buffer_comparison.md).

`sim/tb/integration/gemm_output_tb.sv` provides an 8x8 self-checking workload
with runtime K, output-format, A-reuse and write-delay controls. These are
simulator arguments; the VCS runner remains unchanged.
