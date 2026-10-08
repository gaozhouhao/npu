module postprocess_unit #(
    parameter int unsigned LANES     = 4,
    parameter int unsigned ACC_WIDTH = 32
) (
    // ============================================================
    // Control
    // ============================================================

    input logic bias_en,

    // ============================================================
    // Input accumulator row
    // ============================================================

    input logic signed [ACC_WIDTH-1:0]
        data_in [LANES],

    // ============================================================
    // Bias vector
    //
    // For a GEMM output row:
    //
    // data_in[0] += bias[0]
    // data_in[1] += bias[1]
    // ...
    //
    // The same bias vector is reused for every M row belonging
    // to the same N tile.
    // ============================================================

    input logic signed [ACC_WIDTH-1:0]
        bias [LANES],

    // ============================================================
    // Post-processed output
    // ============================================================

    output logic signed [ACC_WIDTH-1:0]
        data_out [LANES]
);


    // ============================================================
    // Bias stage
    //
    // Current version:
    //
    //   bias_en = 0:
    //       data_out = data_in
    //
    //   bias_en = 1:
    //       data_out = data_in + bias
    //
    // Future stages will be appended after this:
    //
    //   multiplier
    //   rounding
    //   shift
    //   saturation
    //   activation
    // ============================================================

    genvar lane;

    generate

        for (
            lane = 0;
            lane < LANES;
            lane = lane + 1
        ) begin : gen_bias_lane

            always_comb begin

                if (bias_en) begin

                    data_out[lane] =
                        data_in[lane] +
                        bias[lane];

                end else begin

                    data_out[lane] =
                        data_in[lane];

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


        if (ACC_WIDTH < 2) begin

            $fatal(
                1,
                "ACC_WIDTH must be >= 2"
            );

        end

    end

endmodule
