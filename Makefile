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

.PHONY: all test pe matrix controller gemm clean

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


# ============================================================
# Clean
# ============================================================

clean:
	rm -rf $(BUILD_DIR)
	rm -rf obj_dir
	rm -f *.vcd