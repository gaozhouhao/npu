source [file join [file dirname [info script]] .. technology.tcl]

# Elaborate and name the APG before linking the SRAM probe.
# Run from a new directory under build/mbist.
set mbist_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dft_mbist.sldb
set dw_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dw_foundation.sldb
set_app_var target_library [list $stdcell_db]
set_app_var synthetic_library [list $mbist_lib $dw_lib]
set_app_var link_library [list "*" $stdcell_db $sram_db $mbist_lib $dw_lib]
file mkdir reports
# Use the vendor entity and architecture in this experiment's local WORK.
analyze -format vhdl /home/synopsys/syn/O-2018.06-SP1/dw/dw04/src/DW_mbist_apg.vhd.e
analyze -format vhdl /home/synopsys/syn/O-2018.06-SP1/dw/dw04/src/DW_mbist_apg_rtl.vhd.e
# registered_io=2 matches the SRAM's clocked input sampling.
elaborate DW_mbist_apg -architecture rtl -parameters "addr_width=5,data_width=64,num_ports=1,registered_io=2,mem_end_addr=31"
rename_design [current_design] dw_mbist_apg_32x64
analyze -format sverilog [list [file join $project_root sim mbist dw_mbist_controller_probe.sv] [file join $project_root sim mbist dw_mbist_sram_probe.sv]]
elaborate dw_mbist_sram_probe
current_design dw_mbist_sram_probe
if {[link] == 0} {exit 1}
create_clock -name clk -period 100 [get_ports clk]
compile -map_effort medium
change_names -rules verilog -hierarchy
check_design > reports/check_design.rpt
report_area > reports/area.rpt
report_reference -hierarchy > reports/references.rpt
write -format verilog -hierarchy -output mbist_mapped.v
write -format ddc -hierarchy -output mbist.ddc
exit
