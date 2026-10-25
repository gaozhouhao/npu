`timescale 1ns/1ps

// Fixed 8x8 output. Change K, output format, A reuse and AXI write delay at run time.
module gemm_output_tb;
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;
    integer k_size = 260, int8_mode = 0, a_reuse = 0, write_gap = 0;
    integer ab_stride, c_stride, cycles, start_cycle, expected, actual, address;

    logic m_axi_arid, m_axi_arvalid, m_axi_arready, m_axi_rid, m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic [63:0] m_axi_araddr, m_axi_rdata;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst, m_axi_rresp;
    logic m_axi_awid, m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic m_axi_bid, m_axi_bvalid, m_axi_bready;
    logic [63:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst, m_axi_bresp;
    logic [31:0] m_axi_wdata;
    logic [3:0] m_axi_wstrb;
    axi_memory_model memory (.*);

    // Parameters use the executor's separate AXI32 read port.
    logic p_arid, p_arvalid, p_arready, p_rid, p_rlast, p_rvalid, p_rready;
    logic [63:0] p_araddr;
    logic [31:0] p_rdata;
    logic [7:0] p_arlen;
    logic [2:0] p_arsize;
    logic [1:0] p_arburst, p_rresp;
    axi_memory_model #(.READ_DATA_WIDTH(32)) parameter_memory (
        .clk(clk), .reset(reset),
        .m_axi_arid(p_arid), .m_axi_araddr(p_araddr), .m_axi_arlen(p_arlen),
        .m_axi_arsize(p_arsize), .m_axi_arburst(p_arburst), .m_axi_arvalid(p_arvalid),
        .m_axi_arready(p_arready), .m_axi_rid(p_rid), .m_axi_rdata(p_rdata),
        .m_axi_rresp(p_rresp), .m_axi_rlast(p_rlast), .m_axi_rvalid(p_rvalid), .m_axi_rready(p_rready),
        .m_axi_awid(1'b0), .m_axi_awaddr(64'd0), .m_axi_awlen(8'd0),
        .m_axi_awsize(3'd2), .m_axi_awburst(2'b01), .m_axi_awvalid(1'b0), .m_axi_awready(),
        .m_axi_wdata(32'd0), .m_axi_wstrb(4'd0), .m_axi_wlast(1'b0), .m_axi_wvalid(1'b0),
        .m_axi_wready(), .m_axi_bid(), .m_axi_bresp(), .m_axi_bvalid(), .m_axi_bready(1'b1)
    );

    logic cmd_valid, cmd_ready, busy, done, error;
    logic signed [31:0] acc_out [4][4];
    npu_gemm_engine dut (
        .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_m(32'd8), .cmd_n(32'd8), .cmd_k(32'(k_size)),
        .cmd_a_base(64'h1000), .cmd_b_base(64'h2000), .cmd_c_base(64'h3000),
        .cmd_a_stride_bytes(32'(ab_stride)), .cmd_b_stride_bytes(32'(ab_stride)),
        .cmd_c_stride_bytes(32'(c_stride)),
        .busy(busy), .done(done), .error(error), .acc_out(acc_out),
        .cmd_conv_mode(1'b0), .cmd_conv_input_h(32'd0), .cmd_conv_input_w(32'd0),
        .cmd_conv_input_c(32'd0), .cmd_conv_kernel_h(32'd0), .cmd_conv_kernel_w(32'd0),
        .cmd_conv_stride_h(32'd1), .cmd_conv_stride_w(32'd1), .cmd_conv_pad_top(32'd0),
        .cmd_conv_pad_left(32'd0), .cmd_conv_output_w(32'd0), .cmd_conv_output_positions(32'd0),
        .cmd_bias_en(int8_mode != 0), .cmd_requant_en(int8_mode != 0),
        .cmd_relu_en(int8_mode != 0), .cmd_per_channel_en(int8_mode != 0),
        .cmd_multi_k_a_reuse(a_reuse != 0), .cmd_b_stationary(1'b0),
        .cmd_fuse_maxpool(1'b0), .cmd_pool_config(32'd0), .cmd_param_base(64'h5000),
        .operand64_arid(m_axi_arid), .operand64_araddr(m_axi_araddr),
        .operand64_arlen(m_axi_arlen), .operand64_arsize(m_axi_arsize),
        .operand64_arburst(m_axi_arburst), .operand64_arvalid(m_axi_arvalid),
        .operand64_arready(m_axi_arready), .operand64_rid(m_axi_rid),
        .operand64_rdata(m_axi_rdata), .operand64_rresp(m_axi_rresp),
        .operand64_rlast(m_axi_rlast), .operand64_rvalid(m_axi_rvalid), .operand64_rready(m_axi_rready),
        .m_axi_arid(p_arid), .m_axi_araddr(p_araddr), .m_axi_arlen(p_arlen),
        .m_axi_arsize(p_arsize), .m_axi_arburst(p_arburst), .m_axi_arvalid(p_arvalid),
        .m_axi_arready(p_arready), .m_axi_rid(p_rid), .m_axi_rdata(p_rdata),
        .m_axi_rresp(p_rresp), .m_axi_rlast(p_rlast), .m_axi_rvalid(p_rvalid), .m_axi_rready(p_rready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    function automatic integer a_value(input integer row, k);
        return row - 4 + (k % 3) - 1;
    endfunction
    function automatic integer b_value(input integer col, k);
        return col - 3 - (k % 5) + 2;
    endfunction

    always @(posedge clk) begin
        if (reset) cycles <= 0;
        else cycles <= cycles + 1;
    end

    initial begin
        void'($value$plusargs("K=%d", k_size));
        void'($value$plusargs("INT8=%d", int8_mode));
        void'($value$plusargs("A_REUSE=%d", a_reuse));
        void'($value$plusargs("WRITE_GAP=%d", write_gap));
        ab_stride = ((k_size + 7) / 8) * 8;
        c_stride = int8_mode ? 8 : 32;
        reset = 1; cmd_valid = 0;
        for (int i = 0; i < 8192; i++) begin
            memory.mem[i] = 0;
            parameter_memory.mem[i] = 0;
        end
        for (int row = 0; row < 8; row++)
            for (int k = 0; k < k_size; k++) begin
                address = 'h1000 + row*ab_stride + k;
                memory.mem[address>>2][(address%4)*8 +: 8] = 8'(a_value(row, k));
                address = 'h2000 + row*ab_stride + k;
                memory.mem[address>>2][(address%4)*8 +: 8] = 8'(b_value(row, k));
            end
        // Per-channel format: global zero points, then bias/multiplier/shift per column.
        for (int col = 0; col < 8; col++) begin
            parameter_memory.mem[('h5000 + 16 + col*12)>>2] = col*11 - 35;
            parameter_memory.mem[('h5000 + 20 + col*12)>>2] = col%3 + 1;
            parameter_memory.mem[('h5000 + 24 + col*12)>>2] = 2;
        end
        repeat (4) @(posedge clk);
        @(negedge clk); reset = 0;
        @(negedge clk); cmd_valid = 1;
        wait (cmd_ready === 1'b1);
        @(posedge clk); #1; start_cycle = cycles;
        @(negedge clk); cmd_valid = 0;
        wait (done === 1'b1); #1;
        if (error !== 1'b0) $fatal(1, "Executor error");
        for (int row = 0; row < 8; row++)
            for (int col = 0; col < 8; col++) begin
                expected = 0;
                for (int k = 0; k < k_size; k++)
                    expected += a_value(row, k) * b_value(col, k);
                address = 'h3000 + row*c_stride + col*(int8_mode ? 1 : 4);
                if (int8_mode) begin
                    expected = (expected + col*11 - 35) * (col%3 + 1);
                    // Round to nearest, ties away from zero; ReLU then clamp to INT8.
                    if (expected < 0) expected = -((-expected + 2) / 4);
                    else expected = (expected + 2) / 4;
                    if (expected < 0) expected = 0;
                    if (expected > 127) expected = 127;
                    actual = $signed(memory.mem[address>>2][(address%4)*8 +: 8]);
                end else actual = $signed(memory.mem[address>>2]);
                if (actual !== expected)
                    $fatal(1, "C[%0d,%0d] got=%0d expected=%0d", row, col, actual, expected);
            end
        $display("PERF K=%0d INT8=%0d A_REUSE=%0d WRITE_GAP=%0d cycles=%0d AR=%0d PARAM_AR=%0d AW=%0d W=%0d",
                 k_size, int8_mode, a_reuse, write_gap, cycles-start_cycle,
                 memory.read_requests, parameter_memory.read_requests,
                 memory.write_requests, memory.write_beats);
        $display("TEST_PASS gemm_output_tb elements=64");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Executor timeout");
    end
endmodule
