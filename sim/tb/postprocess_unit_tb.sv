module postprocess_unit_tb;

    localparam int unsigned LANES     = 4;
    localparam int unsigned ACC_WIDTH = 32;


    logic bias_en;


    logic signed [ACC_WIDTH-1:0]
        data_in [LANES];

    logic signed [ACC_WIDTH-1:0]
        bias [LANES];

    logic signed [ACC_WIDTH-1:0]
        data_out [LANES];


    // ============================================================
    // DUT
    // ============================================================

    postprocess_unit #(
        .LANES     (LANES),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_dut (
        .bias_en  (bias_en),
        .data_in  (data_in),
        .bias     (bias),
        .data_out (data_out)
    );


    // ============================================================
    // Test
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // Input accumulator row
        // --------------------------------------------------------

        data_in[0] = 32'sd100;
        data_in[1] = -32'sd200;
        data_in[2] = 32'sd3000;
        data_in[3] = -32'sd4000;


        // --------------------------------------------------------
        // Bias vector
        // --------------------------------------------------------

        bias[0] = 32'sd10;
        bias[1] = 32'sd20;
        bias[2] = -32'sd30;
        bias[3] = -32'sd40;


        // ========================================================
        // Case 1:
        // Pure GEMM, bias disabled
        // ========================================================

        bias_en = 1'b0;

        #1;


        if (data_out[0] !== 32'sd100) begin
            $fatal(
                1,
                "Bypass lane 0 mismatch"
            );
        end


        if (data_out[1] !== -32'sd200) begin
            $fatal(
                1,
                "Bypass lane 1 mismatch"
            );
        end


        if (data_out[2] !== 32'sd3000) begin
            $fatal(
                1,
                "Bypass lane 2 mismatch"
            );
        end


        if (data_out[3] !== -32'sd4000) begin
            $fatal(
                1,
                "Bypass lane 3 mismatch"
            );
        end


        // ========================================================
        // Case 2:
        // GEMM + Bias
        // ========================================================

        bias_en = 1'b1;

        #1;


        if (data_out[0] !== 32'sd110) begin
            $fatal(
                1,
                "Bias lane 0 mismatch: got %0d expected 110",
                data_out[0]
            );
        end


        if (data_out[1] !== -32'sd180) begin
            $fatal(
                1,
                "Bias lane 1 mismatch: got %0d expected -180",
                data_out[1]
            );
        end


        if (data_out[2] !== 32'sd2970) begin
            $fatal(
                1,
                "Bias lane 2 mismatch: got %0d expected 2970",
                data_out[2]
            );
        end


        if (data_out[3] !== -32'sd4040) begin
            $fatal(
                1,
                "Bias lane 3 mismatch: got %0d expected -4040",
                data_out[3]
            );
        end


        // ========================================================
        // Case 3:
        // Zero bias
        // ========================================================

        bias[0] = 32'sd0;
        bias[1] = 32'sd0;
        bias[2] = 32'sd0;
        bias[3] = 32'sd0;

        #1;


        if (
            (data_out[0] !== data_in[0]) ||
            (data_out[1] !== data_in[1]) ||
            (data_out[2] !== data_in[2]) ||
            (data_out[3] !== data_in[3])
        ) begin

            $fatal(
                1,
                "Zero-bias case failed"
            );

        end


        $display("");
        $display("========================================");
        $display("POSTPROCESS UNIT TEST PASSED");
        $display("========================================");
        $display("LANES     = %0d", LANES);
        $display("ACC_WIDTH = %0d", ACC_WIDTH);
        $display("Bias bypass and parallel bias add passed");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
