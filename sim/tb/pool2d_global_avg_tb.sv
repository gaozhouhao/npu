
`timescale 1ns/1ps

module pool2d_global_avg_tb;

    logic clk;
    logic reset;

    logic cmd_valid, cmd_ready, cmd_global_avg;
    logic [63:0] cmd_input_base, cmd_output_base;
    logic [31:0] cmd_input_h, cmd_input_w, cmd_channels;
    logic busy, done, error;

    logic [0:0] arid, rid, awid, bid;
    logic [63:0] araddr, awaddr;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, awburst;
    logic arvalid, arready;
    logic rvalid, rready, rlast;
    logic awvalid, awready;
    logic wvalid, wready, wlast;
    logic bvalid, bready;
    logic [31:0] rdata, wdata;
    logic [3:0] wstrb;
    logic [1:0] rresp, bresp;

    logic [31:0] mem [0:4095];

    logic read_pending_q;
    logic [11:0] read_word_q;

    logic write_pending_q;
    logic [11:0] write_word_q;
    logic response_pending_q;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    pool2d_engine dut (
        .clk(clk),
        .reset(reset),

        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_global_avg(cmd_global_avg),

        .cmd_input_base(cmd_input_base),
        .cmd_output_base(cmd_output_base),
        .cmd_input_h(cmd_input_h),
        .cmd_input_w(cmd_input_w),
        .cmd_channels(cmd_channels),

        .busy(busy),
        .done(done),
        .error(error),

        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),

        .m_axi_rid(rid),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),

        .m_axi_awid(awid),
        .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),

        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),

        .m_axi_bid(bid),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready)
    );

    function automatic logic [31:0] word4(
        input integer a,
        input integer b,
        input integer c,
        input integer d
    );
        if (a < -128 || a > 127 ||
            b < -128 || b > 127 ||
            c < -128 || c > 127 ||
            d < -128 || d > 127)
            $fatal(1, "word4 input exceeds INT8 range");

        return {8'(d), 8'(c), 8'(b), 8'(a)};
    endfunction

    // ============================================================
    // Simple one-beat AXI memory model
    // ============================================================

    assign arready = !read_pending_q;
    assign rid = '0;
    assign rresp = 2'b00;
    assign rlast = 1'b1;
    assign rvalid = read_pending_q;
    assign rdata = mem[read_word_q];

    assign awready =
        !write_pending_q && !response_pending_q;

    assign wready = write_pending_q;

    assign bid = '0;
    assign bresp = 2'b00;
    assign bvalid = response_pending_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            read_pending_q <= 1'b0;
            read_word_q <= '0;

            write_pending_q <= 1'b0;
            write_word_q <= '0;
            response_pending_q <= 1'b0;

        end else begin

            if (arvalid && arready) begin
                if (
                    (arid != '0) ||
                    (arlen != 8'd0) ||
                    (arsize != 3'd2) ||
                    !(
                        (arburst == 2'b00) ||
                        (arburst == 2'b01)
                    )
                )
                    $fatal(1, "Invalid AXI read request");

                if (araddr[63:14] != '0 ||
                    araddr[1:0] != 2'b00)
                    $fatal(1, "AXI read address out of range");

                read_word_q <= araddr[13:2];
                read_pending_q <= 1'b1;
            end

            if (rvalid && rready)
                read_pending_q <= 1'b0;

            if (awvalid && awready) begin
                if (
                    (awid != '0) ||
                    (awlen != 8'd0) ||
                    (awsize != 3'd2) ||
                    !(
                        (awburst == 2'b00) ||
                        (awburst == 2'b01)
                    )
                )
                    $fatal(1, "Invalid AXI write request");

                if (awaddr[63:14] != '0 ||
                    awaddr[1:0] != 2'b00)
                    $fatal(1, "AXI write address out of range");

                write_word_q <= awaddr[13:2];
                write_pending_q <= 1'b1;
            end

            if (wvalid && wready) begin
                if (!wlast || wstrb != 4'hf)
                    $fatal(1, "Invalid write data");

                mem[write_word_q] <= wdata;
                write_pending_q <= 1'b0;
                response_pending_q <= 1'b1;
            end

            if (bvalid && bready)
                response_pending_q <= 1'b0;
        end
    end

    // ============================================================
    // Command helper
    // ============================================================

    task automatic run_pool(
        input logic global_avg,
        input logic [31:0] h,
        input logic [31:0] w,
        input logic [31:0] channels,
        input logic [63:0] input_base,
        input logic [63:0] output_base
    );
        wait (cmd_ready);

        @(negedge clk);
        cmd_global_avg = global_avg;
        cmd_input_h = h;
        cmd_input_w = w;
        cmd_channels = channels;
        cmd_input_base = input_base;
        cmd_output_base = output_base;
        cmd_valid = 1'b1;

        @(negedge clk);
        cmd_valid = 1'b0;

        if (!busy)
            $fatal(1, "Pool command did not start");

        wait (done);

        if (error)
            $fatal(1, "Pool engine error");

        @(negedge clk);
    endtask

    initial begin
        #1000000;
        $fatal(1, "Pool2D regression TIMEOUT");
    end

    initial begin
        reset = 1'b1;
        cmd_valid = 1'b0;
        cmd_global_avg = 1'b0;
        cmd_input_base = '0;
        cmd_output_base = '0;
        cmd_input_h = '0;
        cmd_input_w = '0;
        cmd_channels = '0;

        for (int i = 0; i < 4096; i++)
            mem[i] = '0;

        repeat (4) @(negedge clk);
        reset = 1'b0;

        // ========================================================
        // Test 1: Global Average, 2x2x4
        // ========================================================

        mem[0] = word4(-1, 1, -6, 2);
        mem[1] = word4(-1, 1, -4, 4);
        mem[2] = word4( 0, 0, -2, 6);
        mem[3] = word4( 0, 0, -8, 8);

        run_pool(
            1'b1,
            32'd2, 32'd2, 32'd4,
            64'd0, 64'd1024
        );

        if (mem[256] !== word4(-1, 1, -5, 5))
            $fatal(
                1,
                "Global Average 2x2 mismatch: %h",
                mem[256]
            );

        $display("GLOBAL AVG 2x2 PASS");

        // ========================================================
        // Test 2: Original MaxPool, 2x2x4
        // ========================================================

        run_pool(
            1'b0,
            32'd2, 32'd2, 32'd4,
            64'd0, 64'd1028
        );

        if (mem[257] !== word4(0, 1, -2, 8))
            $fatal(
                1,
                "Original MaxPool mismatch: %h",
                mem[257]
            );

        $display("ORIGINAL MAXPOOL PASS");

        // ========================================================
        // Test 3: Global Average, 8x8x8
        // Two groups of four channels.
        // ========================================================

        for (int p = 0; p < 64; p++) begin
            mem[512 + p*2] =
                word4(10, -20, 30, -40);

            mem[513 + p*2] =
                word4(-1, 1, -128, 127);
        end

        run_pool(
            1'b1,
            32'd8, 32'd8, 32'd8,
            64'd2048, 64'd4096
        );

        if (mem[1024] !== word4(10, -20, 30, -40))
            $fatal(1, "Global Average group 0 mismatch");

        if (mem[1025] !== word4(-1, 1, -128, 127))
            $fatal(1, "Global Average group 1 mismatch");

        $display("GLOBAL AVG 8x8x8 PASS");
        // Rectangular 3x5 Global Average, 4 channels.
        for (int p = 0; p < 15; p++)
            mem[1536 + p] = word4(4, -4, 100, -100);

        run_pool(
            1'b1,
            32'd3, 32'd5, 32'd4,
            64'd6144, 64'd7168
        );

        if (mem[1792] !== word4(4, -4, 100, -100))
            $fatal(1, "Rectangular Global Average mismatch");

        $display("GLOBAL AVG 3x5 PASS");
        $display("POOL2D REGRESSION PASS");

        $finish;
    end

endmodule
