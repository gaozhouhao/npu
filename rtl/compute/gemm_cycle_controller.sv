// Issue sequential K reads, drain the mesh, then capture one result row/clock.
module gemm_cycle_controller #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int DEPTH = 256,
    parameter int ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),
    parameter int ROW_INDEX_WIDTH = (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
    input logic clk,
    input logic reset,
    input logic start,
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,
    input logic clear_acc,
    input logic writeback_en,
    output logic clear,
    output logic read_en,
    output logic [ADDR_WIDTH-1:0] read_addr,
    output logic feed_valid,
    output logic c_wen,
    output logic [ROW_INDEX_WIDTH-1:0] c_row,
    output logic busy,
    output logic done
);
    localparam int DRAIN_CYCLES = (ROWS + COLS > 2) ? ROWS + COLS - 2 : 1;
    localparam int DRAIN_WIDTH = (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);
    typedef enum logic [2:0] {IDLE, CLEAR, FEED, DRAIN, WRITEBACK, DONE} state_t;
    state_t state_q;
    logic [K_SIZE_WIDTH-1:0] k_size_q;
    logic writeback_enable_q;
    logic [K_SIZE_WIDTH-1:0] issued_count_q;
    logic read_valid_q;
    logic read_last_q;
    logic [DRAIN_WIDTH-1:0] drain_count_q;
    logic [ROW_INDEX_WIDTH-1:0] writeback_row_q;

    assign read_en = (state_q == FEED) && (issued_count_q < k_size_q);
    assign read_addr = ADDR_WIDTH'(issued_count_q);
    // Operand SRAMs return the requested K vector one cycle later.
    always_ff @(posedge clk) begin
        if (reset) begin
            read_valid_q <= 1'b0;
            read_last_q <= 1'b0;
        end else begin
            read_valid_q <= read_en;
            read_last_q <= read_en && (issued_count_q == k_size_q - 1'b1);
        end
    end
    assign feed_valid = read_valid_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            k_size_q <= '0;
            writeback_enable_q <= 1'b0;
            issued_count_q <= '0;
            drain_count_q <= '0;
            writeback_row_q <= '0;
        end else begin
            case (state_q)
                IDLE: begin
                    issued_count_q <= '0;
                    drain_count_q <= '0;
                    writeback_row_q <= '0;
                    if (start) begin
                        k_size_q <= tile_k_size;
                        writeback_enable_q <= writeback_en;
                        if ((tile_k_size == 0) || (tile_k_size > K_SIZE_WIDTH'(DEPTH)))
                            state_q <= DONE;
                        else
                            state_q <= clear_acc ? CLEAR : FEED;
                    end
                end
                CLEAR: begin
                    issued_count_q <= '0;
                    state_q <= FEED;
                end
                FEED: begin
                    if (read_en) issued_count_q <= issued_count_q + 1'b1;
                    if (read_valid_q && read_last_q) begin
                        drain_count_q <= '0;
                        state_q <= DRAIN;
                    end
                end
                DRAIN: begin
                    if (drain_count_q == DRAIN_WIDTH'(DRAIN_CYCLES - 1)) begin
                        writeback_row_q <= '0;
                        state_q <= writeback_enable_q ? WRITEBACK : DONE;
                    end else
                        drain_count_q <= drain_count_q + 1'b1;
                end
                WRITEBACK: begin
                    if (writeback_row_q == ROW_INDEX_WIDTH'(ROWS - 1))
                        state_q <= DONE;
                    else
                        writeback_row_q <= writeback_row_q + 1'b1;
                end
                DONE: state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
    assign clear = (state_q == CLEAR);
    assign c_wen = (state_q == WRITEBACK);
    assign c_row = writeback_row_q;
    assign busy = (state_q != IDLE);
    assign done = (state_q == DONE);
endmodule
