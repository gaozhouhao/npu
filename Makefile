VERILATOR := verilator

BUILD_DIR := build

# ============================================================
# Common Verilator flags
# ============================================================

VFLAGS := \
	--binary \
	--timing \
	--assert \
	--trace \
	-Wall \
	-Wno-TIMESCALEMOD


# ============================================================
# RTL source groups
# ============================================================

PE_RTL := \
	rtl/compute/pe.sv


MATRIX_RTL := \
	rtl/compute/pe.sv \
	rtl/compute/input_skew.sv \
	rtl/compute/systolic_array.sv \
	rtl/compute/matrix_engine.sv


CONTROLLER_RTL := \
	rtl/core/matrix_controller.sv


MEMORY_RTL := \
	rtl/memory/sram_model.sv \
	rtl/memory/operand_buffer.sv \
	rtl/memory/scratchpad.sv


GEMM_RTL := \
	$(MATRIX_RTL) \
	$(MEMORY_RTL) \
	$(CONTROLLER_RTL) \
	rtl/core/gemm_core.sv


# ============================================================
# Testbenches
# ============================================================

PE_TB := \
	sim/tb/pe_tb.sv

MATRIX_TB := \
	sim/tb/matrix_engine_tb.sv

CONTROLLER_TB := \
	sim/tb/matrix_controller_tb.sv

GEMM_TB := \
	sim/tb/gemm_core_tb.sv


# ============================================================
# Targets
# ============================================================

.PHONY: all test pe matrix controller gemm external_memory clean

all: test

test: pe matrix controller gemm


# ============================================================
# PE test
# ============================================================

pe:
	@echo "========================================"
	@echo "Running PE test"
	@echo "========================================"

	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/pe \
		--top-module pe_tb \
		$(PE_RTL) \
		$(PE_TB)

	./$(BUILD_DIR)/pe/Vpe_tb


# ============================================================
# Matrix engine test
# ============================================================

matrix:
	@echo "========================================"
	@echo "Running matrix engine test"
	@echo "========================================"

	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/matrix \
		--top-module matrix_engine_tb \
		$(MATRIX_RTL) \
		$(MATRIX_TB)

	./$(BUILD_DIR)/matrix/Vmatrix_engine_tb


# ============================================================
# Matrix controller test
# ============================================================

controller:
	@echo "========================================"
	@echo "Running matrix controller test"
	@echo "========================================"

	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/controller \
		--top-module matrix_controller_tb \
		$(CONTROLLER_RTL) \
		$(CONTROLLER_TB)

	./$(BUILD_DIR)/controller/Vmatrix_controller_tb


# ============================================================
# Integrated GEMM core test
# ============================================================

gemm:
	@echo "========================================"
	@echo "Running GEMM core integration test"
	@echo "========================================"

	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/gemm \
		--top-module gemm_core_tb \
		$(GEMM_RTL) \
		$(GEMM_TB)

	./$(BUILD_DIR)/gemm/Vgemm_core_tb




mn_tiling:
	mkdir -p $(BUILD_DIR)/mn_tiling
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/mn_tiling \
		--top-module mn_tiling_tb \
		$(GEMM_RTL) \
		sim/tb/mn_tiling_tb.sv
	./$(BUILD_DIR)/mn_tiling/Vmn_tiling_tb


buffer_manager:
	mkdir -p $(BUILD_DIR)/buffer_manager
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/buffer_manager \
		--top-module buffer_manager_tb \
		rtl/memory/buffer_manager.sv \
		sim/tb/buffer_manager_tb.sv
	./$(BUILD_DIR)/buffer_manager/Vbuffer_manager_tb



tile_scheduler:
	mkdir -p $(BUILD_DIR)/tile_scheduler
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/tile_scheduler \
		--top-module tile_scheduler_tb \
		rtl/core/tile_scheduler.sv \
		sim/tb/tile_scheduler_tb.sv
	./$(BUILD_DIR)/tile_scheduler/Vtile_scheduler_tb


operand_loader:
	mkdir -p $(BUILD_DIR)/operand_loader
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/operand_loader \
		--top-module operand_loader_tb \
		rtl/memory/operand_loader.sv \
		sim/tb/operand_loader_tb.sv
	./$(BUILD_DIR)/operand_loader/Voperand_loader_tb

operand_path:
	mkdir -p $(BUILD_DIR)/operand_path
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/operand_path \
		--top-module operand_path_tb \
		rtl/memory/sram_model.sv \
		rtl/memory/operand_buffer.sv \
		rtl/memory/buffer_manager.sv \
		rtl/memory/operand_loader.sv \
		sim/tb/operand_path_tb.sv
	./$(BUILD_DIR)/operand_path/Voperand_path_tb

command_frontend:
	mkdir -p $(BUILD_DIR)/command_frontend
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/command_frontend \
		--top-module command_frontend_tb \
		rtl/core/command_frontend.sv \
		sim/tb/command_frontend_tb.sv
	./$(BUILD_DIR)/command_frontend/Vcommand_frontend_tb

gemm_dma_integration:
	mkdir -p $(BUILD_DIR)/gemm_dma_integration
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/gemm_dma_integration \
		--top-module gemm_dma_integration_tb \
		rtl/memory/sram_model.sv \
		rtl/memory/operand_buffer.sv \
		rtl/memory/scratchpad.sv \
		rtl/memory/operand_loader.sv \
		rtl/dma/axi_read_master.sv \
		rtl/dma/strided_read_engine.sv \
		rtl/dma/operand_read_dma.sv \
		rtl/dma/read_request_arbiter.sv \
		rtl/dma/gemm_read_path.sv \
		rtl/compute/pe.sv \
		rtl/compute/input_skew.sv \
		rtl/compute/systolic_array.sv \
		rtl/compute/matrix_engine.sv \
		rtl/core/matrix_controller.sv \
		rtl/core/gemm_core.sv \
		sim/tb/gemm_dma_integration_tb.sv
	./$(BUILD_DIR)/gemm_dma_integration/Vgemm_dma_integration_tb


gemm_executor:
	mkdir -p $(BUILD_DIR)/gemm_executor
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(BUILD_DIR)/gemm_executor \
		--top-module gemm_executor_tb \
		rtl/memory/sram_model.sv \
		rtl/memory/operand_buffer.sv \
		rtl/memory/scratchpad.sv \
		rtl/memory/operand_loader.sv \
		rtl/memory/buffer_manager.sv \
		rtl/dma/axi_read_master.sv \
		rtl/dma/strided_read_engine.sv \
		rtl/dma/operand_read_dma.sv \
		rtl/dma/read_request_arbiter.sv \
		rtl/dma/gemm_read_path.sv \
		rtl/compute/pe.sv \
		rtl/compute/input_skew.sv \
		rtl/compute/systolic_array.sv \
		rtl/compute/matrix_engine.sv \
		rtl/core/matrix_controller.sv \
		rtl/core/gemm_core.sv \
		rtl/core/tile_scheduler.sv \
		rtl/core/gemm_address_generator.sv \
		rtl/core/gemm_executor.sv \
		rtl/dma/axi_write_master.sv \
		rtl/dma/c_write_dma.sv \
		sim/tb/gemm_executor_tb.sv
	./$(BUILD_DIR)/gemm_executor/Vgemm_executor_tb


# ============================================================
# Standalone external system memory DPI test
# ============================================================

EXTERNAL_MEMORY_DIR := $(BUILD_DIR)/external_memory
EXTERNAL_MEMORY_BIN := $(EXTERNAL_MEMORY_DIR)/test.bin

$(EXTERNAL_MEMORY_BIN):
	mkdir -p $(EXTERNAL_MEMORY_DIR)
	printf '\001\002\003\004\021\042\063\104' > $@

external_memory: $(EXTERNAL_MEMORY_BIN)
	$(VERILATOR) $(VFLAGS) \
		--Mdir $(EXTERNAL_MEMORY_DIR) \
		--top-module external_memory_tb \
		sim/memory/external_memory.sv \
		sim/memory/external_memory_tb.sv \
		sim/memory/memory.cpp
	./$(EXTERNAL_MEMORY_DIR)/Vexternal_memory_tb


# ============================================================
# Clean
# ============================================================

clean:
	rm -rf $(BUILD_DIR)
	rm -rf obj_dir
	rm -f *.vcd