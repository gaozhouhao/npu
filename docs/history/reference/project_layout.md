# Project layout and naming

Code filenames use lowercase snake_case. A SystemVerilog file is named after its
primary module; a self-checking testbench uses `<design>_tb.sv`. Diagnostic probes
and reusable monitors use `_probe.sv` and `_monitor.sv` respectively. Existing RTL
module and port names are retained to preserve hierarchy references and interfaces.

```text
rtl/
  compute/             PE, systolic array and arithmetic engines
  core/                GEMM control, scheduling and NPU integration
  dma/                 AXI and data-transfer logic
  memory/              SRAM models, operand/result buffers and loaders
sim/
  tb/
    unit/compute/      Arithmetic unit tests and PE waveform wrapper
    unit/core/         Controller, scheduler and command unit tests
    unit/memory/       Loader and bank-manager unit tests
    unit/dma/          DMA-loader unit tests
    integration/       GEMM, tiling, operand-path and dataflow integration tests
    system/            NPU, network, stress tests and system diagnostic probes
    support/           Reusable verification monitors and AXI memory model
  filelists/rtl.f      Shared explicit RTL source list
  filelists/vcs/       Explicit per-test VCS inputs and options
  verdi/               Verdi command scripts
  golden/              Software reference models
  memory/              C++ simulation memory backend
scripts/
  sim/                 Simulation entrypoints
  model/               Model compilation, quantization and correctness tools
  analysis/            Performance-report tools
compiler/              MNIST deployment compiler and its source contract
artifacts/             Versioned deployment images and reference tensors
models/                Optional local model inputs (not required for unit tests)
docs/
  reference/           Naming rules and old-to-new path mapping
  eda_learning_notes.md Actual EDA experiments and explanations
  code_audit.md        Review findings and repair/validation status
build/                 Generated outputs, source snapshots, logs and waveforms
```

`docs/reference/path_migration.json` maps the 47 moved paths that remain in use.
Retired scripts and their replacements are recorded in
`docs/reference/retired_scripts.md`. Existing files whose names already follow
the convention keep their names. Model filenames and binary
artifact formats are external data contracts and are not cosmetically renamed.
Historical `build/` directories retain their original files and source paths.

## Entry points

Run from the repository root:

```bash
make vcs-pe
make vcs-pe-wave
bash scripts/sim/run_vcs.sh gemm_core_tb
make vcs-regression
```

The PE Make targets call `run_vcs.sh pe_tb` and `run_vcs.sh pe_wave_tb` directly;
the two redundant PE shell wrappers have been removed. One-time source migration
scripts have also been removed after confirming their changes are in the RTL.

`run_vcs.sh` accepts a top module followed by VCS compile options. Run it from
the repository root. It reads `sim/filelists/vcs/<top>.f`, compiles the inputs,
then runs `simv`. Shared RTL is listed in `sim/filelists/rtl.f`; the PE and GEMM
Core examples use smaller explicit lists. PE waveform options and Verdi PLI
paths are in `pe_wave_tb.f`.

Each run uses `build/vcs/<top>/<YYYYMMDD_HHMMSS>/` for compiler output,
`compile.log` and `simulation.log`. Read the testbench's result messages directly
in the simulation log. The runner does not generate source snapshots, Git/hash
records or a separate result summary.

`run_vcs_cleanup_regression.sh` lists the 16 functional configurations. The
parameter-slot stress script has three explicit Verilator compile/run sections:
baseline, PSUM and A reuse. It shares `sim/filelists/rtl.f` with VCS.

The Makefile retains the existing Verilator targets. `make clean` now removes only
`.o` and `.d` files below `BUILD_DIR`, using one `find` command. It retains
logs, waveforms, executables, source snapshots and other experimental evidence.
No cleanup is run automatically before a test.

Python model tools require Python 3 and their documented packages. Compiler
RTL-contract verification remains strict after migration.
