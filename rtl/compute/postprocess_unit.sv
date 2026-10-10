module postprocess_unit #(
    parameter int unsigned LANES     = 4,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned OUT_WIDTH = 8
) (
    input logic bias_en,
    input logic requant_en,
    input logic relu_en,

    input logic signed [ACC_WIDTH-1:0]
        data_in [LANES],

    input logic signed [ACC_WIDTH-1:0]
        bias [LANES],

    input logic [31:0]
        multiplier [LANES],

    input logic [5:0]
        shift [LANES],

    input logic signed [7:0] output_zero_point,

    output logic signed [ACC_WIDTH-1:0]
        data_out_int32 [LANES],

    output logic signed [OUT_WIDTH-1:0]
        data_out_int8 [LANES]
);


    // ============================================================
    // Signed rounding:
    //
    // round-to-nearest, ties away from zero
    //
    // Example:
    //
    //   7 / 2  ->  4
    //  -7 / 2  -> -4
    // ============================================================

    function automatic logic signed [63:0]
        round_shift_away_from_zero (
            input logic signed [63:0] value,
            input logic        [5:0]  shift_amount
        );

        logic [63:0]
            magnitude;

        logic [63:0]
            half;

        logic [63:0]
            rounded_magnitude;

        begin

            if (
                shift_amount ==
                6'd0
            ) begin

                round_shift_away_from_zero =
                    value;

            end else begin

                if (value < 0) begin

                    magnitude =
                        $unsigned(-value);

                end else begin

                    magnitude =
                        $unsigned(value);

                end


                half =
                    64'd1 <<
                    (
                        shift_amount -
                        6'd1
                    );


                rounded_magnitude =
                    (
                        magnitude +
                        half
                    ) >>
                    shift_amount;


                if (value < 0) begin

                    round_shift_away_from_zero =
                        -$signed(
                            rounded_magnitude
                        );

                end else begin

                    round_shift_away_from_zero =
                        $signed(
                            rounded_magnitude
                        );

                end

            end

        end

    endfunction


    // ============================================================
    // Per-lane datapath
    // ============================================================

    genvar lane;

    generate

        for (
            lane = 0;
            lane < LANES;
            lane = lane + 1
        ) begin : gen_post_lane

            logic signed [32:0]
                adjusted_wide;

            logic signed [63:0]
                adjusted_ext;

            logic signed [63:0]
                multiplier_ext;

            logic signed [63:0]
                product;

            logic signed [63:0]
                scaled;
            logic signed [63:0]
                scaled_zp;
            logic signed [63:0]
                zp_ext;


            always_comb begin

                // ------------------------------------------------
                // Optional Bias
                // ------------------------------------------------

                if (bias_en) begin

                    adjusted_wide =
                        {
                            data_in[lane][ACC_WIDTH-1],
                            data_in[lane]
                        } +
                        {
                            bias[lane][ACC_WIDTH-1],
                            bias[lane]
                        };

                end else begin

                    adjusted_wide =
                        {
                            data_in[lane][ACC_WIDTH-1],
                            data_in[lane]
                        };

                end


                // INT32 output path.
                //
                // Software/quantizer is expected to keep
                // accumulator + bias inside signed INT32 range.
                data_out_int32[lane] =
                    adjusted_wide[
                        ACC_WIDTH-1:0
                    ];


                // ------------------------------------------------
                // Requantization arithmetic
                // ------------------------------------------------

                adjusted_ext =
                    {
                        {
                            31{
                                adjusted_wide[32]
                            }
                        },
                        adjusted_wide
                    };


                // multiplier is positive and limited to 31 bits.
                multiplier_ext =
                    $signed(
                        {
                            32'd0,
                            multiplier[lane]
                        }
                    );


                product =
                    adjusted_ext *
                    multiplier_ext;


                scaled =
                    round_shift_away_from_zero(
                        product,
                        shift[lane]
                    );


                zp_ext = 64'($signed(output_zero_point));
                scaled_zp = scaled + zp_ext;

                // ------------------------------------------------
                // INT8 output with asymmetric zero point
                // ------------------------------------------------

                if (!requant_en) begin

                    data_out_int8[lane] =
                        '0;

                end else if (relu_en) begin

                    if (scaled_zp <= zp_ext) begin

                        data_out_int8[lane] =
                            output_zero_point;

                    end else if (
                        scaled_zp >
                        64'sd127
                    ) begin

                        data_out_int8[lane] =
                            8'sd127;

                    end else begin

                        data_out_int8[lane] =
                            scaled_zp[7:0];

                    end

                end else begin

                    if (
                        scaled_zp >
                        64'sd127
                    ) begin

                        data_out_int8[lane] =
                            8'sd127;

                    end else if (
                        scaled_zp <
                        -64'sd128
                    ) begin

                        data_out_int8[lane] =
                            -8'sd128;

                    end else begin

                        data_out_int8[lane] =
                            scaled_zp[7:0];

                    end

                end

            end

        end

    endgenerate


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (LANES < 1) begin

            $fatal(
                1,
                "LANES must be >= 1"
            );

        end


        if (ACC_WIDTH != 32) begin

            $fatal(
                1,
                "Current postprocess_unit requires ACC_WIDTH == 32"
            );

        end


        if (OUT_WIDTH != 8) begin

            $fatal(
                1,
                "Current postprocess_unit requires OUT_WIDTH == 8"
            );

        end

    end

endmodule
