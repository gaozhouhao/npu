# Run from build/atpg/npu_stuck_at_20261018.
# Stop on errors; do not generate results from an invalid model.
set_commands exit
set_messages -log tmax.log -replace

# 1. Read library models and the inserted scan netlist.
set stdcell_v /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/verilog/tcbn28hpcplusbwp40p140.v
set sram_v /home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/DFT/ATPG/ts5n28hpcpsvta32x64m2f_130a_tmax.v
read_netlist $stdcell_v -library
read_netlist $sram_v -library
read_netlist ../../dft/npu_scan_20261018/npu_scan.v

# 2. Exclude only the hard SRAM arrays. Their outputs remain unknown.
set_build -black_box TS5N28HPCPSVTA32X64M2F
run_build_model npu_top
report_modules -error
report_rules -fail

# 3. Check the actual scan chains and the DC-generated test protocol.
run_drc ../../dft/npu_scan_20261018/npu_scan.spf
report_rules -fail
report_nonscan_cells -summary

# 4. Generate stuck-at patterns; report both coverage definitions.
set_faults -model stuck -report uncollapsed -summary verbose -fault_coverage
add_faults -all
run_atpg -auto_compression
report_summaries
report_faults -class AU -max 30
report_faults -class ND -max 30

# 5. Save reusable patterns and fault classifications.
write_faults npu_stuck_at.faults -all -replace
write_patterns npu_stuck_at.stil -format stil -replace
exit -force
