module operand_loader #(
    parameter int unsigned ELEM_WIDTH     = 8,
    parameter int unsigned LANE_COUNT     = 4,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned K_DEPTH        = 256,
    parameter int unsigned BUFFER_COUNT   = 2,

    parameter int unsigned K_SIZE_WIDTH =
        $clog2(K_DEPTH + 1),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / ELEM_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    parameter int unsigned LANE_WIDTH =
        (LANE_COUNT <= 1) ?
        1 :
        $clog2(LANE_COUNT),

    parameter int unsigned BANK_WIDTH =
        (BUFFER_COUNT <= 1) ?
        1 :
        $clog2(BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Scheduler request
    //
    // load_size is the LOGICAL K size.
    //
    // Example:
    // load_size = 256
    //
    // With INT8 + 32-bit SRAM:
    // words_per_lane = 64
    // ============================================================

    input  logic                    load_req,
    output logic                    load_accept,
    input  logic [K_SIZE_WIDTH-1:0] load_size,

    output logic load_done,
    output logic busy,

    // ============================================================
    // Buffer manager
    // ============================================================

    output logic                  bank_load_req,
    input  logic                  bank_load_grant,
    input  logic [BANK_WIDTH-1:0] bank_load_bank,

    output logic bank_load_done,

    // ============================================================
    // Incoming DMA data stream
    //
    // Data ordering must be:
    //
    // lane0 word0
    // lane0 word1
    // ...
    // lane1 word0
    // lane1 word1
    // ...
    //
    // This matches row-major A / B^T DMA traversal.
    // ============================================================

    input  logic                      data_valid,
    output logic                      data_ready,
    input  logic [MEM_WORD_WIDTH-1:0] data,

    // ============================================================
    // Operand-buffer write interface
    // ============================================================

    output logic                       buffer_wen,
    output logic [BANK_WIDTH-1:0]      buffer_wbank,
    output logic [LANE_WIDTH-1:0]      buffer_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] buffer_waddr,
    output logic [MEM_WORD_WIDTH-1:0]  buffer_wdata
);

    // ============================================================
    // Constants
    // ============================================================

    localparam int unsigned WORD_SHIFT =
        $clog2(ELEMS_PER_WORD);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_ACQUIRE_BANK,
        ST_RECEIVE,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Locked destination bank
    // ============================================================

    logic [BANK_WIDTH-1:0] bank_q;


    // ============================================================
    // Current lane / SRAM word
    // ============================================================

    logic [LANE_WIDTH-1:0] lane_idx_q;

    logic [WORD_ADDR_WIDTH-1:0] word_idx_q;
    logic [WORD_ADDR_WIDTH-1:0] last_word_idx_q;


    // ============================================================
    // Number of physical SRAM words required for one lane
    //
    // ceil(load_size / ELEMS_PER_WORD)
    //
    // Example:
    //
    // K = 256 -> 64 words
    // K = 257 -> 65 words
    //
    // Note:
    // K_DEPTH should be chosen so WORD_DEPTH can hold the result.
    // ============================================================

    logic [31:0] words_per_lane_calc;

    always_comb begin

        words_per_lane_calc =
            (
                32'(load_size) +
                32'(ELEMS_PER_WORD - 1)
            ) >> WORD_SHIFT;

    end


    // ============================================================
    // Scheduler handshake
    //
    // The request is accepted when it is captured in IDLE.
    // ============================================================

    assign load_accept =
        (state == ST_IDLE) &&
        load_req;


    // ============================================================
    // Buffer-manager request
    // ============================================================

    assign bank_load_req =
        (state == ST_ACQUIRE_BANK);


    // ============================================================
    // DMA stream handshake
    // ============================================================

    assign data_ready =
        (state == ST_RECEIVE);


    // ============================================================
    // Operand SRAM write
    // ============================================================

    assign buffer_wen =
        (state == ST_RECEIVE) &&
        data_valid &&
        data_ready;

    assign buffer_wbank =
        bank_q;

    assign buffer_wlane =
        lane_idx_q;

    assign buffer_waddr =
        word_idx_q;

    assign buffer_wdata =
        data;


    // ============================================================
    // Completion
    // ============================================================

    assign load_done =
        (state == ST_DONE);

    assign bank_load_done =
        (state == ST_DONE);

    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= ST_IDLE;

            bank_q <= '0;

            lane_idx_q <= '0;
            word_idx_q <= '0;

            last_word_idx_q <= '0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                //
                // Capture one logical tile load request.
                // =================================================

                ST_IDLE: begin

                    if (load_req) begin

                        lane_idx_q <= '0;
                        word_idx_q <= '0;

                        // -----------------------------------------
                        // Example:
                        //
                        // load_size = 256
                        // words_per_lane = 64
                        //
                        // last_word_idx = 63
                        // -----------------------------------------

                        if (load_size == '0) begin

                            last_word_idx_q <= '0;

                        end else begin

                            last_word_idx_q <=
                                WORD_ADDR_WIDTH'(
                                    words_per_lane_calc -
                                    32'd1
                                );

                        end

                        state <= ST_ACQUIRE_BANK;

                    end

                end


                // =================================================
                // ACQUIRE BUFFER BANK
                //
                // Wait until buffer_manager gives us an EMPTY bank.
                // =================================================

                ST_ACQUIRE_BANK: begin

                    if (bank_load_grant) begin

                        bank_q <=
                            bank_load_bank;

                        lane_idx_q <= '0;
                        word_idx_q <= '0;

                        if (load_size == '0) begin

                            state <= ST_DONE;

                        end else begin

                            state <= ST_RECEIVE;

                        end

                    end

                end


                // =================================================
                // RECEIVE DMA STREAM
                //
                // Example:
                //
                // lane0:
                //
                // addr0
                // addr1
                // ...
                //
                // then lane1:
                //
                // addr0
                // addr1
                // ...
                // =================================================

                ST_RECEIVE: begin

                    if (
                        data_valid &&
                        data_ready
                    ) begin

                        // -----------------------------------------
                        // Last SRAM word of current lane
                        // -----------------------------------------

                        if (
                            word_idx_q ==
                            last_word_idx_q
                        ) begin

                            word_idx_q <= '0;


                            // -------------------------------------
                            // Last lane of entire tile
                            // -------------------------------------

                            if (
                                lane_idx_q ==
                                LANE_WIDTH'(
                                    LANE_COUNT - 1
                                )
                            ) begin

                                state <= ST_DONE;

                            end else begin

                                lane_idx_q <=
                                    lane_idx_q +
                                    LANE_WIDTH'(1);

                            end

                        end else begin

                            word_idx_q <=
                                word_idx_q +
                                WORD_ADDR_WIDTH'(1);

                        end

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion pulse.
                //
                // buffer_manager sees bank_load_done and changes:
                //
                // LOADING -> READY
                // =================================================

                ST_DONE: begin

                    state <= ST_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

                default: begin

                    state <= ST_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ELEM_WIDTH < 1) begin

            $fatal(
                1,
                "ELEM_WIDTH must be >= 1"
            );

        end


        if (LANE_COUNT < 1) begin

            $fatal(
                1,
                "LANE_COUNT must be >= 1"
            );

        end


        if (MEM_WORD_WIDTH < ELEM_WIDTH) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be >= ELEM_WIDTH"
            );

        end


        if (
            (MEM_WORD_WIDTH % ELEM_WIDTH) != 0
        ) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by ELEM_WIDTH"
            );

        end


        if (
            (
                ELEMS_PER_WORD &
                (ELEMS_PER_WORD - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "ELEMS_PER_WORD must be a power of two"
            );

        end


        if (K_DEPTH < 1) begin

            $fatal(
                1,
                "K_DEPTH must be >= 1"
            );

        end


        if (
            (BUFFER_COUNT != 1) &&
            (BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "BUFFER_COUNT must be 1 or 2"
            );

        end

    end

endmodule
