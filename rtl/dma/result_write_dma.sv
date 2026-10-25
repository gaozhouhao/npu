module result_write_dma #(
    parameter int unsigned ADDR_WIDTH     = 64,
    parameter int unsigned ROWS           = 4,
    parameter int unsigned COLS           = 4,
    parameter int unsigned ACC_WIDTH      = 32,
    parameter int unsigned AXI_DATA_WIDTH = 32,
    parameter int unsigned ID_WIDTH       = 1,
    parameter int unsigned C_ADDR_WIDTH   = 8
) (
    input  logic clk,
    input  logic reset,

    input  logic                  tile_valid,
    output logic                  tile_accept,
    input  logic [ADDR_WIDTH-1:0] tile_addr,
    input  logic [31:0]           tile_stride_bytes,
    input  logic [31:0]           tile_valid_rows,
    input  logic [31:0]           tile_valid_cols,
    // 0 -> accumulator-width output; 1 -> packed INT8 output.
    input  logic                 int8_mode,

    // Synchronous local row read. Packed INT8 occupies the low COLS bytes.
    output logic                        c_ren,
    output logic [C_ADDR_WIDTH-1:0]      c_raddr,
    input  logic [COLS*ACC_WIDTH-1:0]    c_rdata,

    output logic busy,
    output logic done,
    output logic error,

    output logic [ID_WIDTH-1:0]       m_axi_awid,
    output logic [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,
    input  logic [ID_WIDTH-1:0]       m_axi_bid,
    input  logic [1:0]                m_axi_bresp,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready
);
    localparam int unsigned AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam int unsigned AXI_SIZE = $clog2(AXI_BYTES);
    localparam int unsigned MAX_ROW_BYTES = COLS * (ACC_WIDTH / 8);
    // An unaligned row may require one additional beat.
    localparam int unsigned MAX_ROW_BEATS =
        (MAX_ROW_BYTES + 2 * AXI_BYTES - 2) / AXI_BYTES;
    localparam int unsigned ROW_INDEX_WIDTH = (ROWS <= 1) ? 1 : $clog2(ROWS);
    localparam int unsigned BEAT_COUNT_WIDTH =
        (MAX_ROW_BEATS <= 1) ? 1 : $clog2(MAX_ROW_BEATS + 1);

    typedef enum logic [2:0] {
        ST_IDLE, ST_READ_REQ, ST_READ_WAIT, ST_AW, ST_W, ST_B, ST_DONE
    } state_t;
    state_t state_q;

    logic [ADDR_WIDTH-1:0] tile_addr_q;
    logic [31:0] row_stride_bytes_q, valid_rows_q, row_byte_count_q;
    logic [ROW_INDEX_WIDTH-1:0] row_index_q;
    logic [31:0] row_byte_offset_q;
    logic [BEAT_COUNT_WIDTH-1:0] row_beat_count_q, row_beat_index_q;
    logic [ADDR_WIDTH-1:0] burst_addr_q;
    // AXI AWLEN can describe up to 256 beats.
    logic [8:0] burst_beat_count_q, burst_beat_index_q;
    logic [COLS*ACC_WIDTH-1:0] row_data_q;

    logic [ADDR_WIDTH-1:0] next_row_addr, aligned_row_addr, next_burst_addr;
    logic [31:0] next_row_offset;
    logic [BEAT_COUNT_WIDTH-1:0] next_row_beats;

    // Every burst is aligned, contains at least one beat, and stays in a page.
    function automatic logic [8:0] burst_beats(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [BEAT_COUNT_WIDTH-1:0] remaining
    );
        int unsigned count, page_beats;
        begin
            count = int'(remaining);
            page_beats = (4096 - int'(address & ADDR_WIDTH'(4095))) / AXI_BYTES;
            if (count > 256) count = 256;
            if (count > page_beats) count = page_beats;
            return 9'(count);
        end
    endfunction

    always_comb begin
        next_row_addr = tile_addr_q +
            ADDR_WIDTH'(row_index_q) * ADDR_WIDTH'(row_stride_bytes_q);
        aligned_row_addr = (next_row_addr >> AXI_SIZE) << AXI_SIZE;
        next_row_offset = 32'(next_row_addr & ADDR_WIDTH'(AXI_BYTES - 1));
        next_row_beats = BEAT_COUNT_WIDTH'(
            (next_row_offset + row_byte_count_q + AXI_BYTES - 1) / AXI_BYTES);
        next_burst_addr = burst_addr_q + ADDR_WIDTH'(burst_beat_count_q) * AXI_BYTES;
    end

    assign tile_accept = (state_q == ST_IDLE) && tile_valid;
    assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE);
    assign done = (state_q == ST_DONE);
    assign c_ren = (state_q == ST_READ_REQ);
    assign c_raddr = C_ADDR_WIDTH'(row_index_q);

    assign m_axi_awid = '0;
    assign m_axi_awaddr = burst_addr_q;
    assign m_axi_awlen = 8'(burst_beat_count_q - 9'd1);
    assign m_axi_awsize = 3'(AXI_SIZE);
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state_q == ST_AW);

    // Map the original, potentially unaligned row into aligned AXI byte lanes.
    // Padding rows, padding columns, and adjacent tensor bytes are never strobed.
    always_comb begin
        m_axi_wdata = '0;
        m_axi_wstrb = '0;
        for (int lane = 0; lane < AXI_BYTES; lane++) begin
            if ((int'(row_beat_index_q) * AXI_BYTES + lane >= int'(row_byte_offset_q)) &&
                (int'(row_beat_index_q) * AXI_BYTES + lane <
                 int'(row_byte_offset_q + row_byte_count_q))) begin
                m_axi_wstrb[lane] = 1'b1;
                m_axi_wdata[lane*8 +: 8] = row_data_q[
                    (int'(row_beat_index_q) * AXI_BYTES + lane -
                     int'(row_byte_offset_q))*8 +: 8];
            end
        end
    end
    assign m_axi_wlast = (burst_beat_index_q == burst_beat_count_q - 9'd1);
    assign m_axi_wvalid = (state_q == ST_W);
    assign m_axi_bready = (state_q == ST_B);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            tile_addr_q <= '0;
            row_stride_bytes_q <= '0;
            valid_rows_q <= '0;
            row_byte_count_q <= '0;
            row_index_q <= '0;
            row_byte_offset_q <= '0;
            row_beat_count_q <= '0;
            row_beat_index_q <= '0;
            burst_addr_q <= '0;
            burst_beat_count_q <= '0;
            burst_beat_index_q <= '0;
            row_data_q <= '0;
            error <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (tile_accept) begin
                        tile_addr_q <= tile_addr;
                        row_stride_bytes_q <= tile_stride_bytes;
                        valid_rows_q <= tile_valid_rows;
                        row_byte_count_q <= tile_valid_cols *
                            (int8_mode ? 32'd1 : 32'(ACC_WIDTH / 8));
                        row_index_q <= '0;
                        row_beat_index_q <= '0;
                        burst_beat_index_q <= '0;
                        error <= 1'b0;
                        if ((tile_valid_rows == 0) || (tile_valid_rows > ROWS) ||
                            (tile_valid_cols == 0) || (tile_valid_cols > COLS)) begin
                            error <= 1'b1;
                            state_q <= ST_DONE;
                        end else begin
                            state_q <= ST_READ_REQ;
                        end
                    end
                end
                ST_READ_REQ: state_q <= ST_READ_WAIT;
                ST_READ_WAIT: begin
                    row_data_q <= c_rdata;
                    row_byte_offset_q <= next_row_offset;
                    row_beat_count_q <= next_row_beats;
                    row_beat_index_q <= '0;
                    burst_addr_q <= aligned_row_addr;
                    burst_beat_count_q <= burst_beats(aligned_row_addr, next_row_beats);
                    burst_beat_index_q <= '0;
                    state_q <= ST_AW;
                end
                ST_AW: begin
                    if (m_axi_awready) state_q <= ST_W;
                end
                ST_W: begin
                    if (m_axi_wready) begin
                        row_beat_index_q <= row_beat_index_q + BEAT_COUNT_WIDTH'(1);
                        if (m_axi_wlast) begin
                            state_q <= ST_B;
                        end else begin
                            burst_beat_index_q <= burst_beat_index_q + 9'd1;
                        end
                    end
                end
                ST_B: begin
                    if (m_axi_bvalid) begin
                        if ((m_axi_bid != '0) || (m_axi_bresp != 2'b00))
                            error <= 1'b1;
                        if (row_beat_index_q < row_beat_count_q) begin
                            burst_addr_q <= next_burst_addr;
                            burst_beat_count_q <= burst_beats(next_burst_addr,
                                row_beat_count_q - row_beat_index_q);
                            burst_beat_index_q <= '0;
                            state_q <= ST_AW;
                        end else if (32'(row_index_q) == valid_rows_q - 32'd1) begin
                            state_q <= ST_DONE;
                        end else begin
                            row_index_q <= row_index_q + ROW_INDEX_WIDTH'(1);
                            state_q <= ST_READ_REQ;
                        end
                    end
                end
                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule
