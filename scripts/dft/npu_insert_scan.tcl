source [file join [file dirname [info script]] .. technology.tcl]

# 从 build/dft/npu_scan 目录运行。
# 本脚本只插入普通扫描链，功能/shift 时序优化放到后续实验。
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db $sram_db]
read_ddc [file join $build_root dft npu_precheck npu_40mhz.ddc]
current_design npu_top
link
file mkdir reports

# 1. 新增高有效扫描使能；0 为功能模式，1 为扫描移位。
create_port -direction in scan_enable
set_dft_signal -view spec -type ScanEnable -port scan_enable -active_state 1

# 2. 每条链有独立输入和输出，端口统一用小写和下划线命名。
set_scan_configuration -style multiplexed_flip_flop -chain_count 16 -clock_mixing no_mix
for {set i 0} {$i < 16} {incr i} {
    create_port -direction in scan_in_$i
    create_port -direction out scan_out_$i
    set_dft_signal -view spec -type ScanDataIn -port scan_in_$i
    set_dft_signal -view spec -type ScanDataOut -port scan_out_$i
    set_scan_path chain_$i -view spec -scan_enable scan_enable \
        -scan_data_in scan_in_$i -scan_data_out scan_out_$i
}

# 3. 使用已验证的 10 MHz 测试协议，同步 reset 保持无效。
set test_default_period 100
set test_default_delay 5
set test_default_strobe 40
set_dft_signal -view existing_dft -type ScanClock -port clk -timing {45 55}
set_dft_signal -view existing_dft -type Constant -port reset -active_state 0
create_test_protocol

# 4. 先检查和预览，再由 insert_dft 替换寄存器并连接扫描链。
# none 只关闭插入后的时序/设计规则优化，不关闭扫描替换。
set_dft_insertion_configuration -synthesis_optimization none
dft_drc -pre_dft -verbose > reports/dft_drc_pre.rpt
preview_dft > reports/scan_preview.rpt
insert_dft
change_names -rules verilog -hierarchy

# 5. 检查实际链结构，保存网表、设计数据库和测试协议。
dft_drc -verbose > reports/dft_drc_post.rpt
report_scan_path -view existing_dft -chain all > reports/scan_chains.rpt
report_scan_path -view existing_dft -cell all > reports/scan_cells.rpt
report_area > reports/area.rpt
write -format verilog -hierarchy -output npu_scan.v
write -format ddc -hierarchy -output npu_scan.ddc
# dc_shell 保留总线位名，避免 [0:0] 端口在 STIL 中多出转义符。
write_test_protocol -test_mode Internal_scan -output npu_scan.spf -names dc_shell
exit
