
module tile_policy #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter bit ENABLE_A_REUSE = 1'b1,
    parameter bit ENABLE_MULTI_K_A_REUSE = 1'b0,
    parameter int unsigned A_REUSE_BLOCK_SIZE = 4
) (
    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_count,

    input logic [TILE_COUNT_WIDTH-1:0] cursor_m,
    input logic [TILE_COUNT_WIDTH-1:0] cursor_n,
    input logic [TILE_COUNT_WIDTH-1:0] cursor_k,

    output logic [TILE_COUNT_WIDTH-1:0] next_m,
    output logic [TILE_COUNT_WIDTH-1:0] next_n,
    output logic [TILE_COUNT_WIDTH-1:0] next_k,
    output logic next_valid,

    input logic resident_a_valid,
    input logic [TILE_COUNT_WIDTH-1:0] resident_a_m,
    input logic [TILE_COUNT_WIDTH-1:0] resident_a_k,

    output logic reuse_a,
    output logic allow_new_a_load,

    input logic [TILE_COUNT_WIDTH-1:0] compute_n,
    output logic release_a,

    output logic a_reuse_enabled
);

    localparam logic [TILE_COUNT_WIDTH-1:0] BLOCK_SIZE =
        TILE_COUNT_WIDTH'(A_REUSE_BLOCK_SIZE);

    localparam logic [TILE_COUNT_WIDTH:0] BLOCK_SIZE_EXT =
        (TILE_COUNT_WIDTH+1)'(A_REUSE_BLOCK_SIZE);

    logic multi_k_a_reuse;

    logic [TILE_COUNT_WIDTH-1:0] cursor_block_base;
    logic [TILE_COUNT_WIDTH-1:0] compute_block_base;

    logic [TILE_COUNT_WIDTH:0] cursor_block_end;
    logic [TILE_COUNT_WIDTH:0] compute_block_end;

    logic [TILE_COUNT_WIDTH-1:0] cursor_block_last;
    logic [TILE_COUNT_WIDTH-1:0] compute_block_last;

    // K=1 keeps the existing A reuse behavior.
    // K>1 enables grouped A reuse only when requested.

    assign multi_k_a_reuse =
        ENABLE_A_REUSE &&
        ENABLE_MULTI_K_A_REUSE &&
        (A_REUSE_BLOCK_SIZE > 1) &&
        (k_tile_count > TILE_COUNT_WIDTH'(1)) &&
        (n_tile_count > TILE_COUNT_WIDTH'(1));

    assign a_reuse_enabled =
        ENABLE_A_REUSE &&
        (n_tile_count > TILE_COUNT_WIDTH'(1)) &&
        (
            (k_tile_count == TILE_COUNT_WIDTH'(1)) ||
            multi_k_a_reuse
        );

    // Determine N-block boundaries.
    // Example: N=10, block size=4
    // [0,1,2,3], [4,5,6,7], [8,9]

    assign cursor_block_base =
        (cursor_n / BLOCK_SIZE) * BLOCK_SIZE;

    assign compute_block_base =
        (compute_n / BLOCK_SIZE) * BLOCK_SIZE;

    assign cursor_block_end =
        {1'b0, cursor_block_base} + BLOCK_SIZE_EXT;

    assign compute_block_end =
        {1'b0, compute_block_base} + BLOCK_SIZE_EXT;

    assign cursor_block_last =
        (cursor_block_end >= {1'b0, n_tile_count})
            ? (n_tile_count - TILE_COUNT_WIDTH'(1))
            : TILE_COUNT_WIDTH'(
                cursor_block_end -
                (TILE_COUNT_WIDTH+1)'(1)
            );

    assign compute_block_last =
        (compute_block_end >= {1'b0, n_tile_count})
            ? (n_tile_count - TILE_COUNT_WIDTH'(1))
            : TILE_COUNT_WIDTH'(
                compute_block_end -
                (TILE_COUNT_WIDTH+1)'(1)
            );

    // Residency is identified by (M,K).
    // A does not depend on N.

    assign reuse_a =
        a_reuse_enabled &&
        resident_a_valid &&
        (cursor_m == resident_a_m) &&
        (cursor_k == resident_a_k) &&
        (
            multi_k_a_reuse
                ? (cursor_n != cursor_block_base)
                : (cursor_n != '0)
        );

    assign allow_new_a_load =
        !a_reuse_enabled || !resident_a_valid;

    // Release after the last N of the current group.

    assign release_a =
        !a_reuse_enabled ||
        (
            multi_k_a_reuse
                ? (compute_n == compute_block_last)
                : (
                    (n_tile_count != '0) &&
                    (
                        compute_n ==
                        (n_tile_count - TILE_COUNT_WIDTH'(1))
                    )
                )
        );

    // ------------------------------------------------------------
    // Traversal policy
    //
    // Legacy:
    //     M -> N -> K
    //
    // Multi-K A reuse:
    //     M -> N Block -> K -> N within the block
    //
    // Physical C SRAM slots are reused after a block completes.
    // ------------------------------------------------------------

    always_comb begin
        next_m = cursor_m;
        next_n = cursor_n;
        next_k = cursor_k;
        next_valid = 1'b1;

        if (
            (m_tile_count == '0) ||
            (n_tile_count == '0) ||
            (k_tile_count == '0)
        ) begin
            next_valid = 1'b0;

        end else if (multi_k_a_reuse) begin

            if (cursor_n < cursor_block_last) begin
                // Reuse current A across another N tile.
                next_n = cursor_n + TILE_COUNT_WIDTH'(1);

            end else if (
                cursor_k <
                (k_tile_count - TILE_COUNT_WIDTH'(1))
            ) begin
                // Next K, restart the same N block.
                next_n = cursor_block_base;
                next_k = cursor_k + TILE_COUNT_WIDTH'(1);

            end else if (
                cursor_block_end < {1'b0, n_tile_count}
            ) begin
                // Current output block is complete.
                // Advance to the next N block.
                next_n = TILE_COUNT_WIDTH'(cursor_block_end);
                next_k = '0;

            end else begin
                // All N blocks for this M are complete.
                next_n = '0;
                next_k = '0;

                if (
                    cursor_m <
                    (m_tile_count - TILE_COUNT_WIDTH'(1))
                ) begin
                    next_m = cursor_m + TILE_COUNT_WIDTH'(1);
                end else begin
                    next_valid = 1'b0;
                end
            end

        end else begin

            // Original M -> N -> K traversal.
            if (
                cursor_k <
                (k_tile_count - TILE_COUNT_WIDTH'(1))
            ) begin
                next_k = cursor_k + TILE_COUNT_WIDTH'(1);

            end else begin
                next_k = '0;

                if (
                    cursor_n <
                    (n_tile_count - TILE_COUNT_WIDTH'(1))
                ) begin
                    next_n = cursor_n + TILE_COUNT_WIDTH'(1);

                end else begin
                    next_n = '0;

                    if (
                        cursor_m <
                        (m_tile_count - TILE_COUNT_WIDTH'(1))
                    ) begin
                        next_m = cursor_m + TILE_COUNT_WIDTH'(1);
                    end else begin
                        next_valid = 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        if (TILE_COUNT_WIDTH < 2)
            $fatal(1, "TILE_COUNT_WIDTH must be >= 2");

        if (
            (A_REUSE_BLOCK_SIZE < 1) ||
            (A_REUSE_BLOCK_SIZE > 4)
        )
            $fatal(1, "A_REUSE_BLOCK_SIZE must be 1..4");
    end

endmodule
