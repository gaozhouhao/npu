# Explicitly elaborate and link the vendor APG before synthesis.
# Run from a new directory under build/mbist.
set stdcell_db /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db
set mbist_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dft_mbist.sldb
set dw_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dw_foundation.sldb
set_app_var target_library [list $stdcell_db]
set_app_var synthetic_library [list $mbist_lib $dw_lib]
set_app_var link_library [list "*" $stdcell_db $mbist_lib $dw_lib]
file mkdir reports
# Use the vendor entity and architecture in this experiment's local WORK.
analyze -format vhdl /home/synopsys/syn/O-2018.06-SP1/dw/dw04/src/DW_mbist_apg.vhd.e
analyze -format vhdl /home/synopsys/syn/O-2018.06-SP1/dw/dw04/src/DW_mbist_apg_rtl.vhd.e
elaborate DW_mbist_apg -architecture rtl
set apg_design [get_object_name [current_design]]
analyze -format sverilog ../../../sim/mbist/dw_mbist_apg_default_probe.sv
elaborate dw_mbist_apg_default_probe
current_design dw_mbist_apg_default_probe
change_link u_pattern_generator $apg_design
if {[link] == 0} {exit 1}
check_design > reports/check_design.rpt
create_clock -name bist_clk -period 100 [get_ports bist_clk]
create_clock -name bist_clk_t -period 100 [get_ports bist_clk_t]
compile -map_effort medium
check_design > reports/check_design_mapped.rpt
report_reference -hierarchy > reports/references.rpt
report_area > reports/area.rpt
write -format verilog -hierarchy -output apg_mapped.v
exit
