module input_skew #(
    parameter int LANES = 4
) (
    input  logic clk,
    input  logic reset,

    input  logic signed [7:0] data_in   [LANES],
    input  logic              valid_in  [LANES],

    output logic signed [7:0] data_out  [LANES],
    output logic              valid_out [LANES]
);

    assign data_out[0]  = data_in[0];
    assign valid_out[0] = valid_in[0];

    genvar i;
    generate
        for (i = 1; i < LANES; i++) begin : gen_lane

            logic signed [7:0] data_delay [i];
            logic              valid_delay[i];

            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int d = 0; d < i; d++) begin
                        data_delay[d]  <= 8'sd0;
                        valid_delay[d] <= 1'b0;
                    end
                end else begin
                    data_delay[0]  <= data_in[i];
                    valid_delay[0] <= valid_in[i];

                    for (int d = 1; d < i; d++) begin
                        data_delay[d]  <= data_delay[d-1];
                        valid_delay[d] <= valid_delay[d-1];
                    end
                end
            end 
            
            assign data_out[i]  = data_delay[i-1];
            assign valid_out[i] = valid_delay[i-1];

        end
    endgenerate

endmodule

