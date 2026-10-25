// Combinational bias + requantization for one row of accumulators.
module gemm_postprocess #(
    parameter int unsigned LANES = 4,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned OUT_WIDTH = 8
) (
    input logic bias_en,
    input logic requant_en,
    input logic relu_en,
    input logic signed [ACC_WIDTH-1:0] data_in [LANES],
    input logic signed [ACC_WIDTH-1:0] bias [LANES],
    input logic [31:0] multiplier [LANES],
    input logic [5:0] shift [LANES],
    input logic signed [OUT_WIDTH-1:0] output_zero_point,
    output logic signed [ACC_WIDTH-1:0] data_out_int32 [LANES],
    output logic signed [OUT_WIDTH-1:0] data_out_int8 [LANES]
);
    // The descriptor supplies a positive 31-bit multiplier and a 6-bit shift.
    localparam int SCALE_WIDTH = ACC_WIDTH + 32;
    localparam logic signed [SCALE_WIDTH-1:0] OUT_MAX =
        (SCALE_WIDTH'(1) << (OUT_WIDTH - 1)) - 1'b1;
    localparam logic signed [SCALE_WIDTH-1:0] OUT_MIN =
        -(SCALE_WIDTH'(1) << (OUT_WIDTH - 1));

    // Round to nearest, with ties away from zero.
    function automatic logic signed [SCALE_WIDTH-1:0] round_shift (
        input logic signed [SCALE_WIDTH-1:0] value,
        input logic [5:0] shift_amount
    );
        logic [SCALE_WIDTH-1:0] magnitude;
        logic [SCALE_WIDTH-1:0] half;
        logic [SCALE_WIDTH-1:0] rounded;
        if (shift_amount == 0)
            round_shift = value;
        else begin
            magnitude = (value < 0) ? $unsigned(-value) : $unsigned(value);
            half = SCALE_WIDTH'(1) << (shift_amount - 1'b1);
            rounded = (magnitude + half) >> shift_amount;
            round_shift = (value < 0) ? -$signed(rounded) : $signed(rounded);
        end
    endfunction

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_post_lane
        logic signed [ACC_WIDTH:0] biased_value;
        logic signed [SCALE_WIDTH-1:0] product;
        logic signed [SCALE_WIDTH-1:0] scaled_value;
        logic signed [SCALE_WIDTH-1:0] zero_point;
        always_comb begin
            biased_value = $signed({data_in[lane][ACC_WIDTH-1], data_in[lane]});
            if (bias_en)
                biased_value = biased_value + $signed({bias[lane][ACC_WIDTH-1], bias[lane]});
            data_out_int32[lane] = biased_value[ACC_WIDTH-1:0];

            product = SCALE_WIDTH'(biased_value) * SCALE_WIDTH'($signed({1'b0, multiplier[lane]}));
            zero_point = SCALE_WIDTH'(output_zero_point);
            scaled_value = round_shift(product, shift[lane]) + zero_point;
            if (relu_en && (scaled_value < zero_point)) scaled_value = zero_point;

            if (!requant_en)
                data_out_int8[lane] = '0;
            else if (scaled_value > OUT_MAX)
                data_out_int8[lane] = OUT_WIDTH'(OUT_MAX);
            else if (scaled_value < OUT_MIN)
                data_out_int8[lane] = OUT_WIDTH'(OUT_MIN);
            else
                data_out_int8[lane] = OUT_WIDTH'(scaled_value);
        end
    end
endmodule
