SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

SIM ?= vcs
TEST ?= npu_top_tb
CONFIG ?= default
BUILD_DIR ?= build
RUN_DIR ?= $(BUILD_DIR)/$(SIM)/$(TEST)/$(CONFIG)
VCS ?= vcs
VERILATOR ?= verilator
# Keep legacy model commands usable on this host without changing system Python.
PYTHON ?= $(if $(shell command -v python3 2>/dev/null),python3,$(if $(wildcard $(CURDIR)/build/resnet8-compat/runtime/bin/python),$(CURDIR)/build/resnet8-compat/runtime/bin/python,python3))
FC_PYTHON ?= python
DC ?= dc_shell
LC ?= lc_shell
TMAX ?= tmax
JOBS ?= 4
DEFINES ?=
PARAMS ?=
COMPILE_ARGS ?=
RUN_ARGS ?=
WAVE ?= 0
VERDI_HOME ?= /home/synopsys/verdi/Verdi_O-2018.09-SP2

# Lesson 1: keep UVM separate from the existing module-based testbenches.
UVM_TEST ?= pe_smoke_test
UVM_VERBOSITY ?= UVM_MEDIUM
UVM_WAVE ?= 0
UVM_RUN_DIR ?= $(BUILD_DIR)/vcs/pe_uvm/$(CONFIG)
UVM_RUN_ABS := $(abspath $(UVM_RUN_DIR))
UVM_PE_DIR := $(abspath sim/uvm/pe)
UVM_PE_SRCS := $(abspath rtl/compute/gemm_pe.sv) \
	$(UVM_PE_DIR)/pe_if.sv $(UVM_PE_DIR)/pe_pkg.sv $(UVM_PE_DIR)/pe_uvm_tb.sv

# All RTL is listed once. Testbench and shared verification sources are separate.
RTL_SRCS := $(shell cat sim/filelists/rtl.f)
TB_SRC := $(shell find sim/tb -type f -name '$(TEST).sv')
ifeq ($(TEST),gemm_pe_wave_tb)
TB_SRC += sim/tb/unit/compute/gemm_pe_tb.sv
endif
SUPPORT_SRCS := $(wildcard sim/tb/support/*.sv)
SIM_SRCS := $(abspath $(RTL_SRCS) $(SUPPORT_SRCS) $(TB_SRC))
RUN_ABS := $(abspath $(RUN_DIR))
RUN_CWD ?= $(RUN_ABS)
EDA_ENV = NPU_BUILD_DIR="$(abspath $(BUILD_DIR))" NPU_PDK_ROOT="$(PDK_ROOT)"

ifeq ($(SIM),vcs)
SIM_EXE := $(RUN_ABS)/simv
SIM_COMPILE = $(VCS) -full64 -sverilog -timescale=1ns/1ps \
	-top $(TEST) $(SIM_SRCS) $(addprefix +define+,$(DEFINES)) \
	$(foreach p,$(PARAMS),-pvalue+$(TEST).$(p)) \
	$(if $(filter 1,$(WAVE)),-debug_access+all -P $(VERDI_HOME)/share/PLI/VCS/linux64/novas.tab $(VERDI_HOME)/share/PLI/VCS/linux64/pli.a) \
	-Mdir=$(RUN_ABS)/csrc -o $(SIM_EXE) -l $(RUN_ABS)/compile.log $(COMPILE_ARGS)
else ifeq ($(SIM),verilator)
SIM_EXE := $(RUN_ABS)/V$(TEST)
SIM_COMPILE = $(VERILATOR) --binary --timing --assert --trace \
	-Wall -Wno-TIMESCALEMOD -j $(JOBS) --top-module $(TEST) \
	--Mdir $(RUN_ABS) $(addprefix -D,$(DEFINES)) \
	$(addprefix -G,$(PARAMS)) $(SIM_SRCS) $(COMPILE_ARGS) \
	2>&1 | tee $(RUN_ABS)/compile.log
else
$(error SIM must be vcs or verilator)
endif

.PHONY: help list-tests compile test regression tail-check fusion-check pool-fifo-check fc-pool-check fc-alignment-check parameter-check stress wave uvm-pe uvm-pe-compile \
	mnist mnist-all mnist-fused resnet8-model resnet8 resnet8-perf resnet8-benchmark compiler-test compiler-check \
	resnet50-prepare resnet50-model resnet50-reference resnet50-benchmark resnet50-compare resnet50-readpath-benchmark \
	synth synth-hold sram-lib sram-generate dft-precheck dft atpg atpg-resume \
	atpg-smoke mbist mbist-sim clean

help:
	@printf '%s\n' \
	  'make test TEST=npu_top_tb [SIM=vcs|verilator]' \
	  'make regression            Core, DMA, Conv, pooling and top-level checks' \
	  'make tail-check            Logical M/N/K tails, masked writes and Conv chaining' \
	  'make fusion-check          Streaming pool and fused/unfused Conv comparison' \
	  'make pool-fifo-check       FIFO capacity, independent writeback and completion checks' \
	  'make fc-pool-check         FC reshape coordinates and streaming MaxPool comparison' \
	  'make fc-alignment-check    FC software packing, hardware output and logical cropping' \
	  'make parameter-check       Rectangular and 1x1 array configurations' \
	  'make stress                Output/parameter reuse and dataflow checks' \
	  'make wave                  PE FSDB/VCD waveform (VCS + Verdi)' \
	  'make uvm-pe                First UVM lesson: one PE, directed checks (VCS)' \
	  'make uvm-pe UVM_WAVE=1     Also write pe_uvm.vcd; see docs/uvm_pe_tutorial.md' \
	  'make mnist | mnist-all     Checked-in MNIST inference artifacts' \
	  'make mnist-fused           Four MNIST images with on-chip Conv/MaxPool fusion' \
	  'make resnet8 | resnet8-perf MODEL=path/to/model.tflite' \
	  'make resnet8-benchmark      Same-input baseline/current integer correctness and performance' \
	  'make compiler-check        Shared ABI, ONNX, legacy compatibility and residual graph RTL' \
	  'make resnet50-prepare      Normalize real ResNet-50 and emit a calibration template' \
	  'make resnet50-benchmark    Full real-weight integer workload; no classification accuracy claim' \
	  'make resnet50-compare      Matched baseline/current full-network performance comparison' \
	  'make resnet50-readpath-benchmark  Matched cache/prefetch ablation; reuses prepared model/goldens' \
	  'make synth [DESIGN=npu|gemm_pe] Synthesis using local process libraries' \
	  'make dft-precheck | dft | atpg | atpg-smoke | mbist | mbist-sim' \
	  'make list-tests            Available testbench names' \
	  'PARAMS="ROWS=2 COLS=3" DEFINES="NPU_PERF_ENABLE" RUN_ARGS="+K=17"' \
	  'COMPILE_ARGS adds simulator options; CONFIG selects a build directory.'

list-tests:
	@find sim/tb -type f -name '*_tb.sv' -printf '%f\n' | sed 's/\.sv$$//' | sort

compile:
	@test -n "$(TB_SRC)" || { echo "Unknown testbench: $(TEST). Run make list-tests." >&2; exit 1; }
	@mkdir -p "$(RUN_ABS)"
	cd "$(RUN_ABS)" && $(SIM_COMPILE)

test: compile
	cd "$(RUN_CWD)" && $(SIM_EXE) +NPU_DATA_ROOT=$(CURDIR)/artifacts/npu $(RUN_ARGS) | tee "$(RUN_ABS)/simulation.log"
	@! grep -E '(^Fatal:|^Error:|^FAIL|TEST FAIL|TEST_FAIL)' "$(RUN_ABS)/simulation.log"
	@grep -Eiq 'PASS|RESNET8 NPU FINISHED' "$(RUN_ABS)/simulation.log"

# Each selected test adds a distinct functional check. Model files are optional.
REGRESSION_TESTS := gemm_pe_tb gemm_array_tb gemm_cycle_controller_tb \
	operand_bank_controller_tb operand_packer_tb operand_path_tb gemm_postprocess_tb \
	gemm_tile_scheduler_tb gemm_tile_scheduler_early_done_tb gemm_tile_order_multik_tb gemm_tile_order_pool_channel_tb result_param_buffer_tb \
	gemm_tile_compute_tb npu_gemm_engine_tb gemm_dma_integration_tb gemm_output_tb \
	npu_top_tb conv_patch_reader_tb result_write_dma_tb conv2d_npu_tb cnn_pool_npu_tb \
	cnn_pool_per_channel_npu_tb cnn_pool_global_avg_npu_tb pool2d_global_avg_tb \
	stream_maxpool2x2_tb pool_result_dma_tb pool_window_buffer_tb pool_coordinate_mapper_tb conv_pool_fused_npu_tb fc_pool_fused_npu_tb tail_tiles_npu_tb pool2d_configurable_tb maxpool_padding_npu_tb npu_command_reader_tb
regression:
	@$(foreach t,$(REGRESSION_TESTS),$(MAKE) --no-print-directory test TEST=$(t) &&) true

RESNET50_ONNX ?= build/nvidia_reference_models/resnet50/resnet50_v1.onnx
RESNET50_OUT ?= $(BUILD_DIR)/resnet50-compiler
resnet50-prepare:
	$(FC_PYTHON) compiler/compile_onnx.py prepare --model "$(RESNET50_ONNX)" --out "$(RESNET50_OUT)"

RESNET50_BENCH_DIR ?= $(BUILD_DIR)/resnet50-benchmark
RESNET50_MODEL_DIR ?= $(RESNET50_BENCH_DIR)/model
RESNET50_CHECK_DIR ?= $(RESNET50_BENCH_DIR)/check
RESNET50_INPUT_SEED ?= 8
RESNET50_BENCH_SCALE ?= 0.0625
BENCH_BASELINE_REF ?= 9d3ccce
BENCH_CANDIDATE_REF ?= HEAD
DDR_WR_LATENCY ?= 0
resnet50-model:
	$(PYTHON) compiler/compile_onnx.py compile --model "$(RESNET50_ONNX)" \
		--out "$(RESNET50_MODEL_DIR)" --benchmark-only \
		--benchmark-scale $(RESNET50_BENCH_SCALE) --input-seed $(RESNET50_INPUT_SEED)

resnet50-reference: resnet50-model
	$(PYTHON) scripts/model/run_graph_model.py prepare \
		--package "$(RESNET50_MODEL_DIR)" --out "$(RESNET50_CHECK_DIR)"

resnet50-benchmark: resnet50-model
	$(PYTHON) scripts/model/run_graph_model.py all \
		--package "$(RESNET50_MODEL_DIR)" --out "$(RESNET50_CHECK_DIR)" \
		--source-ref "$(BENCH_CANDIDATE_REF)" --label current \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)

resnet50-compare: resnet50-reference
	$(PYTHON) scripts/model/run_graph_model.py run --package "$(RESNET50_MODEL_DIR)" \
		--out "$(RESNET50_CHECK_DIR)" --source-ref "$(BENCH_BASELINE_REF)" --label baseline \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/run_graph_model.py check --package "$(RESNET50_MODEL_DIR)" \
		--out "$(RESNET50_CHECK_DIR)" --label baseline \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/run_graph_model.py run --package "$(RESNET50_MODEL_DIR)" \
		--out "$(RESNET50_CHECK_DIR)" --source-ref "$(BENCH_CANDIDATE_REF)" --label current \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/run_graph_model.py check --package "$(RESNET50_MODEL_DIR)" \
		--out "$(RESNET50_CHECK_DIR)" --label current \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/analysis/compare_graph_benchmarks.py \
		--baseline "$(RESNET50_CHECK_DIR)/baseline-report.json" \
		--current "$(RESNET50_CHECK_DIR)/current-report.json" --out "$(RESNET50_CHECK_DIR)/comparison.json"

RESNET50_READPATH_DIR ?= $(BUILD_DIR)/resnet50-readpath-benchmark
RESNET50_READPATH_REF ?= f7419986f24fb7a2ba9902eb5e451e147d6b7abc
resnet50-readpath-benchmark:
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py prepare \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)"
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py run \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)" \
		--source-ref "$(RESNET50_READPATH_REF)" --variant baseline \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py check \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)" --variant baseline \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py run \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)" \
		--source-ref "$(RESNET50_READPATH_REF)" --variant optimized \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py check \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)" --variant optimized \
		--read-latency $(DDR_RD_LATENCY) --write-latency $(DDR_WR_LATENCY)
	$(PYTHON) scripts/model/benchmark_resnet50_readpath.py compare \
		--package "$(RESNET50_MODEL_DIR)" --reference "$(RESNET50_CHECK_DIR)" --out "$(RESNET50_READPATH_DIR)"

compiler-check:
	$(FC_PYTHON) compiler/test_target_compat.py
	$(FC_PYTHON) compiler/test_onnx_frontend.py
	$(FC_PYTHON) compiler/test_graph_compiler.py
	$(FC_PYTHON) compiler/test_reference_int8.py
	$(FC_PYTHON) compiler/test_resnet8_compat.py
	$(FC_PYTHON) compiler/test_fc_layout.py
	$(FC_PYTHON) compiler/test_fc_pool.py
	$(FC_PYTHON) compiler/test_pool_channel_tiling.py
	$(FC_PYTHON) compiler/check_graph_compiler.py generate --out "$(BUILD_DIR)/compiler-graph-check"
	$(MAKE) test TEST=resnet8_npu_tb CONFIG=compiler-graph RUN_ARGS="$$($(FC_PYTHON) compiler/check_graph_compiler.py rtl-args --out '$(BUILD_DIR)/compiler-graph-check')"
	$(FC_PYTHON) compiler/check_graph_compiler.py check --out "$(BUILD_DIR)/compiler-graph-check"

tail-check:
	$(FC_PYTHON) compiler/test_pool_channel_tiling.py
	$(MAKE) test TEST=result_write_dma_tb CONFIG=tails-cols4 PARAMS="COLS=4"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=tails-cols8 PARAMS="COLS=8"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=tails-1x4 PARAMS="ROWS=1 COLS=4"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=tails-3x5 PARAMS="ROWS=3 COLS=5"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=cols4 PARAMS="COLS=4"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=cols8 PARAMS="COLS=8"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=rows3-cols4 PARAMS="ROWS=3 COLS=4"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=rows8-cols4 PARAMS="ROWS=8 COLS=4"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=k24 PARAMS="K_TILE_SIZE=24"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=fused-tail-cols4 PARAMS="COLS=4 POOL_LINE_WORDS=14 FUSED_ONLY=1"
	$(MAKE) test TEST=tail_tiles_npu_tb CONFIG=fused-tail-cols8 PARAMS="COLS=8 POOL_LINE_WORDS=28 FUSED_ONLY=1"

fc-alignment-check:
	$(FC_PYTHON) compiler/test_fc_layout.py
	@for fc_case in resnet50 small-int8 resnet50-repeat; do \
	  $(FC_PYTHON) scripts/model/check_fc_alignment.py generate --case $$fc_case --out $(BUILD_DIR)/fc-alignment/$$fc_case; \
	  $(MAKE) --no-print-directory test TEST=fc_alignment_npu_tb CONFIG=$$fc_case RUN_ARGS="+CASE_DIR=$(abspath $(BUILD_DIR))/fc-alignment/$$fc_case"; \
	  $(FC_PYTHON) scripts/model/check_fc_alignment.py check --out $(BUILD_DIR)/fc-alignment/$$fc_case; \
	done

fc-pool-check:
	$(FC_PYTHON) compiler/test_fc_pool.py
	$(MAKE) test TEST=pool_window_buffer_tb
	$(MAKE) test TEST=pool_coordinate_mapper_tb
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=fused-fc
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=channels12 PARAMS="RESHAPE_C=12"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=overlap PARAMS="RESHAPE_H=3 RESHAPE_W=3 POOL_SH=1 POOL_SW=1"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=cols8 PARAMS="COLS=8 RESHAPE_C=8"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=cols8-channels16 PARAMS="COLS=8 RESHAPE_C=16 K=8 WRITE_RESPONSE_DELAY=50 EXPECT_POOL_BACKPRESSURE=1"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=gap-tail PARAMS="RESHAPE_H=6 RESHAPE_W=6 POOL_SH=3 POOL_SW=3 K=8 WRITE_RESPONSE_DELAY=50 EXPECT_POOL_BACKPRESSURE=1"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=single-k PARAMS="K=8"
	$(MAKE) test TEST=fc_pool_fused_npu_tb CONFIG=padding-rows PARAMS="REPEAT_INPUT_ROW=0"
	@set -e; for fc_pool_case in per-channel per-tensor overlap; do \
	  $(FC_PYTHON) scripts/model/check_fc_pool.py generate --case $$fc_pool_case --out $(BUILD_DIR)/fc-pool/$$fc_pool_case; \
	  $(MAKE) --no-print-directory test TEST=fc_alignment_npu_tb CONFIG=fc-pool-$$fc_pool_case RUN_ARGS="+CASE_DIR=$(abspath $(BUILD_DIR))/fc-pool/$$fc_pool_case"; \
	  $(FC_PYTHON) scripts/model/check_fc_pool.py check --out $(BUILD_DIR)/fc-pool/$$fc_pool_case; \
	done

pool-fifo-check:
	$(MAKE) test TEST=pool_result_dma_tb CONFIG=fifo1 PARAMS="FIFO_DEPTH=1"
	$(MAKE) test TEST=pool_result_dma_tb CONFIG=fifo3 PARAMS="FIFO_DEPTH=3"
	$(MAKE) test TEST=pool_result_dma_tb CONFIG=fifo16 PARAMS="FIFO_DEPTH=16"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=fifo1-cols4 PARAMS="COLS=4 OUTPUT_FIFO_DEPTH=1"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=fifo3-cols8 PARAMS="COLS=8 OUTPUT_FIFO_DEPTH=3"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=fifo16-cols12 PARAMS="COLS=12 OUTPUT_FIFO_DEPTH=16"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=fifo-overlap PARAMS="WRITE_RESPONSE_DELAY=2000 POOL_OUTPUT_FIFO_DEPTH=3 EXPECT_POOL_OVERLAP=1 EXPECT_POOL_BACKPRESSURE=1"

fusion-check:
	$(MAKE) test TEST=pool_window_buffer_tb CONFIG=cols4 PARAMS="COLS=4"
	$(MAKE) test TEST=pool_window_buffer_tb CONFIG=cols8 PARAMS="COLS=8"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=cols4 PARAMS="COLS=4"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=cols8 PARAMS="COLS=8"
	$(MAKE) test TEST=stream_maxpool2x2_tb CONFIG=cols12 PARAMS="COLS=12"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=fused-system
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=width6-rows3 PARAMS="OUT_W=6 ROWS=3"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=cols8 PARAMS="COLS=8"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=tile-crosses-row PARAMS="OUT_H=6 ROWS=3"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=overlap PARAMS="POOL_SH=1 POOL_SW=1"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=kernel3-stride2 PARAMS="OUT_H=6 ROWS=3 POOL_KH=3 POOL_KW=3"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=asymmetric PARAMS="OUT_W=9 ROWS=3 POOL_KH=3 POOL_KW=2 POOL_SH=1 POOL_SW=3"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=stride5-gaps PARAMS="OUT_H=9 OUT_W=9 ROWS=3 POOL_SH=5 POOL_SW=3"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=capacity-fallback PARAMS="POOL_SH=1 POOL_SW=1 LINE_WORDS=1 CAPACITY_FALLBACK=1"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=channel-tiling PARAMS="COUT=12 LINE_WORDS=16"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=channel-tiling-overlap PARAMS="COUT=12 POOL_SH=1 POOL_SW=1 LINE_WORDS=16 WRITE_RESPONSE_DELAY=30"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=channel-tiling-cols8 PARAMS="COUT=24 COLS=8 LINE_WORDS=32"
	$(MAKE) test TEST=conv_pool_fused_npu_tb CONFIG=full-buffer-stall PARAMS="POOL_SH=1 POOL_SW=1 WRITE_RESPONSE_DELAY=2000 POOL_OUTPUT_FIFO_DEPTH=1 REQUIRE_FULL_BUFFER=1"
	$(MAKE) test TEST=pool2d_configurable_tb

parameter-check:
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=2x3 PARAMS="ROWS=2 COLS=3 A_BUFFER_COUNT=2 B_BUFFER_COUNT=1"
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=3x2 PARAMS="ROWS=3 COLS=2 A_BUFFER_COUNT=1 B_BUFFER_COUNT=2"
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=1x1 PARAMS="ROWS=1 COLS=1"
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=depth1 PARAMS="ROWS=4 COLS=3 DEPTH=1 A_BUFFER_COUNT=2 B_BUFFER_COUNT=1"
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=int4 PARAMS="DATA_WIDTH=4 ACC_WIDTH=24 MEM_WORD_WIDTH=32"
	$(MAKE) test TEST=gemm_tile_compute_tb CONFIG=int16 PARAMS="DATA_WIDTH=16 ACC_WIDTH=48 MEM_WORD_WIDTH=64"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=cols2 PARAMS="COLS=2"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=cols3 PARAMS="COLS=3"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=cols4 PARAMS="COLS=4"
	$(MAKE) test TEST=result_write_dma_tb CONFIG=cols5 PARAMS="COLS=5"

stress:
	$(MAKE) test TEST=param_slot_stress_npu_tb
	$(MAKE) test TEST=param_slot_stress_npu_tb CONFIG=a-reuse RUN_ARGS="+A_REUSE=1"
	$(MAKE) test TEST=gemm_output_tb CONFIG=a-reuse RUN_ARGS="+K=260 +A_REUSE=1 +INT8=1 +WRITE_GAP=3"

wave:
	$(MAKE) test SIM=vcs TEST=gemm_pe_wave_tb WAVE=1

# VCS supplies the real UVM 1.2 library and its DPI support.
uvm-pe-compile:
	@mkdir -p "$(UVM_RUN_ABS)"
	cd "$(UVM_RUN_ABS)" && $(VCS) -full64 -sverilog -timescale=1ns/1ps \
		-ntb_opts uvm-1.2 +incdir+$(UVM_PE_DIR) -top pe_uvm_tb $(UVM_PE_SRCS) \
		$(addprefix +define+,$(DEFINES)) $(if $(filter 1,$(UVM_WAVE)),-debug_access+all) \
		-Mdir=$(UVM_RUN_ABS)/csrc -o $(UVM_RUN_ABS)/simv \
		-l $(UVM_RUN_ABS)/compile.log $(COMPILE_ARGS)

uvm-pe: uvm-pe-compile
	cd "$(UVM_RUN_ABS)" && ./simv +UVM_TESTNAME=$(UVM_TEST) \
		+UVM_VERBOSITY=$(UVM_VERBOSITY) $(if $(filter 1,$(UVM_WAVE)),+UVM_WAVE) \
		$(RUN_ARGS) | tee simulation.log
	@grep -Eq '\[TEST_PASS\]' "$(UVM_RUN_ABS)/simulation.log"
	@grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$$' "$(UVM_RUN_ABS)/simulation.log"
	@grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0[[:space:]]*$$' "$(UVM_RUN_ABS)/simulation.log"
	@! grep -Eq '^(Fatal:|Error:)' "$(UVM_RUN_ABS)/simulation.log"

mnist:
	$(MAKE) test TEST=mnist_npu_tb DEFINES="$(DEFINES) NPU_PERF_ENABLE" RUN_ARGS="+IMAGE=0 $(RUN_ARGS)"

mnist-all:
	$(MAKE) test TEST=mnist_npu_tb DEFINES="$(DEFINES) NPU_PERF_ENABLE"

mnist-fused:
	$(MAKE) test TEST=mnist_npu_tb CONFIG=fused-model \
		DEFINES="$(DEFINES) NPU_PERF_ENABLE" RUN_ARGS="+FUSE_CONV_POOL=1 $(RUN_ARGS)"

compiler-test:
	$(PYTHON) -m unittest discover -s compiler -p 'test_*.py'

MODEL ?= models/resnet8/pretrainedResnet_quant.tflite
DATAFLOW ?= auto
MODEL_DIR ?= $(BUILD_DIR)/resnet8_model
resnet8-model:
	$(PYTHON) scripts/model/compile_resnet8_tflite.py "$(MODEL)" --output "$(MODEL_DIR)" --dataflow "$(DATAFLOW)"
	$(PYTHON) scripts/model/optimize_dataflow.py --model-dir "$(MODEL_DIR)" --dataflow "$(DATAFLOW)"

# Keep manifest decoding here: no generated shell environment or helper script.
RESNET_ARGS = $(shell $(PYTHON) -c 'import json; m=json.load(open("$(MODEL_DIR)/manifest.json")); print("+DESC_BASE=%x +DESC_COUNT=%d +LOGITS_BASE=%x" % (m["descriptor_addr"], m["descriptor_count"], m["logits_addr"]))')
resnet8: resnet8-model
	$(MAKE) test TEST=resnet8_npu_tb RUN_ARGS="+DDR_HEX=$(abspath $(MODEL_DIR))/ddr.hex $(RESNET_ARGS) $(RUN_ARGS)"

resnet8-perf:
	$(MAKE) resnet8 MODEL_DIR=$(BUILD_DIR)/resnet8_perf/model \
		RUN_DIR=$(BUILD_DIR)/resnet8_perf DEFINES="$(DEFINES) NPU_PERF_ENABLE" \
		RUN_ARGS="+DDR_RD_LATENCY=$(DDR_RD_LATENCY) $(RUN_ARGS)"
	cp "$(BUILD_DIR)/resnet8_perf/simulation.log" "$(BUILD_DIR)/resnet8_perf/perf.log"
	$(PYTHON) scripts/analysis/report_resnet8_perf.py --dir "$(BUILD_DIR)/resnet8_perf"
DDR_RD_LATENCY ?= 20

RESNET8_BENCH_DIR ?= $(BUILD_DIR)/resnet8-benchmark
RESNET8_BENCH_ZERO ?= $(BUILD_DIR)/resnet8-compat/zero
RESNET8_BENCH_NONZERO ?= $(BUILD_DIR)/resnet8-compat/nonzero
resnet8-benchmark:
	$(PYTHON) scripts/model/benchmark_resnet8.py \
		--model-dir "zero=$(RESNET8_BENCH_ZERO)" \
		--model-dir "nonzero=$(RESNET8_BENCH_NONZERO)" \
		--zero-input zero --seeded-input nonzero=8 \
		--baseline-ref "$(BENCH_BASELINE_REF)" --current-ref "$(BENCH_CANDIDATE_REF)" \
		--ddr-read-latency $(DDR_RD_LATENCY) --output "$(RESNET8_BENCH_DIR)"

# EDA commands are explicit targets and use the existing local technology setup.
DESIGN ?= npu
synth:
	mkdir -p "$(BUILD_DIR)/dc/$(DESIGN)"
	cd "$(BUILD_DIR)/dc/$(DESIGN)" && $(EDA_ENV) $(DC) -f "$(CURDIR)/scripts/synth/$(DESIGN).tcl" | tee run.log

synth-hold:
	mkdir -p "$(BUILD_DIR)/dc/npu_hold"
	cd "$(BUILD_DIR)/dc/npu_hold" && $(EDA_ENV) $(DC) -f "$(CURDIR)/scripts/synth/npu_fix_hold.tcl" | tee run.log

sram-lib:
	mkdir -p "$(BUILD_DIR)/dc/sram_lib"
	cd "$(BUILD_DIR)/dc/sram_lib" && $(EDA_ENV) $(LC) -f "$(CURDIR)/scripts/synth/operand_sram_lib.tcl" | tee run.log

PDK_ROOT ?= /home/ICer/eda/pdk/tsmc28
SRAM_MACRO_DIR ?= $(PDK_ROOT)/Memory/macros/operand_32x64
MC_HOME ?= $(PDK_ROOT)/Memory/compilers/tsn28hpcp1prf_20120200_130a
sram-generate:
	mkdir -p "$(SRAM_MACRO_DIR)"
	cp scripts/synth/operand_32x64.txt "$(SRAM_MACRO_DIR)/"
	cd "$(SRAM_MACRO_DIR)" && MC_HOME="$(MC_HOME)" \
		PATH="$(PDK_ROOT)/Memory/compilers/MC2_2012.02.00.d/bin/Linux-64:$$PATH" \
		perl "$(MC_HOME)/tsn28hpcp1prf_130a.pl" \
		-file operand_32x64.txt -SVT -NonBWEB -NonBIST -NonSLP -NonSD

dft-precheck:
	mkdir -p "$(BUILD_DIR)/dft/npu_precheck"
	cd "$(BUILD_DIR)/dft/npu_precheck" && $(EDA_ENV) $(DC) -f "$(CURDIR)/scripts/dft/npu_precheck.tcl" | tee run.log

dft:
	mkdir -p "$(BUILD_DIR)/dft/npu_scan"
	cd "$(BUILD_DIR)/dft/npu_scan" && $(EDA_ENV) $(DC) -f "$(CURDIR)/scripts/dft/npu_insert_scan.tcl" | tee run.log

ATPG_DIR ?= $(BUILD_DIR)/atpg/npu
atpg:
	mkdir -p "$(ATPG_DIR)"
	cd "$(ATPG_DIR)" && $(EDA_ENV) $(TMAX) -shell -tcl "$(CURDIR)/scripts/atpg/npu_stuck_at.tcl" | tee run.log

atpg-resume:
	cd "$(ATPG_DIR)" && $(EDA_ENV) $(TMAX) -shell -tcl "$(CURDIR)/scripts/atpg/npu_resume_stuck_at.tcl" | tee resume.log

STDCELL_V ?= $(PDK_ROOT)/logic/tcbn28hpcplusbwp40p140_180b/verilog/tcbn28hpcplusbwp40p140.v
SRAM_V ?= $(SRAM_MACRO_DIR)/ts5n28hpcpsvta32x64m2f_130a/VERILOG/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.v
SYNOPSYS_TMAX ?= /home/synopsys/txs/O-2018.06-SP1
SCAN_NETLIST ?= $(BUILD_DIR)/dft/npu_scan/npu_scan.v
atpg-smoke:
	cd "$(ATPG_DIR)" && SYNOPSYS_TMAX="$(SYNOPSYS_TMAX)" \
		"$(SYNOPSYS_TMAX)/bin/stil2verilog" npu_stuck_at.stil npu_patterns_tb \
		-parallel 2 -first 0 -last 9 -tb_module_name npu_patterns_tb -replace -log stil2verilog.log
	cd "$(ATPG_DIR)" && $(VCS) -full64 -sverilog -timescale=1ns/1ps \
		+define+UNIT_DELAY +notimingcheck -debug_access+all -debug_region+cell \
		-top npu_patterns_tb "$(STDCELL_V)" "$(SRAM_V)" \
		"$(abspath $(SCAN_NETLIST))" npu_patterns_tb.v -o simv_patterns -l vcs_compile.log
	cd "$(ATPG_DIR)" && ./simv_patterns -l vcs_sim.log
	grep 'Simulation of 10 patterns completed with 0 mismatches' "$(ATPG_DIR)/vcs_sim.log"

MBIST_DIR ?= $(BUILD_DIR)/mbist/sram_probe
mbist:
	mkdir -p "$(MBIST_DIR)"
	cd "$(MBIST_DIR)" && $(EDA_ENV) $(DC) -f "$(CURDIR)/scripts/mbist/dc_sram_probe.tcl" | tee run.log

mbist-sim:
	cd "$(MBIST_DIR)" && $(VCS) -full64 -sverilog -timescale=1ns/1ps \
		+define+UNIT_DELAY +notimingcheck -top dw_mbist_sram_probe_tb \
		"$(STDCELL_V)" "$(SRAM_V)" mbist_mapped.v \
		"$(CURDIR)/sim/mbist/dw_mbist_sram_probe_tb.sv" -o simv -l vcs_compile.log
	cd "$(MBIST_DIR)" && ./simv -l vcs_sim.log
	grep 'PASS: DC DesignWare MBIST normal and injected-fault tests' "$(MBIST_DIR)/vcs_sim.log"

# Preserve reports, logs, generated models and waveforms for later inspection.
clean:
	find "$(BUILD_DIR)" -type f \( -name '*.o' -o -name '*.d' \) -delete
