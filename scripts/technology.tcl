# Shared local process-library setup for the Make EDA targets.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set build_root [file join $project_root build]
if {[info exists ::env(NPU_BUILD_DIR)]} {set build_root $::env(NPU_BUILD_DIR)}
set pdk_root /home/ICer/eda/pdk/tsmc28
if {[info exists ::env(NPU_PDK_ROOT)]} {set pdk_root $::env(NPU_PDK_ROOT)}
set logic_name tcbn28hpcplusbwp40p140
set logic_root [file join $pdk_root logic ${logic_name}_180b]
set stdcell_db [file join $logic_root nldm ${logic_name}tt0p9v25c.db]
set stdcell_v [file join $logic_root verilog ${logic_name}.v]
set sram_root [file join $pdk_root Memory macros operand_32x64 ts5n28hpcpsvta32x64m2f_130a]
set sram_corner ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c
set sram_lib [file join $sram_root NLDM ${sram_corner}.lib]
set sram_db [file join $sram_root NLDM ${sram_corner}.db]
set sram_v [file join $sram_root VERILOG ${sram_corner}.v]
set sram_atpg_v [file join $sram_root DFT ATPG ts5n28hpcpsvta32x64m2f_130a_tmax.v]
