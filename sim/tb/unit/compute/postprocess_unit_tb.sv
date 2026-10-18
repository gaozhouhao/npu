`timescale 1ns/1ps

module postprocess_unit_tb;

    localparam int unsigned LANES     = 4;
    localparam int unsigned ACC_WIDTH = 32;


    logic bias_en;
    logic requant_en, relu_en;
    logic [31:0] multiplier [LANES];
    logic [5:0] shift [LANES];
    logic signed [7:0] data_out_int8 [LANES];


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
        .data_out_int32(data_out),
        .data_out_int8(data_out_int8),
        .requant_en(requant_en), .relu_en(relu_en),
        .multiplier(multiplier), .shift(shift), .output_zero_point(8'sd0)
    );


    // ============================================================
    // Test
    // ============================================================

    initial begin
        requant_en = 0;
        relu_en = 0;
        for (int lane = 0; lane < LANES; lane++) begin
            multiplier[lane] = 1;
            shift[lane] = 0;
        end

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

        requant_en = 1;
        #1;
        if (data_out_int8[0] !== 8'sd100 || data_out_int8[1] !== -8'sd128 ||
            data_out_int8[2] !== 8'sd127 || data_out_int8[3] !== -8'sd128)
            $fatal(1, "INT8 saturation mismatch");
        relu_en = 1;
        #1;
        if (data_out_int8[1] !== 8'sd0 || data_out_int8[3] !== 8'sd0)
            $fatal(1, "ReLU mismatch");
        data_in[0] = 7; data_in[1] = -7;
        shift[0] = 1; shift[1] = 1;
        relu_en = 0;
        #1;
        if (data_out_int8[0] !== 8'sd4 || data_out_int8[1] !== -8'sd4)
            $fatal(1, "Signed ties-away rounding mismatch");
        $display("TEST_PASS postprocess_unit_tb");
        $finish;

    end

endmodule
