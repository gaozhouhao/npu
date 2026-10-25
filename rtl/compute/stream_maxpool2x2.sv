// Shared FC/Conv raw-input window buffer, followed by a MaxPool consumer.
// The historical module name and external command/data/AXI ports are retained.
// LINE_WORDS counts 32-bit raw input words, not partial pooled results.
module stream_maxpool2x2 #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1,
    parameter int unsigned COLS = 4,
    parameter int unsigned LINE_WORDS = 1024,
    parameter int unsigned OUTPUT_FIFO_DEPTH = 16
) (
    input logic clk,
    input logic reset,
    input logic start,
    input logic [31:0] cfg_input_h,
    input logic [31:0] cfg_input_w,
    input logic [31:0] cfg_channels,
    // Zero selects 2x2/stride-2; otherwise {stride_w,stride_h,kernel_w,kernel_h}.
    input logic [31:0] cfg_pool_config,
    input logic [ADDR_WIDTH-1:0] cfg_output_base,
    input logic in_valid,
    output logic in_ready,
    input logic [COLS*8-1:0] in_data,
    input logic [31:0] in_spatial_index,
    input logic [31:0] in_channel_base,
    output logic busy,
    output logic error,
    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    input logic [ID_WIDTH-1:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);
    logic configured_q, config_error_q, accept_start;
    logic raw_ready, raw_busy, raw_error, channel_tiled_q;
    logic sample_valid, sample_ready, sample_first, sample_last;
    logic [31:0] sample_data, sample_spatial_index, sample_channel_base;
    logic [31:0] output_width, channels_q;
    logic [ADDR_WIDTH-1:0] output_base_q, result_addr;
    logic result_valid, result_ready, reduce_busy;
    logic [31:0] result_data, result_spatial_index, result_channel_base;
    logic dma_ready, dma_busy, dma_error;

    // The raw window buffer protects its own sample lifetime. DDR stalls
    // propagate through the result FIFO/reducer only when capacity runs out.
    assign in_ready = configured_q && !start && raw_ready;
    assign busy = raw_busy || reduce_busy || dma_busy;
    // All stages replace configuration together, only after pending writes
    // complete. A stray start while busy must not mix two tasks.
    assign accept_start = start && !busy;
    assign error = config_error_q || raw_error || dma_error;
    assign result_ready = configured_q && !start && dma_ready;
    assign result_addr = output_base_q + ADDR_WIDTH'(
        64'(result_spatial_index) * 64'(channels_q) +
        64'(result_channel_base));

    pool_window_buffer #(.COLS(COLS), .LINE_WORDS(LINE_WORDS)) u_input_buffer (
        .clk(clk), .reset(reset), .start(accept_start),
        .cfg_input_h(cfg_input_h), .cfg_input_w(cfg_input_w),
        .cfg_channels(cfg_channels), .cfg_pool_config(cfg_pool_config),
        // The actual raw-memory write observes the external handshake.
        .in_valid(in_valid && in_ready), .in_ready(raw_ready),
        .in_data(in_data), .in_spatial_index(in_spatial_index),
        .in_channel_base(in_channel_base), .busy(raw_busy), .error(raw_error),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_data(sample_data), .sample_first(sample_first),
        .sample_last(sample_last), .sample_spatial_index(sample_spatial_index),
        .sample_channel_base(sample_channel_base), .output_width(output_width),
        .channel_tiled(channel_tiled_q)
    );

    pool_max_reducer u_max (
        .clk(clk), .reset(reset), .clear(accept_start),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_data(sample_data), .sample_first(sample_first),
        .sample_last(sample_last), .sample_spatial_index(sample_spatial_index),
        .sample_channel_base(sample_channel_base), .result_valid(result_valid),
        .result_ready(result_ready), .result_data(result_data),
        .result_spatial_index(result_spatial_index),
        .result_channel_base(result_channel_base), .busy(reduce_busy)
    );

    pool_result_dma #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH),
        .FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) u_result_dma (
        .clk(clk), .reset(reset), .clear(accept_start),
        .in_valid(configured_q && !start && result_valid),
        .in_ready(dma_ready), .in_addr(result_addr), .in_data(result_data),
        .busy(dma_busy), .error(dma_error),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    always_ff @(posedge clk) begin
        if (reset || accept_start) begin
            configured_q <= !reset && cfg_output_base[1:0] == 0;
            config_error_q <= !reset && cfg_output_base[1:0] != 0;
            channels_q <= reset ? 32'd0 : cfg_channels;
            output_base_q <= reset ? '0 : cfg_output_base;
        end
    end
endmodule
