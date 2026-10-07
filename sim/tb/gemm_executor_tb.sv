module gemm_executor_tb;

    localparam int unsigned ADDR_WIDTH       = 64;
    localparam int unsigned TILE_COUNT_WIDTH = 16;

    localparam int unsigned ROWS           = 4;
    localparam int unsigned COLS           = 4;
    localparam int unsigned DATA_WIDTH     = 8;
    localparam int unsigned ACC_WIDTH      = 32;
    localparam int unsigned MEM_WORD_WIDTH = 32;

    localparam int unsigned ID_WIDTH = 1;

    localparam int unsigned K_TILE_SIZE = 256;
    localparam int unsigned K_TOTAL     = 260;

    localparam int unsigned A_BUFFER_COUNT = 1;
    localparam int unsigned B_BUFFER_COUNT = 1;

    localparam int unsigned CORE_ADDR_WIDTH =
        $clog2(K_TILE_SIZE);

    localparam int unsigned STRIDE_BYTES =
        K_TOTAL;

    localparam int unsigned WORD_BYTES =
        MEM_WORD_WIDTH / 8;

    localparam int unsigned WORDS_PER_ROW =
        STRIDE_BYTES / WORD_BYTES;

    localparam int unsigned TIMEOUT_CYCLES =
        10000;


    // ============================================================
    // Memory map
    // ============================================================

    localparam logic [ADDR_WIDTH-1:0] A_BASE =
        64'h0000_0000_0000_1000;

    localparam logic [ADDR_WIDTH-1:0] BT_BASE =
        64'h0000_0000_0000_2000;

    localparam logic [ADDR_WIDTH-1:0] C_BASE =
        64'h0000_0000_0000_3000;

    localparam int unsigned A_WORD_BASE =
        32'd1024;

    localparam int unsigned BT_WORD_BASE =
        32'd2048;


    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic reset;

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    // ============================================================
    // Command interface
    // ============================================================

    logic cmd_valid;
    logic cmd_ready;

    logic [31:0] cmd_m;
    logic [31:0] cmd_n;
    logic [31:0] cmd_k;

    logic [ADDR_WIDTH-1:0] cmd_a_base;
    logic [ADDR_WIDTH-1:0] cmd_b_base;
    logic [ADDR_WIDTH-1:0] cmd_c_base;

    logic [31:0] cmd_a_stride_bytes;
    logic [31:0] cmd_b_stride_bytes;
    logic [31:0] cmd_c_stride_bytes;

    logic exec_busy;
    logic exec_done;
    logic exec_error;


    // ============================================================
    // C tile completion
    // ============================================================

    logic                  c_tile_valid;
    logic                  c_tile_accept;
    logic [ADDR_WIDTH-1:0] c_tile_addr;
    logic [31:0]           c_tile_stride_bytes;

    logic                  c_tile_seen;
    logic [ADDR_WIDTH-1:0] c_tile_addr_seen;
    logic [31:0]           c_tile_stride_seen;


    // ============================================================
    // C buffer read
    // ============================================================

    logic                               c_ren;
    logic [CORE_ADDR_WIDTH-1:0]         c_raddr;
    logic [COLS*ACC_WIDTH-1:0]          c_rdata;

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // AXI
    // ============================================================

    logic [ID_WIDTH-1:0]       axi_arid;
    logic [ADDR_WIDTH-1:0]     axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid;
    logic                      axi_arready;

    logic [ID_WIDTH-1:0]       axi_rid;
    logic [MEM_WORD_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast;
    logic                      axi_rvalid;
    logic                      axi_rready;


    // ============================================================
    // External memory
    //
    // 16 KB = 4096 x 32-bit
    // ============================================================

    logic [31:0] memory [0:4095];

    logic                  mem_read_active;
    logic [ADDR_WIDTH-1:0] mem_read_addr_q;
    logic [8:0]            mem_beats_left_q;


    // ============================================================
    // Debug counters
    // ============================================================

    integer cycle_count;

    integer ar_count;
    integer ar_64beat_count;
    integer ar_1beat_count;

    logic saw_a_second_k_tile;
    logic saw_b_second_k_tile;


    // ============================================================
    // DUT
    // ============================================================

    gemm_executor #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),

        .ROWS             (ROWS),
        .COLS             (COLS),

        .DATA_WIDTH       (DATA_WIDTH),
        .ACC_WIDTH        (ACC_WIDTH),
        .MEM_WORD_WIDTH   (MEM_WORD_WIDTH),

        .ID_WIDTH         (ID_WIDTH),

        .K_TILE_SIZE      (K_TILE_SIZE),

        .A_BUFFER_COUNT   (A_BUFFER_COUNT),
        .B_BUFFER_COUNT   (B_BUFFER_COUNT)
    ) u_dut (
        .clk                (clk),
        .reset              (reset),

        // command
        .cmd_valid          (cmd_valid),
        .cmd_ready          (cmd_ready),

        .cmd_m              (cmd_m),
        .cmd_n              (cmd_n),
        .cmd_k              (cmd_k),

        .cmd_a_base         (cmd_a_base),
        .cmd_b_base         (cmd_b_base),
        .cmd_c_base         (cmd_c_base),

        .cmd_a_stride_bytes (cmd_a_stride_bytes),
        .cmd_b_stride_bytes (cmd_b_stride_bytes),
        .cmd_c_stride_bytes (cmd_c_stride_bytes),

        .busy               (exec_busy),
        .done               (exec_done),
        .error              (exec_error),

        // completed C tile
        .c_tile_valid       (c_tile_valid),
        .c_tile_accept      (c_tile_accept),
        .c_tile_addr        (c_tile_addr),
        .c_tile_stride_bytes(c_tile_stride_bytes),

        // C buffer
        .c_ren              (c_ren),
        .c_raddr            (c_raddr),
        .c_rdata            (c_rdata),

        .acc_out            (acc_out),

        // AXI AR
        .m_axi_arid         (axi_arid),
        .m_axi_araddr       (axi_araddr),
        .m_axi_arlen        (axi_arlen),
        .m_axi_arsize       (axi_arsize),
        .m_axi_arburst      (axi_arburst),
        .m_axi_arvalid      (axi_arvalid),
        .m_axi_arready      (axi_arready),

        // AXI R
        .m_axi_rid          (axi_rid),
        .m_axi_rdata        (axi_rdata),
        .m_axi_rresp        (axi_rresp),
        .m_axi_rlast        (axi_rlast),
        .m_axi_rvalid       (axi_rvalid),
        .m_axi_rready       (axi_rready)
    );


    // ============================================================
    // Cycle counter
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            cycle_count <= 0;

        end else begin

            cycle_count <=
                cycle_count + 1;

        end

    end


    // ============================================================
    // C tile monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            c_tile_seen        <= 1'b0;
            c_tile_addr_seen   <= '0;
            c_tile_stride_seen <= '0;

        end else if (
            c_tile_valid &&
            c_tile_accept
        ) begin

            c_tile_seen <=
                1'b1;

            c_tile_addr_seen <=
                c_tile_addr;

            c_tile_stride_seen <=
                c_tile_stride_bytes;

            $display(
                "[%0t] C tile complete: addr=0x%016h stride=%0d",
                $time,
                c_tile_addr,
                c_tile_stride_bytes
            );

        end

    end


    // ============================================================
    // AXI request monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            ar_count <=
                0;

            ar_64beat_count <=
                0;

            ar_1beat_count <=
                0;

            saw_a_second_k_tile <=
                1'b0;

            saw_b_second_k_tile <=
                1'b0;

        end else if (
            axi_arvalid &&
            axi_arready
        ) begin

            ar_count <=
                ar_count + 1;

            if (axi_arlen == 8'd63) begin

                ar_64beat_count <=
                    ar_64beat_count + 1;

            end

            if (axi_arlen == 8'd0) begin

                ar_1beat_count <=
                    ar_1beat_count + 1;

            end

            if (
                axi_araddr ==
                (A_BASE + ADDR_WIDTH'(K_TILE_SIZE))
            ) begin

                saw_a_second_k_tile <=
                    1'b1;

            end

            if (
                axi_araddr ==
                (BT_BASE + ADDR_WIDTH'(K_TILE_SIZE))
            ) begin

                saw_b_second_k_tile <=
                    1'b1;

            end

            $display(
                "[%0t] AXI AR addr=0x%016h beats=%0d",
                $time,
                axi_araddr,
                {1'b0, axi_arlen} + 9'd1
            );

        end

    end


    // ============================================================
    // AXI memory model
    // ============================================================

    assign axi_arready =
        !mem_read_active &&
        !axi_rvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            mem_read_active  <= 1'b0;
            mem_read_addr_q  <= '0;
            mem_beats_left_q <= '0;

            axi_rid    <= '0;
            axi_rdata  <= '0;
            axi_rresp  <= 2'b00;
            axi_rlast  <= 1'b0;
            axi_rvalid <= 1'b0;

        end else begin

            // ----------------------------------------------------
            // AR handshake
            // ----------------------------------------------------

            if (
                axi_arvalid &&
                axi_arready
            ) begin

                if (axi_arsize != 3'd2) begin

                    $fatal(
                        1,
                        "Expected 32-bit AXI beat"
                    );

                end

                if (axi_arburst != 2'b01) begin

                    $fatal(
                        1,
                        "Expected AXI INCR burst"
                    );

                end

                if (axi_arid != '0) begin

                    $fatal(
                        1,
                        "Unexpected AXI ARID"
                    );

                end

                mem_read_active <=
                    1'b1;

                mem_read_addr_q <=
                    axi_araddr;

                mem_beats_left_q <=
                    {1'b0, axi_arlen} +
                    9'd1;

            end


            // ----------------------------------------------------
            // Consume current R beat
            // ----------------------------------------------------

            if (
                axi_rvalid &&
                axi_rready
            ) begin

                axi_rvalid <=
                    1'b0;

                if (
                    mem_beats_left_q ==
                    9'd1
                ) begin

                    mem_read_active <=
                        1'b0;

                    mem_beats_left_q <=
                        '0;

                end else begin

                    mem_beats_left_q <=
                        mem_beats_left_q -
                        9'd1;

                    mem_read_addr_q <=
                        mem_read_addr_q +
                        ADDR_WIDTH'(WORD_BYTES);

                end

            end


            // ----------------------------------------------------
            // Produce next R beat
            // ----------------------------------------------------

            if (
                mem_read_active &&
                !axi_rvalid
            ) begin

                axi_rid <=
                    '0;

                axi_rdata <=
                    memory[
                        mem_read_addr_q[13:2]
                    ];

                axi_rresp <=
                    2'b00;

                axi_rlast <=
                    (
                        mem_beats_left_q ==
                        9'd1
                    );

                axi_rvalid <=
                    1'b1;

            end

        end

    end


    // ============================================================
    // Fill one matrix row
    //
    // Each row contains K=260 identical INT8 elements.
    // ============================================================

    task automatic fill_row (
        input int unsigned base_word,
        input logic [7:0] value
    );

        integer word_idx;

        begin

            for (
                word_idx = 0;
                word_idx < WORDS_PER_ROW;
                word_idx = word_idx + 1
            ) begin

                memory[
                    base_word +
                    word_idx
                ] = {
                    value,
                    value,
                    value,
                    value
                };

            end

        end

    endtask


    // ============================================================
    // C checker
    // ============================================================

    task automatic check_c_row (
        input logic [CORE_ADDR_WIDTH-1:0] addr,

        input logic signed [31:0] e0,
        input logic signed [31:0] e1,
        input logic signed [31:0] e2,
        input logic signed [31:0] e3
    );

        logic signed [31:0] r0;
        logic signed [31:0] r1;
        logic signed [31:0] r2;
        logic signed [31:0] r3;

        begin

            @(negedge clk);

            c_ren   = 1'b1;
            c_raddr = addr;

            @(posedge clk);
            #1;

            r0 = $signed(c_rdata[31:0]);
            r1 = $signed(c_rdata[63:32]);
            r2 = $signed(c_rdata[95:64]);
            r3 = $signed(c_rdata[127:96]);

            $display(
                "[%0t] C[%0d] = [%0d %0d %0d %0d]",
                $time,
                addr,
                r0,
                r1,
                r2,
                r3
            );

            if (
                (r0 !== e0) ||
                (r1 !== e1) ||
                (r2 !== e2) ||
                (r3 !== e3)
            ) begin

                $fatal(
                    1,
                    "C row %0d mismatch: got [%0d %0d %0d %0d], expected [%0d %0d %0d %0d]",
                    addr,
                    r0,
                    r1,
                    r2,
                    r3,
                    e0,
                    e1,
                    e2,
                    e3
                );

            end

            @(negedge clk);

            c_ren =
                1'b0;

        end

    endtask


    // ============================================================
    // Global timeout
    // ============================================================

    initial begin

        repeat (TIMEOUT_CYCLES) begin
            @(posedge clk);
        end

        $display("");
        $display("========================================");
        $display("GEMM EXECUTOR TEST TIMEOUT");
        $display("========================================");
        $display("cycle      = %0d", cycle_count);
        $display("cmd_ready  = %b", cmd_ready);
        $display("busy       = %b", exec_busy);
        $display("done       = %b", exec_done);
        $display("error      = %b", exec_error);
        $display("AR count   = %0d", ar_count);
        $display("ARVALID/R  = %b/%b",
                 axi_arvalid,
                 axi_arready);
        $display("RVALID/R   = %b/%b",
                 axi_rvalid,
                 axi_rready);
        $display("C valid    = %b", c_tile_valid);
        $display("========================================");
        $display("");

        $fatal(
            1,
            "Timeout after %0d cycles",
            TIMEOUT_CYCLES
        );

    end


    // ============================================================
    // Main test
    // ============================================================

    integer init_idx;

    initial begin

        reset =
            1'b1;

        cmd_valid =
            1'b0;

        cmd_m =
            32'd4;

        cmd_n =
            32'd4;

        cmd_k =
            32'd260;

        cmd_a_base =
            A_BASE;

        cmd_b_base =
            BT_BASE;

        cmd_c_base =
            C_BASE;

        cmd_a_stride_bytes =
            32'd260;

        cmd_b_stride_bytes =
            32'd260;

        cmd_c_stride_bytes =
            32'd16;

        c_tile_accept =
            1'b1;

        c_ren =
            1'b0;

        c_raddr =
            '0;


        // ========================================================
        // Clear memory
        // ========================================================

        for (
            init_idx = 0;
            init_idx < 4096;
            init_idx = init_idx + 1
        ) begin

            memory[init_idx] =
                32'd0;

        end


        // ========================================================
        // A = 4 x 260
        //
        // row0 = all 1
        // row1 = all 2
        // row2 = all 3
        // row3 = all 4
        // ========================================================

        fill_row(
            A_WORD_BASE +
            (0 * WORDS_PER_ROW),
            8'd1
        );

        fill_row(
            A_WORD_BASE +
            (1 * WORDS_PER_ROW),
            8'd2
        );

        fill_row(
            A_WORD_BASE +
            (2 * WORDS_PER_ROW),
            8'd3
        );

        fill_row(
            A_WORD_BASE +
            (3 * WORDS_PER_ROW),
            8'd4
        );


        // ========================================================
        // B^T = 4 x 260
        //
        // B column0 = all 1
        // B column1 = all 2
        // B column2 = all 3
        // B column3 = all 4
        //
        // Therefore:
        //
        // C[i][j] = 260 * (i+1) * (j+1)
        // ========================================================

        fill_row(
            BT_WORD_BASE +
            (0 * WORDS_PER_ROW),
            8'd1
        );

        fill_row(
            BT_WORD_BASE +
            (1 * WORDS_PER_ROW),
            8'd2
        );

        fill_row(
            BT_WORD_BASE +
            (2 * WORDS_PER_ROW),
            8'd3
        );

        fill_row(
            BT_WORD_BASE +
            (3 * WORDS_PER_ROW),
            8'd4
        );


        // ========================================================
        // Reset
        // ========================================================

        repeat (4) begin
            @(posedge clk);
        end

        @(negedge clk);

        reset =
            1'b0;

        $display(
            "[%0t] Reset released",
            $time
        );


        // ========================================================
        // Submit one complete GEMM command
        // ========================================================

        @(negedge clk);

        cmd_valid =
            1'b1;

        wait (
            cmd_ready === 1'b1
        );

        $display(
            "[%0t] GEMM command accepted: M=4 N=4 K=260",
            $time
        );

        @(negedge clk);

        cmd_valid =
            1'b0;


        // ========================================================
        // Wait for executor
        // ========================================================

        wait (
            exec_busy === 1'b1
        );

        wait (
            exec_done === 1'b1
        );

        $display(
            "[%0t] GEMM executor done",
            $time
        );

        #1;


        // ========================================================
        // Status checks
        // ========================================================

        if (exec_error) begin

            $fatal(
                1,
                "Executor reported an error"
            );

        end


        if (!c_tile_seen) begin

            $fatal(
                1,
                "C tile completion was not observed"
            );

        end


        if (
            c_tile_addr_seen !==
            C_BASE
        ) begin

            $fatal(
                1,
                "Unexpected C tile address: 0x%016h",
                c_tile_addr_seen
            );

        end


        if (
            c_tile_stride_seen !==
            32'd16
        ) begin

            $fatal(
                1,
                "Unexpected C stride: %0d",
                c_tile_stride_seen
            );

        end


        // ========================================================
        // AXI request checks
        //
        // First K tile:
        // 4 A rows + 4 B rows = 8 requests
        // each = 256 bytes = 64 beats
        //
        // Second K tile:
        // 4 A rows + 4 B rows = 8 requests
        // each = 4 bytes = 1 beat
        //
        // Total = 16 row requests.
        // ========================================================

        if (ar_count != 16) begin

            $fatal(
                1,
                "Expected 16 AXI row requests, got %0d",
                ar_count
            );

        end


        if (ar_64beat_count != 8) begin

            $fatal(
                1,
                "Expected 8 x 64-beat requests, got %0d",
                ar_64beat_count
            );

        end


        if (ar_1beat_count != 8) begin

            $fatal(
                1,
                "Expected 8 x 1-beat requests, got %0d",
                ar_1beat_count
            );

        end


        if (!saw_a_second_k_tile) begin

            $fatal(
                1,
                "A second K tile address was not observed"
            );

        end


        if (!saw_b_second_k_tile) begin

            $fatal(
                1,
                "B second K tile address was not observed"
            );

        end


        // ========================================================
        // Accumulator quick check
        // ========================================================

        if (
            acc_out[0][0] !==
            32'sd260
        ) begin

            $fatal(
                1,
                "Accumulator mismatch: acc[0][0]=%0d",
                acc_out[0][0]
            );

        end


        // ========================================================
        // Complete C check
        // ========================================================

        check_c_row(
            CORE_ADDR_WIDTH'(0),
            32'sd260,
            32'sd520,
            32'sd780,
            32'sd1040
        );

        check_c_row(
            CORE_ADDR_WIDTH'(1),
            32'sd520,
            32'sd1040,
            32'sd1560,
            32'sd2080
        );

        check_c_row(
            CORE_ADDR_WIDTH'(2),
            32'sd780,
            32'sd1560,
            32'sd2340,
            32'sd3120
        );

        check_c_row(
            CORE_ADDR_WIDTH'(3),
            32'sd1040,
            32'sd2080,
            32'sd3120,
            32'sd4160
        );


        $display("");
        $display("========================================");
        $display("ALL GEMM EXECUTOR TESTS PASSED");
        $display("M = 4, N = 4, K = 260");
        $display("K tiling = 256 + 4");
        $display("AXI row requests = %0d", ar_count);
        $display("cycles = %0d", cycle_count);
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
