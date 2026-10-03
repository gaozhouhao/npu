module matrix_engine #(
    parameter int ROWS = 4,
    parameter int COLS = 4
) (
    input logic clk,
    input logic reset,
    input logic clear,

    input logic signed [7:0] a_in [ROWS],
    input logic              a_valid_in [ROWS],

    input logic signed [7:0] b_in [COLS],
    input logic              b_valid_in [COLS],

    output logic signed [31:0] acc_out [ROWS][COLS]
);

    logic signed [7:0] a_skewed [ROWS];
    logic              a_valid_skewed [ROWS];

    logic signed [7:0] b_skewed [COLS];
    logic              b_valid_skewed [COLS];

    input_skew #(
        .LANES(ROWS)
    ) u_a_skew (
        .clk(clk),
        .reset(reset),

        .data_in(a_in),
        .valid_in(a_valid_in),

        .data_out(a_skewed),
        .valid_out(a_valid_skewed)
    );

    input_skew #(
        .LANES(COLS)
    ) u_b_skew (
        .clk(clk),
        .reset(reset),

        .data_in(b_in),
        .valid_in(b_valid_in),

        .data_out(b_skewed),
        .valid_out(b_valid_skewed)
    );

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS)
    ) u_array (
        .clk(clk),
        .reset(reset),
        .clear(clear),

        .a_in(a_skewed),
        .a_valid_in(a_valid_skewed),

        .b_in(b_skewed),
        .b_valid_in(b_valid_skewed),

        .acc_out(acc_out)
    );

endmodule
