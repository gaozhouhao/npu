module matrix_controller #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),

    parameter int C_INDEX_WIDTH =
        (ROWS * COLS <= 1) ? 1 : $clog2(ROWS * COLS)
) (
    input  logic clk,
    input  logic reset,

    input  logic start,

    // Current local K tile size
    // Legal range: 1 ~ DEPTH
    input  logic [K_SIZE_WIDTH-1:0] tile_k_size,

    // Clear matrix accumulators
    output logic clear,

    // ============================================================
    // A/B Scratchpad read request
    // ============================================================

    output logic                  read_en,
    output logic [ADDR_WIDTH-1:0] read_addr,

    // SRAM response -> matrix engine
    output logic feed_valid,

    // ============================================================
    // C Scratchpad writeback control
    // ============================================================

    output logic                     c_wen,
    output logic [C_INDEX_WIDTH-1:0] c_index,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done
);


    // ============================================================
    // Parameters
    // ============================================================

    localparam int DRAIN_CYCLES = ROWS + COLS - 2;

    localparam int DRAIN_WIDTH =
        (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);

    localparam logic [DRAIN_WIDTH-1:0] DRAIN_LAST =
        DRAIN_WIDTH'(DRAIN_CYCLES - 1);

    localparam int RESULT_COUNT = ROWS * COLS;

    localparam logic [C_INDEX_WIDTH-1:0] C_INDEX_LAST =
        C_INDEX_WIDTH'(RESULT_COUNT - 1);


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

    // Latched K size for current local tile
    logic [K_SIZE_WIDTH-1:0] tile_k_size_q;

    // Number of SRAM read requests already issued
    logic [K_SIZE_WIDTH-1:0] issue_count;

    // SRAM response tracking
    // SRAM read latency = 1 cycle
    logic rsp_valid_q;
    logic rsp_last_q;

    // Systolic array drain counter
    logic [DRAIN_WIDTH-1:0] drain_counter;

    // C SRAM writeback counter
    logic [C_INDEX_WIDTH-1:0] wb_count;


    // ============================================================
    // A/B SRAM request generation
    // ============================================================

    assign read_en =
        (state == FEED) &&
        (issue_count < tile_k_size_q);

    // issue_count is wider because it must represent DEPTH.
    // SRAM address itself only needs ADDR_WIDTH bits.
    assign read_addr =
        issue_count[ADDR_WIDTH-1:0];


    // ============================================================
    // 1-cycle SRAM response tracking
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin

            rsp_valid_q <= 1'b0;
            rsp_last_q  <= 1'b0;

        end else begin

            // Request issued this cycle ->
            // SRAM data valid next cycle
            rsp_valid_q <= read_en;

            // Remember whether this request was the final K element
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
            issue_count     <= '0;
            drain_counter   <= '0;
            wb_count        <= '0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                IDLE: begin

                    issue_count   <= '0;
                    drain_counter <= '0;
                    wb_count      <= '0;

                    if (start) begin

                        tile_k_size_q <= tile_k_size;

                        // Invalid / empty operation
                        if (
                            (tile_k_size == 0) ||
                            (tile_k_size > K_SIZE_WIDTH'(DEPTH))
                        ) begin

                            state <= DONE;

                        end else begin

                            state <= CLEAR;

                        end

                    end

                end


                // =================================================
                // CLEAR
                //
                // Clear accumulators before a new GEMM tile
                // =================================================

                CLEAR: begin

                    issue_count <= '0;

                    state <= FEED;

                end


                // =================================================
                // FEED
                //
                // Issue SRAM reads and feed returned data into
                // matrix_engine.
                // =================================================

                FEED: begin

                    if (read_en) begin

                        issue_count <= issue_count + 1'b1;

                    end


                    // Do NOT enter DRAIN when the final address is
                    // issued.
                    //
                    // Enter DRAIN only after the final SRAM response
                    // has actually reached matrix_engine.
                    if (rsp_valid_q && rsp_last_q) begin

                        drain_counter <= '0;

                        state <= DRAIN;

                    end

                end


                // =================================================
                // DRAIN
                //
                // Wait for the systolic wavefront to propagate to
                // the furthest PE.
                // =================================================

                DRAIN: begin

                    if (drain_counter == DRAIN_LAST) begin

                        wb_count <= '0;

                        state <= WRITEBACK;

                    end else begin

                        drain_counter <= drain_counter + 1'b1;

                    end

                end


                // =================================================
                // WRITEBACK
                //
                // Write one INT32 accumulator to C SRAM per cycle.
                //
                // For 4x4:
                // c_index = 0  -> C[0][0]
                // c_index = 1  -> C[0][1]
                // ...
                // c_index = 15 -> C[3][3]
                // =================================================

                WRITEBACK: begin

                    if (wb_count == C_INDEX_LAST) begin

                        state <= DONE;

                    end else begin

                        wb_count <= wb_count + 1'b1;

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle done pulse
                // =================================================

                DONE: begin

                    state <= IDLE;

                end


                // =================================================
                // Default
                // =================================================

                default: begin

                    state <= IDLE;

                end

            endcase
        end
    end


    // ============================================================
    // Output decode
    // ============================================================

    assign clear = (state == CLEAR);

    assign c_wen   = (state == WRITEBACK);
    assign c_index = wb_count;

    assign busy = (state != IDLE);
    assign done = (state == DONE);


endmodule
