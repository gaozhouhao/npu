VERILATOR = verilator

PE_RTL = rtl/compute/pe.sv
PE_TB  = sim/tb/pe_tb.sv

.PHONY: pe clean

MATRIX_RTL = \
	rtl/compute/pe.sv \
	rtl/compute/input_skew.sv \
	rtl/compute/systolic_array.sv \
	rtl/compute/matrix_engine.sv

MATRIX_TB = sim/tb/matrix_engine_tb.sv

.PHONY: matrix

matrix:
	$(VERILATOR) --binary --timing \
		-Wall \
		-Wno-TIMESCALEMOD \
		--top-module matrix_engine_tb \
		$(MATRIX_RTL) $(MATRIX_TB)

	./obj_dir/Vmatrix_engine_tb

pe:
	$(VERILATOR) --binary --timing \
		-Wall \
		--top-module pe_tb \
		$(PE_RTL) $(PE_TB)

	./obj_dir/Vpe_tb

controller:
	verilator --binary --timing \
		-Wno-TIMESCALEMOD \
		rtl/core/matrix_controller.sv \
		sim/tb/matrix_controller_tb.sv \
		--top-module matrix_controller_tb

	./obj_dir/Vmatrix_controller_tb

clean:
	rm -rf obj_dir