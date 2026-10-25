// Shared raw INT8 line storage and VALID pooling-window reader.
// Every COLS-wide input is stored without reduction. A completed window is
// replayed in row-major order, four channels at a time, for any downstream
// pooling operator. Channel groups may interleave while full-channel storage
// fits; otherwise one COLS-channel tile must finish its complete raster first.
module pool_window_buffer #(
    parameter int unsigned COLS = 4,
    parameter int unsigned LINE_WORDS = 1024
) (
    input logic clk,
    input logic reset,
    input logic start,
    input logic [31:0] cfg_input_h,
    input logic [31:0] cfg_input_w,
    input logic [31:0] cfg_channels,
    input logic [31:0] cfg_pool_config,

    input logic in_valid,
    output logic in_ready,
    input logic [COLS*8-1:0] in_data,
    input logic [31:0] in_spatial_index,
    input logic [31:0] in_channel_base,

    output logic busy,
    output logic error,
    output logic sample_valid,
    input logic sample_ready,
    output logic [31:0] sample_data,
    output logic sample_first,
    output logic sample_last,
    output logic [31:0] sample_spatial_index,
    output logic [31:0] sample_channel_base,
    output logic [31:0] output_width,
    output logic channel_tiled
);
    localparam int unsigned GROUPS = COLS / 4;
    localparam int unsigned GROUP_WIDTH = GROUPS <= 1 ? 1 : $clog2(GROUPS);
    localparam int unsigned SAFE_GROUPS = GROUPS == 0 ? 1 : GROUPS;
    localparam int unsigned RAW_ENTRIES = LINE_WORDS / SAFE_GROUPS;
    localparam int unsigned SAFE_ENTRIES = RAW_ENTRIES == 0 ? 1 : RAW_ENTRIES;
    localparam int unsigned RAW_ADDR_WIDTH =
        SAFE_ENTRIES <= 1 ? 1 : $clog2(SAFE_ENTRIES);

    typedef enum logic [1:0] {ST_IDLE, ST_READ, ST_SAMPLE} state_t;
    state_t state_q;
    logic configured_q;
    logic channel_tiled_q;
    logic [31:0] next_spatial_q, next_channel_q;
    logic [31:0] width_q, channels_q, channel_tiles_q;
    logic [31:0] kernel_h_q, kernel_w_q, stride_h_q, stride_w_q;
    logic [31:0] output_w_q;
    logic [63:0] pixel_count_q;
    logic [31:0] top_y_q, top_x_q, channel_base_q, output_spatial_q;
    logic [31:0] sample_y_q, sample_x_q;
    logic [GROUP_WIDTH-1:0] group_q;
    logic [COLS*8-1:0] raw_data_q;
    logic [COLS*8-1:0] raw_memory [0:SAFE_ENTRIES-1];
    logic [63:0] write_index, read_index;
    logic [RAW_ADDR_WIDTH-1:0] write_addr, read_addr;

    logic [31:0] cfg_kh, cfg_kw, cfg_sh, cfg_sw, cfg_oh, cfg_ow;
    logic [63:0] cfg_pixels;
    logic [95:0] cfg_full_words, cfg_tile_words;
    logic config_valid;
    logic [31:0] incoming_x, incoming_y, incoming_oy, incoming_ox;
    logic incoming_metadata_valid, incoming_order_valid, incoming_window;
    logic input_fire;

    always_comb begin
        cfg_kh = cfg_pool_config == 0 ? 32'd2 : {24'd0, cfg_pool_config[7:0]};
        cfg_kw = cfg_pool_config == 0 ? 32'd2 : {24'd0, cfg_pool_config[15:8]};
        cfg_sh = cfg_pool_config == 0 ? 32'd2 : {24'd0, cfg_pool_config[23:16]};
        cfg_sw = cfg_pool_config == 0 ? 32'd2 : {24'd0, cfg_pool_config[31:24]};
        cfg_oh = 0;
        cfg_ow = 0;
        if (cfg_kh != 0 && cfg_sh != 0 && cfg_input_h >= cfg_kh)
            cfg_oh = (cfg_input_h - cfg_kh) / cfg_sh + 1;
        if (cfg_kw != 0 && cfg_sw != 0 && cfg_input_w >= cfg_kw)
            cfg_ow = (cfg_input_w - cfg_kw) / cfg_sw + 1;
        cfg_pixels = 64'(cfg_input_h) * 64'(cfg_input_w);
        cfg_full_words = 96'(cfg_kh) * 96'(cfg_input_w) *
            96'(cfg_channels >> 2);
        cfg_tile_words = 96'(cfg_kh) * 96'(cfg_input_w) * 96'(GROUPS);
        config_valid = cfg_kh != 0 && cfg_kw != 0 &&
            cfg_sh != 0 && cfg_sw != 0 && cfg_oh != 0 && cfg_ow != 0 &&
            COLS >= 4 && COLS % 4 == 0 && RAW_ENTRIES != 0 &&
            cfg_channels >= COLS && cfg_channels % COLS == 0 &&
            cfg_pixels <= 64'h1_0000_0000 &&
            cfg_tile_words <= 96'(LINE_WORDS);
    end

    always_comb begin
        incoming_x = 0;
        incoming_y = 0;
        incoming_oy = 0;
        incoming_ox = 0;
        incoming_window = 1'b0;
        if (configured_q) begin
            incoming_x = in_spatial_index % width_q;
            incoming_y = in_spatial_index / width_q;
            if (incoming_y >= kernel_h_q - 1 &&
                incoming_x >= kernel_w_q - 1) begin
                incoming_oy = (incoming_y - (kernel_h_q - 1)) / stride_h_q;
                incoming_ox = (incoming_x - (kernel_w_q - 1)) / stride_w_q;
                incoming_window =
                    (incoming_y - (kernel_h_q - 1)) % stride_h_q == 0 &&
                    (incoming_x - (kernel_w_q - 1)) % stride_w_q == 0;
            end
        end
    end

    assign in_ready = configured_q && state_q == ST_IDLE && !start;
    assign input_fire = in_valid && in_ready;
    assign busy = state_q != ST_IDLE;
    assign incoming_metadata_valid =
        in_channel_base % COLS == 0 &&
        64'(in_channel_base) + 64'(COLS) <= 64'(channels_q) &&
        64'(in_spatial_index) < pixel_count_q;
    assign incoming_order_valid = !channel_tiled_q ||
        (in_channel_base == next_channel_q &&
         in_spatial_index == next_spatial_q);

    // Distinct channels own distinct ring entries in full-channel mode. Each
    // channel tile visits its own spatial raster monotonically, even when
    // Conv result tiles interleave channel groups over several positions.
    assign write_index = !configured_q ? 64'd0 : channel_tiled_q
        ? 64'(incoming_y % kernel_h_q) * 64'(width_q) + 64'(incoming_x)
        : (64'(incoming_y % kernel_h_q) * 64'(width_q) + 64'(incoming_x)) *
            64'(channel_tiles_q) + 64'(in_channel_base / COLS);
    assign read_index = !configured_q ? 64'd0 : channel_tiled_q
        ? 64'((top_y_q + sample_y_q) % kernel_h_q) * 64'(width_q) +
            64'(top_x_q + sample_x_q)
        : (64'((top_y_q + sample_y_q) % kernel_h_q) * 64'(width_q) +
            64'(top_x_q + sample_x_q)) * 64'(channel_tiles_q) +
            64'(channel_base_q / COLS);
    assign write_addr = RAW_ADDR_WIDTH'(write_index);
    assign read_addr = RAW_ADDR_WIDTH'(read_index);

    // Writes preserve the complete producer vector. The following ST_READ
    // cycle performs a synchronous SRAM read, including a 1x1 window's just
    // accepted sample. No reset/clear touches the SRAM contents.
    always_ff @(posedge clk) begin
        if (input_fire && incoming_metadata_valid && incoming_order_valid)
            raw_memory[write_addr] <= in_data;
        if (state_q == ST_READ)
            raw_data_q <= raw_memory[read_addr];
    end

    assign sample_valid = state_q == ST_SAMPLE;
    assign sample_data = raw_data_q[32*group_q +: 32];
    assign sample_first = sample_y_q == 0 && sample_x_q == 0;
    assign sample_last = sample_y_q == kernel_h_q - 1 &&
        sample_x_q == kernel_w_q - 1;
    assign sample_spatial_index = output_spatial_q;
    assign sample_channel_base = channel_base_q + (32'(group_q) << 2);
    assign output_width = output_w_q;
    assign channel_tiled = channel_tiled_q;

    // Check raw-memory lifetime without adding tags or SRAM reset hardware.
    // An entry belongs to a particular task, pixel and COLS-channel vector;
    // a changed producer traversal must not silently replay a stale sample.
    // synthesis translate_off
`ifndef SYNTHESIS
    logic [63:0] simulation_epoch_q = 0;
    logic [63:0] simulation_epoch [0:SAFE_ENTRIES-1];
    logic [31:0] simulation_spatial [0:SAFE_ENTRIES-1];
    logic [31:0] simulation_channel [0:SAFE_ENTRIES-1];
    always_ff @(posedge clk) begin
        if (reset) simulation_epoch_q <= simulation_epoch_q + 1;
        else begin
            if (start && state_q == ST_IDLE)
                simulation_epoch_q <= simulation_epoch_q + 1;
            if (input_fire && incoming_metadata_valid && incoming_order_valid) begin
                assert (write_index < 64'(RAW_ENTRIES))
                    else $fatal(1, "Pool raw write exceeds admitted capacity");
                simulation_epoch[write_addr] <= simulation_epoch_q;
                simulation_spatial[write_addr] <= in_spatial_index;
                simulation_channel[write_addr] <= in_channel_base;
            end
            if (state_q == ST_READ) begin
                assert (read_index < 64'(RAW_ENTRIES))
                    else $fatal(1, "Pool raw read exceeds admitted capacity");
                assert (simulation_epoch[read_addr] === simulation_epoch_q &&
                    simulation_spatial[read_addr] ===
                        ((top_y_q + sample_y_q) * width_q + top_x_q + sample_x_q) &&
                    simulation_channel[read_addr] === channel_base_q)
                    else $fatal(1,
                        "Pool raw sample missing/overwritten: pixel=%0d channel=%0d slot=%0d",
                        (top_y_q + sample_y_q) * width_q + top_x_q + sample_x_q,
                        channel_base_q, read_index);
            end
        end
    end
`endif
    // synthesis translate_on

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            configured_q <= 1'b0;
            channel_tiled_q <= 1'b0;
            next_spatial_q <= 0;
            next_channel_q <= 0;
            width_q <= 0;
            channels_q <= 0;
            channel_tiles_q <= 0;
            kernel_h_q <= 0;
            kernel_w_q <= 0;
            stride_h_q <= 0;
            stride_w_q <= 0;
            output_w_q <= 0;
            pixel_count_q <= 0;
            top_y_q <= 0;
            top_x_q <= 0;
            channel_base_q <= 0;
            output_spatial_q <= 0;
            sample_y_q <= 0;
            sample_x_q <= 0;
            group_q <= 0;
            error <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        configured_q <= config_valid;
                        channel_tiled_q <= cfg_full_words > 96'(LINE_WORDS);
                        next_spatial_q <= 0;
                        next_channel_q <= 0;
                        width_q <= cfg_input_w;
                        channels_q <= cfg_channels;
                        channel_tiles_q <= cfg_channels / COLS;
                        kernel_h_q <= cfg_kh;
                        kernel_w_q <= cfg_kw;
                        stride_h_q <= cfg_sh;
                        stride_w_q <= cfg_sw;
                        output_w_q <= cfg_ow;
                        pixel_count_q <= cfg_pixels;
                        error <= !config_valid;
                    end else if (input_fire) begin
                        if (!incoming_metadata_valid || !incoming_order_valid) begin
                            // Drain malformed input without corrupting live
                            // raw entries or moving the accepted-order cursor.
                            error <= 1'b1;
                        end else begin
                            if (channel_tiled_q) begin
                                if (64'(in_spatial_index) + 64'd1 == pixel_count_q) begin
                                    next_spatial_q <= 0;
                                    next_channel_q <= in_channel_base + 32'(COLS);
                                end else next_spatial_q <= in_spatial_index + 1;
                            end
                            if (incoming_window) begin
                                top_y_q <= incoming_y - (kernel_h_q - 1);
                                top_x_q <= incoming_x - (kernel_w_q - 1);
                                channel_base_q <= in_channel_base;
                                output_spatial_q <= incoming_oy * output_w_q + incoming_ox;
                                sample_y_q <= 0;
                                sample_x_q <= 0;
                                group_q <= 0;
                                state_q <= ST_READ;
                            end
                        end
                    end
                end
                ST_READ: state_q <= ST_SAMPLE;
                ST_SAMPLE: if (sample_ready) begin
                    if (sample_last) begin
                        if (group_q == GROUP_WIDTH'(GROUPS-1)) begin
                            state_q <= ST_IDLE;
                        end else begin
                            group_q <= group_q + 1'b1;
                            sample_y_q <= 0;
                            sample_x_q <= 0;
                            state_q <= ST_READ;
                        end
                    end else begin
                        if (sample_x_q == kernel_w_q - 1) begin
                            sample_x_q <= 0;
                            sample_y_q <= sample_y_q + 1;
                        end else sample_x_q <= sample_x_q + 1;
                        state_q <= ST_READ;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule
