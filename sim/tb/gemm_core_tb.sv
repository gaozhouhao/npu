`timescale 1ns/1ps

module gemm_core_tb;


    // ============================================================
    // Parameters
    // ============================================================

    localparam int ROWS         = 4;
    localparam int COLS         = 4;
    localparam int DATA_WIDTH   = 8;
    localparam int ACC_WIDTH    = 32;

    localparam int DEPTH        = 256;
    localparam int ADDR_WIDTH   = $clog2(DEPTH);
    localparam int K_SIZE_WIDTH = $clog2(DEPTH + 1);


    // ============================================================
    // DUT signals
    // ============================================================

    logic clk;
    logic reset;

    logic                    start;
    logic [K_SIZE_WIDTH-1:0] tile_k_size;

    logic clear_acc;
    logic writeback_en;

    logic busy;
    logic done;


    // ============================================================
    // A Scratchpad write
    // ============================================================

    logic                       a_wen;
    logic [ADDR_WIDTH-1:0]      a_waddr;
    logic [ROWS*DATA_WIDTH-1:0] a_wdata;


    // ============================================================
    // B Scratchpad write
    // ============================================================

    logic                       b_wen;
    logic [ADDR_WIDTH-1:0]      b_waddr;
    logic [COLS*DATA_WIDTH-1:0] b_wdata;


    // ============================================================
    // C Buffer read
    // ============================================================

    logic                       c_ren;
    logic [ADDR_WIDTH-1:0]      c_raddr;
    logic [COLS*ACC_WIDTH-1:0] c_rdata;


    // ============================================================
    // Debug
    // ============================================================

    logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS];


    // ============================================================
    // DUT
    // ============================================================

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

        .a_wen        (a_wen),
        .a_waddr      (a_waddr),
        .a_wdata      (a_wdata),

        .b_wen        (b_wen),
        .b_waddr      (b_waddr),
        .b_wdata      (b_wdata),

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

    end


    // ============================================================
    // Write A word
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


    // ============================================================
    // Write B word
    // ============================================================

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
    // Launch one local K tile
    // ============================================================

    task automatic run_k_tile(
        input logic do_clear,
        input logic do_writeback
    );
    begin

        @(negedge clk);

        tile_k_size  = K_SIZE_WIDTH'(3);

        clear_acc    = do_clear;
        writeback_en = do_writeback;

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
    // Check one complete C row
    // ============================================================

    task automatic check_c_row(
        input logic [ADDR_WIDTH-1:0] addr,

        input integer expected0,
        input integer expected1,
        input integer expected2,
        input integer expected3
    );

        integer got0;
        integer got1;
        integer got2;
        integer got3;

    begin

        @(negedge clk);

        c_ren   = 1'b1;
        c_raddr = addr;

        @(posedge clk);
        #1;

        got0 = $signed(
            c_rdata[
                0*ACC_WIDTH +: ACC_WIDTH
            ]
        );

        got1 = $signed(
            c_rdata[
                1*ACC_WIDTH +: ACC_WIDTH
            ]
        );

        got2 = $signed(
            c_rdata[
                2*ACC_WIDTH +: ACC_WIDTH
            ]
        );

        got3 = $signed(
            c_rdata[
                3*ACC_WIDTH +: ACC_WIDTH
            ]
        );


        assert (got0 == expected0)
            else $fatal(
                1,
                "C[%0d][0] got %0d expected %0d",
                addr,
                got0,
                expected0
            );

        assert (got1 == expected1)
            else $fatal(
                1,
                "C[%0d][1] got %0d expected %0d",
                addr,
                got1,
                expected1
            );

        assert (got2 == expected2)
            else $fatal(
                1,
                "C[%0d][2] got %0d expected %0d",
                addr,
                got2,
                expected2
            );

        assert (got3 == expected3)
            else $fatal(
                1,
                "C[%0d][3] got %0d expected %0d",
                addr,
                got3,
                expected3
            );


        $display(
            "C row %0d = [%0d, %0d, %0d, %0d] : PASS",
            addr,
            got0,
            got1,
            got2,
            got3
        );


        @(negedge clk);

        c_ren   = 1'b0;
        c_raddr = '0;

    end
    endtask


    // ============================================================
    // Main test
    // ============================================================

    initial begin


        // ========================================================
        // Init
        // ========================================================

        reset        = 1'b1;

        start        = 1'b0;
        tile_k_size  = '0;

        clear_acc    = 1'b0;
        writeback_en = 1'b0;

        a_wen        = 1'b0;
        a_waddr      = '0;
        a_wdata      = '0;

        b_wen        = 1'b0;
        b_waddr      = '0;
        b_wdata      = '0;

        c_ren        = 1'b0;
        c_raddr      = '0;


        // ========================================================
        // Reset
        // ========================================================

        repeat (3) @(posedge clk);

        @(negedge clk);

        reset = 1'b0;


        // ========================================================
        // K TILE 0
        //
        // A0:
        //
        //  1  2  3
        //  7  8  9
        // 13 14 15
        // 19 20 21
        //
        // B0:
        //
        // 1  2  3  4
        // 5  6  7  8
        // 9 10 11 12
        // ========================================================

        write_a(
            ADDR_WIDTH'(0),
            {
                8'd19,
                8'd13,
                8'd7,
                8'd1
            }
        );

        write_a(
            ADDR_WIDTH'(1),
            {
                8'd20,
                8'd14,
                8'd8,
                8'd2
            }
        );

        write_a(
            ADDR_WIDTH'(2),
            {
                8'd21,
                8'd15,
                8'd9,
                8'd3
            }
        );


        write_b(
            ADDR_WIDTH'(0),
            {
                8'd4,
                8'd3,
                8'd2,
                8'd1
            }
        );

        write_b(
            ADDR_WIDTH'(1),
            {
                8'd8,
                8'd7,
                8'd6,
                8'd5
            }
        );

        write_b(
            ADDR_WIDTH'(2),
            {
                8'd12,
                8'd11,
                8'd10,
                8'd9
            }
        );


        $display("");
        $display("Running K tile 0...");

        run_k_tile(
            1'b1,   // clear accumulator
            1'b0    // do not write back
        );


        // ========================================================
        // Check partial sums directly in PE accumulator
        //
        // Expected:
        //
        //  38   44   50   56
        // 128  152  176  200
        // 218  260  302  344
        // 308  368  428  488
        // ========================================================

        assert (acc_out[0][0] == 38);
        assert (acc_out[0][1] == 44);
        assert (acc_out[0][2] == 50);
        assert (acc_out[0][3] == 56);

        assert (acc_out[1][0] == 128);
        assert (acc_out[1][1] == 152);
        assert (acc_out[1][2] == 176);
        assert (acc_out[1][3] == 200);

        assert (acc_out[2][0] == 218);
        assert (acc_out[2][1] == 260);
        assert (acc_out[2][2] == 302);
        assert (acc_out[2][3] == 344);

        assert (acc_out[3][0] == 308);
        assert (acc_out[3][1] == 368);
        assert (acc_out[3][2] == 428);
        assert (acc_out[3][3] == 488);


        $display(
            "K tile 0 partial sums preserved: PASS"
        );


        // ========================================================
        // K TILE 1
        //
        // Overwrite local A/B scratchpad.
        //
        // A1:
        //
        //  4  5  6
        // 10 11 12
        // 16 17 18
        // 22 23 24
        //
        // B1:
        //
        // 13 14 15 16
        // 17 18 19 20
        // 21 22 23 24
        // ========================================================

        write_a(
            ADDR_WIDTH'(0),
            {
                8'd22,
                8'd16,
                8'd10,
                8'd4
            }
        );

        write_a(
            ADDR_WIDTH'(1),
            {
                8'd23,
                8'd17,
                8'd11,
                8'd5
            }
        );

        write_a(
            ADDR_WIDTH'(2),
            {
                8'd24,
                8'd18,
                8'd12,
                8'd6
            }
        );


        write_b(
            ADDR_WIDTH'(0),
            {
                8'd16,
                8'd15,
                8'd14,
                8'd13
            }
        );

        write_b(
            ADDR_WIDTH'(1),
            {
                8'd20,
                8'd19,
                8'd18,
                8'd17
            }
        );

        write_b(
            ADDR_WIDTH'(2),
            {
                8'd24,
                8'd23,
                8'd22,
                8'd21
            }
        );


        $display("");
        $display("Running K tile 1...");

        run_k_tile(
            1'b0,   // DO NOT clear accumulator
            1'b1    // final K tile -> writeback
        );


        // ========================================================
        // Final accumulator result
        // ========================================================

        $display("");
        $display("Final accumulator:");

        for (int r = 0; r < ROWS; r++) begin

            $display(
                "%0d %0d %0d %0d",
                acc_out[r][0],
                acc_out[r][1],
                acc_out[r][2],
                acc_out[r][3]
            );

        end


        // ========================================================
        // Check banked C Buffer
        // ========================================================

        $display("");
        $display("Checking final C Buffer...");


        check_c_row(
            ADDR_WIDTH'(0),
            301,
            322,
            343,
            364
        );

        check_c_row(
            ADDR_WIDTH'(1),
            697,
            754,
            811,
            868
        );

        check_c_row(
            ADDR_WIDTH'(2),
            1093,
            1186,
            1279,
            1372
        );

        check_c_row(
            ADDR_WIDTH'(3),
            1489,
            1618,
            1747,
            1876
        );


        // ========================================================
        // PASS
        // ========================================================

        $display("");
        $display("========================================");
        $display("K-TILING TEST PASSED");
        $display("========================================");
        $display("");


        #20;

        $finish;

    end


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        #20000;

        $fatal(
            1,
            "Timeout: K-tiling test did not finish"
        );

    end


    // ============================================================
    // Waveform
    // ============================================================

    initial begin

        $dumpfile("gemm_core_tb.vcd");

        $dumpvars(
            0,
            gemm_core_tb
        );

    end


endmodule
