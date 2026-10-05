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
    // GEMM result
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

        .a_wen       (a_wen),
        .a_waddr     (a_waddr),
        .a_wdata     (a_wdata),

        .b_wen       (b_wen),
        .b_waddr     (b_waddr),
        .b_wdata     (b_wdata),

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
    // Check result
    // ============================================================

    task automatic check_result;
    begin

        // Expected:
        //
        // 38   44   50   56
        // 83   98  113  128
        // 128 152  176  200
        // 173 206  239  272

        assert (acc_out[0][0] == 38)
            else $fatal(
                "C[0][0] error: got %0d",
                acc_out[0][0]
            );

        assert (acc_out[0][1] == 44)
            else $fatal(
                "C[0][1] error: got %0d",
                acc_out[0][1]
            );

        assert (acc_out[0][2] == 50)
            else $fatal(
                "C[0][2] error: got %0d",
                acc_out[0][2]
            );

        assert (acc_out[0][3] == 56)
            else $fatal(
                "C[0][3] error: got %0d",
                acc_out[0][3]
            );


        assert (acc_out[1][0] == 83)
            else $fatal(
                "C[1][0] error: got %0d",
                acc_out[1][0]
            );

        assert (acc_out[1][1] == 98)
            else $fatal(
                "C[1][1] error: got %0d",
                acc_out[1][1]
            );

        assert (acc_out[1][2] == 113)
            else $fatal(
                "C[1][2] error: got %0d",
                acc_out[1][2]
            );

        assert (acc_out[1][3] == 128)
            else $fatal(
                "C[1][3] error: got %0d",
                acc_out[1][3]
            );


        assert (acc_out[2][0] == 128)
            else $fatal(
                "C[2][0] error: got %0d",
                acc_out[2][0]
            );

        assert (acc_out[2][1] == 152)
            else $fatal(
                "C[2][1] error: got %0d",
                acc_out[2][1]
            );

        assert (acc_out[2][2] == 176)
            else $fatal(
                "C[2][2] error: got %0d",
                acc_out[2][2]
            );

        assert (acc_out[2][3] == 200)
            else $fatal(
                "C[2][3] error: got %0d",
                acc_out[2][3]
            );


        assert (acc_out[3][0] == 173)
            else $fatal(
                "C[3][0] error: got %0d",
                acc_out[3][0]
            );

        assert (acc_out[3][1] == 206)
            else $fatal(
                "C[3][1] error: got %0d",
                acc_out[3][1]
            );

        assert (acc_out[3][2] == 239)
            else $fatal(
                "C[3][2] error: got %0d",
                acc_out[3][2]
            );

        assert (acc_out[3][3] == 272)
            else $fatal(
                "C[3][3] error: got %0d",
                acc_out[3][3]
            );


        $display("");
        $display("========================================");
        $display("GEMM TEST PASSED");
        $display("========================================");
        $display("");

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


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (3) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;


        // ========================================================
        //
        // A = 4x3
        //
        //  1   2   3
        //  4   5   6
        //  7   8   9
        // 10  11  12
        //
        //
        // B = 3x4
        //
        //  1   2   3   4
        //  5   6   7   8
        //  9  10  11  12
        //
        //
        // C = A * B
        //
        //  38   44   50   56
        //  83   98  113  128
        // 128  152  176  200
        // 173  206  239  272
        //
        // ========================================================


        // ========================================================
        // Load A scratchpad
        //
        // Layout:
        //
        // SRAM[k] =
        // {
        //     A[3][k],
        //     A[2][k],
        //     A[1][k],
        //     A[0][k]
        // }
        //
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
        // Layout:
        //
        // SRAM[k] =
        // {
        //     B[k][3],
        //     B[k][2],
        //     B[k][1],
        //     B[k][0]
        // }
        //
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
        // Check idle state before start
        // ========================================================

        assert (busy == 1'b0)
            else $fatal("busy should be 0 before start");

        assert (done == 1'b0)
            else $fatal("done should be 0 before start");


        // ========================================================
        // Start GEMM
        // ========================================================

        @(negedge clk);

        tile_k_size = K_SIZE_WIDTH'(3);
        start       = 1'b1;

        @(negedge clk);

        start = 1'b0;


        // ========================================================
        // Wait for completion
        // ========================================================

        wait(done == 1'b1);


        // ========================================================
        // Display result
        // ========================================================

        $display("");
        $display("Result matrix:");

        for (int r = 0; r < ROWS; r++) begin

            $display(
                "%0d  %0d  %0d  %0d",
                acc_out[r][0],
                acc_out[r][1],
                acc_out[r][2],
                acc_out[r][3]
            );

        end

        $display("");


        // ========================================================
        // Check result
        // ========================================================

        check_result();


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

        #5000;

        $fatal(
            "Timeout: GEMM test did not finish"
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
