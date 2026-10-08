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
# GEMM core
# ================================================================

CORE_SRCS := \
	rtl/core/matrix_controller.sv \
	rtl/core/gemm_core.sv \
	rtl/core/tile_scheduler.sv \
	rtl/core/gemm_address_generator.sv \
	rtl/core/gemm_executor.sv


# ================================================================
# Common GEMM RTL
# ================================================================

GEMM_RTL_SRCS := \
	$(MEMORY_SRCS) \
	$(DMA_SRCS) \
	$(COMPUTE_SRCS) \
	$(CORE_SRCS)


# ================================================================
# GEMM executor TB
# ================================================================

GEMM_EXECUTOR_SRCS := \
	$(GEMM_RTL_SRCS) \
	sim/tb/gemm_executor_tb.sv


# ================================================================
# NPU top RTL / TB
# ================================================================

NPU_TOP_SRCS := \
	$(GEMM_RTL_SRCS) \
	rtl/dma/axi_read_mux.sv \
	rtl/core/command_frontend.sv \
	rtl/core/npu_top.sv \
	sim/tb/npu_top_tb.sv


# ================================================================
# Default
# ================================================================

.PHONY: all

all: npu_top


# ================================================================
# Double-buffer GEMM regression
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
# Single vs double comparison
# ================================================================

.PHONY: gemm_executor_compare

gemm_executor_compare:
	$(MAKE) gemm_executor_sb
	$(MAKE) gemm_executor_db


# ================================================================
# Descriptor-driven NPU integration test
# ================================================================

.PHONY: npu_top

npu_top:
	mkdir -p $(BUILD_DIR)/npu_top
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/npu_top \
		--top-module npu_top_tb \
		$(NPU_TOP_SRCS)
	./$(BUILD_DIR)/npu_top/Vnpu_top_tb


# ================================================================
# Regression
# ================================================================

.PHONY: regression

regression:
	$(MAKE) gemm_executor_sb
	$(MAKE) gemm_executor_db
	$(MAKE) npu_top


# ================================================================
# Clean
# ================================================================

.PHONY: clean

clean:
	rm -rf $(BUILD_DIR)


# ================================================================
# Help
# ================================================================

.PHONY: help

help:
	@echo "Targets:"
	@echo "  make npu_top"
	@echo "      Descriptor-driven NPU end-to-end test"
	@echo ""
	@echo "  make gemm_executor_db"
	@echo "      Double-buffer GEMM regression"
	@echo ""
	@echo "  make gemm_executor_sb"
	@echo "      Single-buffer baseline"
	@echo ""
	@echo "  make gemm_executor_compare"
	@echo "      Run single/double comparison"
	@echo ""
	@echo "  make regression"
	@echo "      Run all current integration tests"
	@echo ""
	@echo "  make clean"