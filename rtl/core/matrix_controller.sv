module matrix_controller #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),

    parameter int ROW_INDEX_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
    input logic clk,
    input logic reset,

    input logic start,

    // Current local K tile size
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,

    // K-tiling control
    //
    // clear_acc = 1:
    //     clear PE accumulators before this tile
    //
    // writeback_en = 1:
    //     write final result to C buffer after this tile
    input logic clear_acc,
    input logic writeback_en,

    // Clear PE accumulators
    output logic clear,

    // ============================================================
    // A/B Scratchpad read
    // ============================================================

    output logic                  read_en,
    output logic [ADDR_WIDTH-1:0] read_addr,

    output logic feed_valid,

    // ============================================================
    // C Buffer writeback
    // ============================================================

    output logic                       c_wen,
    output logic [ROW_INDEX_WIDTH-1:0] c_row,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done
);


    // ============================================================
    // Systolic drain timing
    // ============================================================

    localparam int DRAIN_CYCLES =
        ROWS + COLS - 2;

    localparam int DRAIN_WIDTH =
        (DRAIN_CYCLES <= 1)
            ? 1
            : $clog2(DRAIN_CYCLES);

    localparam logic [DRAIN_WIDTH-1:0] DRAIN_LAST =
        DRAIN_WIDTH'(DRAIN_CYCLES - 1);


    // ============================================================
    // C writeback
    // ============================================================

    localparam logic [ROW_INDEX_WIDTH-1:0] ROW_LAST =
        ROW_INDEX_WIDTH'(ROWS - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        IDLE,
        CLEAR,
        FEED,
        DRAIN,
        WRITEBACK,
        DONE
    } state_t;

    state_t state;


    // ============================================================
    // Registers
    // ============================================================

    logic [K_SIZE_WIDTH-1:0] tile_k_size_q;

    // logic clear_acc_q;
    logic writeback_en_q;

    logic [K_SIZE_WIDTH-1:0] issue_count;

    // SRAM read response tracking
    logic rsp_valid_q;
    logic rsp_last_q;

    logic [DRAIN_WIDTH-1:0] drain_counter;

    logic [ROW_INDEX_WIDTH-1:0] wb_row;


    // ============================================================
    // SRAM request generation
    // ============================================================

    assign read_en =
        (state == FEED) &&
        (issue_count < tile_k_size_q);

    assign read_addr =
        issue_count[ADDR_WIDTH-1:0];


    // ============================================================
    // SRAM response tracking
    //
    // A/B SRAM has 1-cycle read latency.
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            rsp_valid_q <= 1'b0;
            rsp_last_q  <= 1'b0;

        end else begin

            rsp_valid_q <= read_en;

            rsp_last_q <=
                read_en &&
                (issue_count == tile_k_size_q - 1'b1);

        end

    end


    assign feed_valid = rsp_valid_q;


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state           <= IDLE;

            tile_k_size_q   <= '0;

            // clear_acc_q     <= 1'b0;
            writeback_en_q  <= 1'b0;

            issue_count     <= '0;
            drain_counter   <= '0;
            wb_row          <= '0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                IDLE: begin

                    issue_count   <= '0;
                    drain_counter <= '0;
                    wb_row        <= '0;

                    if (start) begin

                        tile_k_size_q  <= tile_k_size;
                        // clear_acc_q    <= clear_acc;
                        writeback_en_q <= writeback_en;

                        if (
                            (tile_k_size == 0) ||
                            (tile_k_size > K_SIZE_WIDTH'(DEPTH))
                        ) begin

                            state <= DONE;

                        end else if (clear_acc) begin

                            state <= CLEAR;

                        end else begin

                            // Intermediate K tile:
                            // keep old partial sums
                            state <= FEED;

                        end

                    end

                end


                // =================================================
                // CLEAR
                // =================================================

                CLEAR: begin

                    issue_count <= '0;

                    state <= FEED;

                end


                // =================================================
                // FEED
                // =================================================

                FEED: begin

                    if (read_en) begin

                        issue_count <=
                            issue_count + 1'b1;

                    end


                    if (rsp_valid_q && rsp_last_q) begin

                        drain_counter <= '0;

                        state <= DRAIN;

                    end

                end


                // =================================================
                // DRAIN
                // =================================================

                DRAIN: begin

                    if (drain_counter == DRAIN_LAST) begin

                        if (writeback_en_q) begin

                            wb_row <= '0;

                            state <= WRITEBACK;

                        end else begin

                            // Intermediate K tile:
                            // partial sums remain inside PEs.
                            state <= DONE;

                        end

                    end else begin

                        drain_counter <=
                            drain_counter + 1'b1;

                    end

                end


                // =================================================
                // WRITEBACK
                //
                // One complete output row per cycle.
                // =================================================

                WRITEBACK: begin

                    if (wb_row == ROW_LAST) begin

                        state <= DONE;

                    end else begin

                        wb_row <= wb_row + 1'b1;

                    end

                end


                // =================================================
                // DONE
                // =================================================

                DONE: begin

                    state <= IDLE;

                end


                default: begin

                    state <= IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Output decode
    // ============================================================

    assign clear =
        (state == CLEAR);

    assign c_wen =
        (state == WRITEBACK);

    assign c_row =
        wb_row;

    assign busy =
        (state != IDLE);

    assign done =
        (state == DONE);


endmodule
