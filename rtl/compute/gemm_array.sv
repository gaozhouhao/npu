// Skew each input lane by its row/column index, then feed the PE mesh.
module gemm_array #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32
) (
    input logic clk,
    input logic reset,
    input logic clear,
    input logic signed [DATA_WIDTH-1:0] a_in [ROWS],
    input logic a_valid_in [ROWS],
    input logic signed [DATA_WIDTH-1:0] b_in [COLS],
    input logic b_valid_in [COLS],
    output logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS]
);
    logic signed [DATA_WIDTH-1:0] array_a_data [ROWS][COLS+1];
    logic signed [DATA_WIDTH-1:0] array_b_data [ROWS+1][COLS];
    logic array_a_valid [ROWS][COLS+1];
    logic array_b_valid [ROWS+1][COLS];

    for (genvar row = 0; row < ROWS; row++) begin : gen_a_skew
        if (row == 0) begin : gen_direct
            assign array_a_data[row][0] = a_in[row];
            assign array_a_valid[row][0] = a_valid_in[row];
        end else begin : gen_delay
            logic signed [DATA_WIDTH-1:0] data_pipe [row];
            logic valid_pipe [row];
            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int stage = 0; stage < row; stage++) begin
                        data_pipe[stage] <= '0;
                        valid_pipe[stage] <= 1'b0;
                    end
                end else begin
                    data_pipe[0] <= a_in[row];
                    valid_pipe[0] <= a_valid_in[row];
                    for (int stage = 1; stage < row; stage++) begin
                        data_pipe[stage] <= data_pipe[stage-1];
                        valid_pipe[stage] <= valid_pipe[stage-1];
                    end
                end
            end
            assign array_a_data[row][0] = data_pipe[row-1];
            assign array_a_valid[row][0] = valid_pipe[row-1];
        end
    end

    for (genvar col = 0; col < COLS; col++) begin : gen_b_skew
        if (col == 0) begin : gen_direct
            assign array_b_data[0][col] = b_in[col];
            assign array_b_valid[0][col] = b_valid_in[col];
        end else begin : gen_delay
            logic signed [DATA_WIDTH-1:0] data_pipe [col];
            logic valid_pipe [col];
            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int stage = 0; stage < col; stage++) begin
                        data_pipe[stage] <= '0;
                        valid_pipe[stage] <= 1'b0;
                    end
                end else begin
                    data_pipe[0] <= b_in[col];
                    valid_pipe[0] <= b_valid_in[col];
                    for (int stage = 1; stage < col; stage++) begin
                        data_pipe[stage] <= data_pipe[stage-1];
                        valid_pipe[stage] <= valid_pipe[stage-1];
                    end
                end
            end
            assign array_b_data[0][col] = data_pipe[col-1];
            assign array_b_valid[0][col] = valid_pipe[col-1];
        end
    end

    for (genvar row = 0; row < ROWS; row++) begin : gen_row
        for (genvar col = 0; col < COLS; col++) begin : gen_col
            gemm_pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_gemm_pe (
                .clk(clk), .reset(reset), .clear(clear),
                .a_in(array_a_data[row][col]),
                .b_in(array_b_data[row][col]),
                .a_valid_in(array_a_valid[row][col]),
                .b_valid_in(array_b_valid[row][col]),
                .a_out(array_a_data[row][col+1]),
                .b_out(array_b_data[row+1][col]),
                .a_valid_out(array_a_valid[row][col+1]),
                .b_valid_out(array_b_valid[row+1][col]),
                .acc_out(acc_out[row][col])
            );
        end
    end
endmodule
