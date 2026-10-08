VERILATOR ?= verilator

BUILD_DIR ?= build

VFLAGS := \
	--binary \
	--timing \
	--assert \
	--trace \
	-Wall \
	-Wno-TIMESCALEMOD


# ================================================================
# Memory
# ================================================================

MEMORY_SRCS := \
	rtl/memory/sram_model.sv \
	rtl/memory/operand_buffer.sv \
	rtl/memory/scratchpad.sv \
	rtl/memory/operand_loader.sv \
	rtl/memory/buffer_manager.sv


# ================================================================
# DMA
# ================================================================

DMA_SRCS := \
	rtl/dma/axi_read_master.sv \
	rtl/dma/axi_write_master.sv \
	rtl/dma/strided_read_engine.sv \
	rtl/dma/operand_read_dma.sv \
	rtl/dma/read_request_arbiter.sv \
	rtl/dma/gemm_read_path.sv \
	rtl/dma/c_write_dma.sv


# ================================================================
# Compute
# ================================================================

COMPUTE_SRCS := \
	rtl/compute/pe.sv \
	rtl/compute/input_skew.sv \
	rtl/compute/systolic_array.sv \
	rtl/compute/matrix_engine.sv


# ================================================================
# Core
# ================================================================

CORE_SRCS := \
	rtl/core/matrix_controller.sv \
	rtl/core/gemm_core.sv \
	rtl/core/tile_scheduler.sv \
	rtl/core/gemm_address_generator.sv \
	rtl/core/gemm_executor.sv


# ================================================================
# GEMM executor integration test
# ================================================================

GEMM_EXECUTOR_SRCS := \
	$(MEMORY_SRCS) \
	$(DMA_SRCS) \
	$(COMPUTE_SRCS) \
	$(CORE_SRCS) \
	sim/tb/gemm_executor_tb.sv


# ================================================================
# Default
#
# Current development configuration = double buffer.
# ================================================================

.PHONY: all

all: gemm_executor_db


# ================================================================
# Alias
# ================================================================

.PHONY: gemm_executor

gemm_executor: gemm_executor_db


# ================================================================
# Double-buffer test
#
# A bank0/bank1
# B bank0/bank1
#
# Expected:
#   functional PASS
#   DMA/compute overlap > 0
# ================================================================

.PHONY: gemm_executor_db

gemm_executor_db:
	mkdir -p $(BUILD_DIR)/gemm_executor_db
	$(VERILATOR) $(VFLAGS) \
		-GA_BUFFER_COUNT=2 \
		-GB_BUFFER_COUNT=2 \
		--Mdir $(BUILD_DIR)/gemm_executor_db \
		--top-module gemm_executor_tb \
		$(GEMM_EXECUTOR_SRCS)
	./$(BUILD_DIR)/gemm_executor_db/Vgemm_executor_tb


# ================================================================
# Single-buffer baseline
#
# Used only as the baseline for double-buffer comparison.
#
# Expected:
#   functional PASS
#   overlap is not required
# ================================================================

.PHONY: gemm_executor_sb

gemm_executor_sb:
	mkdir -p $(BUILD_DIR)/gemm_executor_sb
	$(VERILATOR) $(VFLAGS) \
		-GA_BUFFER_COUNT=1 \
		-GB_BUFFER_COUNT=1 \
		--Mdir $(BUILD_DIR)/gemm_executor_sb \
		--top-module gemm_executor_tb \
		$(GEMM_EXECUTOR_SRCS)
	./$(BUILD_DIR)/gemm_executor_sb/Vgemm_executor_tb


# ================================================================
# Run both baselines
# ================================================================

.PHONY: gemm_executor_compare

gemm_executor_compare:
	@echo ""
	@echo "========================================"
	@echo "Running single-buffer baseline"
	@echo "========================================"
	$(MAKE) gemm_executor_sb
	@echo ""
	@echo "========================================"
	@echo "Running double-buffer configuration"
	@echo "========================================"
	$(MAKE) gemm_executor_db


# ================================================================
# Clean only these integration builds.
#
# This deliberately does NOT delete the entire build/ directory,
# because other unit-test build products may exist there.
# ================================================================

.PHONY: clean-gemm-executor

clean-gemm-executor:
	rm -rf \
		$(BUILD_DIR)/gemm_executor_sb \
		$(BUILD_DIR)/gemm_executor_db


# ================================================================
# Help
# ================================================================

.PHONY: help

help:
	@echo "Available targets:"
	@echo ""
	@echo "  make gemm_executor_db"
	@echo "      Run double-buffer GEMM test"
	@echo ""
	@echo "  make gemm_executor_sb"
	@echo "      Run single-buffer baseline"
	@echo ""
	@echo "  make gemm_executor_compare"
	@echo "      Run single-buffer then double-buffer"
	@echo ""
	@echo "  make gemm_executor"
	@echo "      Alias for double-buffer test"
	@echo ""
	@echo "  make clean-gemm-executor"
	@echo "      Remove only GEMM executor build directories"