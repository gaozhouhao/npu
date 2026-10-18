
module cnn_pool_npu_tb;

    localparam int unsigned MEM_WORDS = 8192;

    localparam int unsigned INPUT_BASE  = 'h1000;
    localparam int unsigned WEIGHT_BASE = 'h2000;
    localparam int unsigned CONV_BASE   = 'h3000;
    localparam int unsigned POOL_BASE   = 'h3800;
    localparam int unsigned PARAM_BASE  = 'h4000;
    localparam int unsigned DESC_BASE   = 'h5000;

    localparam int unsigned CIN  = 8;
    localparam int unsigned COUT = 4;
    localparam int unsigned K    = 3 * 3 * CIN;

    logic clk;
    logic reset;
    logic start;
    logic busy;
    logic done;
    logic error;

    logic signed [31:0] acc_out [4][4];

    logic [0:0] arid;
    logic [0:0] rid;
    logic [0:0] awid;
    logic [0:0] bid;

    logic [63:0] araddr;
    logic [63:0] awaddr;

    logic [7:0] arlen;
    logic [7:0] awlen;

    logic [2:0] arsize;
    logic [2:0] awsize;

    logic [1:0] arburst;
    logic [1:0] awburst;
    logic [1:0] rresp;
    logic [1:0] bresp;

    logic arvalid;
    logic arready;
    logic rlast;
    logic rvalid;
    logic rready;

    logic awvalid;
    logic awready;
    logic wlast;
    logic wvalid;
    logic wready;
    logic bvalid;
    logic bready;

    logic [31:0] rdata;
    logic [31:0] wdata;
    logic [3:0] wstrb;

    logic [31:0] init_mem [0:MEM_WORDS-1];
    logic [31:0] mem [0:MEM_WORDS-1];

    logic rd_active_q;
    logic wr_active_q;
    logic bvalid_q;

    logic [63:0] rd_addr_q;
    logic [63:0] wr_addr_q;

    logic [8:0] rd_left_q;
    logic [8:0] wr_left_q;

    logic [0:0] rd_id_q;
    logic [0:0] wr_id_q;

    logic [31:0] read_beats_q;
    logic [31:0] write_beats_q;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ============================================================
    // NPU Top
    // ============================================================

    npu_top u_dut (
        .clk           (clk),
        .reset         (reset),
        .start         (start),

        .desc_base     (64'(DESC_BASE)),
        .desc_count    (16'd2),

        .busy          (busy),
        .done          (done),
        .error         (error),
        .acc_out       (acc_out),

        .m_axi_arid    (arid),
        .m_axi_araddr  (araddr),
        .m_axi_arlen   (arlen),
        .m_axi_arsize  (arsize),
        .m_axi_arburst (arburst),
        .m_axi_arvalid (arvalid),
        .m_axi_arready (arready),

        .m_axi_rid     (rid),
        .m_axi_rdata   (rdata),
        .m_axi_rresp   (rresp),
        .m_axi_rlast   (rlast),
        .m_axi_rvalid  (rvalid),
        .m_axi_rready  (rready),

        .m_axi_awid    (awid),
        .m_axi_awaddr  (awaddr),
        .m_axi_awlen   (awlen),
        .m_axi_awsize  (awsize),
        .m_axi_awburst (awburst),
        .m_axi_awvalid (awvalid),
        .m_axi_awready (awready),

        .m_axi_wdata   (wdata),
        .m_axi_wstrb   (wstrb),
        .m_axi_wlast   (wlast),
        .m_axi_wvalid  (wvalid),
        .m_axi_wready  (wready),

        .m_axi_bid     (bid),
        .m_axi_bresp   (bresp),
        .m_axi_bvalid  (bvalid),
        .m_axi_bready  (bready)
    );

    // ============================================================
    // AXI Read Memory Model
    // ============================================================

    assign arready = !rd_active_q;

    assign rid = rd_id_q;
    assign rvalid = rd_active_q;
    assign rdata = mem[int'(rd_addr_q >> 2)];
    assign rresp = 2'b00;
    assign rlast = (rd_left_q == 9'd1);

    always_ff @(posedge clk) begin

        if (reset) begin

            rd_active_q <= 1'b0;
            rd_addr_q <= '0;
            rd_left_q <= '0;
            rd_id_q <= '0;
            read_beats_q <= '0;

        end else begin

            if (arvalid && arready) begin

                if (
                    arsize != 3'd2 ||
                    arburst != 2'b01 ||
                    araddr[1:0] != 2'b00 ||
                    araddr >= 64'(MEM_WORDS * 4)
                ) begin
                    $fatal(1, "Invalid AXI read request");
                end

                rd_active_q <= 1'b1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0, arlen} + 9'd1;
                rd_id_q <= arid;

            end else if (rvalid && rready) begin

                read_beats_q <= read_beats_q + 32'd1;

                if (rlast) begin

                    rd_active_q <= 1'b0;

                end else begin

                    rd_addr_q <= rd_addr_q + 64'd4;
                    rd_left_q <= rd_left_q - 9'd1;

                end

            end

        end

    end

    // ============================================================
    // AXI Write Memory Model
    // ============================================================

    assign awready = !wr_active_q && !bvalid_q;
    assign wready = wr_active_q;

    assign bid = wr_id_q;
    assign bresp = 2'b00;
    assign bvalid = bvalid_q;

    always_ff @(posedge clk) begin

        if (reset) begin

            wr_active_q <= 1'b0;
            wr_addr_q <= '0;
            wr_left_q <= '0;
            wr_id_q <= '0;
            bvalid_q <= 1'b0;
            write_beats_q <= '0;

            for (int i = 0; i < MEM_WORDS; i++) begin
                mem[i] <= init_mem[i];
            end

        end else begin

            if (awvalid && awready) begin

                if (
                    awsize != 3'd2 ||
                    awburst != 2'b01 ||
                    awaddr[1:0] != 2'b00 ||
                    awaddr >= 64'(MEM_WORDS * 4)
                ) begin
                    $fatal(1, "Invalid AXI write request");
                end

                wr_active_q <= 1'b1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0, awlen} + 9'd1;
                wr_id_q <= awid;

            end

            if (wvalid && wready) begin

                if (
                    wlast != (wr_left_q == 9'd1) ||
                    wr_addr_q >= 64'(MEM_WORDS * 4)
                ) begin
                    $fatal(1, "Invalid AXI write data");
                end

                for (int i = 0; i < 4; i++) begin

                    if (wstrb[i]) begin

                        mem[int'(wr_addr_q >> 2)][8*i +: 8] <=
                            wdata[8*i +: 8];

                    end

                end

                write_beats_q <= write_beats_q + 32'd1;

                if (wr_left_q == 9'd1) begin

                    wr_active_q <= 1'b0;
                    bvalid_q <= 1'b1;

                end else begin

                    wr_addr_q <= wr_addr_q + 64'd4;
                    wr_left_q <= wr_left_q - 9'd1;

                end

            end

            if (bvalid && bready)
                bvalid_q <= 1'b0;

        end

    end

    // ============================================================
    // Input Pattern
    // ============================================================

    function automatic int signed xval(
        input int h,
        input int w,
        input int c
    );

        return ((h * 11 + w * 5 + c * 3) % 15) - 7;

    endfunction

    // ============================================================
    // Weight Pattern
    // ============================================================

    function automatic int signed kval(
        input int oc,
        input int kh,
        input int kw,
        input int ci
    );

        return (
            (oc * 13 + kh * 5 + kw * 9 + ci * 7) % 13
        ) - 6;

    endfunction

    function automatic int signed biasval(
        input int oc
    );

        return (oc - 2) * 4;

    endfunction

    // ============================================================
    // Conv2D Golden Reference
    // ============================================================

    function automatic int signed conv_golden(
        input int oh,
        input int ow,
        input int oc
    );

        int signed acc;
        int signed p;
        int signed q;

        acc = biasval(oc);

        for (int kh = 0; kh < 3; kh++) begin

            for (int kw = 0; kw < 3; kw++) begin

                for (int ci = 0; ci < int'(CIN); ci++) begin

                    acc +=
                        xval(oh + kh, ow + kw, ci) *
                        kval(oc, kh, kw, ci);

                end

            end

        end

        p = acc * 3;

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
    // MaxPool Golden Reference
    // ============================================================

    function automatic int signed pool_golden(
        input int oc
    );

        int signed best;
        int signed value;

        best = -128;

        for (int h = 0; h < 2; h++) begin

            for (int w = 0; w < 2; w++) begin

                value = conv_golden(h, w, oc);

                if (value > best)
                    best = value;

            end

        end

        return best;

    endfunction

    // ============================================================
    // Memory Initialization Helper
    //
    // Validate all 32 bits before narrowing to INT8.
    // This avoids Verilator UNUSEDSIGNAL on value[31:8].
    // ============================================================

    task automatic put_byte(
        input int unsigned addr,
        input int signed value
    );

        if ((value < -128) || (value > 127)) begin
            $fatal(
                1,
                "INT8 initialization out of range: %0d",
                value
            );
        end

        if (addr >= MEM_WORDS * 4) begin
            $fatal(1, "Memory initialization out of range");
        end

        init_mem[addr >> 2][8*addr[1:0] +: 8] =
            8'(value);

    endtask

    // ============================================================
    // Main System-Level Test
    // ============================================================

    initial begin : run

        int cycles;
        logic [31:0] word_out;

        reset = 1'b1;
        start = 1'b0;

        for (int i = 0; i < MEM_WORDS; i++) begin
            init_mem[i] = '0;
        end

        // --------------------------------------------------------
        // Input HWC
        // --------------------------------------------------------

        for (int h = 0; h < 4; h++) begin

            for (int w = 0; w < 4; w++) begin

                for (int ci = 0; ci < int'(CIN); ci++) begin

                    put_byte(
                        INPUT_BASE +
                        (h * 4 + w) * int'(CIN) + ci,
                        xval(h, w, ci)
                    );

                end

            end

        end

        // --------------------------------------------------------
        // Weights [Cout][Kh][Kw][Cin]
        // --------------------------------------------------------

        for (int oc = 0; oc < int'(COUT); oc++) begin

            for (int kh = 0; kh < 3; kh++) begin

                for (int kw = 0; kw < 3; kw++) begin

                    for (int ci = 0; ci < int'(CIN); ci++) begin

                        put_byte(
                            WEIGHT_BASE +
                            oc * int'(K) +
                            (kh * 3 + kw) * int'(CIN) + ci,
                            kval(oc, kh, kw, ci)
                        );

                    end

                end

            end

        end

        // --------------------------------------------------------
        // Epilogue Parameters
        // --------------------------------------------------------

        init_mem[PARAM_BASE/4 + 0] = 32'd3;
        init_mem[PARAM_BASE/4 + 1] = 32'd2;

        for (int oc = 0; oc < int'(COUT); oc++) begin

            init_mem[PARAM_BASE/4 + 4 + oc] =
                32'(biasval(oc));

        end

        // --------------------------------------------------------
        // Descriptor 0: Conv2D
        //
        // 4x4x8 -> 2x2x4
        // Conv + Bias + Requant + ReLU
        // --------------------------------------------------------

        init_mem[DESC_BASE/4 + 0]  = 32'h0000_0702;
        init_mem[DESC_BASE/4 + 1]  = 32'd4;
        init_mem[DESC_BASE/4 + 2]  = 32'd4;
        init_mem[DESC_BASE/4 + 3]  = 32'(K);

        init_mem[DESC_BASE/4 + 4]  = 32'(INPUT_BASE);
        init_mem[DESC_BASE/4 + 6]  = 32'(WEIGHT_BASE);
        init_mem[DESC_BASE/4 + 8]  = 32'(CONV_BASE);

        init_mem[DESC_BASE/4 + 10] = {16'd4, 16'd4};
        init_mem[DESC_BASE/4 + 11] = {
            8'd3,
            8'd3,
            16'(CIN)
        };

        init_mem[DESC_BASE/4 + 12] = {
            8'd0,
            8'd0,
            8'd1,
            8'd1
        };

        init_mem[DESC_BASE/4 + 13] = 32'(PARAM_BASE);

        // --------------------------------------------------------
        // Descriptor 1: MaxPool2D
        //
        // 2x2x4 -> 1x1x4
        // --------------------------------------------------------

        init_mem[DESC_BASE/4 + 16] = 32'h0000_0003;
        init_mem[DESC_BASE/4 + 17] = 32'd2;
        init_mem[DESC_BASE/4 + 18] = 32'd2;
        init_mem[DESC_BASE/4 + 19] = 32'(COUT);

        init_mem[DESC_BASE/4 + 20] = 32'(CONV_BASE);
        init_mem[DESC_BASE/4 + 24] = 32'(POOL_BASE);

        // --------------------------------------------------------
        // Reset and start
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
            $fatal(1, "Conv->Pool chain timed out");

        if (error)
            $fatal(1, "NPU error during Conv->Pool chain");

        if (write_beats_q != 32'd5) begin

            $fatal(
                1,
                "Expected 4 Conv writes + 1 Pool write, got=%0d",
                write_beats_q
            );

        end

        // --------------------------------------------------------
        // Check intermediate Conv2D output
        // --------------------------------------------------------

        for (int oh = 0; oh < 2; oh++) begin

            for (int ow = 0; ow < 2; ow++) begin

                word_out = mem[CONV_BASE/4 + oh * 2 + ow];

                for (int oc = 0; oc < int'(COUT); oc++) begin

                    if (
                        word_out[8*oc +: 8] !==
                        8'(conv_golden(oh, ow, oc))
                    ) begin

                        $fatal(
                            1,
                            "Conv mismatch at (%0d,%0d,%0d)",
                            oh,
                            ow,
                            oc
                        );

                    end

                end

            end

        end

        // --------------------------------------------------------
        // Check final MaxPool output
        // --------------------------------------------------------

        word_out = mem[POOL_BASE/4];

        for (int oc = 0; oc < int'(COUT); oc++) begin

            if (
                word_out[8*oc +: 8] !==
                8'(pool_golden(oc))
            ) begin

                $fatal(
                    1,
                    "Pool mismatch at channel %0d",
                    oc
                );

            end

        end

        $display(
            "Conv2D -> MaxPool2D system PASS: cycles=%0d read_beats=%0d write_beats=%0d busy=%0b acc00=%0d",
            cycles,
            read_beats_q,
            write_beats_q,
            busy,
            acc_out[0][0]
        );

        $finish;

    end

endmodule
