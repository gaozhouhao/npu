module result_tile_buffer #(
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned C_ADDR_WIDTH = 8,
    parameter int unsigned ROW_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
    input logic clk,
    input logic reset,
    input logic clear,

    input logic capture_start,
    output logic capture_ready,
    input logic [ADDR_WIDTH-1:0] capture_addr,
    input logic [31:0] capture_stride_bytes,
    input logic [31:0] capture_spatial_base,
    input logic [31:0] capture_channel_base,
    input logic capture_int8_mode,
    input logic [31:0] capture_valid_rows,
    input logic [31:0] capture_valid_cols,
    input logic capture_row_valid,
    output logic capture_row_ready,
    input logic [ROW_WIDTH-1:0] capture_row_index,
    input logic [COLS*ACC_WIDTH-1:0] capture_row_data,
    output logic capture_done,

    output logic result_valid,
    input logic result_accept,
    input logic result_done,
    output logic [ADDR_WIDTH-1:0] result_addr,
    output logic [31:0] result_stride_bytes,
    output logic [31:0] result_spatial_base,
    output logic [31:0] result_channel_base,
    output logic result_int8_mode,
    output logic [31:0] result_valid_rows,
    output logic [31:0] result_valid_cols,

    input logic dma_ren,
    input logic [C_ADDR_WIDTH-1:0] dma_raddr,
    output logic [COLS*ACC_WIDTH-1:0] dma_rdata,
    output logic busy
);
    typedef enum logic [1:0] {
        EMPTY, CAPTURE, READY, WRITING
    } bank_state_t;
    bank_state_t bank_state_q [2];
    logic [COLS*ACC_WIDTH-1:0] row_mem [2][ROWS];
    logic [ADDR_WIDTH-1:0] bank_addr_q [2];
    logic [31:0] bank_stride_q [2];
    logic [31:0] bank_spatial_q [2];
    logic [31:0] bank_channel_q [2];
    logic bank_int8_q [2];
    logic [31:0] bank_rows_q [2], bank_cols_q [2];
    logic capture_bank_q;
    logic dma_bank_q;

    // 采集与 DMA 分别按 0、1、0、1 的顺序使用缓存。
    assign capture_ready = (bank_state_q[capture_bank_q] == EMPTY);
    assign capture_row_ready = (bank_state_q[capture_bank_q] == CAPTURE);
    assign capture_done = capture_row_valid && capture_row_ready &&
        (capture_row_index == ROW_WIDTH'(ROWS - 1));
    assign result_valid = (bank_state_q[dma_bank_q] == READY);
    assign result_addr = bank_addr_q[dma_bank_q];
    assign result_stride_bytes = bank_stride_q[dma_bank_q];
    assign result_spatial_base = bank_spatial_q[dma_bank_q];
    assign result_channel_base = bank_channel_q[dma_bank_q];
    assign result_int8_mode = bank_int8_q[dma_bank_q];
    assign result_valid_rows = bank_rows_q[dma_bank_q];
    assign result_valid_cols = bank_cols_q[dma_bank_q];
    assign busy = (bank_state_q[0] != EMPTY) ||
        (bank_state_q[1] != EMPTY);

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            capture_bank_q <= 1'b0;
            dma_bank_q <= 1'b0;
            dma_rdata <= '0;
            for (int b = 0; b < 2; b++) begin
                bank_state_q[b] <= EMPTY;
                bank_addr_q[b] <= '0;
                bank_stride_q[b] <= '0;
                bank_spatial_q[b] <= '0;
                bank_channel_q[b] <= '0;
                bank_int8_q[b] <= 1'b0;
                bank_rows_q[b] <= '0;
                bank_cols_q[b] <= '0;
            end
        end else begin
            if (capture_start && capture_ready) begin
                bank_state_q[capture_bank_q] <= CAPTURE;
                bank_addr_q[capture_bank_q] <= capture_addr;
                bank_stride_q[capture_bank_q] <= capture_stride_bytes;
                bank_spatial_q[capture_bank_q] <= capture_spatial_base;
                bank_channel_q[capture_bank_q] <= capture_channel_base;
                bank_int8_q[capture_bank_q] <= capture_int8_mode;
                bank_rows_q[capture_bank_q] <= capture_valid_rows;
                bank_cols_q[capture_bank_q] <= capture_valid_cols;
            end

            // Capture a physical tile and keep its logical row/column
            // extents with the bank until the consumer finishes.
            if (capture_row_valid && capture_row_ready) begin
                row_mem[capture_bank_q][capture_row_index] <= capture_row_data;
                if (capture_done) begin
                    bank_state_q[capture_bank_q] <= READY;
                    capture_bank_q <= ~capture_bank_q;
                end
            end

            if (result_valid && result_accept)
                bank_state_q[dma_bank_q] <= WRITING;

            // 同步读延迟一拍，DMA 随后接收这一行。
            if (dma_ren && (bank_state_q[dma_bank_q] == WRITING) &&
                (dma_raddr < ROWS))
                dma_rdata <= row_mem[dma_bank_q][dma_raddr];

            // DMA 完成后才释放缓存，接受发送请求时仍需保留数据。
            if (result_done && (bank_state_q[dma_bank_q] == WRITING)) begin
                bank_state_q[dma_bank_q] <= EMPTY;
                dma_bank_q <= ~dma_bank_q;
            end
        end
    end
endmodule
