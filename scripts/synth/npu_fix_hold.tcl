source [file join [file dirname [info script]] .. technology.tcl]

# 从 build/dc/npu_hold 运行，读取原始已映射设计。
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db $sram_db]
read_ddc [file join $build_root dc npu npu.ddc]
current_design npu_top
link

# 延迟单元的逻辑功能为 Z=I，实际延迟由库模型计算。
set delay_cell [get_lib_cells tcbn28hpcplusbwp40p140tt0p9v25c/DEL200MD1BWP40P140]
file mkdir reports
report_timing -delay_type min -max_paths 1 > reports/hold_before.rpt
report_timing -max_paths 1 > reports/timing_before.rpt

# 每轮先保存终点名称，再取得引脚或端口，避免混合对象和旧路径。
# 最多三轮；没有 hold 违例就结束。
for {set pass 1} {$pass <= 3} {incr pass} {
    set paths [get_timing_paths -delay_type min -slack_lesser_than 0 -nworst 1 -max_paths 100000]
    puts "HOLD_ECO_PASS $pass: [sizeof_collection $paths] violating endpoints"
    if {[sizeof_collection $paths] == 0} {
        break
    }
    set endpoints {}
    foreach_in_collection path $paths {
        lappend endpoints [get_object_name [get_attribute $path endpoint]]
    }
    foreach name $endpoints {
        set endpoint [get_pins -quiet $name]
        if {[sizeof_collection $endpoint] == 0} {
            set endpoint [get_ports $name]
        }
        insert_buffer $endpoint $delay_cell
    }
}

# 保存真实裕量和全部约束违例，不改变原时钟或接口约束。
report_area > reports/area.rpt
report_timing -max_paths 10 -significant_digits 4 > reports/timing.rpt
report_timing -delay_type min -max_paths 10 -significant_digits 4 > reports/hold.rpt
report_constraint -all_violators -significant_digits 4 > reports/constraints.rpt
check_design > reports/check_design.rpt
check_timing > reports/check_timing.rpt
write -format verilog -hierarchy -output npu_mapped.v
write -format ddc -hierarchy -output npu.ddc
write_sdc npu.sdc
exit
