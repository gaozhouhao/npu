
`timescale 1ns/1ps

module tile_policy_multik_tb #(
    parameter int unsigned BLOCK_SIZE = 4
);

    localparam int unsigned W = 8;
    localparam int unsigned M_COUNT = 2;
    localparam int unsigned N_COUNT = 5;
    localparam int unsigned K_COUNT = 3;
    localparam int unsigned TOTAL_TILES =
        M_COUNT * N_COUNT * K_COUNT;

    logic [W-1:0] cursor_m;
    logic [W-1:0] cursor_n;
    logic [W-1:0] cursor_k;

    logic [W-1:0] next_m;
    logic [W-1:0] next_n;
    logic [W-1:0] next_k;
    logic next_valid;

    logic resident_a_valid;
    logic [W-1:0] resident_a_m;
    logic [W-1:0] resident_a_k;

    logic reuse_a;
    logic allow_new_a_load;
    logic release_a;
    logic a_reuse_enabled;

    logic [W-1:0] compute_n;

    int tiles_seen;
    int a_load_count;
    int prev_m;
    int prev_n;
    int prev_k;
    logic prev_valid;

    tile_policy #(
        .TILE_COUNT_WIDTH      (W),
        .ENABLE_A_REUSE        (1'b1),
        .ENABLE_MULTI_K_A_REUSE(1'b1),
        .A_REUSE_BLOCK_SIZE    (BLOCK_SIZE)
    ) dut (
        .m_tile_count   (W'(M_COUNT)),
        .n_tile_count   (W'(N_COUNT)),
        .k_tile_count   (W'(K_COUNT)),

        .cursor_m       (cursor_m),
        .cursor_n       (cursor_n),
        .cursor_k       (cursor_k),

        .next_m         (next_m),
        .next_n         (next_n),
        .next_k         (next_k),
        .next_valid     (next_valid),

        .resident_a_valid (resident_a_valid),
        .resident_a_m     (resident_a_m),
        .resident_a_k     (resident_a_k),

        .reuse_a         (reuse_a),
        .allow_new_a_load(allow_new_a_load),

        .compute_n       (compute_n),
        .release_a       (release_a),

        .a_reuse_enabled (a_reuse_enabled)
    );

    initial begin
        cursor_m = '0;
        cursor_n = '0;
        cursor_k = '0;

        resident_a_valid = 1'b0;
        resident_a_m = '0;
        resident_a_k = '0;
        compute_n = '0;

        tiles_seen = 0;
        a_load_count = 0;

        prev_m = 0;
        prev_n = 0;
        prev_k = 0;
        prev_valid = 1'b0;

        if ((BLOCK_SIZE < 2) || (BLOCK_SIZE > 4))
            $fatal(1, "Test BLOCK_SIZE must be 2..4");

        for (int mi = 0; mi < M_COUNT; mi++) begin

            for (
                int base = 0;
                base < N_COUNT;
                base += BLOCK_SIZE
            ) begin

                for (int ki = 0; ki < K_COUNT; ki++) begin

                    for (
                        int ni = base;
                        (ni < base + BLOCK_SIZE) &&
                        (ni < N_COUNT);
                        ni++
                    ) begin

                        cursor_m = W'(mi);
                        cursor_n = W'(ni);
                        cursor_k = W'(ki);
                        compute_n = W'(ni);

                        #1;

                        if (!a_reuse_enabled)
                            $fatal(1, "A reuse must be enabled");

                        // Check the previous tile's next cursor.
                        if (tiles_seen > 0) begin
                            if (
                                !prev_valid ||
                                (prev_m != mi) ||
                                (prev_n != ni) ||
                                (prev_k != ki)
                            )
                                $fatal(
                                    1,
                                    "Traversal mismatch at tile %0d",
                                    tiles_seen
                                );
                        end

                        // First N of each block loads A from DDR.
                        if (ni == base) begin

                            if (reuse_a || !allow_new_a_load)
                                $fatal(
                                    1,
                                    "Expected a fresh A load"
                                );

                            a_load_count++;

                            resident_a_valid = 1'b1;
                            resident_a_m = W'(mi);
                            resident_a_k = W'(ki);

                        end else begin

                            if (!reuse_a)
                                $fatal(
                                    1,
                                    "Expected A reuse: m=%0d n=%0d k=%0d",
                                    mi, ni, ki
                                );

                        end

                        #1;

                        if (
                            release_a !==
                            (
                                (ni == N_COUNT-1) ||
                                (ni == base+BLOCK_SIZE-1)
                            )
                        )
                            $fatal(
                                1,
                                "Unexpected A release: n=%0d",
                                ni
                            );

                        // Save the DUT's next-tile decision.
                        prev_m = int'(next_m);
                        prev_n = int'(next_n);
                        prev_k = int'(next_k);
                        prev_valid = next_valid;

                        tiles_seen++;

                        if (release_a) begin
                            resident_a_valid = 1'b0;
                        end
                    end
                end
            end
        end

        if (tiles_seen != TOTAL_TILES)
            $fatal(
                1,
                "Missing tiles: got=%0d expected=%0d",
                tiles_seen, TOTAL_TILES
            );

        if (prev_valid)
            $fatal(1, "Iterator must terminate");

        if (
            a_load_count !=
            (
                M_COUNT * K_COUNT *
                ((N_COUNT + BLOCK_SIZE - 1) / BLOCK_SIZE)
            )
        )
            $fatal(
                1,
                "Unexpected A load count=%0d",
                a_load_count
            );

        $display(
            "PASS BLOCK_SIZE=%0d tiles=%0d A_loads=%0d",
            BLOCK_SIZE,
            tiles_seen,
            a_load_count
        );

        $finish;
    end

endmodule
