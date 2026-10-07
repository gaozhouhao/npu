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

    localparam int unsigned M_TOTAL = 8;
    localparam int unsigned N_TOTAL = 8;
    localparam int unsigned K_TOTAL = 260;

    localparam int unsigned A_BUFFER_COUNT = 1;
    localparam int unsigned B_BUFFER_COUNT = 1;

    localparam int unsigned WORD_BYTES =
        MEM_WORD_WIDTH / 8;

    localparam int unsigned AB_STRIDE_BYTES =
        K_TOTAL;

    localparam int unsigned C_STRIDE_BYTES =
        N_TOTAL * (ACC_WIDTH / 8);

    localparam int unsigned WORDS_PER_AB_ROW =
        AB_STRIDE_BYTES / WORD_BYTES;

    localparam int unsigned TIMEOUT_CYCLES =
        30000;


    // ============================================================
    // External memory map
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

    localparam int unsigned C_WORD_BASE =
        32'd3072;


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
    // GEMM command
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
    // Debug accumulator
    // ============================================================

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // AXI Read Address Channel
    // ============================================================

    logic [ID_WIDTH-1:0]       axi_arid;
    logic [ADDR_WIDTH-1:0]     axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid;
    logic                      axi_arready;


    // ============================================================
    // AXI Read Data Channel
    // ============================================================

    logic [ID_WIDTH-1:0]       axi_rid;
    logic [MEM_WORD_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast;
    logic                      axi_rvalid;
    logic                      axi_rready;


    // ============================================================
    // AXI Write Address Channel
    // ============================================================

    logic [ID_WIDTH-1:0]       axi_awid;
    logic [ADDR_WIDTH-1:0]     axi_awaddr;
    logic [7:0]                axi_awlen;
    logic [2:0]                axi_awsize;
    logic [1:0]                axi_awburst;
    logic                      axi_awvalid;
    logic                      axi_awready;


    // ============================================================
    // AXI Write Data Channel
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        axi_wdata;

    logic [(MEM_WORD_WIDTH/8)-1:0]
        axi_wstrb;

    logic axi_wlast;
    logic axi_wvalid;
    logic axi_wready;


    // ============================================================
    // AXI Write Response Channel
    // ============================================================

    logic [ID_WIDTH-1:0] axi_bid;
    logic [1:0]          axi_bresp;
    logic                axi_bvalid;
    logic                axi_bready;


    // ============================================================
    // External memory
    //
    // Separate read/write arrays keep this TB simple and avoid
    // multiple procedural writers.
    // ============================================================

    logic [31:0] read_memory  [0:4095];
    logic [31:0] write_memory [0:4095];


    // ============================================================
    // AXI read-slave state
    // ============================================================

    logic                  rd_active_q;
    logic [ADDR_WIDTH-1:0] rd_addr_q;
    logic [8:0]            rd_beats_left_q;


    // ============================================================
    // AXI write-slave state
    // ============================================================

    logic                  wr_active_q;
    logic [ADDR_WIDTH-1:0] wr_addr_q;
    logic [8:0]            wr_beats_left_q;

    logic [ID_WIDTH-1:0]
        wr_id_q;


    // ============================================================
    // Counters
    // ============================================================

    integer cycle_count;

    integer ar_count;
    integer ar_64beat_count;
    integer ar_1beat_count;

    integer aw_count;
    integer w_count;
    integer b_count;


    // ============================================================
    // Address-coverage flags
    // ============================================================

    logic saw_a_m1_k0;
    logic saw_a_m1_k1;

    logic saw_b_n1_k0;
    logic saw_b_n1_k1;

    logic saw_c_tile_00;
    logic saw_c_tile_01;
    logic saw_c_tile_10;
    logic saw_c_tile_11;


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

        // --------------------------------------------------------
        // GEMM command
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // Status
        // --------------------------------------------------------

        .busy               (exec_busy),
        .done               (exec_done),
        .error              (exec_error),

        .acc_out            (acc_out),

        // --------------------------------------------------------
        // AXI Read Address
        // --------------------------------------------------------

        .m_axi_arid         (axi_arid),
        .m_axi_araddr       (axi_araddr),
        .m_axi_arlen        (axi_arlen),
        .m_axi_arsize       (axi_arsize),
        .m_axi_arburst      (axi_arburst),
        .m_axi_arvalid      (axi_arvalid),
        .m_axi_arready      (axi_arready),

        // --------------------------------------------------------
        // AXI Read Data
        // --------------------------------------------------------

        .m_axi_rid          (axi_rid),
        .m_axi_rdata        (axi_rdata),
        .m_axi_rresp        (axi_rresp),
        .m_axi_rlast        (axi_rlast),
        .m_axi_rvalid       (axi_rvalid),
        .m_axi_rready       (axi_rready),

        // --------------------------------------------------------
        // AXI Write Address
        // --------------------------------------------------------

        .m_axi_awid         (axi_awid),
        .m_axi_awaddr       (axi_awaddr),
        .m_axi_awlen        (axi_awlen),
        .m_axi_awsize       (axi_awsize),
        .m_axi_awburst      (axi_awburst),
        .m_axi_awvalid      (axi_awvalid),
        .m_axi_awready      (axi_awready),

        // --------------------------------------------------------
        // AXI Write Data
        // --------------------------------------------------------

        .m_axi_wdata        (axi_wdata),
        .m_axi_wstrb        (axi_wstrb),
        .m_axi_wlast        (axi_wlast),
        .m_axi_wvalid       (axi_wvalid),
        .m_axi_wready       (axi_wready),

        // --------------------------------------------------------
        // AXI Write Response
        // --------------------------------------------------------

        .m_axi_bid          (axi_bid),
        .m_axi_bresp        (axi_bresp),
        .m_axi_bvalid       (axi_bvalid),
        .m_axi_bready       (axi_bready)
    );


    // ============================================================
    // Cycle counter
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            cycle_count <=
                0;

        end else begin

            cycle_count <=
                cycle_count + 1;

        end

    end


    // ============================================================
    // AXI Read monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            ar_count <=
                0;

            ar_64beat_count <=
                0;

            ar_1beat_count <=
                0;

            saw_a_m1_k0 <=
                1'b0;

            saw_a_m1_k1 <=
                1'b0;

            saw_b_n1_k0 <=
                1'b0;

            saw_b_n1_k1 <=
                1'b0;

        end else if (
            axi_arvalid &&
            axi_arready
        ) begin

            ar_count <=
                ar_count + 1;


            // ----------------------------------------------------
            // Full K tile = 256 bytes = 64 beats
            // ----------------------------------------------------

            if (
                axi_arlen ==
                8'd63
            ) begin

                ar_64beat_count <=
                    ar_64beat_count + 1;

            end


            // ----------------------------------------------------
            // K tail = 4 bytes = 1 beat
            // ----------------------------------------------------

            if (
                axi_arlen ==
                8'd0
            ) begin

                ar_1beat_count <=
                    ar_1beat_count + 1;

            end


            // ----------------------------------------------------
            // Verify second M tile addresses for A.
            //
            // m_start = 4
            // A offset = 4 * 260 = 1040 bytes
            // ----------------------------------------------------

            if (
                axi_araddr ==
                (
                    A_BASE +
                    ADDR_WIDTH'(
                        4 * AB_STRIDE_BYTES
                    )
                )
            ) begin

                saw_a_m1_k0 <=
                    1'b1;

            end


            if (
                axi_araddr ==
                (
                    A_BASE +
                    ADDR_WIDTH'(
                        (4 * AB_STRIDE_BYTES) +
                        K_TILE_SIZE
                    )
                )
            ) begin

                saw_a_m1_k1 <=
                    1'b1;

            end


            // ----------------------------------------------------
            // Verify second N tile addresses for B^T.
            //
            // n_start = 4
            // BT offset = 4 * 260 = 1040 bytes
            // ----------------------------------------------------

            if (
                axi_araddr ==
                (
                    BT_BASE +
                    ADDR_WIDTH'(
                        4 * AB_STRIDE_BYTES
                    )
                )
            ) begin

                saw_b_n1_k0 <=
                    1'b1;

            end


            if (
                axi_araddr ==
                (
                    BT_BASE +
                    ADDR_WIDTH'(
                        (4 * AB_STRIDE_BYTES) +
                        K_TILE_SIZE
                    )
                )
            ) begin

                saw_b_n1_k1 <=
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
    // AXI Read slave
    // ============================================================

    assign axi_arready =
        !rd_active_q &&
        !axi_rvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            rd_active_q <=
                1'b0;

            rd_addr_q <=
                '0;

            rd_beats_left_q <=
                '0;

            axi_rid <=
                '0;

            axi_rdata <=
                '0;

            axi_rresp <=
                2'b00;

            axi_rlast <=
                1'b0;

            axi_rvalid <=
                1'b0;

        end else begin

            // ----------------------------------------------------
            // Accept AR
            // ----------------------------------------------------

            if (
                axi_arvalid &&
                axi_arready
            ) begin

                if (
                    axi_arsize !=
                    3'd2
                ) begin

                    $fatal(
                        1,
                        "AXI read ARSIZE must be 2"
                    );

                end


                if (
                    axi_arburst !=
                    2'b01
                ) begin

                    $fatal(
                        1,
                        "AXI read burst must be INCR"
                    );

                end


                if (
                    axi_arid !=
                    '0
                ) begin

                    $fatal(
                        1,
                        "Unexpected read ARID"
                    );

                end


                rd_active_q <=
                    1'b1;

                rd_addr_q <=
                    axi_araddr;

                rd_beats_left_q <=
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
                    rd_beats_left_q ==
                    9'd1
                ) begin

                    rd_active_q <=
                        1'b0;

                    rd_beats_left_q <=
                        '0;

                end else begin

                    rd_beats_left_q <=
                        rd_beats_left_q -
                        9'd1;

                    rd_addr_q <=
                        rd_addr_q +
                        ADDR_WIDTH'(WORD_BYTES);

                end

            end


            // ----------------------------------------------------
            // Generate next R beat
            // ----------------------------------------------------

            if (
                rd_active_q &&
                !axi_rvalid
            ) begin

                axi_rid <=
                    '0;

                axi_rdata <=
                    read_memory[
                        rd_addr_q[13:2]
                    ];

                axi_rresp <=
                    2'b00;

                axi_rlast <=
                    (
                        rd_beats_left_q ==
                        9'd1
                    );

                axi_rvalid <=
                    1'b1;

            end

        end

    end


    // ============================================================
    // AXI Write monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            aw_count <=
                0;

            w_count <=
                0;

            b_count <=
                0;

            saw_c_tile_00 <=
                1'b0;

            saw_c_tile_01 <=
                1'b0;

            saw_c_tile_10 <=
                1'b0;

            saw_c_tile_11 <=
                1'b0;

        end else begin

            if (
                axi_awvalid &&
                axi_awready
            ) begin

                aw_count <=
                    aw_count + 1;


                // ------------------------------------------------
                // First row of C tile (m=0,n=0)
                // ------------------------------------------------

                if (
                    axi_awaddr ==
                    C_BASE
                ) begin

                    saw_c_tile_00 <=
                        1'b1;

                end


                // ------------------------------------------------
                // First row of C tile (m=0,n=1)
                //
                // n_start = 4
                // 4 * INT32 = 16 bytes
                // ------------------------------------------------

                if (
                    axi_awaddr ==
                    (
                        C_BASE +
                        ADDR_WIDTH'(16)
                    )
                ) begin

                    saw_c_tile_01 <=
                        1'b1;

                end


                // ------------------------------------------------
                // First row of C tile (m=1,n=0)
                //
                // m_start = 4
                // 4 * C_stride = 4 * 32 = 128
                // ------------------------------------------------

                if (
                    axi_awaddr ==
                    (
                        C_BASE +
                        ADDR_WIDTH'(128)
                    )
                ) begin

                    saw_c_tile_10 <=
                        1'b1;

                end


                // ------------------------------------------------
                // First row of C tile (m=1,n=1)
                //
                // 128 + 16 = 144
                // ------------------------------------------------

                if (
                    axi_awaddr ==
                    (
                        C_BASE +
                        ADDR_WIDTH'(144)
                    )
                ) begin

                    saw_c_tile_11 <=
                        1'b1;

                end


                $display(
                    "[%0t] AXI AW addr=0x%016h beats=%0d",
                    $time,
                    axi_awaddr,
                    {1'b0, axi_awlen} + 9'd1
                );

            end


            if (
                axi_wvalid &&
                axi_wready
            ) begin

                w_count <=
                    w_count + 1;

            end


            if (
                axi_bvalid &&
                axi_bready
            ) begin

                b_count <=
                    b_count + 1;

            end

        end

    end


    // ============================================================
    // AXI Write slave
    // ============================================================

    assign axi_awready =
        !wr_active_q &&
        !axi_bvalid;

    assign axi_wready =
        wr_active_q &&
        !axi_bvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            wr_active_q <=
                1'b0;

            wr_addr_q <=
                '0;

            wr_beats_left_q <=
                '0;

            wr_id_q <=
                '0;

            axi_bid <=
                '0;

            axi_bresp <=
                2'b00;

            axi_bvalid <=
                1'b0;

        end else begin

            // ----------------------------------------------------
            // AW
            // ----------------------------------------------------

            if (
                axi_awvalid &&
                axi_awready
            ) begin

                if (
                    axi_awsize !=
                    3'd2
                ) begin

                    $fatal(
                        1,
                        "AXI write AWSIZE must be 2"
                    );

                end


                if (
                    axi_awburst !=
                    2'b01
                ) begin

                    $fatal(
                        1,
                        "AXI write burst must be INCR"
                    );

                end


                if (
                    axi_awid !=
                    '0
                ) begin

                    $fatal(
                        1,
                        "Unexpected write AWID"
                    );

                end


                // One 4x4 C tile row:
                //
                // 4 INT32
                // = 16 bytes
                // = 4 AXI beats
                //
                // AWLEN = beats - 1 = 3.

                if (
                    axi_awlen !=
                    8'd3
                ) begin

                    $fatal(
                        1,
                        "Expected 4-beat C row, AWLEN=%0d",
                        axi_awlen
                    );

                end


                wr_active_q <=
                    1'b1;

                wr_addr_q <=
                    axi_awaddr;

                wr_beats_left_q <=
                    {1'b0, axi_awlen} +
                    9'd1;

                wr_id_q <=
                    axi_awid;

            end


            // ----------------------------------------------------
            // W
            // ----------------------------------------------------

            if (
                axi_wvalid &&
                axi_wready
            ) begin

                if (
                    axi_wstrb !=
                    {WORD_BYTES{1'b1}}
                ) begin

                    $fatal(
                        1,
                        "Unexpected WSTRB"
                    );

                end


                if (
                    axi_wlast !=
                    (
                        wr_beats_left_q ==
                        9'd1
                    )
                ) begin

                    $fatal(
                        1,
                        "WLAST mismatch"
                    );

                end


                write_memory[
                    wr_addr_q[13:2]
                ] <=
                    axi_wdata;


                if (
                    wr_beats_left_q ==
                    9'd1
                ) begin

                    wr_active_q <=
                        1'b0;

                    wr_beats_left_q <=
                        '0;

                    axi_bid <=
                        wr_id_q;

                    axi_bresp <=
                        2'b00;

                    axi_bvalid <=
                        1'b1;

                end else begin

                    wr_beats_left_q <=
                        wr_beats_left_q -
                        9'd1;

                    wr_addr_q <=
                        wr_addr_q +
                        ADDR_WIDTH'(WORD_BYTES);

                end

            end


            // ----------------------------------------------------
            // B
            // ----------------------------------------------------

            if (
                axi_bvalid &&
                axi_bready
            ) begin

                axi_bvalid <=
                    1'b0;

            end

        end

    end


    // ============================================================
    // Fill one A / B^T row
    // ============================================================

    task automatic fill_ab_row (
        input int unsigned base_word,
        input logic [7:0] value
    );

        integer word_idx;

        begin

            for (
                word_idx = 0;
                word_idx < WORDS_PER_AB_ROW;
                word_idx = word_idx + 1
            ) begin

                read_memory[
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
    // Check complete C matrix in external memory
    //
    // A[i][k] = i + 1
    // B[k][j] = j + 1
    //
    // Therefore:
    //
    // C[i][j] =
    //     sum(k=0..259) ((i+1)*(j+1))
    //
    // = 260 * (i+1) * (j+1)
    // ============================================================

    task automatic check_c_matrix;

        integer row_idx;
        integer col_idx;

        integer signed expected;

        logic signed [31:0]
            actual;

        begin

            $display("");
            $display("DDR C matrix:");

            for (
                row_idx = 0;
                row_idx < M_TOTAL;
                row_idx = row_idx + 1
            ) begin

                $write(
                    "row %0d:",
                    row_idx
                );

                for (
                    col_idx = 0;
                    col_idx < N_TOTAL;
                    col_idx = col_idx + 1
                ) begin

                    actual =
                        $signed(
                            write_memory[
                                C_WORD_BASE +
                                (row_idx * N_TOTAL) +
                                col_idx
                            ]
                        );

                    expected =
                        K_TOTAL *
                        (row_idx + 1) *
                        (col_idx + 1);


                    $write(
                        " %0d",
                        actual
                    );


                    if (
                        actual !==
                        expected
                    ) begin

                        $display("");

                        $fatal(
                            1,
                            "C[%0d][%0d] mismatch: got %0d expected %0d",
                            row_idx,
                            col_idx,
                            actual,
                            expected
                        );

                    end

                end

                $display("");

            end

        end

    endtask


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        repeat (TIMEOUT_CYCLES) begin
            @(posedge clk);
        end

        $display("");
        $display("========================================");
        $display("MULTI-TILE GEMM TEST TIMEOUT");
        $display("========================================");

        $display(
            "cycle     = %0d",
            cycle_count
        );

        $display(
            "cmd_ready = %b",
            cmd_ready
        );

        $display(
            "busy      = %b",
            exec_busy
        );

        $display(
            "done      = %b",
            exec_done
        );

        $display(
            "error     = %b",
            exec_error
        );

        $display(
            "AR count  = %0d",
            ar_count
        );

        $display(
            "AW count  = %0d",
            aw_count
        );

        $display(
            "W count   = %0d",
            w_count
        );

        $display(
            "B count   = %0d",
            b_count
        );

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
    integer row_idx;

    initial begin

        reset =
            1'b1;

        cmd_valid =
            1'b0;


        // ========================================================
        // GEMM command
        // ========================================================

        cmd_m =
            32'(M_TOTAL);

        cmd_n =
            32'(N_TOTAL);

        cmd_k =
            32'(K_TOTAL);

        cmd_a_base =
            A_BASE;

        cmd_b_base =
            BT_BASE;

        cmd_c_base =
            C_BASE;

        cmd_a_stride_bytes =
            32'(AB_STRIDE_BYTES);

        cmd_b_stride_bytes =
            32'(AB_STRIDE_BYTES);

        cmd_c_stride_bytes =
            32'(C_STRIDE_BYTES);


        // ========================================================
        // Initialize memories
        // ========================================================

        for (
            init_idx = 0;
            init_idx < 4096;
            init_idx = init_idx + 1
        ) begin

            read_memory[init_idx] =
                32'd0;

            write_memory[init_idx] =
                32'hDEAD_BEEF;

        end


        // ========================================================
        // A = 8 x 260
        //
        // row0 = all 1
        // row1 = all 2
        // ...
        // row7 = all 8
        // ========================================================

        for (
            row_idx = 0;
            row_idx < M_TOTAL;
            row_idx = row_idx + 1
        ) begin

            fill_ab_row(
                A_WORD_BASE +
                (
                    row_idx *
                    WORDS_PER_AB_ROW
                ),
                8'(row_idx + 1)
            );

        end


        // ========================================================
        // B^T = 8 x 260
        //
        // B column j corresponds to BT row j.
        //
        // BT row0 = all 1
        // BT row1 = all 2
        // ...
        // BT row7 = all 8
        // ========================================================

        for (
            row_idx = 0;
            row_idx < N_TOTAL;
            row_idx = row_idx + 1
        ) begin

            fill_ab_row(
                BT_WORD_BASE +
                (
                    row_idx *
                    WORDS_PER_AB_ROW
                ),
                8'(row_idx + 1)
            );

        end


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
        // Submit ONE complete GEMM command
        // ========================================================

        @(negedge clk);

        cmd_valid =
            1'b1;

        wait (
            cmd_ready ===
            1'b1
        );

        $display(
            "[%0t] GEMM command accepted: M=%0d N=%0d K=%0d",
            $time,
            M_TOTAL,
            N_TOTAL,
            K_TOTAL
        );

        @(negedge clk);

        cmd_valid =
            1'b0;


        // ========================================================
        // Wait for full:
        //
        // DDR -> NPU -> DDR
        // ========================================================

        wait (
            exec_busy ===
            1'b1
        );

        wait (
            exec_done ===
            1'b1
        );

        $display(
            "[%0t] GEMM executor done",
            $time
        );

        #1;


        // ========================================================
        // Error status
        // ========================================================

        if (exec_error) begin

            $fatal(
                1,
                "Executor reported an error"
            );

        end


        // ========================================================
        // AXI read counts
        //
        // 4 C tiles
        // x 2 K tiles
        // x (4 A rows + 4 B rows)
        //
        // = 64 requests
        //
        // 32 full-K row requests
        // 32 K-tail row requests
        // ========================================================

        if (
            ar_count !=
            64
        ) begin

            $fatal(
                1,
                "Expected 64 AXI read requests, got %0d",
                ar_count
            );

        end


        if (
            ar_64beat_count !=
            32
        ) begin

            $fatal(
                1,
                "Expected 32 x 64-beat reads, got %0d",
                ar_64beat_count
            );

        end


        if (
            ar_1beat_count !=
            32
        ) begin

            $fatal(
                1,
                "Expected 32 x 1-beat reads, got %0d",
                ar_1beat_count
            );

        end


        // ========================================================
        // Verify M/N address generation
        // ========================================================

        if (
            !saw_a_m1_k0 ||
            !saw_a_m1_k1
        ) begin

            $fatal(
                1,
                "Second M tile A addresses were not fully observed"
            );

        end


        if (
            !saw_b_n1_k0 ||
            !saw_b_n1_k1
        ) begin

            $fatal(
                1,
                "Second N tile B addresses were not fully observed"
            );

        end


        // ========================================================
        // AXI write counts
        //
        // 4 C tiles
        // x 4 rows
        //
        // = 16 AW
        //
        // 16 rows x 4 beats
        // = 64 W beats
        // ========================================================

        if (
            aw_count !=
            16
        ) begin

            $fatal(
                1,
                "Expected 16 AXI write requests, got %0d",
                aw_count
            );

        end


        if (
            w_count !=
            64
        ) begin

            $fatal(
                1,
                "Expected 64 AXI write beats, got %0d",
                w_count
            );

        end


        if (
            b_count !=
            16
        ) begin

            $fatal(
                1,
                "Expected 16 AXI write responses, got %0d",
                b_count
            );

        end


        // ========================================================
        // Verify all four C tile base addresses
        // ========================================================

        if (
            !saw_c_tile_00 ||
            !saw_c_tile_01 ||
            !saw_c_tile_10 ||
            !saw_c_tile_11
        ) begin

            $fatal(
                1,
                "Not all four C tile base addresses were observed"
            );

        end


        // ========================================================
        // Final local accumulator corresponds to C tile (1,1).
        //
        // Local [0][0] maps to global C[4][4].
        //
        // C[4][4] = 260 * 5 * 5 = 6500
        // ========================================================

        if (
            acc_out[0][0] !==
            32'sd6500
        ) begin

            $fatal(
                1,
                "Final accumulator mismatch: got %0d expected 6500",
                acc_out[0][0]
            );

        end


        // ========================================================
        // Check complete 8x8 C matrix in DDR
        // ========================================================

        check_c_matrix();


        $display("");
        $display("========================================");
        $display("ALL MULTI-TILE GEMM TESTS PASSED");
        $display("DDR -> NPU -> DDR");
        $display("M = 8, N = 8, K = 260");
        $display("M tiling = 4 + 4");
        $display("N tiling = 4 + 4");
        $display("K tiling = 256 + 4");
        $display("Compute tiles      = 8");
        $display("C tiles            = 4");
        $display("AXI read requests  = %0d", ar_count);
        $display("AXI write requests = %0d", aw_count);
        $display("AXI write beats    = %0d", w_count);
        $display("cycles             = %0d", cycle_count);
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
