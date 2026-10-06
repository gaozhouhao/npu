`timescale 1ns/1ps

module mn_tiling_tb;

    localparam int ROWS         = 4;
    localparam int COLS         = 4;
    localparam int DATA_WIDTH   = 8;
    localparam int ACC_WIDTH    = 32;

    localparam int DEPTH        = 256;
    localparam int ADDR_WIDTH   = $clog2(DEPTH);
    localparam int K_SIZE_WIDTH = $clog2(DEPTH + 1);


    logic clk;
    logic reset;

    logic                    start;
    logic [K_SIZE_WIDTH-1:0] tile_k_size;

    logic clear_acc;
    logic writeback_en;

    logic busy;
    logic done;

    logic a_wbank;
    logic a_rbank;
    logic b_wbank;
    logic b_rbank;

    logic [ADDR_WIDTH-1:0] c_base_addr;


    logic                       a_wen;
    logic [ADDR_WIDTH-1:0]      a_waddr;
    logic [ROWS*DATA_WIDTH-1:0] a_wdata;

    logic                       b_wen;
    logic [ADDR_WIDTH-1:0]      b_waddr;
    logic [COLS*DATA_WIDTH-1:0] b_wdata;

    logic                       c_ren;
    logic [ADDR_WIDTH-1:0]      c_raddr;
    logic [COLS*ACC_WIDTH-1:0] c_rdata;

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];

    gemm_core #(
        .ROWS         (ROWS),
        .COLS         (COLS),
        .DATA_WIDTH   (DATA_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .DEPTH        (DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .K_SIZE_WIDTH (K_SIZE_WIDTH)
    ) dut (
        .clk          (clk),
        .reset        (reset),

        .start        (start),
        .tile_k_size  (tile_k_size),

        .clear_acc    (clear_acc),
        .writeback_en (writeback_en),

        .busy         (busy),
        .done         (done),

        .c_base_addr  (c_base_addr),

        .a_wen        (a_wen),
        .a_waddr      (a_waddr),
        .a_wdata      (a_wdata),
        .a_wbank (a_wbank),
        .a_rbank (a_rbank),


        .b_wen        (b_wen),
        .b_waddr      (b_waddr),
        .b_wdata      (b_wdata),
        .b_wbank (b_wbank),
        .b_rbank (b_rbank),

        .c_ren        (c_ren),
        .c_raddr      (c_raddr),
        .c_rdata      (c_rdata),

        .acc_out      (acc_out)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;

        a_wbank = 1'b0;
        a_rbank = 1'b0;

        b_wbank = 1'b0;
        b_rbank = 1'b0;
    end


    // ============================================================
    // Scratchpad writers
    // ============================================================

    task automatic write_a(
        input logic [ADDR_WIDTH-1:0]      addr,
        input logic [ROWS*DATA_WIDTH-1:0] data
    );
    begin

        @(negedge clk);

        a_wen   = 1'b1;
        a_waddr = addr;
        a_wdata = data;

        @(negedge clk);

        a_wen   = 1'b0;
        a_waddr = '0;
        a_wdata = '0;

    end
    endtask


    task automatic write_b(
        input logic [ADDR_WIDTH-1:0]      addr,
        input logic [COLS*DATA_WIDTH-1:0] data
    );
    begin

        @(negedge clk);

        b_wen   = 1'b1;
        b_waddr = addr;
        b_wdata = data;

        @(negedge clk);

        b_wen   = 1'b0;
        b_waddr = '0;
        b_wdata = '0;

    end
    endtask


    // ============================================================
    // Run one 4x4 output tile
    // ============================================================

    task automatic run_output_tile(
        input logic [ADDR_WIDTH-1:0] base_addr
    );
    begin

        @(negedge clk);

        c_base_addr = base_addr;

        tile_k_size  = K_SIZE_WIDTH'(3);
        clear_acc    = 1'b1;
        writeback_en = 1'b1;

        start = 1'b1;

        @(negedge clk);

        start = 1'b0;

        wait(busy == 1'b1);
        wait(done == 1'b1);

        @(posedge clk);
        #1;

        assert (busy == 1'b0)
            else $fatal(
                1,
                "busy did not return to zero"
            );

    end
    endtask


    // ============================================================
    // Check one C-buffer row
    // ============================================================

    task automatic check_c_row(
        input logic [ADDR_WIDTH-1:0] addr,
        input integer e0,
        input integer e1,
        input integer e2,
        input integer e3
    );

        integer g0;
        integer g1;
        integer g2;
        integer g3;

    begin

        @(negedge clk);

        c_ren   = 1'b1;
        c_raddr = addr;

        @(posedge clk);
        #1;

        g0 = $signed(c_rdata[0*ACC_WIDTH +: ACC_WIDTH]);
        g1 = $signed(c_rdata[1*ACC_WIDTH +: ACC_WIDTH]);
        g2 = $signed(c_rdata[2*ACC_WIDTH +: ACC_WIDTH]);
        g3 = $signed(c_rdata[3*ACC_WIDTH +: ACC_WIDTH]);

        assert (g0 == e0)
            else $fatal(1, "addr %0d col0: got %0d expected %0d",
                        addr, g0, e0);

        assert (g1 == e1)
            else $fatal(1, "addr %0d col1: got %0d expected %0d",
                        addr, g1, e1);

        assert (g2 == e2)
            else $fatal(1, "addr %0d col2: got %0d expected %0d",
                        addr, g2, e2);

        assert (g3 == e3)
            else $fatal(1, "addr %0d col3: got %0d expected %0d",
                        addr, g3, e3);

        $display(
            "C buffer addr %0d = [%0d %0d %0d %0d] : PASS",
            addr, g0, g1, g2, g3
        );

        @(negedge clk);

        c_ren   = 1'b0;
        c_raddr = '0;

    end
    endtask


    // ============================================================
    // Main test
    //
    // A = 8x3
    // B = 3x8
    // C = 8x8
    //
    // 4x4 hardware -> 4 output tiles
    // ============================================================

    initial begin

        reset        = 1'b1;

        start        = 1'b0;
        tile_k_size  = '0;

        clear_acc    = 1'b0;
        writeback_en = 1'b0;

        c_base_addr  = '0;

        a_wen        = 1'b0;
        a_waddr      = '0;
        a_wdata      = '0;

        b_wen        = 1'b0;
        b_waddr      = '0;
        b_wdata      = '0;

        c_ren        = 1'b0;
        c_raddr      = '0;


        repeat (3) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;


        // ========================================================
        // A top rows: A[0:3][0:2]
        //
        //  1  2  3
        //  4  5  6
        //  7  8  9
        // 10 11 12
        // ========================================================

        write_a(ADDR_WIDTH'(0),
                {8'd10, 8'd7, 8'd4, 8'd1});

        write_a(ADDR_WIDTH'(1),
                {8'd11, 8'd8, 8'd5, 8'd2});

        write_a(ADDR_WIDTH'(2),
                {8'd12, 8'd9, 8'd6, 8'd3});


        // ========================================================
        // B left columns: B[0:2][0:3]
        // ========================================================

        write_b(ADDR_WIDTH'(0),
                {8'd4, 8'd3, 8'd2, 8'd1});

        write_b(ADDR_WIDTH'(1),
                {8'd12, 8'd11, 8'd10, 8'd9});

        write_b(ADDR_WIDTH'(2),
                {8'd20, 8'd19, 8'd18, 8'd17});


        // C00
        run_output_tile(
            ADDR_WIDTH'(0)
        );


        // ========================================================
        // B right columns: B[0:2][4:7]
        // ========================================================

        write_b(ADDR_WIDTH'(0),
                {8'd8, 8'd7, 8'd6, 8'd5});

        write_b(ADDR_WIDTH'(1),
                {8'd16, 8'd15, 8'd14, 8'd13});

        write_b(ADDR_WIDTH'(2),
                {8'd24, 8'd23, 8'd22, 8'd21});


        // C01
        // A top remains in A scratchpad and is reused.
        run_output_tile(
            ADDR_WIDTH'(4)
        );


        // ========================================================
        // A bottom rows: A[4:7][0:2]
        //
        // 13 14 15
        // 16 17 18
        // 19 20 21
        // 22 23 24
        // ========================================================

        write_a(ADDR_WIDTH'(0),
                {8'd22, 8'd19, 8'd16, 8'd13});

        write_a(ADDR_WIDTH'(1),
                {8'd23, 8'd20, 8'd17, 8'd14});

        write_a(ADDR_WIDTH'(2),
                {8'd24, 8'd21, 8'd18, 8'd15});


        // ========================================================
        // Reload B left
        // ========================================================

        write_b(ADDR_WIDTH'(0),
                {8'd4, 8'd3, 8'd2, 8'd1});

        write_b(ADDR_WIDTH'(1),
                {8'd12, 8'd11, 8'd10, 8'd9});

        write_b(ADDR_WIDTH'(2),
                {8'd20, 8'd19, 8'd18, 8'd17});


        // C10
        run_output_tile(
            ADDR_WIDTH'(8)
        );


        // ========================================================
        // Reload B right
        // ========================================================

        write_b(ADDR_WIDTH'(0),
                {8'd8, 8'd7, 8'd6, 8'd5});

        write_b(ADDR_WIDTH'(1),
                {8'd16, 8'd15, 8'd14, 8'd13});

        write_b(ADDR_WIDTH'(2),
                {8'd24, 8'd23, 8'd22, 8'd21});


        // C11
        run_output_tile(
            ADDR_WIDTH'(12)
        );

        assert (acc_out[0][0] == 562)
            else $fatal(1, "acc_out[0][0] mismatch");

        assert (acc_out[3][3] == 1120)
            else $fatal(1, "acc_out[3][3] mismatch");

        // ========================================================
        // Verify C00
        // ========================================================

        check_c_row(ADDR_WIDTH'(0),  70,  76,  82,  88);
        check_c_row(ADDR_WIDTH'(1), 151, 166, 181, 196);
        check_c_row(ADDR_WIDTH'(2), 232, 256, 280, 304);
        check_c_row(ADDR_WIDTH'(3), 313, 346, 379, 412);


        // ========================================================
        // Verify C01
        // ========================================================

        check_c_row(ADDR_WIDTH'(4),  94, 100, 106, 112);
        check_c_row(ADDR_WIDTH'(5), 211, 226, 241, 256);
        check_c_row(ADDR_WIDTH'(6), 328, 352, 376, 400);
        check_c_row(ADDR_WIDTH'(7), 445, 478, 511, 544);


        // ========================================================
        // Verify C10
        // ========================================================

        check_c_row(ADDR_WIDTH'(8),  394, 436,478, 520);
        check_c_row(ADDR_WIDTH'(9),  475,526,577, 628);
        check_c_row(ADDR_WIDTH'(10), 556,616,676, 736);
        check_c_row(ADDR_WIDTH'(11), 637,706,775, 844);


        // ========================================================
        // Verify C11
        // ========================================================

        check_c_row(ADDR_WIDTH'(12), 562,604,646,688);
        check_c_row(ADDR_WIDTH'(13), 679,730,781,832);
        check_c_row(ADDR_WIDTH'(14), 796,856,916,976);
        check_c_row(ADDR_WIDTH'(15), 913,982,1051,1120);


        $display("");
        $display("========================================");
        $display("M/N TILING TEST PASSED");
        $display("========================================");
        $display("");

        #20;
        $finish;

    end


    initial begin
        #30000;
        $fatal(1, "Timeout: M/N tiling test did not finish");
    end


    initial begin
        $dumpfile("mn_tiling_tb.vcd");
        $dumpvars(0, mn_tiling_tb);
    end

endmodule
