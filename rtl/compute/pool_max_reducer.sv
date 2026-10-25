// A MaxPool consumer of the operator-independent raw window stream.
module pool_max_reducer (
    input logic clk,
    input logic reset,
    input logic clear,
    input logic sample_valid,
    output logic sample_ready,
    input logic [31:0] sample_data,
    input logic sample_first,
    input logic sample_last,
    input logic [31:0] sample_spatial_index,
    input logic [31:0] sample_channel_base,
    output logic result_valid,
    input logic result_ready,
    output logic [31:0] result_data,
    output logic [31:0] result_spatial_index,
    output logic [31:0] result_channel_base,
    output logic busy
);
    logic [31:0] accumulator_q, reduced_word;
    logic active_q;

    always_comb begin
        for (int lane = 0; lane < 4; lane++)
            reduced_word[lane*8 +: 8] = sample_first ||
                $signed(sample_data[lane*8 +: 8]) >
                    $signed(accumulator_q[lane*8 +: 8])
                ? sample_data[lane*8 +: 8]
                : accumulator_q[lane*8 +: 8];
    end
    assign sample_ready = !result_valid && !clear;
    assign busy = active_q || result_valid;

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            accumulator_q <= '0;
            active_q <= 1'b0;
            result_valid <= 1'b0;
            result_data <= '0;
            result_spatial_index <= '0;
            result_channel_base <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;
            if (sample_valid && sample_ready) begin
                accumulator_q <= reduced_word;
                active_q <= !sample_last;
                if (sample_last) begin
                    result_valid <= 1'b1;
                    result_data <= reduced_word;
                    result_spatial_index <= sample_spatial_index;
                    result_channel_base <= sample_channel_base;
                end
            end
        end
    end
endmodule
