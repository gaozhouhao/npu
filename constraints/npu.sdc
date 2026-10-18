# NPU 功能模式教学约束：TT / 0.9 V / 25°C。
# 功能目标调整为 40 MHz，保留既有接口延迟和时钟不确定性。
# 已核对标准单元和 SRAM 库：时间单位均为 ns，电容单位均为 pF。

# 时钟周期 25 ns，即 40 MHz。
create_clock -name npu_clk -period 25.0 [get_ports clk]

# 0.2 ns 同时用于 setup 和 hold，延续 PE 实验的教学假设。
# 当前为理想时钟；这不是布局布线后的时钟树或最终签核约束。
set_clock_uncertainty 0.2 [get_clocks npu_clk]

# 除 clk 外的全部输入。reset 是同步复位，保留正常时序分析。
set data_inputs [get_ports {
    reset start desc_base* desc_count*
    m_axi_arready
    m_axi_rid* m_axi_rdata* m_axi_rresp* m_axi_rlast m_axi_rvalid
    m_axi_awready m_axi_wready
    m_axi_bid* m_axi_bresp* m_axi_bvalid
}]

# 假设上游输入在时钟沿后的 0 至 1 ns 到达。
# min=0 ns 是当前教学假设，后续应由真实上游的最小延迟替换。
set_input_delay -clock npu_clk -max 1.0 $data_inputs
set_input_delay -clock npu_clk -min 0.0 $data_inputs

# 假设下游接口预留最多 1 ns，最小输出延迟为 0 ns。
# all_outputs 包括状态、acc_out 和 AXI 输出。
set_output_delay -clock npu_clk -max 1.0 [all_outputs]
set_output_delay -clock npu_clk -min 0.0 [all_outputs]

# 假设输入转换时间 0.1 ns，每个输出端口负载 0.01 pF。
set_input_transition 0.1 $data_inputs
set_load 0.01 [all_outputs]
