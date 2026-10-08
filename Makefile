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
	rtl/dma/axi_read_mux.sv \
	rtl/dma/strided_read_engine.sv \
	rtl/dma/operand_read_dma.sv \
	rtl/dma/read_request_arbiter.sv \
	rtl/dma/gemm_read_path.sv \
	rtl/dma/bias_loader.sv \
	rtl/dma/c_write_dma.sv


# ================================================================
# Compute
# ================================================================

COMPUTE_SRCS := \
	rtl/compute/pe.sv \
	rtl/compute/input_skew.sv \
	rtl/compute/systolic_array.sv \
	rtl/compute/matrix_engine.sv \
	rtl/compute/postprocess_unit.sv


# ================================================================
# Core
# ================================================================

CORE_SRCS := \
	rtl/core/matrix_controller.sv \
	rtl/core/gemm_core.sv \
	rtl/core/tile_scheduler.sv \
	rtl/core/gemm_address_generator.sv \
	rtl/core/gemm_executor.sv \
	rtl/core/command_frontend.sv \
	rtl/core/npu_top.sv


# ================================================================
# NPU integration test
# ================================================================

NPU_TOP_SRCS := \
	$(MEMORY_SRCS) \
	$(DMA_SRCS) \
	$(COMPUTE_SRCS) \
	$(CORE_SRCS) \
	sim/tb/npu_top_tb.sv


# ================================================================
# Default
# ================================================================

.PHONY: all

all: npu_top


# ================================================================
# Descriptor-driven NPU
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
	@echo "      Run descriptor-driven optional-Bias NPU integration test"
	@echo ""
	@echo "  make clean"
	@echo "      Remove build directory"