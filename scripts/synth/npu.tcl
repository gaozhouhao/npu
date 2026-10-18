# NPU 的第一轮 DC 综合。
# 请从工程的 build/dc/npu 目录启动 DC。
# 运行前先执行 operand_sram_lib.tcl，生成下方使用的真实 SRAM .db。

# 1. 标准单元采用与 PE 实验相同的 TT / 0.9 V / 25°C 库。
set stdcell_db "/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/tcbn28hpcplusbwp40p140tt0p9v25c.db"

# Memory Compiler 生成模型，再由 LC 编译得到的 SRAM .db。
# SRAM 的工艺、电压和温度条件需要与本轮标准单元库配套。
set sram_db "/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/NLDM/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.db"

# target_library 用于逻辑映射；link_library 用于解析标准单元和 SRAM 实例。
set_app_var target_library [list $stdcell_db]
set_app_var link_library [list "*" $stdcell_db $sram_db]

# 2. 创建 RTL 分析目录和报告目录，均位于 build/dc/npu 下。
file mkdir work
file mkdir reports
define_design_lib WORK -path work

# 3. 明确列出设计 RTL，不读取 Testbench 和厂商 SRAM 仿真模型。
# operand_sram.sv 连接真实 A/B 宏；厂商行为模型只用于 VCS。
set rtl_files {
    ../../../rtl/compute/input_skew.sv
    ../../../rtl/compute/matrix_engine.sv
    ../../../rtl/compute/pe.sv
    ../../../rtl/compute/pool2d_engine.sv
    ../../../rtl/compute/postprocess_unit.sv
    ../../../rtl/compute/systolic_array.sv
    ../../../rtl/core/command_frontend.sv
    ../../../rtl/core/dataflow_tile_iterator.sv
    ../../../rtl/core/gemm_address_generator.sv
    ../../../rtl/core/gemm_core.sv
    ../../../rtl/core/gemm_executor.sv
    ../../../rtl/core/matrix_controller.sv
    ../../../rtl/core/npu_top.sv
    ../../../rtl/core/output_param_slot_bank.sv
    ../../../rtl/core/psum_tile_engine.sv
    ../../../rtl/core/residual_add_engine.sv
    ../../../rtl/core/tile_policy.sv
    ../../../rtl/core/tile_scheduler.sv
    ../../../rtl/dma/axi_read_32to64.sv
    ../../../rtl/dma/axi_read_master.sv
    ../../../rtl/dma/axi_read_mux.sv
    ../../../rtl/dma/axi_write_master.sv
    ../../../rtl/dma/bias_loader.sv
    ../../../rtl/dma/c_write_dma.sv
    ../../../rtl/dma/conv_patch_loader.sv
    ../../../rtl/dma/conv_read_cache.sv
    ../../../rtl/dma/gemm_read_path.sv
    ../../../rtl/dma/operand_read_dma.sv
    ../../../rtl/dma/postprocess_param_loader.sv
    ../../../rtl/dma/read_request_arbiter.sv
    ../../../rtl/dma/strided_read_engine.sv
    ../../../rtl/memory/buffer_manager.sv
    ../../../rtl/memory/c_result_buffer.sv
    ../../../rtl/memory/operand_buffer.sv
    ../../../rtl/memory/operand_loader.sv
    ../../../rtl/memory/operand_sram.sv
    ../../../rtl/memory/psum_tile_sram.sv
    ../../../rtl/memory/scratchpad.sv
    ../../../rtl/memory/sram_model.sv
}

# SYNTHESIS 选择综合代码；NPU_TSMC28 选择真实存储宏连接。
# 不定义 NPU_PERF_ENABLE，避免加入仿真性能统计逻辑。
analyze -format sverilog -define {SYNTHESIS NPU_TSMC28} $rtl_files

# 保留 npu_top 默认参数：4×4 INT8、K=256、A/B 双缓冲。
# 顶层 MEM_WORD_WIDTH=32；内部操作数 SRAM 字宽已经设置为 64。
elaborate npu_top
current_design npu_top
link

# 4. 检查单位，加载接口及时钟约束，检查综合前的设计。
report_units
source ../../../constraints/npu.sdc
check_design > reports/check_design.rpt

# 5. 将 RTL 逻辑映射到标准单元库；SRAM 实例由 link_library 解析。
compile

# 6. 保存综合后结构、面积、setup、hold 和约束报告。
check_design > reports/check_design_mapped.rpt
report_area > reports/area.rpt
report_area -hierarchy > reports/area_hierarchy.rpt
report_reference -hierarchy > reports/references.rpt
check_timing > reports/check_timing.rpt
report_timing -max_paths 10 > reports/timing.rpt
report_timing -delay_type min -max_paths 10 > reports/hold.rpt
report_constraint -all_violators > reports/constraints.rpt

# 7. 输出门级网表、DC 设计数据库和本轮约束。
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output npu_mapped.v
write -format ddc -hierarchy -output npu.ddc
write_sdc npu.sdc

exit
