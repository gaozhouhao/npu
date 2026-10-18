# Current validation is blocked by APG SYNH-14; see docs/eda_learning_notes.md.
# Run from build/mbist/dc_sram_20261018.
set stdcell_db /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db
set sram_db /home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/NLDM/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.db
set mbist_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dft_mbist.sldb
set dw_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dw_foundation.sldb
set_app_var target_library [list $stdcell_db]
set_app_var synthetic_library [list $mbist_lib $dw_lib]
set_app_var link_library [list "*" $stdcell_db $sram_db $mbist_lib $dw_lib]
file mkdir reports
analyze -format sverilog [list ../../../sim/mbist/dw_mbist_controller_probe.sv ../../../sim/mbist/dw_mbist_sram_probe.sv]
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
