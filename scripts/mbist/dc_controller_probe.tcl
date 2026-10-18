# Run from build/mbist/dc_controller_20261018.
set stdcell_db /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db
set mbist_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dft_mbist.sldb
set dw_lib /home/synopsys/syn/O-2018.06-SP1/libraries/syn/dw_foundation.sldb
set_app_var target_library [list $stdcell_db]
set_app_var synthetic_library [list $mbist_lib $dw_lib]
set_app_var link_library [list "*" $stdcell_db $mbist_lib $dw_lib]
file mkdir reports

analyze -format sverilog ../../../sim/mbist/dw_mbist_controller_probe.sv
elaborate dw_mbist_controller_probe
current_design dw_mbist_controller_probe
if {[link] == 0} {exit 1}
check_design > reports/check_design.rpt
create_clock -name clk -period 100 [get_ports clk]
compile -map_effort medium
report_area > reports/area.rpt
report_reference -hierarchy > reports/references.rpt
write -format verilog -hierarchy -output controller_mapped.v
write -format ddc -hierarchy -output controller.ddc
exit
