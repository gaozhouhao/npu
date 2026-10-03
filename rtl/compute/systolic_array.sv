module systolic_array #(
    parameter int ROWS = 4,
    parameter int COLS = 4
) (
    input logic clk,
    input logic reset,
    input logic clear,

    // A 从每一行左侧进入
    input logic signed [7:0] a_in [ROWS],
    input logic              a_valid_in [ROWS],

    // B 从每一列顶部进入
    input logic signed [7:0] b_in [COLS],
    input logic              b_valid_in [COLS],

    // 每个 PE 的最终 accumulator
    output logic signed [31:0] acc_out [ROWS][COLS]
);

    logic a_valid_wire [ROWS][COLS+1];
    logic b_valid_wire [ROWS+1][COLS];

    logic signed [7:0] a_wire [ROWS][COLS+1];
    logic signed [7:0] b_wire [ROWS+1][COLS];

    genvar i;
    generate
        for (i = 0; i < ROWS; i++) begin
            assign a_wire[i][0]       = a_in[i];
            assign a_valid_wire[i][0] = a_valid_in[i];
        end
    endgenerate

    genvar j;
    generate
        for (j = 0; j < COLS; j ++) begin
            assign b_wire[0][j]       = b_in[j];
            assign b_valid_wire[0][j] = b_valid_in[j];
        end
    endgenerate

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : gen_row
            for (c = 0; c < COLS; c++) begin : gen_col

                pe u_pe (
                    .clk         (clk),
                    .reset       (reset),

                    .a_in        (a_wire[r][c]),
                    .b_in        (b_wire[r][c]),
                    .a_valid_in  (a_valid_wire[r][c]),
                    .b_valid_in  (b_valid_wire[r][c]),

                    .clear       (clear),

                    .a_out       (a_wire[r][c+1]),
                    .b_out       (b_wire[r+1][c]),
                    .a_valid_out (a_valid_wire[r][c+1]),
                    .b_valid_out (b_valid_wire[r+1][c]),

                    .acc_out     (acc_out[r][c])
                );

            end
        end
    endgenerate

endmodule
