module pe (
    input  logic                    clk,
    input  logic                    reset,

    input  logic signed [7:0]       a_in,
    input  logic signed [7:0]       b_in,
    input  logic                    a_valid_in,
    input  logic                    b_valid_in,

    input  logic                    clear,

    output logic signed [7:0]       a_out,
    output logic signed [7:0]       b_out,
    output logic                    a_valid_out,
    output logic                    b_valid_out,

    output logic signed [31:0]      acc_out
);

    logic signed [15:0] product;

    assign product = a_in * b_in;

    always_ff @(posedge clk) begin
        if (reset) begin
            acc_out <= 32'sd0;
        end else if (clear) begin
            acc_out <= 32'sd0;
        end else if (a_valid_in && b_valid_in) begin
            acc_out <= acc_out + {{16{product[15]}}, product};
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            a_out <= 8'sd0;
            b_out <= 8'sd0;
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
