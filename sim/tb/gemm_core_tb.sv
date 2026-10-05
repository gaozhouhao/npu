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

    logic busy;
    logic done;


    // ============================================================
    // A scratchpad write port
    // ============================================================

    logic                           a_wen;
    logic [ADDR_WIDTH-1:0]          a_waddr;
    logic [ROWS*DATA_WIDTH-1:0]     a_wdata;


    // ============================================================
    // B scratchpad write port
    // ============================================================

    logic                           b_wen;
    logic [ADDR_WIDTH-1:0]          b_waddr;
    logic [COLS*DATA_WIDTH-1:0]     b_wdata;


    // ============================================================
    // C scratchpad read port
    // ============================================================

    logic                           c_ren;
    logic [ADDR_WIDTH-1:0]          c_raddr;
    logic [ACC_WIDTH-1:0]           c_rdata;


    // ============================================================
    // Debug accumulator output
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
        .clk         (clk),
        .reset       (reset),

        .start       (start),
        .tile_k_size (tile_k_size),

        .busy        (busy),
        .done        (done),

        // A preload
        .a_wen       (a_wen),
        .a_waddr     (a_waddr),
        .a_wdata     (a_wdata),

        // B preload
        .b_wen       (b_wen),
        .b_waddr     (b_waddr),
        .b_wdata     (b_wdata),

        // C read
        .c_ren       (c_ren),
        .c_raddr     (c_raddr),
        .c_rdata     (c_rdata),

        // Debug
        .acc_out     (acc_out)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end


    // ============================================================
    // Write A scratchpad
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
    // Write B scratchpad
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
    // Read and check one C SRAM word
    //
    // C SRAM is synchronous-read:
    //
    // negedge:
    //      set c_ren / c_raddr
    //
    // next posedge:
    //      SRAM captures address and updates c_rdata
    //
    // #1:
    //      check result
    // ============================================================

    task automatic check_c(
        input logic [ADDR_WIDTH-1:0] addr,
        input integer                expected
    );
    begin

        @(negedge clk);

        c_ren   = 1'b1;
        c_raddr = addr;

        @(posedge clk);
        #1;

        assert ($signed(c_rdata) == expected)
            else $fatal(
                1,
                "C SRAM[%0d] error: got %0d, expected %0d",
                addr,
                $signed(c_rdata),
                expected
            );

        $display(
            "C SRAM[%0d] = %0d : PASS",
            addr,
            $signed(c_rdata)
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

        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------

        reset       = 1'b1;

        start       = 1'b0;
        tile_k_size = '0;

        a_wen       = 1'b0;
        a_waddr     = '0;
        a_wdata     = '0;

        b_wen       = 1'b0;
        b_waddr     = '0;
        b_wdata     = '0;

        c_ren       = 1'b0;
        c_raddr     = '0;


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (3) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;


        // --------------------------------------------------------
        // Controller should initially be idle
        // --------------------------------------------------------

        assert (busy == 1'b0)
            else $fatal(
                1,
                "busy should be 0 before start"
            );

        assert (done == 1'b0)
            else $fatal(
                1,
                "done should be 0 before start"
            );


        // ========================================================
        //
        // Test matrix
        //
        // A = 4x3
        //
        //   1   2   3
        //   4   5   6
        //   7   8   9
        //  10  11  12
        //
        //
        // B = 3x4
        //
        //   1   2   3   4
        //   5   6   7   8
        //   9  10  11  12
        //
        //
        // C = A * B
        //
        //   38   44   50   56
        //   83   98  113  128
        //  128  152  176  200
        //  173  206  239  272
        //
        // ========================================================


        // ========================================================
        // Load A scratchpad
        //
        // SRAM[k] =
        // {
        //     A[3][k],
        //     A[2][k],
        //     A[1][k],
        //     A[0][k]
        // }
        //
        // a_rdata[7:0]   -> row 0
        // a_rdata[15:8]  -> row 1
        // a_rdata[23:16] -> row 2
        // a_rdata[31:24] -> row 3
        // ========================================================

        write_a(
            ADDR_WIDTH'(0),
            {
                8'd10,
                8'd7,
                8'd4,
                8'd1
            }
        );

        write_a(
            ADDR_WIDTH'(1),
            {
                8'd11,
                8'd8,
                8'd5,
                8'd2
            }
        );

        write_a(
            ADDR_WIDTH'(2),
            {
                8'd12,
                8'd9,
                8'd6,
                8'd3
            }
        );


        // ========================================================
        // Load B scratchpad
        //
        // SRAM[k] =
        // {
        //     B[k][3],
        //     B[k][2],
        //     B[k][1],
        //     B[k][0]
        // }
        //
        // b_rdata[7:0]   -> col 0
        // b_rdata[15:8]  -> col 1
        // b_rdata[23:16] -> col 2
        // b_rdata[31:24] -> col 3
        // ========================================================

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


        // ========================================================
        // Start GEMM
        // ========================================================

        @(negedge clk);

        tile_k_size = K_SIZE_WIDTH'(3);
        start       = 1'b1;

        @(negedge clk);

        start = 1'b0;


        // ========================================================
        // Controller should become busy
        // ========================================================

        wait(busy == 1'b1);

        $display("");
        $display("GEMM started: busy asserted");


        // ========================================================
        // Wait for:
        //
        // CLEAR
        // FEED
        // DRAIN
        // WRITEBACK
        // DONE
        // ========================================================

        wait(done == 1'b1);


        // DONE is still considered busy in current controller
        assert (busy == 1'b1)
            else $fatal(
                1,
                "busy should remain 1 while done is asserted"
            );

        $display("GEMM completed: done asserted");


        // ========================================================
        // Debug: display raw acc_out
        // ========================================================

        $display("");
        $display("Accumulator matrix:");

        for (int r = 0; r < ROWS; r++) begin

            $display(
                "%0d  %0d  %0d  %0d",
                acc_out[r][0],
                acc_out[r][1],
                acc_out[r][2],
                acc_out[r][3]
            );

        end


        // ========================================================
        // Wait until controller returns to IDLE
        // ========================================================

        @(posedge clk);
        #1;

        assert (busy == 1'b0)
            else $fatal(
                1,
                "busy should return to 0 after DONE"
            );

        assert (done == 1'b0)
            else $fatal(
                1,
                "done should only stay high for one cycle"
            );


        // ========================================================
        // Read C SRAM and verify complete writeback
        //
        // Row-major:
        //
        // addr 0  -> C[0][0]
        // addr 1  -> C[0][1]
        // ...
        // addr 15 -> C[3][3]
        // ========================================================

        $display("");
        $display("Checking C SRAM...");


        // Row 0
        check_c(
            ADDR_WIDTH'(0),
            38
        );

        check_c(
            ADDR_WIDTH'(1),
            44
        );

        check_c(
            ADDR_WIDTH'(2),
            50
        );

        check_c(
            ADDR_WIDTH'(3),
            56
        );


        // Row 1
        check_c(
            ADDR_WIDTH'(4),
            83
        );

        check_c(
            ADDR_WIDTH'(5),
            98
        );

        check_c(
            ADDR_WIDTH'(6),
            113
        );

        check_c(
            ADDR_WIDTH'(7),
            128
        );


        // Row 2
        check_c(
            ADDR_WIDTH'(8),
            128
        );

        check_c(
            ADDR_WIDTH'(9),
            152
        );

        check_c(
            ADDR_WIDTH'(10),
            176
        );

        check_c(
            ADDR_WIDTH'(11),
            200
        );


        // Row 3
        check_c(
            ADDR_WIDTH'(12),
            173
        );

        check_c(
            ADDR_WIDTH'(13),
            206
        );

        check_c(
            ADDR_WIDTH'(14),
            239
        );

        check_c(
            ADDR_WIDTH'(15),
            272
        );


        // ========================================================
        // PASS
        // ========================================================

        $display("");
        $display("========================================");
        $display("SRAM-BACKED GEMM + WRITEBACK TEST PASSED");
        $display("========================================");
        $display("");


        // ========================================================
        // Finish
        // ========================================================

        #20;

        $finish;

    end


    // ============================================================
    // Timeout protection
    // ============================================================

    initial begin

        #10000;

        $fatal(
            1,
            "Timeout: GEMM core test did not finish"
        );

    end


    // ============================================================
    // Waveform
    // ============================================================

    initial begin

        $dumpfile("gemm_core_tb.vcd");
        $dumpvars(0, gemm_core_tb);

    end


endmodule
