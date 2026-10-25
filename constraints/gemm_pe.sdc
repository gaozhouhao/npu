# PE 第一轮综合的教学约束：TT / 0.9 V / 25°C。
# 已核对所选 Liberty：时间单位为 ns，电容单位为 pF。
# 时钟和输入输出环境仍是本轮教学假设。

# 时钟周期 10 ns，即 100 MHz；预留 0.2 ns 时钟不确定度。
create_clock -name pe_clk -period 10.0 [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks pe_clk]

# 列出除 clk 外的全部输入；通配符 * 包含总线各位。
# reset 和 clear 都是同步控制信号，需要正常检查时序。
set data_inputs [get_ports {reset clear a_in* b_in* a_valid_in b_valid_in}]

# 假设上游信号在时钟沿后的 0 至 1 ns 到达 PE 输入。
set_input_delay -clock pe_clk -max 1.0 $data_inputs
set_input_delay -clock pe_clk -min 0.0 $data_inputs

# 假设下游接口预留最多 1 ns，最小输出延迟为 0 ns。
set_output_delay -clock pe_clk -max 1.0 [all_outputs]
set_output_delay -clock pe_clk -min 0.0 [all_outputs]

# 假设输入转换时间 0.1 ns，每个输出端口负载 0.01 pF。
set_input_transition 0.1 $data_inputs
set_load 0.01 [all_outputs]
