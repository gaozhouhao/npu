source [file join [file dirname [info script]] .. technology.tcl]

# Run from a NEW directory under build/atpg (see learning notes).
# Stop on errors; do not generate results from an invalid model.
set_commands exit
set_messages -log tmax.log -replace

# 1. Read library models and the inserted scan netlist.
read_netlist $stdcell_v -library
read_netlist $sram_atpg_v -library
read_netlist [file join $build_root dft npu_scan npu_scan.v]

# 2. Exclude only the hard SRAM arrays. Their outputs remain unknown.
set_build -black_box TS5N28HPCPSVTA32X64M2F
run_build_model npu_top
report_modules -error
report_rules -fail

# 3. Check the actual scan chains and the DC-generated test protocol.
run_drc [file join $build_root dft npu_scan npu_scan.spf]
report_rules -fail
report_nonscan_cells -summary

# 4. Save the checked model, including names needed by parallel simulation.
write_image npu_model.image -netlist_data -replace
set_faults -model stuck -report uncollapsed -summary verbose -fault_coverage
add_faults -all
source [file join $project_root scripts atpg npu_generate_patterns.tcl]
