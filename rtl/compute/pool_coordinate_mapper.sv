// Convert a result tile's physical coordinates to pooling coordinates.
// A fully connected result is emitted on physical row zero; its channel
// vector represents consecutive pixels with fc_channels channels each.
// FC words arrive in increasing output-index order. Only an accepted real
// result advances the logical coordinate; Conv coordinates pass through.
module pool_coordinate_mapper #(
    parameter int unsigned COLS = 4
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        clear,
    input  logic        start,
    input  logic        fc_fire,
    input  logic        fc_mode,
    input  logic [31:0] source_spatial_index,
    input  logic [31:0] source_channel_base,
    input  logic [31:0] fc_channels,
    output logic        mapped_valid,
    output logic [31:0] mapped_spatial_index,
    output logic [31:0] mapped_channel_base,
    output logic        mapping_error
);
    logic [31:0] pixel_q, channel_q;
    logic [31:0] last_channel_q;
    logic configured_q;

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            pixel_q <= '0;
            channel_q <= '0;
            last_channel_q <= '0;
            configured_q <= 1'b0;
        end else if (start) begin
            pixel_q <= '0;
            channel_q <= '0;
            // Configuration has already passed layer admission. Retain a
            // local guard for standalone use, outside the result data path.
            configured_q <= fc_channels >= 32'(COLS) &&
                fc_channels % 32'(COLS) == 0;
            last_channel_q <= fc_channels >= 32'(COLS) ?
                fc_channels - 32'(COLS) : 32'd0;
        end else if (fc_fire && fc_mode && mapped_valid) begin
            if (channel_q == last_channel_q) begin
                channel_q <= '0;
                pixel_q <= pixel_q + 32'd1;
            end else begin
                channel_q <= channel_q + 32'(COLS);
            end
        end
    end

    always_comb begin
        mapped_valid = 1'b1;
        mapped_spatial_index = source_spatial_index;
        mapped_channel_base = source_channel_base;
        mapping_error = 1'b0;

        if (fc_mode) begin
            mapped_valid = 1'b0;
            mapped_spatial_index = '0;
            mapped_channel_base = '0;

            // Padded physical rows carry no logical FC outputs. Ignore
            // them even when no usable FC shape has been configured.
            if (source_spatial_index == 32'd0) begin
                if (!configured_q) begin
                    mapping_error = 1'b1;
                end else begin
                    mapped_valid = 1'b1;
                    mapped_spatial_index = pixel_q;
                    mapped_channel_base = channel_q;
                end
            end
        end
    end
endmodule
