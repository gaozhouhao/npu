# PE 的第一轮 DC 综合。
# 请从工程的 build/dc/pe 目录启动 DC，运行方法见学习笔记。

# 1. 选择 TSMC 28nm HPC+、9T、Standard Vt 的 TT / 0.9 V / 25°C 库。
# NLDM 包已提供 .db，可直接读取。
set stdcell_db "/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db"
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db]

# 2. 创建 RTL 分析目录和报告目录，均位于 build/dc/pe 下。
file mkdir work
file mkdir reports
define_design_lib WORK -path work

# 3. 读取 SystemVerilog，建立顶层 pe，并解析引用关系。
analyze -format sverilog ../../../rtl/compute/pe.sv
elaborate pe
current_design pe
link

# 4. 显示单位，再读取时钟、输入输出延迟和负载约束。
report_units
source ../../../constraints/pe.sdc
check_design > reports/check_design.rpt

# 5. 将 RTL 逻辑映射到标准单元库。
compile

# 6. 检查映射后的结构，保存面积、setup、hold 和约束报告。
check_design > reports/check_design_mapped.rpt
report_area > reports/area.rpt
report_timing -max_paths 10 > reports/timing.rpt
report_timing -delay_type min -max_paths 10 > reports/hold.rpt
report_constraint -all_violators > reports/constraints.rpt

# 7. 输出门级网表、DC 设计数据库和本轮约束。
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output pe_mapped.v
write -format ddc -hierarchy -output pe.ddc
write_sdc pe.sdc

exit
