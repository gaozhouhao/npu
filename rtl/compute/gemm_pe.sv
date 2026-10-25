// One signed multiply-accumulate cell; operands advance one cell per clock.
module gemm_pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32
) (
    input logic clk,
    input logic reset,
    input logic clear,
    input logic signed [DATA_WIDTH-1:0] a_in,
    input logic signed [DATA_WIDTH-1:0] b_in,
    input logic a_valid_in,
    input logic b_valid_in,
    output logic signed [DATA_WIDTH-1:0] a_out,
    output logic signed [DATA_WIDTH-1:0] b_out,
    output logic a_valid_out,
    output logic b_valid_out,
    output logic signed [ACC_WIDTH-1:0] acc_out
);
    logic signed [2*DATA_WIDTH-1:0] product;
    assign product = a_in * b_in;

    always_ff @(posedge clk) begin
        if (reset || clear)
            acc_out <= '0;
        else if (a_valid_in && b_valid_in)
            acc_out <= acc_out + ACC_WIDTH'(product);

        if (reset) begin
            a_out <= '0;
            b_out <= '0;
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
        end else begin
            a_out <= a_in;
            b_out <= b_in;
            a_valid_out <= a_valid_in;
            b_valid_out <= b_valid_in;
        end
    end
endmodule
