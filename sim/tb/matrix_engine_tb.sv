`timescale 1ns/1ps

module matrix_engine_tb;

    localparam int ROWS = 4;
    localparam int COLS = 4;

    logic clk;
    logic reset;
    logic clear;

    logic signed [7:0] a_in [ROWS];
    logic              a_valid_in [ROWS];

    logic signed [7:0] b_in [COLS];
    logic              b_valid_in [COLS];

    logic signed [31:0] acc_out [ROWS][COLS];

    matrix_engine #(
        .ROWS(ROWS),
        .COLS(COLS)
    ) dut (
        .clk(clk),
        .reset(reset),
        .clear(clear),

        .a_in(a_in),
        .a_valid_in(a_valid_in),

        .b_in(b_in),
        .b_valid_in(b_valid_in),

        .acc_out(acc_out)
    );

    // 10 ns clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        // -------------------------
        // Initialize
        // -------------------------
        reset = 1'b1;
        clear = 1'b0;

        for (int i = 0; i < ROWS; i++) begin
            a_in[i]       = 8'sd0;
            a_valid_in[i] = 1'b0;
        end

        for (int j = 0; j < COLS; j++) begin
            b_in[j]       = 8'sd0;
            b_valid_in[j] = 1'b0;
        end

        // -------------------------
        // Reset
        // -------------------------
        repeat (2) @(posedge clk);
        reset = 1'b0;

        // -------------------------
        // Clear accumulators
        // -------------------------
        clear = 1'b1;
        @(posedge clk);
        clear = 1'b0;

        // -------------------------
        // k = 0
        //
        // A[:,0] = {1,3}
        // B[0,:] = {5,6}
        // -------------------------
        a_in[0] = 8'sd1;
        a_in[1] = 8'sd3;

        b_in[0] = 8'sd5;
        b_in[1] = 8'sd6;

        a_valid_in[0] = 1'b1;
        a_valid_in[1] = 1'b1;

        b_valid_in[0] = 1'b1;
        b_valid_in[1] = 1'b1;

        @(posedge clk);

        // -------------------------
        // k = 1
        //
        // A[:,1] = {2,4}
        // B[1,:] = {7,8}
        // -------------------------
        a_in[0] = 8'sd2;
        a_in[1] = 8'sd4;

        b_in[0] = 8'sd7;
        b_in[1] = 8'sd8;

        @(posedge clk);

        // -------------------------
        // Stop injecting data
        // -------------------------
        for (int i = 0; i < ROWS; i++) begin
            a_in[i]       = 8'sd0;
            a_valid_in[i] = 1'b0;
        end

        for (int j = 0; j < COLS; j++) begin
            b_in[j]       = 8'sd0;
            b_valid_in[j] = 1'b0;
        end

        // Allow skew + systolic propagation to drain.
        repeat (6) @(posedge clk);
        #1;

        // -------------------------
        // Check result
        //
        // [1 2] [5 6] = [19 22]
        // [3 4] [7 8]   [43 50]
        // -------------------------

        if (acc_out[0][0] !== 32'sd19)
            $fatal(1, "C[0][0] FAIL: expected 19, got %0d",
                   acc_out[0][0]);

        if (acc_out[0][1] !== 32'sd22)
            $fatal(1, "C[0][1] FAIL: expected 22, got %0d",
                   acc_out[0][1]);

        if (acc_out[1][0] !== 32'sd43)
            $fatal(1, "C[1][0] FAIL: expected 43, got %0d",
                   acc_out[1][0]);

        if (acc_out[1][1] !== 32'sd50)
            $fatal(1, "C[1][1] FAIL: expected 50, got %0d",
                   acc_out[1][1]);

        $display("================================");
        $display(" MATRIX ENGINE TEST PASS");
        $display(" C =");
        $display(" [%0d, %0d]",
                 acc_out[0][0], acc_out[0][1]);
        $display(" [%0d, %0d]",
                 acc_out[1][0], acc_out[1][1]);
        $display("================================");

        $finish;
    end

endmodule

