module tile_policy #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter bit ENABLE_A_REUSE = 1'b1
) (
    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_count,

    // Current traversal cursor
    input logic [TILE_COUNT_WIDTH-1:0] cursor_m,
    input logic [TILE_COUNT_WIDTH-1:0] cursor_n,
    input logic [TILE_COUNT_WIDTH-1:0] cursor_k,

    // Next logical tile
    output logic [TILE_COUNT_WIDTH-1:0] next_m,
    output logic [TILE_COUNT_WIDTH-1:0] next_n,
    output logic [TILE_COUNT_WIDTH-1:0] next_k,
    output logic next_valid,

    // Currently resident A(M,K) tag
    input logic resident_a_valid,
    input logic [TILE_COUNT_WIDTH-1:0] resident_a_m,
    input logic [TILE_COUNT_WIDTH-1:0] resident_a_k,

    // Load decisions for the current cursor
    output logic reuse_a,
    output logic allow_new_a_load,

    // Compute completion decision
    input logic [TILE_COUNT_WIDTH-1:0] compute_n,
    output logic release_a,

    // Policy status
    output logic a_reuse_enabled
);

    // ============================================================
    // V1 Dataflow Policy
    //
    // Traversal:
    //   for M
    //     for N
    //       for K
    //
    // A-stationary is enabled only when K has one tile.
    //
    // Multi-K GEMM keeps the original output-stationary
    // accumulation behavior.
    // ============================================================

    assign a_reuse_enabled =
        ENABLE_A_REUSE &&
        (k_tile_count == TILE_COUNT_WIDTH'(1)) &&
        (n_tile_count > TILE_COUNT_WIDTH'(1));

    // ============================================================
    // A Residency
    //
    // A is independent of N.
    // Reuse is legal when M and K match.
    //
    // Only one resident A tile is permitted by this policy.
    // A different tile cannot be loaded until the previous
    // resident A bank is released.
    // ============================================================

    assign reuse_a =
        a_reuse_enabled &&
        resident_a_valid &&
        (cursor_n != '0) &&
        (cursor_m == resident_a_m) &&
        (cursor_k == resident_a_k);

    assign allow_new_a_load =
        !a_reuse_enabled ||
        !resident_a_valid;

    // ============================================================
    // Release A after the last N tile of the current M.
    // Otherwise COMPUTING -> READY for another N tile.
    // ============================================================

    assign release_a =
        !a_reuse_enabled ||
        (
            (n_tile_count != '0) &&
            (compute_n == (n_tile_count - 1'b1))
        );

    // ============================================================
    // Logical Tile Traversal
    //
    // M outermost, N middle, K innermost.
    // This preserves current partial-sum ordering.
    // ============================================================

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

        end else if (
            cursor_k != (k_tile_count - 1'b1)
        ) begin

            next_k = cursor_k + 1'b1;

        end else begin

            next_k = '0;

            if (
                cursor_n != (n_tile_count - 1'b1)
            ) begin

                next_n = cursor_n + 1'b1;

            end else begin

                next_n = '0;

                if (
                    cursor_m != (m_tile_count - 1'b1)
                ) begin

                    next_m = cursor_m + 1'b1;

                end else begin

                    next_valid = 1'b0;

                end
            end
        end
    end

    initial begin
        if (TILE_COUNT_WIDTH < 1)
            $fatal(1, "TILE_COUNT_WIDTH must be >= 1");
    end

endmodule
