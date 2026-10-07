module gemm_dma_integration_tb;

    localparam int unsigned ADDR_WIDTH     = 64;
    localparam int unsigned DATA_WIDTH     = 8;
    localparam int unsigned ACC_WIDTH      = 32;
    localparam int unsigned MEM_WORD_WIDTH = 32;

    localparam int unsigned ROWS = 4;
    localparam int unsigned COLS = 4;

    localparam int unsigned K_DEPTH = 256;

    localparam int unsigned A_BUFFER_COUNT = 1;
    localparam int unsigned B_BUFFER_COUNT = 1;

    localparam int unsigned K_SIZE_WIDTH =
        $clog2(K_DEPTH + 1);

    localparam int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / DATA_WIDTH;

    localparam int unsigned WORD_DEPTH =
        (K_DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD;

    localparam int unsigned WORD_ADDR_WIDTH =
        $clog2(WORD_DEPTH);

    localparam int unsigned A_LANE_WIDTH =
        $clog2(ROWS);

    localparam int unsigned B_LANE_WIDTH =
        $clog2(COLS);

    localparam int unsigned TIMEOUT_CYCLES =
        2000;


    // ============================================================
    // External memory locations
    // ============================================================

    localparam logic [ADDR_WIDTH-1:0] A_BASE =
        64'h0000_0000_0000_0100;

    localparam logic [ADDR_WIDTH-1:0] BT_BASE =
        64'h0000_0000_0000_0200;

    localparam int unsigned A_WORD_BASE =
        32'd64;

    localparam int unsigned BT_WORD_BASE =
        32'd128;


    // ============================================================
    // Debug stages
    // ============================================================

    localparam logic [3:0] TB_STAGE_RESET      = 4'd0;
    localparam logic [3:0] TB_STAGE_LOAD_REQ   = 4'd1;
    localparam logic [3:0] TB_STAGE_LOAD_DONE  = 4'd2;
    localparam logic [3:0] TB_STAGE_READ_IDLE  = 4'd3;
    localparam logic [3:0] TB_STAGE_GEMM_START = 4'd4;
    localparam logic [3:0] TB_STAGE_GEMM_BUSY  = 4'd5;
    localparam logic [3:0] TB_STAGE_GEMM_DONE  = 4'd6;
    localparam logic [3:0] TB_STAGE_CHECK_C    = 4'd7;
    localparam logic [3:0] TB_STAGE_FINISHED   = 4'd8;

    logic [3:0] tb_stage;

    integer cycle_count;


    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic reset;

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    always_ff @(posedge clk) begin

        if (reset) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
        end

    end


    // ============================================================
    // A/B load commands
    // ============================================================

    logic                    a_load_req;
    logic                    a_load_accept;
    logic [ADDR_WIDTH-1:0]   a_base_addr;
    logic [31:0]             a_stride_bytes;
    logic [K_SIZE_WIDTH-1:0] a_load_size;
    logic                    a_load_done;
    logic                    a_load_error;

    logic                    b_load_req;
    logic                    b_load_accept;
    logic [ADDR_WIDTH-1:0]   b_base_addr;
    logic [31:0]             b_stride_bytes;
    logic [K_SIZE_WIDTH-1:0] b_load_size;
    logic                    b_load_done;
    logic                    b_load_error;


    // ============================================================
    // Simplified one-bank load manager interfaces
    // ============================================================

    logic a_bank_load_req;
    logic a_bank_load_grant;
    logic a_bank_load_bank;
    logic a_bank_load_done;

    logic b_bank_load_req;
    logic b_bank_load_grant;
    logic b_bank_load_bank;
    logic b_bank_load_done;


    // ============================================================
    // Scratchpad write interfaces
    // ============================================================

    logic                       a_wen;
    logic                       a_wbank;
    logic [A_LANE_WIDTH-1:0]    a_wlane;
    logic [WORD_ADDR_WIDTH-1:0] a_waddr;
    logic [MEM_WORD_WIDTH-1:0]  a_wdata;

    logic                       b_wen;
    logic                       b_wbank;
    logic [B_LANE_WIDTH-1:0]    b_wlane;
    logic [WORD_ADDR_WIDTH-1:0] b_waddr;
    logic [MEM_WORD_WIDTH-1:0]  b_wdata;


    // ============================================================
    // GEMM read path status
    // ============================================================

    logic read_path_busy;
    logic read_path_error;


    // ============================================================
    // AXI
    // ============================================================

    logic                      axi_arid;
    logic [ADDR_WIDTH-1:0]     axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid;
    logic                      axi_arready;

    logic                      axi_rid;
    logic [MEM_WORD_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast;
    logic                      axi_rvalid;
    logic                      axi_rready;


    // ============================================================
    // GEMM core
    // ============================================================

    logic                    gemm_start;
    logic [K_SIZE_WIDTH-1:0] tile_k_size;

    logic clear_acc;
    logic writeback_en;

    logic gemm_busy;
    logic gemm_done;

    logic [7:0] c_base_addr;

    logic         c_ren;
    logic [7:0]   c_raddr;
    logic [127:0] c_rdata;

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // AXI memory model
    //
    // 4 KB
    // 1024 x 32-bit words
    // ============================================================

    logic [31:0] memory [0:1023];

    logic                  mem_read_active;
    logic [ADDR_WIDTH-1:0] mem_read_addr_q;
    logic [8:0]            mem_beats_left_q;


    // ============================================================
    // Completion tracking
    // ============================================================

    logic a_bank_done_seen;
    logic b_bank_done_seen;


    // ============================================================
    // GEMM read path
    // ============================================================

    gemm_read_path #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ELEM_WIDTH     (DATA_WIDTH),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH       (1),

        .A_LANE_COUNT   (ROWS),
        .B_LANE_COUNT   (COLS),

        .K_DEPTH        (K_DEPTH),

        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT)
    ) u_read_path (
        .clk               (clk),
        .reset             (reset),

        // A command
        .a_load_req        (a_load_req),
        .a_load_accept     (a_load_accept),

        .a_base_addr       (a_base_addr),
        .a_stride_bytes    (a_stride_bytes),
        .a_load_size       (a_load_size),

        .a_load_done       (a_load_done),
        .a_load_error      (a_load_error),

        // B command
        .b_load_req        (b_load_req),
        .b_load_accept     (b_load_accept),

        .b_base_addr       (b_base_addr),
        .b_stride_bytes    (b_stride_bytes),
        .b_load_size       (b_load_size),

        .b_load_done       (b_load_done),
        .b_load_error      (b_load_error),

        // A buffer manager
        .a_bank_load_req   (a_bank_load_req),
        .a_bank_load_grant (a_bank_load_grant),
        .a_bank_load_bank  (a_bank_load_bank),
        .a_bank_load_done  (a_bank_load_done),

        // B buffer manager
        .b_bank_load_req   (b_bank_load_req),
        .b_bank_load_grant (b_bank_load_grant),
        .b_bank_load_bank  (b_bank_load_bank),
        .b_bank_load_done  (b_bank_load_done),

        // A scratchpad write
        .a_wen             (a_wen),
        .a_wbank           (a_wbank),
        .a_wlane           (a_wlane),
        .a_waddr           (a_waddr),
        .a_wdata           (a_wdata),

        // B scratchpad write
        .b_wen             (b_wen),
        .b_wbank           (b_wbank),
        .b_wlane           (b_wlane),
        .b_waddr           (b_waddr),
        .b_wdata           (b_wdata),

        // Status
        .busy              (read_path_busy),
        .error             (read_path_error),

        // AXI AR
        .m_axi_arid        (axi_arid),
        .m_axi_araddr      (axi_araddr),
        .m_axi_arlen       (axi_arlen),
        .m_axi_arsize      (axi_arsize),
        .m_axi_arburst     (axi_arburst),
        .m_axi_arvalid     (axi_arvalid),
        .m_axi_arready     (axi_arready),

        // AXI R
        .m_axi_rid         (axi_rid),
        .m_axi_rdata       (axi_rdata),
        .m_axi_rresp       (axi_rresp),
        .m_axi_rlast       (axi_rlast),
        .m_axi_rvalid      (axi_rvalid),
        .m_axi_rready      (axi_rready)
    );


    // ============================================================
    // GEMM core
    // ============================================================

    gemm_core #(
        .ROWS           (ROWS),
        .COLS           (COLS),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),

        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT),

        .DEPTH          (K_DEPTH),

        .MEM_WORD_WIDTH (MEM_WORD_WIDTH)
    ) u_gemm_core (
        .clk          (clk),
        .reset        (reset),

        .start        (gemm_start),
        .tile_k_size  (tile_k_size),

        .clear_acc    (clear_acc),
        .writeback_en (writeback_en),

        .busy         (gemm_busy),
        .done         (gemm_done),

        .c_base_addr  (c_base_addr),

        // A
        .a_wen        (a_wen),
        .a_wlane      (a_wlane),
        .a_waddr      (a_waddr),
        .a_wdata      (a_wdata),
        .a_wbank      (a_wbank),
        .a_rbank      (1'b0),

        // B
        .b_wen        (b_wen),
        .b_wlane      (b_wlane),
        .b_waddr      (b_waddr),
        .b_wdata      (b_wdata),
        .b_wbank      (b_wbank),
        .b_rbank      (1'b0),

        // C
        .c_ren        (c_ren),
        .c_raddr      (c_raddr),
        .c_rdata      (c_rdata),

        .acc_out      (acc_out)
    );


    // ============================================================
    // Simplified buffer managers
    //
    // Single-buffer test:
    // always grant bank 0.
    // ============================================================

    assign a_bank_load_grant =
        a_bank_load_req;

    assign a_bank_load_bank =
        1'b0;

    assign b_bank_load_grant =
        b_bank_load_req;

    assign b_bank_load_bank =
        1'b0;


    // ============================================================
    // Observe loader completion
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            a_bank_done_seen <= 1'b0;
            b_bank_done_seen <= 1'b0;

        end else begin

            if (a_bank_load_done) begin

                a_bank_done_seen <= 1'b1;

                $display(
                    "[%0t] A operand buffer load complete",
                    $time
                );

            end

            if (b_bank_load_done) begin

                b_bank_done_seen <= 1'b1;

                $display(
                    "[%0t] B operand buffer load complete",
                    $time
                );

            end

        end

    end


    // ============================================================
    // AXI transaction debug
    // ============================================================

    always_ff @(posedge clk) begin

        if (!reset) begin

            if (
                axi_arvalid &&
                axi_arready
            ) begin

                $display(
                    "[%0t] AXI AR: addr=0x%016h beats=%0d",
                    $time,
                    axi_araddr,
                    axi_arlen + 1
                );

            end

            if (
                axi_rvalid &&
                axi_rready &&
                axi_rlast
            ) begin

                $display(
                    "[%0t] AXI RLAST accepted",
                    $time
                );

            end

        end

    end


    // ============================================================
    // Minimal AXI4 read slave
    // ============================================================

    assign axi_arready =
        !mem_read_active &&
        !axi_rvalid;


    always_ff @(posedge clk) begin

        if (reset) begin

            mem_read_active <= 1'b0;
            mem_read_addr_q <= '0;
            mem_beats_left_q <= '0;

            axi_rid    <= 1'b0;
            axi_rdata  <= '0;
            axi_rresp  <= 2'b00;
            axi_rlast  <= 1'b0;
            axi_rvalid <= 1'b0;

        end else begin

            // ----------------------------------------------------
            // Accept AR
            // ----------------------------------------------------

            if (
                axi_arvalid &&
                axi_arready
            ) begin

                if (axi_arsize != 3'd2) begin

                    $fatal(
                        1,
                        "AXI ARSIZE must be 2 for 32-bit transfer"
                    );

                end

                if (axi_arburst != 2'b01) begin

                    $fatal(
                        1,
                        "AXI burst must be INCR"
                    );

                end

                if (axi_arid != 1'b0) begin

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
                    {1'b0, axi_arlen} + 9'd1;

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

                    mem_beats_left_q <=
                        '0;

                    mem_read_active <=
                        1'b0;

                end else begin

                    mem_beats_left_q <=
                        mem_beats_left_q -
                        9'd1;

                    mem_read_addr_q <=
                        mem_read_addr_q +
                        ADDR_WIDTH'(4);

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
                    1'b0;

                axi_rdata <=
                    memory[
                        mem_read_addr_q[11:2]
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
    // C row checker
    // ============================================================

    task automatic check_c_row (
        input logic [7:0] addr,

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
    // GLOBAL TIMEOUT
    // ============================================================

    initial begin

        repeat (TIMEOUT_CYCLES) begin
            @(posedge clk);
        end

        $display("");
        $display("========================================");
        $display("GEMM DMA INTEGRATION TEST TIMEOUT");
        $display("========================================");

        $display(
            "time                  = %0t",
            $time
        );

        $display(
            "cycle                 = %0d",
            cycle_count
        );

        $display(
            "tb_stage              = %0d",
            tb_stage
        );

        $display(
            "a_load_req            = %b",
            a_load_req
        );

        $display(
            "a_load_accept         = %b",
            a_load_accept
        );

        $display(
            "a_load_done           = %b",
            a_load_done
        );

        $display(
            "a_load_error          = %b",
            a_load_error
        );

        $display(
            "b_load_req            = %b",
            b_load_req
        );

        $display(
            "b_load_accept         = %b",
            b_load_accept
        );

        $display(
            "b_load_done           = %b",
            b_load_done
        );

        $display(
            "b_load_error          = %b",
            b_load_error
        );

        $display(
            "a_bank_load_req       = %b",
            a_bank_load_req
        );

        $display(
            "a_bank_load_grant     = %b",
            a_bank_load_grant
        );

        $display(
            "a_bank_load_done      = %b",
            a_bank_load_done
        );

        $display(
            "b_bank_load_req       = %b",
            b_bank_load_req
        );

        $display(
            "b_bank_load_grant     = %b",
            b_bank_load_grant
        );

        $display(
            "b_bank_load_done      = %b",
            b_bank_load_done
        );

        $display(
            "read_path_busy        = %b",
            read_path_busy
        );

        $display(
            "read_path_error       = %b",
            read_path_error
        );

        $display(
            "AXI ARVALID/ARREADY   = %b/%b",
            axi_arvalid,
            axi_arready
        );

        $display(
            "AXI ARADDR            = 0x%016h",
            axi_araddr
        );

        $display(
            "AXI RVALID/RREADY     = %b/%b",
            axi_rvalid,
            axi_rready
        );

        $display(
            "AXI RLAST             = %b",
            axi_rlast
        );

        $display(
            "mem_read_active       = %b",
            mem_read_active
        );

        $display(
            "mem_beats_left        = %0d",
            mem_beats_left_q
        );

        $display(
            "gemm_busy             = %b",
            gemm_busy
        );

        $display(
            "gemm_done             = %b",
            gemm_done
        );

        $display("========================================");
        $display("");

        $fatal(
            1,
            "Simulation timeout after %0d cycles",
            TIMEOUT_CYCLES
        );

    end


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        tb_stage =
            TB_STAGE_RESET;

        cycle_count =
            0;

        reset =
            1'b1;

        a_load_req =
            1'b0;

        b_load_req =
            1'b0;

        a_base_addr =
            A_BASE;

        a_stride_bytes =
            32'd8;

        a_load_size =
            K_SIZE_WIDTH'(6);

        b_base_addr =
            BT_BASE;

        b_stride_bytes =
            32'd8;

        b_load_size =
            K_SIZE_WIDTH'(6);

        gemm_start =
            1'b0;

        tile_k_size =
            K_SIZE_WIDTH'(6);

        clear_acc =
            1'b1;

        writeback_en =
            1'b1;

        c_base_addr =
            8'd0;

        c_ren =
            1'b0;

        c_raddr =
            '0;


        // ========================================================
        // A matrix
        //
        // A =
        //
        // [ 1   2   3   4   5   6 ]
        // [ 7   8   9  10  11  12 ]
        // [ 1  -1   2  -2   3  -3 ]
        // [ 4   0  -1   2   1   3 ]
        //
        // Physical stride = 8 bytes.
        // ========================================================

        memory[A_WORD_BASE + 0] =
            32'h0403_0201;

        memory[A_WORD_BASE + 1] =
            32'h0000_0605;


        memory[A_WORD_BASE + 2] =
            32'h0A09_0807;

        memory[A_WORD_BASE + 3] =
            32'h0000_0C0B;


        memory[A_WORD_BASE + 4] =
            32'hFE02_FF01;

        memory[A_WORD_BASE + 5] =
            32'h0000_FD03;


        memory[A_WORD_BASE + 6] =
            32'h02FF_0004;

        memory[A_WORD_BASE + 7] =
            32'h0000_0301;


        // ========================================================
        // B^T
        //
        // Original B =
        //
        // [1 2 3 4]
        // [0 1 0 1]
        // [2 0 1 0]
        // [1 1 1 1]
        // [0 2 0 2]
        // [1 0 1 0]
        //
        // External memory stores B^T as four rows.
        // ========================================================

        // BT row 0:
        // [1, 0, 2, 1, 0, 1]

        memory[BT_WORD_BASE + 0] =
            32'h0102_0001;

        memory[BT_WORD_BASE + 1] =
            32'h0000_0100;


        // BT row 1:
        // [2, 1, 0, 1, 2, 0]

        memory[BT_WORD_BASE + 2] =
            32'h0100_0102;

        memory[BT_WORD_BASE + 3] =
            32'h0000_0002;


        // BT row 2:
        // [3, 0, 1, 1, 0, 1]

        memory[BT_WORD_BASE + 4] =
            32'h0101_0003;

        memory[BT_WORD_BASE + 5] =
            32'h0000_0100;


        // BT row 3:
        // [4, 1, 0, 1, 2, 0]

        memory[BT_WORD_BASE + 6] =
            32'h0100_0104;

        memory[BT_WORD_BASE + 7] =
            32'h0000_0002;


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
        // Start A/B DMA
        // ========================================================

        tb_stage =
            TB_STAGE_LOAD_REQ;

        @(negedge clk);

        a_load_req =
            1'b1;

        b_load_req =
            1'b1;

        $display(
            "[%0t] Starting A/B operand loads",
            $time
        );


        // --------------------------------------------------------
        // Wait for A request acceptance
        // independently.
        // --------------------------------------------------------

        fork

            begin

                wait (
                    a_load_accept === 1'b1
                );

                $display(
                    "[%0t] A load request accepted",
                    $time
                );

                @(negedge clk);

                a_load_req =
                    1'b0;

            end


            begin

                wait (
                    b_load_accept === 1'b1
                );

                $display(
                    "[%0t] B load request accepted",
                    $time
                );

                @(negedge clk);

                b_load_req =
                    1'b0;

            end

        join


        $display(
            "[%0t] Both load commands accepted",
            $time
        );


        // ========================================================
        // Wait for both operand loads
        // ========================================================

        tb_stage =
            TB_STAGE_LOAD_DONE;

        fork

            begin

                wait (
                    a_load_done === 1'b1
                );

                $display(
                    "[%0t] A DMA load_done",
                    $time
                );

            end


            begin

                wait (
                    b_load_done === 1'b1
                );

                $display(
                    "[%0t] B DMA load_done",
                    $time
                );

            end

        join


        $display(
            "[%0t] Both operand loads completed",
            $time
        );


        #1;


        if (a_load_error) begin

            $fatal(
                1,
                "A DMA reported an error"
            );

        end


        if (b_load_error) begin

            $fatal(
                1,
                "B DMA reported an error"
            );

        end


        if (read_path_error) begin

            $fatal(
                1,
                "GEMM read path reported an error"
            );

        end


        if (!a_bank_done_seen) begin

            $fatal(
                1,
                "A buffer load completion not observed"
            );

        end


        if (!b_bank_done_seen) begin

            $fatal(
                1,
                "B buffer load completion not observed"
            );

        end


        // ========================================================
        // Wait until complete read path returns idle
        // ========================================================

        tb_stage =
            TB_STAGE_READ_IDLE;

        wait (
            read_path_busy === 1'b0
        );

        $display(
            "[%0t] Read path idle",
            $time
        );


        // ========================================================
        // Start GEMM
        // ========================================================

        tb_stage =
            TB_STAGE_GEMM_START;

        @(negedge clk);

        gemm_start =
            1'b1;

        $display(
            "[%0t] GEMM start asserted",
            $time
        );

        @(negedge clk);

        gemm_start =
            1'b0;


        // ========================================================
        // Wait GEMM busy
        // ========================================================

        tb_stage =
            TB_STAGE_GEMM_BUSY;

        wait (
            gemm_busy === 1'b1
        );

        $display(
            "[%0t] GEMM busy asserted",
            $time
        );


        // ========================================================
        // Wait GEMM done
        // ========================================================

        tb_stage =
            TB_STAGE_GEMM_DONE;

        wait (
            gemm_done === 1'b1
        );

        $display(
            "[%0t] GEMM done",
            $time
        );

        #1;


        // ========================================================
        // Quick accumulator check
        // ========================================================

        if (
            acc_out[0][0] !==
            32'sd17
        ) begin

            $fatal(
                1,
                "Accumulator check failed: acc[0][0]=%0d",
                acc_out[0][0]
            );

        end


        // ========================================================
        // Check complete C matrix
        // ========================================================

        tb_stage =
            TB_STAGE_CHECK_C;

        check_c_row(
            8'd0,
            32'sd17,
            32'sd18,
            32'sd16,
            32'sd20
        );

        check_c_row(
            8'd1,
            32'sd47,
            32'sd54,
            32'sd52,
            32'sd68
        );

        check_c_row(
            8'd2,
            32'sd0,
            32'sd5,
            32'sd0,
            32'sd7
        );

        check_c_row(
            8'd3,
            32'sd7,
            32'sd12,
            32'sd16,
            32'sd20
        );


        // ========================================================
        // PASS
        // ========================================================

        tb_stage =
            TB_STAGE_FINISHED;

        $display("");
        $display("========================================");
        $display("ALL GEMM DMA INTEGRATION TESTS PASSED");
        $display("cycles = %0d", cycle_count);
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
