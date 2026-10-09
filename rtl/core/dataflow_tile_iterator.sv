
module dataflow_tile_iterator #(
    parameter int unsigned COUNT_WIDTH = 16,
    parameter int unsigned PSUM_SLOTS = 4,
    parameter int unsigned SLOT_WIDTH =
        (PSUM_SLOTS <= 1) ? 1 : $clog2(PSUM_SLOTS)
) (
    input logic clk,
    input logic reset,
    input logic start,

    input logic [1:0] dataflow_mode,
    input logic [COUNT_WIDTH-1:0] m_tile_count,
    input logic [COUNT_WIDTH-1:0] n_tile_count,
    input logic [COUNT_WIDTH-1:0] k_tile_count,

    output logic busy,
    output logic done,
    output logic error,

    output logic tile_valid,
    input logic tile_retire,

    output logic [COUNT_WIDTH-1:0] tile_m,
    output logic [COUNT_WIDTH-1:0] tile_n,
    output logic [COUNT_WIDTH-1:0] tile_k,
    output logic [SLOT_WIDTH-1:0] c_slot,

    output logic load_a,
    output logic load_b,
    output logic release_a,
    output logic release_b,

    output logic use_psum_sram,
    output logic psum_first_k,
    output logic psum_last_k
);

    localparam logic [1:0] MODE_OUTPUT = 2'b00;
    localparam logic [1:0] MODE_A = 2'b01;
    localparam logic [1:0] MODE_B = 2'b10;

    typedef enum logic [1:0] {
        IDLE,
        ACTIVE,
        FINISHED
    } state_t;

    state_t state_q;

    logic [1:0] mode_q;

    logic [COUNT_WIDTH-1:0] m_count_q;
    logic [COUNT_WIDTH-1:0] n_count_q;
    logic [COUNT_WIDTH-1:0] k_count_q;

    logic [COUNT_WIDTH-1:0] m_q;
    logic [COUNT_WIDTH-1:0] n_q;
    logic [COUNT_WIDTH-1:0] k_q;

    logic [COUNT_WIDTH-1:0] m_base_q;
    logic [COUNT_WIDTH-1:0] n_base_q;
    logic [COUNT_WIDTH-1:0] m_off_q;
    logic [COUNT_WIDTH-1:0] n_off_q;

    logic [COUNT_WIDTH-1:0] block_size;
    logic [COUNT_WIDTH-1:0] remaining;
    logic [COUNT_WIDTH-1:0] c_capacity;
    logic [COUNT_WIDTH-1:0] last_in_block;
    logic [COUNT_WIDTH-1:0] next_base;

    // Output-stationary does not require cross-output
    // partial-sum storage.
    //
    // When K has only one tile, A/B reuse also does not
    // require partial-sum storage.

    assign use_psum_sram =
        (mode_q != MODE_OUTPUT) &&
        (k_count_q > COUNT_WIDTH'(1));

    assign c_capacity = COUNT_WIDTH'(PSUM_SLOTS);

    // Calculate the number of output tiles that can
    // coexist in C SRAM.

    always_comb begin
        remaining = '0;

        if (mode_q == MODE_A)
            remaining = n_count_q - n_base_q;
        else if (mode_q == MODE_B)
            remaining = m_count_q - m_base_q;

        block_size = remaining;

        if (use_psum_sram && remaining > c_capacity)
            block_size = c_capacity;
    end

    assign last_in_block =
        block_size - COUNT_WIDTH'(1);

    assign next_base =
        ((mode_q == MODE_A) ? n_base_q : m_base_q)
        + block_size;

    // Current tile information.

    assign tile_valid = (state_q == ACTIVE);
    assign busy = (state_q == ACTIVE);
    assign done = (state_q == FINISHED);

    assign tile_m =
        (mode_q == MODE_B)
            ? m_base_q + m_off_q
            : m_q;

    assign tile_n =
        (mode_q == MODE_A)
            ? n_base_q + n_off_q
            : n_q;

    assign tile_k = k_q;

    // Each live output tile receives its own C slot.
    assign c_slot = use_psum_sram
        ? ((mode_q == MODE_A)
            ? SLOT_WIDTH'(n_off_q)
            : SLOT_WIDTH'(m_off_q))
        : '0;

    // In A-stationary mode, A is loaded once per
    // K tile and reused across the current N block.

    assign load_a =
        tile_valid &&
        ((mode_q != MODE_A) || (n_off_q == '0));

    // In B-stationary mode, B is loaded once per
    // K tile and reused across the current M block.

    assign load_b =
        tile_valid &&
        ((mode_q != MODE_B) || (m_off_q == '0));

    assign release_a =
        (mode_q != MODE_A) ||
        (n_off_q == last_in_block);

    assign release_b =
        (mode_q != MODE_B) ||
        (m_off_q == last_in_block);

    assign psum_first_k =
        tile_valid && (k_q == '0);

    assign psum_last_k =
        tile_valid &&
        (k_q == (k_count_q - COUNT_WIDTH'(1)));

    // Tile traversal FSM.

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;

            mode_q <= MODE_OUTPUT;

            m_count_q <= '0;
            n_count_q <= '0;
            k_count_q <= '0;

            m_q <= '0;
            n_q <= '0;
            k_q <= '0;

            m_base_q <= '0;
            n_base_q <= '0;
            m_off_q <= '0;
            n_off_q <= '0;

            error <= 1'b0;
        end else begin

            case (state_q)

                IDLE: begin
                    if (start) begin
                        error <= 1'b0;

                        if (
                            (dataflow_mode == 2'b11) ||
                            (m_tile_count == '0) ||
                            (n_tile_count == '0) ||
                            (k_tile_count == '0)
                        ) begin
                            error <= 1'b1;
                            state_q <= FINISHED;
                        end else begin
                            mode_q <= dataflow_mode;

                            m_count_q <= m_tile_count;
                            n_count_q <= n_tile_count;
                            k_count_q <= k_tile_count;

                            m_q <= '0;
                            n_q <= '0;
                            k_q <= '0;

                            m_base_q <= '0;
                            n_base_q <= '0;
                            m_off_q <= '0;
                            n_off_q <= '0;

                            state_q <= ACTIVE;
                        end
                    end
                end

                ACTIVE: begin
                    if (tile_retire) begin

                        case (mode_q)

                            MODE_OUTPUT: begin
                                if (
                                    k_q + COUNT_WIDTH'(1)
                                    < k_count_q
                                ) begin
                                    k_q <=
                                        k_q + COUNT_WIDTH'(1);
                                end else begin
                                    k_q <= '0;

                                    if (
                                        n_q + COUNT_WIDTH'(1)
                                        < n_count_q
                                    ) begin
                                        n_q <=
                                            n_q + COUNT_WIDTH'(1);
                                    end else begin
                                        n_q <= '0;

                                        if (
                                            m_q + COUNT_WIDTH'(1)
                                            < m_count_q
                                        ) begin
                                            m_q <=
                                                m_q + COUNT_WIDTH'(1);
                                        end else begin
                                            state_q <= FINISHED;
                                        end
                                    end
                                end
                            end

                            MODE_A: begin
                                if (n_off_q < last_in_block) begin
                                    n_off_q <=
                                        n_off_q + COUNT_WIDTH'(1);
                                end else begin
                                    n_off_q <= '0;

                                    if (
                                        k_q + COUNT_WIDTH'(1)
                                        < k_count_q
                                    ) begin
                                        k_q <=
                                            k_q + COUNT_WIDTH'(1);
                                    end else begin
                                        k_q <= '0;

                                        if (next_base < n_count_q) begin
                                            n_base_q <= next_base;
                                        end else begin
                                            n_base_q <= '0;

                                            if (
                                                m_q + COUNT_WIDTH'(1)
                                                < m_count_q
                                            ) begin
                                                m_q <=
                                                    m_q + COUNT_WIDTH'(1);
                                            end else begin
                                                state_q <= FINISHED;
                                            end
                                        end
                                    end
                                end
                            end

                            MODE_B: begin
                                if (m_off_q < last_in_block) begin
                                    m_off_q <=
                                        m_off_q + COUNT_WIDTH'(1);
                                end else begin
                                    m_off_q <= '0;

                                    if (
                                        k_q + COUNT_WIDTH'(1)
                                        < k_count_q
                                    ) begin
                                        k_q <=
                                            k_q + COUNT_WIDTH'(1);
                                    end else begin
                                        k_q <= '0;

                                        if (next_base < m_count_q) begin
                                            m_base_q <= next_base;
                                        end else begin
                                            m_base_q <= '0;

                                            if (
                                                n_q + COUNT_WIDTH'(1)
                                                < n_count_q
                                            ) begin
                                                n_q <=
                                                    n_q + COUNT_WIDTH'(1);
                                            end else begin
                                                state_q <= FINISHED;
                                            end
                                        end
                                    end
                                end
                            end

                            default: begin
                                state_q <= FINISHED;
                            end

                        endcase
                    end
                end

                FINISHED: begin
                    state_q <= IDLE;
                end

                default: begin
                    state_q <= IDLE;
                end

            endcase
        end
    end

    initial begin
        if (COUNT_WIDTH < 2)
            $fatal(1, "COUNT_WIDTH must be >= 2");

        if (
            (PSUM_SLOTS < 1) ||
            (PSUM_SLOTS >= (2**COUNT_WIDTH))
        )
            $fatal(1, "Invalid PSUM_SLOTS");
    end

endmodule
