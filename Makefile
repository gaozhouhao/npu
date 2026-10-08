
VERILATOR ?= verilator
BUILD_DIR ?= build
VFLAGS := --binary --timing --assert --trace -Wall -Wno-TIMESCALEMOD

MEMORY_SRCS := \
	rtl/memory/sram_model.sv \
	rtl/memory/operand_buffer.sv \
	rtl/memory/scratchpad.sv \
	rtl/memory/operand_loader.sv \
	rtl/memory/buffer_manager.sv

DMA_SRCS := \
	rtl/dma/axi_read_master.sv \
	rtl/dma/axi_write_master.sv \
	rtl/dma/axi_read_mux.sv \
	rtl/dma/strided_read_engine.sv \
	rtl/dma/operand_read_dma.sv \
	rtl/dma/read_request_arbiter.sv \
	rtl/dma/gemm_read_path.sv \
	rtl/dma/conv_patch_loader.sv \
	rtl/dma/postprocess_param_loader.sv \
	rtl/dma/c_write_dma.sv

COMPUTE_SRCS := \
	rtl/compute/pe.sv \
	rtl/compute/input_skew.sv \
	rtl/compute/systolic_array.sv \
	rtl/compute/matrix_engine.sv \
	rtl/compute/postprocess_unit.sv \
	rtl/compute/pool2d_engine.sv

CORE_SRCS := \
	rtl/core/matrix_controller.sv \
	rtl/core/gemm_core.sv \
	rtl/core/tile_scheduler.sv \
	rtl/core/gemm_address_generator.sv \
	rtl/core/gemm_executor.sv \
	rtl/core/command_frontend.sv \
	rtl/core/npu_top.sv

NPU_SRCS := $(MEMORY_SRCS) $(DMA_SRCS) $(COMPUTE_SRCS) $(CORE_SRCS)

.PHONY: all npu_top conv2d conv_patch cnn_pool regression clean
all: npu_top

npu_top:
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD_DIR)/npu_top \
		--top-module npu_top_tb $(NPU_SRCS) sim/tb/npu_top_tb.sv
	./$(BUILD_DIR)/npu_top/Vnpu_top_tb

conv2d:
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD_DIR)/conv2d \
		--top-module conv2d_npu_tb $(NPU_SRCS) sim/tb/conv2d_npu_tb.sv
	./$(BUILD_DIR)/conv2d/Vconv2d_npu_tb

conv_patch:
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD_DIR)/conv_patch \
		--top-module conv_patch_loader_tb \
		rtl/memory/operand_loader.sv rtl/dma/conv_patch_loader.sv \
		sim/tb/conv_patch_loader_tb.sv
	./$(BUILD_DIR)/conv_patch/Vconv_patch_loader_tb

cnn_pool:
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD_DIR)/cnn_pool \
		--top-module cnn_pool_npu_tb $(NPU_SRCS) sim/tb/cnn_pool_npu_tb.sv
	./$(BUILD_DIR)/cnn_pool/Vcnn_pool_npu_tb

regression: npu_top conv_patch conv2d cnn_pool

clean:
	rm -rf $(BUILD_DIR)
