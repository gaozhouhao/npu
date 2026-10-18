`timescale 1ns/1ps

// Direct executor command: 8x8 outputs, K=256+4, with 8-byte-aligned physical rows.
module gemm_executor_tb #(
    parameter int A_BUFFER_COUNT = 2,
    parameter int B_BUFFER_COUNT = 2
);
    logic clk = 0;
    logic reset;
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
    always #5 clk = ~clk;
    logic cmd_valid, cmd_ready, busy, done, error;
    logic signed [31:0] acc_out [4][4];
    gemm_executor #(.A_BUFFER_COUNT(A_BUFFER_COUNT), .B_BUFFER_COUNT(B_BUFFER_COUNT)) dut (
        .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_m(32'd8), .cmd_n(32'd8), .cmd_k(32'd260),
        .cmd_a_base(64'h1000), .cmd_b_base(64'h2000), .cmd_c_base(64'h3000),
        .cmd_a_stride_bytes(32'd264), .cmd_b_stride_bytes(32'd264), .cmd_c_stride_bytes(32'd32),
        .busy(busy), .done(done), .error(error), .acc_out(acc_out),
        .cmd_conv_mode(1'b0), .cmd_conv_input_h(32'd0), .cmd_conv_input_w(32'd0),
        .cmd_conv_input_c(32'd0), .cmd_conv_kernel_h(32'd0), .cmd_conv_kernel_w(32'd0),
        .cmd_conv_stride_h(32'd1), .cmd_conv_stride_w(32'd1), .cmd_conv_pad_top(32'd0),
        .cmd_conv_pad_left(32'd0), .cmd_conv_output_w(32'd0), .cmd_conv_output_positions(32'd0),
        .cmd_bias_en(1'b0), .cmd_requant_en(1'b0), .cmd_relu_en(1'b0), .cmd_per_channel_en(1'b0),
        .cmd_multi_k_a_reuse(1'b0), .cmd_b_stationary(1'b0), .cmd_param_base(64'd0),
        .operand64_arid(m_axi_arid), .operand64_araddr(m_axi_araddr),
        .operand64_arlen(m_axi_arlen), .operand64_arsize(m_axi_arsize),
        .operand64_arburst(m_axi_arburst), .operand64_arvalid(m_axi_arvalid),
        .operand64_arready(m_axi_arready), .operand64_rid(m_axi_rid),
        .operand64_rdata(m_axi_rdata), .operand64_rresp(m_axi_rresp),
        .operand64_rlast(m_axi_rlast), .operand64_rvalid(m_axi_rvalid), .operand64_rready(m_axi_rready),
        .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(), .m_axi_arsize(), .m_axi_arburst(),
        .m_axi_arvalid(), .m_axi_arready(1'b0), .m_axi_rid(1'b0), .m_axi_rdata(32'd0),
        .m_axi_rresp(2'd0), .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0), .m_axi_rready(),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );
    initial begin
        reset = 1; cmd_valid = 0;
        for (int i = 0; i < 8192; i++) memory.mem[i] = 0;
        for (int row = 0; row < 8; row++)
            for (int k = 0; k < 260; k++) begin
                memory.mem[('h1000+row*264+k)>>2][((row*264+k)%4)*8 +: 8] = 8'(row+1);
                memory.mem[('h2000+row*264+k)>>2][((row*264+k)%4)*8 +: 8] = 8'(row+1);
            end
        repeat (4) @(posedge clk);
        @(negedge clk); reset = 0;
        @(negedge clk); cmd_valid = 1;
        wait (cmd_ready === 1'b1);
        @(negedge clk); cmd_valid = 0;
        wait (done === 1'b1); #1;
        if (error !== 1'b0) $fatal(1, "Executor error");
        for (int row = 0; row < 8; row++)
            for (int col = 0; col < 8; col++)
                if ($signed(memory.mem[('h3000+row*32+col*4)>>2]) !== 260*(row+1)*(col+1))
                    $fatal(1, "Executor C[%0d,%0d] mismatch", row, col);
        if (memory.read_requests != 64 || memory.write_requests != 16 || memory.write_beats != 64)
            $fatal(1, "Unexpected GEMM traffic AR=%0d AW=%0d W=%0d", memory.read_requests,
                   memory.write_requests, memory.write_beats);
        $display("TEST_PASS gemm_executor_tb elements=64 AR=%0d AW=%0d W=%0d", memory.read_requests,
                 memory.write_requests, memory.write_beats);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Executor timeout");
    end
endmodule
