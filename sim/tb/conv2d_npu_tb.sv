
module conv2d_npu_tb;

    localparam int unsigned ADDR_WIDTH   = 64;
    localparam int unsigned ID_WIDTH     = 1;
    localparam int unsigned MEMORY_WORDS = 8192;

    localparam int unsigned INPUT_H = 4;
    localparam int unsigned INPUT_W = 4;
    localparam int unsigned CIN     = 8;
    localparam int unsigned KH      = 3;
    localparam int unsigned KW      = 3;
    localparam int unsigned COUT    = 4;
    localparam int unsigned HOUT    = 2;
    localparam int unsigned WOUT    = 2;
    localparam int unsigned M       = HOUT * WOUT;
    localparam int unsigned K       = KH * KW * CIN;

    localparam int unsigned INPUT_BASE  = 'h1000;
    localparam int unsigned WEIGHT_BASE = 'h2000;
    localparam int unsigned OUTPUT_BASE = 'h3000;
    localparam int unsigned PARAM_BASE  = 'h4000;
    localparam int unsigned DESC_BASE   = 'h5000;

    logic clk;
    logic reset;
    logic start;
    logic busy;
    logic done;
    logic error;

    logic signed [31:0] acc_out [4][4];

    // ============================================================
    // AXI read
    // ============================================================

    logic [ID_WIDTH-1:0] axi_arid;
    logic [ADDR_WIDTH-1:0] axi_araddr;
    logic [7:0] axi_arlen;
    logic [2:0] axi_arsize;
    logic [1:0] axi_arburst;
    logic axi_arvalid;
    logic axi_arready;

    logic [ID_WIDTH-1:0] axi_rid;
    logic [31:0] axi_rdata;
    logic [1:0] axi_rresp;
    logic axi_rlast;
    logic axi_rvalid;
    logic axi_rready;

    // ============================================================
    // AXI write
    // ============================================================

    logic [ID_WIDTH-1:0] axi_awid;
    logic [ADDR_WIDTH-1:0] axi_awaddr;
    logic [7:0] axi_awlen;
    logic [2:0] axi_awsize;
    logic [1:0] axi_awburst;
    logic axi_awvalid;
    logic axi_awready;

    logic [31:0] axi_wdata;
    logic [3:0] axi_wstrb;
    logic axi_wlast;
    logic axi_wvalid;
    logic axi_wready;

    logic [ID_WIDTH-1:0] axi_bid;
    logic [1:0] axi_bresp;
    logic axi_bvalid;
    logic axi_bready;

    // ============================================================
    // DDR memory
    // ============================================================

    logic [31:0] init_mem [0:MEMORY_WORDS-1];
    logic [31:0] mem [0:MEMORY_WORDS-1];

    logic read_active_q;
    logic [63:0] read_addr_q;
    logic [8:0] read_left_q;
    logic [ID_WIDTH-1:0] read_id_q;

    logic write_active_q;
    logic [63:0] write_addr_q;
    logic [8:0] write_left_q;
    logic [ID_WIDTH-1:0] write_id_q;
    logic bvalid_q;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ============================================================
    // DUT
    // ============================================================

    npu_top u_dut (
        .clk           (clk),
        .reset         (reset),
        .start         (start),
        .desc_base     (64'(DESC_BASE)),
        .desc_count    (16'd1),

        .busy          (busy),
        .done          (done),
        .error         (error),
        .acc_out       (acc_out),

        .m_axi_arid    (axi_arid),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),

        .m_axi_rid     (axi_rid),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rresp   (axi_rresp),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),

        .m_axi_awid    (axi_awid),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),

        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),

        .m_axi_bid     (axi_bid),
        .m_axi_bresp   (axi_bresp),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready)
    );

    // ============================================================
    // AXI read slave
    // ============================================================

    assign axi_arready = !read_active_q;

    assign axi_rvalid = read_active_q;
    assign axi_rdata = mem[int'(read_addr_q >> 2)];
    assign axi_rid = read_id_q;
    assign axi_rresp = 2'b00;
    assign axi_rlast = (read_left_q == 9'd1);

    always_ff @(posedge clk) begin

        if (reset) begin

            read_active_q <= 1'b0;
            read_addr_q <= '0;
            read_left_q <= '0;
            read_id_q <= '0;

        end else begin

            if (axi_arvalid && axi_arready) begin

                if (
                    (axi_arsize != 3'd2) ||
                    (axi_arburst != 2'b01) ||
                    (axi_araddr[1:0] != 2'b00) ||
                    (axi_araddr >= 64'(MEMORY_WORDS * 4))
                ) begin

                    $fatal(1, "Invalid AXI read request");

                end

                read_active_q <= 1'b1;
                read_addr_q <= axi_araddr;
                read_left_q <= {1'b0, axi_arlen} + 9'd1;
                read_id_q <= axi_arid;

            end else if (axi_rvalid && axi_rready) begin

                if (axi_rlast) begin

                    read_active_q <= 1'b0;

                end else begin

                    read_addr_q <= read_addr_q + 64'd4;
                    read_left_q <= read_left_q - 9'd1;

                end

            end

        end

    end

    // ============================================================
    // AXI write slave
    // ============================================================

    assign axi_awready =
        !write_active_q && !bvalid_q;

    assign axi_wready =
        write_active_q;

    assign axi_bvalid =
        bvalid_q;

    assign axi_bid =
        write_id_q;

    assign axi_bresp =
        2'b00;

    // ============================================================
    // DDR initialization and AXI writes
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            write_active_q <= 1'b0;
            write_addr_q <= '0;
            write_left_q <= '0;
            write_id_q <= '0;
            bvalid_q <= 1'b0;

            for (int i = 0; i < MEMORY_WORDS; i++) begin
                mem[i] <= init_mem[i];
            end

        end else begin

            // ----------------------------------------------------
            // Write address channel
            // ----------------------------------------------------

            if (axi_awvalid && axi_awready) begin

                if (
                    (axi_awsize != 3'd2) ||
                    (axi_awburst != 2'b01) ||
                    (axi_awaddr[1:0] != 2'b00) ||
                    (axi_awaddr >= 64'(MEMORY_WORDS * 4))
                ) begin

                    $fatal(1, "Invalid AXI write request");

                end

                write_active_q <= 1'b1;
                write_addr_q <= axi_awaddr;
                write_left_q <= {1'b0, axi_awlen} + 9'd1;
                write_id_q <= axi_awid;

            end

            // ----------------------------------------------------
            // Write data channel
            // ----------------------------------------------------

            if (axi_wvalid && axi_wready) begin

                if (axi_wlast != (write_left_q == 9'd1))
                    $fatal(1, "Unexpected WLAST");

                if (write_addr_q >= 64'(MEMORY_WORDS * 4))
                    $fatal(1, "AXI write address overflow");

                for (int i = 0; i < 4; i++) begin

                    if (axi_wstrb[i]) begin

                        mem[int'(write_addr_q >> 2)]
                           [8*i +: 8] <= axi_wdata[8*i +: 8];

                    end

                end

                if (write_left_q == 9'd1) begin

                    write_active_q <= 1'b0;
                    bvalid_q <= 1'b1;

                end else begin

                    write_addr_q <= write_addr_q + 64'd4;
                    write_left_q <= write_left_q - 9'd1;

                end

            end

            // ----------------------------------------------------
            // Write response channel
            // ----------------------------------------------------

            if (axi_bvalid && axi_bready)
                bvalid_q <= 1'b0;

        end

    end

    // ============================================================
    // Independent input and weight functions
    // ============================================================

    function automatic int signed input_value (
        input int h,
        input int w,
        input int c
    );

        return ((h * 11 + w * 5 + c * 3) % 15) - 7;

    endfunction

    function automatic int signed weight_value (
        input int oc,
        input int kh,
        input int kw,
        input int ci
    );

        return (
            (oc * 13 + kh * 5 + kw * 9 + ci * 7) % 13
        ) - 6;

    endfunction

    function automatic int signed bias_value (
        input int oc
    );

        return (oc - 2) * 4;

    endfunction

    // ============================================================
    // Golden Conv2D + Bias + Requant + ReLU
    // ============================================================

    function automatic int signed golden_value (
        input int oh,
        input int ow,
        input int oc
    );

        int signed accum;
        int signed p;
        int signed q;

        accum = 0;

        for (int kh = 0; kh < int'(KH); kh++) begin

            for (int kw = 0; kw < int'(KW); kw++) begin

                for (int ci = 0; ci < int'(CIN); ci++) begin

                    accum +=
                        input_value(oh + kh, ow + kw, ci) *
                        weight_value(oc, kh, kw, ci);

                end

            end

        end

        accum += bias_value(oc);
        p = accum * 3;

        // Round-to-nearest, ties away from zero.

        if (p >= 0) begin

            q = (p + 2) >>> 2;

        end else begin

            q = -((-p + 2) >>> 2);

        end

        if (q < 0)
            q = 0;

        if (q > 127)
            q = 127;

        return q;

    endfunction

    // ============================================================
    // Memory initialization
    // ============================================================

    task automatic set_byte (
        input int unsigned byte_addr,
        input int signed value
    );

        if ((value < -128) || (value > 127))
            $fatal(1, "Input value out of INT8 range");

        if (byte_addr >= MEMORY_WORDS * 4)
            $fatal(1, "Input memory overflow");

        init_mem[byte_addr >> 2][8*byte_addr[1:0] +: 8] =
            8'(value);

    endtask

    // ============================================================
    // Main test
    // ============================================================

    initial begin : test_main

        int cycles;
        int expected;

        logic [31:0] word_out;
        logic [7:0] actual;

        reset = 1'b1;
        start = 1'b0;

        for (int i = 0; i < MEMORY_WORDS; i++)
            init_mem[i] = '0;

        // --------------------------------------------------------
        // Input HWC
        // --------------------------------------------------------

        for (int h = 0; h < int'(INPUT_H); h++) begin

            for (int w = 0; w < int'(INPUT_W); w++) begin

                for (int ci = 0; ci < int'(CIN); ci++) begin

                    set_byte(
                        INPUT_BASE +
                        (h * int'(INPUT_W) + w) * int'(CIN) + ci,
                        input_value(h, w, ci)
                    );

                end

            end

        end

        // --------------------------------------------------------
        // Weights [Cout][Kh][Kw][Cin]
        // --------------------------------------------------------

        for (int oc = 0; oc < int'(COUT); oc++) begin

            for (int kh = 0; kh < int'(KH); kh++) begin

                for (int kw = 0; kw < int'(KW); kw++) begin

                    for (int ci = 0; ci < int'(CIN); ci++) begin

                        set_byte(
                            WEIGHT_BASE +
                            oc * int'(K) +
                            (kh * int'(KW) + kw) * int'(CIN) + ci,
                            weight_value(oc, kh, kw, ci)
                        );

                    end

                end

            end

        end

        // --------------------------------------------------------
        // Existing epilogue parameter block
        // --------------------------------------------------------

        init_mem[PARAM_BASE/4 + 0] = 32'd3;
        init_mem[PARAM_BASE/4 + 1] = 32'd2;
        init_mem[PARAM_BASE/4 + 2] = 32'd0;
        init_mem[PARAM_BASE/4 + 3] = 32'd0;

        for (int oc = 0; oc < int'(COUT); oc++) begin

            init_mem[PARAM_BASE/4 + 4 + oc] =
                32'(bias_value(oc));

        end

        // --------------------------------------------------------
        // Conv2D descriptor
        // --------------------------------------------------------

        init_mem[DESC_BASE/4 + 0]  = 32'h0000_0702;
        init_mem[DESC_BASE/4 + 1]  = 32'(M);
        init_mem[DESC_BASE/4 + 2]  = 32'(COUT);
        init_mem[DESC_BASE/4 + 3]  = 32'(K);

        init_mem[DESC_BASE/4 + 4]  = 32'(INPUT_BASE);
        init_mem[DESC_BASE/4 + 5]  = 32'd0;
        init_mem[DESC_BASE/4 + 6]  = 32'(WEIGHT_BASE);
        init_mem[DESC_BASE/4 + 7]  = 32'd0;
        init_mem[DESC_BASE/4 + 8]  = 32'(OUTPUT_BASE);
        init_mem[DESC_BASE/4 + 9]  = 32'd0;

        init_mem[DESC_BASE/4 + 10] = {
            16'(INPUT_W),
            16'(INPUT_H)
        };

        init_mem[DESC_BASE/4 + 11] = {
            8'(KW),
            8'(KH),
            16'(CIN)
        };

        init_mem[DESC_BASE/4 + 12] = {
            8'd0,
            8'd0,
            8'd1,
            8'd1
        };

        init_mem[DESC_BASE/4 + 13] = 32'(PARAM_BASE);
        init_mem[DESC_BASE/4 + 14] = 32'd0;
        init_mem[DESC_BASE/4 + 15] = 32'd0;

        // --------------------------------------------------------
        // Start NPU
        // --------------------------------------------------------

        repeat (6) @(negedge clk);
        reset = 1'b0;

        repeat (2) @(negedge clk);
        start = 1'b1;

        @(negedge clk);
        start = 1'b0;

        cycles = 0;

        while (!done && cycles < 250000) begin

            @(negedge clk);
            cycles++;

        end

        if (!done)
            $fatal(1, "Conv2D timeout");

        if (error)
            $fatal(1, "Conv2D command failed");

        // --------------------------------------------------------
        // Compare all 16 INT8 output elements
        // --------------------------------------------------------

        for (int oh = 0; oh < int'(HOUT); oh++) begin

            for (int ow = 0; ow < int'(WOUT); ow++) begin

                word_out =
                    mem[
                        (
                            OUTPUT_BASE +
                            (oh * int'(WOUT) + ow) * int'(COUT)
                        ) / 4
                    ];

                for (int oc = 0; oc < int'(COUT); oc++) begin

                    expected = golden_value(oh, ow, oc);
                    actual = word_out[8*oc +: 8];

                    if (actual !== 8'(expected)) begin

                        $fatal(
                            1,
                            "Conv mismatch (%0d,%0d,%0d): got=%0d expected=%0d",
                            oh, ow, oc, actual, expected
                        );

                    end

                end

            end

        end

        $display(
            "Conv2D + Bias + Requant + ReLU + INT8 writeback PASS cycles=%0d busy=%0b acc00=%0d",
            cycles, busy, acc_out[0][0]
        );

        $finish;

    end

endmodule
