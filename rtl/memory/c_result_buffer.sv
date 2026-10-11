module c_result_buffer #(
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
    input logic capture_int8_mode,
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
    output logic result_int8_mode,

    input logic dma_ren,
    input logic [C_ADDR_WIDTH-1:0] dma_raddr,
    output logic [COLS*ACC_WIDTH-1:0] dma_rdata,
    output logic busy
);
    typedef enum logic [1:0] {
        BANK_EMPTY,
        BANK_CAPTURE,
        BANK_READY,
        BANK_WRITING
    } bank_state_t;

    bank_state_t bank_state_q [2];
    logic [COLS*ACC_WIDTH-1:0] row_mem [2][ROWS];
    logic [ADDR_WIDTH-1:0] bank_addr_q [2];
    logic [31:0] bank_stride_q [2];
    logic bank_int8_q [2];

    logic capture_bank_q;
    logic [ROW_WIDTH-1:0] expected_row_q;
    logic capture_active_q;
    logic free_bank;
    logic free_available;
    logic capture_fire;

    // Two-entry FIFO stores completion order; an accepted DMA tile is
    // removed from this FIFO but its bank remains allocated until done.
    logic ready_fifo_q [2];
    logic fifo_head_q;
    logic fifo_tail_q;
    logic [1:0] fifo_count_q;
    logic dma_bank_q;
    logic dma_active_q;
    logic push_ready;
    logic pop_ready;
    logic selected_bank;

    always_comb begin
        free_available = 1'b0;
        free_bank = 1'b0;
        if (bank_state_q[0] == BANK_EMPTY) begin
            free_available = 1'b1;
            free_bank = 1'b0;
        end else if (bank_state_q[1] == BANK_EMPTY) begin
            free_available = 1'b1;
            free_bank = 1'b1;
        end
    end

    assign capture_ready = !capture_active_q && free_available;
    assign capture_row_ready = capture_active_q;
    assign capture_fire = capture_row_valid && capture_row_ready &&
        (capture_row_index == expected_row_q);
    assign capture_done = capture_fire &&
        (expected_row_q == ROW_WIDTH'(ROWS - 1));
    assign push_ready = capture_done;

    assign result_valid = (fifo_count_q != 2'd0) && !dma_active_q;
    assign selected_bank = ready_fifo_q[fifo_head_q];
    assign result_addr = bank_addr_q[selected_bank];
    assign result_stride_bytes = bank_stride_q[selected_bank];
    assign result_int8_mode = bank_int8_q[selected_bank];
    assign pop_ready = result_valid && result_accept;

    assign busy = capture_active_q || dma_active_q ||
        (fifo_count_q != 2'd0) ||
        (bank_state_q[0] != BANK_EMPTY) ||
        (bank_state_q[1] != BANK_EMPTY);

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            capture_active_q <= 1'b0;
            capture_bank_q <= 1'b0;
            expected_row_q <= '0;
            fifo_head_q <= 1'b0;
            fifo_tail_q <= 1'b0;
            fifo_count_q <= 2'd0;
            ready_fifo_q[0] <= 1'b0;
            ready_fifo_q[1] <= 1'b0;
            dma_bank_q <= 1'b0;
            dma_active_q <= 1'b0;
            dma_rdata <= '0;
            for (int b = 0; b < 2; b++) begin
                bank_state_q[b] <= BANK_EMPTY;
                bank_addr_q[b] <= '0;
                bank_stride_q[b] <= '0;
                bank_int8_q[b] <= 1'b0;
                for (int r = 0; r < ROWS; r++)
                    row_mem[b][r] <= '0;
            end
        end else begin
            if (capture_start && capture_ready) begin
                capture_active_q <= 1'b1;
                capture_bank_q <= free_bank;
                expected_row_q <= '0;
                bank_state_q[free_bank] <= BANK_CAPTURE;
                bank_addr_q[free_bank] <= capture_addr;
                bank_stride_q[free_bank] <= capture_stride_bytes;
                bank_int8_q[free_bank] <= capture_int8_mode;
            end

            if (capture_fire) begin
                row_mem[capture_bank_q][capture_row_index] <=
                    capture_row_data;
                if (capture_done) begin
                    capture_active_q <= 1'b0;
                    bank_state_q[capture_bank_q] <= BANK_READY;
                    ready_fifo_q[fifo_tail_q] <= capture_bank_q;
                    fifo_tail_q <= ~fifo_tail_q;
                end else begin
                    expected_row_q <= expected_row_q + 1'b1;
                end
            end

            if (pop_ready) begin
                dma_active_q <= 1'b1;
                dma_bank_q <= selected_bank;
                bank_state_q[selected_bank] <= BANK_WRITING;
                fifo_head_q <= ~fifo_head_q;
            end

            case ({push_ready, pop_ready})
                2'b10: fifo_count_q <= fifo_count_q + 2'd1;
                2'b01: fifo_count_q <= fifo_count_q - 2'd1;
                default: ;
            endcase

            if (dma_ren && dma_active_q &&
                (dma_raddr < C_ADDR_WIDTH'(ROWS))) begin
                dma_rdata <= row_mem[dma_bank_q][ROW_WIDTH'(dma_raddr)];
            end

            if (result_done && dma_active_q) begin
                dma_active_q <= 1'b0;
                bank_state_q[dma_bank_q] <= BANK_EMPTY;
            end
        end
    end

    initial begin
        if (ROWS < 1 || COLS < 1)
            $fatal(1, "Invalid result-buffer dimensions");
        if (C_ADDR_WIDTH < ROW_WIDTH)
            $fatal(1, "C read address too narrow");
    end
endmodule
