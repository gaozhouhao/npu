VERILATOR = verilator

PE_RTL = rtl/compute/pe.sv
PE_TB  = sim/tb/pe_tb.sv

.PHONY: pe clean

pe:
	$(VERILATOR) --binary --timing \
		-Wall \
		--top-module pe_tb \
		$(PE_RTL) $(PE_TB)

	./obj_dir/Vpe_tb

clean:
	rm -rf obj_dir