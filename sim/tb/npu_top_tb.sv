module npu_top_tb;

    localparam int unsigned ADDR_WIDTH       = 64;
    localparam int unsigned DESC_COUNT_WIDTH = 16;
    localparam int unsigned TILE_COUNT_WIDTH = 16;

    localparam int unsigned ROWS             = 4;
    localparam int unsigned COLS             = 4;

    localparam int unsigned DATA_WIDTH       = 8;
    localparam int unsigned ACC_WIDTH        = 32;
    localparam int unsigned MEM_WORD_WIDTH   = 32;

    localparam int unsigned ID_WIDTH         = 1;
    localparam int unsigned K_TILE_SIZE      = 256;

    localparam int unsigned A_BUFFER_COUNT   = 2;
    localparam int unsigned B_BUFFER_COUNT   = 2;


    // ============================================================
    // Workload
    // ============================================================

    localparam int unsigned M_TOTAL = 8;
    localparam int unsigned N_TOTAL = 8;
    localparam int unsigned K_TOTAL = 260;

    localparam int unsigned WORD_BYTES =
        MEM_WORD_WIDTH / 8;

    localparam int unsigned AB_STRIDE_BYTES =
        K_TOTAL;

    localparam int unsigned C_STRIDE_BYTES =
        N_TOTAL * (ACC_WIDTH / 8);

    localparam int unsigned WORDS_PER_AB_ROW =
        AB_STRIDE_BYTES / WORD_BYTES;


    // ============================================================
    // Memory map
    // ============================================================

    localparam logic [ADDR_WIDTH-1:0] A_BASE =
        64'h0000_0000_0000_1000;

    localparam logic [ADDR_WIDTH-1:0] BT_BASE =
        64'h0000_0000_0000_2000;

    localparam logic [ADDR_WIDTH-1:0] C_BASE =
        64'h0000_0000_0000_3000;

    localparam logic [ADDR_WIDTH-1:0] DESC_BASE =
        64'h0000_0000_0000_4000;


    localparam int unsigned A_WORD_BASE =
        1024;

    localparam int unsigned BT_WORD_BASE =
        2048;

    localparam int unsigned C_WORD_BASE =
        3072;

    localparam int unsigned DESC_WORD_BASE =
        4096;


    // 32 KiB
    localparam int unsigned MEMORY_WORDS =
        8192;

    localparam int unsigned TIMEOUT_CYCLES =
        40000;


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
    // Host interface
    // ============================================================

    logic start;

    logic [63:0]
        desc_base;

    logic [DESC_COUNT_WIDTH-1:0]
        desc_count;

    logic npu_busy;
    logic npu_done;
    logic npu_error;


    // ============================================================
    // Debug accumulator
    // ============================================================

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // AXI read address
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_arid;

    logic [ADDR_WIDTH-1:0]
        axi_araddr;

    logic [7:0]
        axi_arlen;

    logic [2:0]
        axi_arsize;

    logic [1:0]
        axi_arburst;

    logic
        axi_arvalid;

    logic
        axi_arready;


    // ============================================================
    // AXI read data
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_rid;

    logic [MEM_WORD_WIDTH-1:0]
        axi_rdata;

    logic [1:0]
        axi_rresp;

    logic
        axi_rlast;

    logic
        axi_rvalid;

    logic
        axi_rready;


    // ============================================================
    // AXI write address
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_awid;

    logic [ADDR_WIDTH-1:0]
        axi_awaddr;

    logic [7:0]
        axi_awlen;

    logic [2:0]
        axi_awsize;

    logic [1:0]
        axi_awburst;

    logic
        axi_awvalid;

    logic
        axi_awready;


    // ============================================================
    // AXI write data
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        axi_wdata;

    logic [(MEM_WORD_WIDTH/8)-1:0]
        axi_wstrb;

    logic
        axi_wlast;

    logic
        axi_wvalid;

    logic
        axi_wready;


    // ============================================================
    // AXI write response
    // ============================================================

    logic [ID_WIDTH-1:0]
        axi_bid;

    logic [1:0]
        axi_bresp;

    logic
        axi_bvalid;

    logic
        axi_bready;


    // ============================================================
    // External memory
    // ============================================================

    logic [MEM_WORD_WIDTH-1:0]
        read_memory [0:MEMORY_WORDS-1];

    logic [MEM_WORD_WIDTH-1:0]
        write_memory [0:MEMORY_WORDS-1];


    // ============================================================
    // AXI read slave state
    // ============================================================

    logic
        rd_active_q;

    logic [ADDR_WIDTH-1:0]
        rd_addr_q;

    logic [8:0]
        rd_beats_left_q;


    // ============================================================
    // AXI write slave state
    // ============================================================

    logic
        wr_active_q;

    logic [ADDR_WIDTH-1:0]
        wr_addr_q;

    logic [8:0]
        wr_beats_left_q;

    logic [ID_WIDTH-1:0]
        wr_id_q;


    // ============================================================
    // Counters
    // ============================================================

    integer cycle_count;

    integer total_ar_count;
    integer descriptor_ar_count;
    integer gemm_ar_count;

    integer gemm_ar_64beat_count;
    integer gemm_ar_1beat_count;

    integer aw_count;
    integer w_count;
    integer b_count;


    // ============================================================
    // C-address coverage
    // ============================================================

    logic saw_c_tile_00;
    logic saw_c_tile_01;
    logic saw_c_tile_10;
    logic saw_c_tile_11;


    // ============================================================
    // DUT
    // ============================================================

    npu_top #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DESC_COUNT_WIDTH (DESC_COUNT_WIDTH),
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
        .clk           (clk),
        .reset         (reset),

        .start         (start),
        .desc_base     (desc_base),
        .desc_count    (desc_count),

        .busy          (npu_busy),
        .done          (npu_done),
        .error         (npu_error),

        .acc_out       (acc_out),

        // AXI read address
        .m_axi_arid    (axi_arid),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),

        // AXI read data
        .m_axi_rid     (axi_rid),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rresp   (axi_rresp),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),

        // AXI write address
        .m_axi_awid    (axi_awid),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),

        // AXI write data
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),

        // AXI write response
        .m_axi_bid     (axi_bid),
        .m_axi_bresp   (axi_bresp),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready)
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
    // AXI read monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            total_ar_count <=
                0;

            descriptor_ar_count <=
                0;

            gemm_ar_count <=
                0;

            gemm_ar_64beat_count <=
                0;

            gemm_ar_1beat_count <=
                0;

        end else if (
            axi_arvalid &&
            axi_arready
        ) begin

            total_ar_count <=
                total_ar_count + 1;


            // ----------------------------------------------------
            // Descriptor address range:
            //
            // 0x4000 ... 0x403f
            // ----------------------------------------------------

            if (
                (axi_araddr >= DESC_BASE) &&
                (
                    axi_araddr <
                    (
                        DESC_BASE +
                        ADDR_WIDTH'(64)
                    )
                )
            ) begin

                if (
                    axi_arlen !=
                    8'd0
                ) begin

                    $fatal(
                        1,
                        "Descriptor read must be single beat"
                    );

                end


                if (
                    axi_araddr !=
                    (
                        DESC_BASE +
                        ADDR_WIDTH'(
                            descriptor_ar_count * 4
                        )
                    )
                ) begin

                    $fatal(
                        1,
                        "Descriptor address mismatch: got 0x%0h expected 0x%0h",
                        axi_araddr,
                        (
                            DESC_BASE +
                            ADDR_WIDTH'(
                                descriptor_ar_count * 4
                            )
                        )
                    );

                end


                descriptor_ar_count <=
                    descriptor_ar_count + 1;

            end else begin

                gemm_ar_count <=
                    gemm_ar_count + 1;


                if (
                    axi_arlen ==
                    8'd63
                ) begin

                    gemm_ar_64beat_count <=
                        gemm_ar_64beat_count + 1;

                end


                if (
                    axi_arlen ==
                    8'd0
                ) begin

                    gemm_ar_1beat_count <=
                        gemm_ar_1beat_count + 1;

                end

            end

        end

    end


    // ============================================================
    // AXI read slave
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
                        "AXI ARSIZE must be 2"
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
                        "Unexpected ARID"
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
            // Consume R beat
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
            // Produce R beat
            // ----------------------------------------------------

            if (
                rd_active_q &&
                !axi_rvalid
            ) begin

                axi_rid <=
                    '0;

                axi_rdata <=
                    read_memory[
                        rd_addr_q[14:2]
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
    // AXI write monitor
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


                if (axi_awaddr == C_BASE) begin

                    saw_c_tile_00 <=
                        1'b1;

                end


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
    // AXI write slave
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
                        "AXI AWSIZE must be 2"
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
                        "Unexpected AWID"
                    );

                end


                if (
                    axi_awlen !=
                    8'd3
                ) begin

                    $fatal(
                        1,
                        "Expected 4-beat C row"
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
                    wr_addr_q[14:2]
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
    // Fill one INT8 matrix row
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
    // Create one GEMM descriptor
    // ============================================================

    task automatic write_gemm_descriptor;

        begin

            // word 0:
            // opcode = 1
            // flags  = 0
            read_memory[
                DESC_WORD_BASE + 0
            ] =
                32'h0000_0001;


            read_memory[
                DESC_WORD_BASE + 1
            ] =
                32'(M_TOTAL);


            read_memory[
                DESC_WORD_BASE + 2
            ] =
                32'(N_TOTAL);


            read_memory[
                DESC_WORD_BASE + 3
            ] =
                32'(K_TOTAL);


            // A base
            read_memory[
                DESC_WORD_BASE + 4
            ] =
                A_BASE[31:0];

            read_memory[
                DESC_WORD_BASE + 5
            ] =
                A_BASE[63:32];


            // B^T base
            read_memory[
                DESC_WORD_BASE + 6
            ] =
                BT_BASE[31:0];

            read_memory[
                DESC_WORD_BASE + 7
            ] =
                BT_BASE[63:32];


            // C base
            read_memory[
                DESC_WORD_BASE + 8
            ] =
                C_BASE[31:0];

            read_memory[
                DESC_WORD_BASE + 9
            ] =
                C_BASE[63:32];


            read_memory[
                DESC_WORD_BASE + 10
            ] =
                32'(AB_STRIDE_BYTES);


            read_memory[
                DESC_WORD_BASE + 11
            ] =
                32'(AB_STRIDE_BYTES);


            read_memory[
                DESC_WORD_BASE + 12
            ] =
                32'(C_STRIDE_BYTES);


            // param0
            read_memory[
                DESC_WORD_BASE + 13
            ] =
                32'd0;


            // param1
            read_memory[
                DESC_WORD_BASE + 14
            ] =
                32'd0;


            // reserved
            read_memory[
                DESC_WORD_BASE + 15
            ] =
                32'd0;

        end

    endtask


    // ============================================================
    // Check complete C matrix
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
                                (
                                    row_idx *
                                    N_TOTAL
                                ) +
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
        $display("NPU TOP TEST TIMEOUT");
        $display("========================================");

        $display(
            "cycles              = %0d",
            cycle_count
        );

        $display(
            "busy                = %b",
            npu_busy
        );

        $display(
            "done                = %b",
            npu_done
        );

        $display(
            "error               = %b",
            npu_error
        );

        $display(
            "descriptor AR       = %0d",
            descriptor_ar_count
        );

        $display(
            "GEMM AR             = %0d",
            gemm_ar_count
        );

        $display("========================================");

        $fatal(
            1,
            "Timeout"
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

        start =
            1'b0;

        desc_base =
            DESC_BASE;

        desc_count =
            DESC_COUNT_WIDTH'(1);


        // --------------------------------------------------------
        // Initialize memory
        // --------------------------------------------------------

        for (
            init_idx = 0;
            init_idx < MEMORY_WORDS;
            init_idx = init_idx + 1
        ) begin

            read_memory[init_idx] =
                32'd0;

            write_memory[init_idx] =
                32'hDEAD_BEEF;

        end


        // --------------------------------------------------------
        // A row i = i+1
        // --------------------------------------------------------

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


        // --------------------------------------------------------
        // B^T row j = j+1
        // --------------------------------------------------------

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


        // --------------------------------------------------------
        // Place descriptor in external memory
        // --------------------------------------------------------

        write_gemm_descriptor();


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (4) begin
            @(posedge clk);
        end

        @(negedge clk);

        reset =
            1'b0;


        // --------------------------------------------------------
        // Host starts NPU
        // --------------------------------------------------------

        @(negedge clk);

        start =
            1'b1;


        $display(
            "[%0t] NPU start: desc_base=0x%0h desc_count=%0d",
            $time,
            desc_base,
            desc_count
        );


        @(negedge clk);

        start =
            1'b0;


        // --------------------------------------------------------
        // Wait until NPU actually starts
        // --------------------------------------------------------

        wait (
            npu_busy ===
            1'b1
        );


        // --------------------------------------------------------
        // Wait until entire descriptor list completes
        // --------------------------------------------------------

        wait (
            npu_done ===
            1'b1
        );

        #1;


        // ========================================================
        // Status
        // ========================================================

        if (npu_error) begin

            $fatal(
                1,
                "NPU reported an error"
            );

        end


        // ========================================================
        // Descriptor fetch checks
        // ========================================================

        if (
            descriptor_ar_count !=
            16
        ) begin

            $fatal(
                1,
                "Expected 16 descriptor reads, got %0d",
                descriptor_ar_count
            );

        end


        // ========================================================
        // GEMM read checks
        // ========================================================

        if (
            gemm_ar_count !=
            64
        ) begin

            $fatal(
                1,
                "Expected 64 GEMM AXI reads, got %0d",
                gemm_ar_count
            );

        end


        if (
            gemm_ar_64beat_count !=
            32
        ) begin

            $fatal(
                1,
                "Expected 32 x 64-beat GEMM reads, got %0d",
                gemm_ar_64beat_count
            );

        end


        if (
            gemm_ar_1beat_count !=
            32
        ) begin

            $fatal(
                1,
                "Expected 32 x 1-beat GEMM reads, got %0d",
                gemm_ar_1beat_count
            );

        end


        if (
            total_ar_count !=
            80
        ) begin

            $fatal(
                1,
                "Expected 80 total AXI reads, got %0d",
                total_ar_count
            );

        end


        // ========================================================
        // GEMM write checks
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


        if (
            !saw_c_tile_00 ||
            !saw_c_tile_01 ||
            !saw_c_tile_10 ||
            !saw_c_tile_11
        ) begin

            $fatal(
                1,
                "Not all C tiles were written"
            );

        end


        // ========================================================
        // Final compute state
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
        // Full DDR result
        // ========================================================

        check_c_matrix();


        // ========================================================
        // Report
        // ========================================================

        $display("");
        $display("========================================");
        $display("DESCRIPTOR-DRIVEN NPU TEST PASSED");
        $display("========================================");

        $display(
            "descriptor count      = %0d",
            desc_count
        );

        $display(
            "descriptor AXI reads  = %0d",
            descriptor_ar_count
        );

        $display(
            "GEMM AXI reads        = %0d",
            gemm_ar_count
        );

        $display(
            "total AXI reads       = %0d",
            total_ar_count
        );

        $display(
            "AXI write requests    = %0d",
            aw_count
        );

        $display(
            "AXI write beats       = %0d",
            w_count
        );

        $display(
            "total cycles          = %0d",
            cycle_count
        );

        $display("========================================");
        $display("");

        $finish;

    end

endmodule
