source [file join [file dirname [info script]] .. technology.tcl]

# 从 build/dft/npu_precheck 目录运行，不插链、不修改 RTL。
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db $sram_db]
read_ddc [file join $build_root dc npu_hold npu.ddc]
current_design npu_top
link

# 1. 读取 40 MHz 功能约束，复查同一份已修 hold 的网表。
source [file join $project_root constraints npu.sdc]
file mkdir reports
report_clock > reports/functional_clock.rpt
report_area > reports/area.rpt
report_timing -max_paths 10 -significant_digits 4 > reports/timing_40mhz.rpt
report_timing -delay_type min -max_paths 10 -significant_digits 4 > reports/hold_40mhz.rpt
report_constraint -all_violators -significant_digits 4 > reports/constraints_40mhz.rpt
check_timing > reports/check_timing.rpt
write -format ddc -hierarchy -output npu_40mhz.ddc
write_sdc npu_40mhz.sdc

# 2. 普通 MUX-D 扫描方案：暂定 16 条链，共用现有 clk。
# 这是配置和插入前检查，不创建扫描端口，也不执行 insert_dft。
set_scan_configuration -style multiplexed_flip_flop -chain_count 16 -clock_mixing no_mix

# 测试周期 100 ns，输入在 5 ns 驱动，输出在 40 ns 采样。
# clk 在 45 ns 上升、55 ns 下降，先采用低速静态测试协议。
set test_default_period 100
set test_default_delay 5
set test_default_strobe 40
set_dft_signal -view existing_dft -type ScanClock -port clk -timing {45 55}

# reset 是同步复位；本阶段测试时保持无效，不声明为异步 Reset。
set_dft_signal -view existing_dft -type Constant -port reset -active_state 0
create_test_protocol
write_test_protocol -output npu_precheck.spf

dft_drc -pre_dft -verbose > reports/dft_drc_pre.rpt

# 仅预览链结构和所需接口，不执行扫描替换或插链。
preview_dft > reports/scan_preview.rpt
exit
