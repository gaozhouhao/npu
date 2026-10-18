# 从 build/dc/npu_hold 运行，复用上一轮已映射设计。
set stdcell_db "/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db"
set sram_db "/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/NLDM/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.db"
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db $sram_db]

read_ddc ../npu_20261018_133300/npu.ddc
current_design npu_top
link

# 保留 DDC 中的时钟和接口约束，只优化 hold。
set_fix_hold [get_clocks npu_clk]
compile -only_hold_time

file mkdir reports
report_area > reports/area.rpt
report_timing -max_paths 10 > reports/timing.rpt
report_timing -delay_type min -max_paths 10 > reports/hold.rpt
report_constraint -all_violators > reports/constraints.rpt
check_design > reports/check_design.rpt
check_timing > reports/check_timing.rpt
write -format verilog -hierarchy -output npu_mapped.v
write -format ddc -hierarchy -output npu.ddc
write_sdc npu.sdc
exit
