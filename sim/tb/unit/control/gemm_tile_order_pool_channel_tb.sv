`timescale 1ns/1ps

module gemm_tile_order_pool_channel_tb;
    localparam int W = 8;
    logic enable_pool_channel_tiling;
    logic enable_b_stationary;
    logic [W-1:0] m_count, n_count, k_count;
    logic [W-1:0] cursor_m, cursor_n, cursor_k;
    logic [W-1:0] next_m, next_n, next_k;
    logic next_valid;
    logic reuse_a, allow_new_a_load, release_a, a_reuse_enabled;
    int tiles;

    gemm_tile_order #(
        .TILE_COUNT_WIDTH(W), .ENABLE_A_REUSE(1'b1),
        .ENABLE_MULTI_K_A_REUSE(1'b1), .A_REUSE_BLOCK_SIZE(4)
    ) dut (
        // Exercise the mode's own safety: pooling order must disable A
        // residency even if a caller also requests multi-K A reuse.
        .enable_multi_k_a_reuse(1'b1),
        .enable_b_stationary(enable_b_stationary),
        .enable_pool_channel_tiling(enable_pool_channel_tiling),
        .m_tile_count(m_count), .n_tile_count(n_count), .k_tile_count(k_count),
        .cursor_m(cursor_m), .cursor_n(cursor_n), .cursor_k(cursor_k),
        .next_m(next_m), .next_n(next_n), .next_k(next_k), .next_valid(next_valid),
        .resident_a_valid(1'b1), .resident_a_m(cursor_m), .resident_a_k(cursor_k),
        .reuse_a(reuse_a), .allow_new_a_load(allow_new_a_load),
        .compute_n(cursor_n), .release_a(release_a), .a_reuse_enabled(a_reuse_enabled)
    );

    task automatic check_channel_order(input int kc, input bit b_stationary);
        int em, en, ek;
        bit ev;
        begin
            m_count = W'(3);
            n_count = W'(2);
            k_count = W'(kc);
            enable_pool_channel_tiling = 1'b1;
            enable_b_stationary = b_stationary;
            tiles = 0;
            for (int n = 0; n < 2; n++) begin
                for (int m = 0; m < 3; m++) begin
                    for (int k = 0; k < kc; k++) begin
                        cursor_m = W'(m);
                        cursor_n = W'(n);
                        cursor_k = W'(k);
                        #1;
                        if (a_reuse_enabled || reuse_a || !allow_new_a_load || !release_a)
                            $fatal(1, "Channel order retained A at m=%0d n=%0d k=%0d", m,n,k);
                        em = m; en = n; ek = k; ev = 1'b1;
                        if (k+1 < kc) ek++;
                        else begin
                            ek = 0;
                            if (m+1 < 3) em++;
                            else begin
                                em = 0;
                                if (n+1 < 2) en++;
                                else ev = 1'b0;
                            end
                        end
                        if (next_valid !== ev ||
                            (ev && (next_m != W'(em) || next_n != W'(en) || next_k != W'(ek))))
                            $fatal(1, "Wrong N/M/K successor at (%0d,%0d,%0d)",m,n,k);
                        tiles++;
                    end
                end
            end
            if (tiles != 3*2*kc) $fatal(1, "Missing channel-order tiles");
        end
    endtask

    initial begin
        check_channel_order(3, 1'b0);
        check_channel_order(1, 1'b0);
        check_channel_order(1, 1'b1);

        // Returning to the old policy restores its single-K A reuse.
        enable_pool_channel_tiling = 1'b0;
        enable_b_stationary = 1'b0;
        cursor_m = 0; cursor_n = 1; cursor_k = 0;
        #1;
        if (!a_reuse_enabled || !reuse_a || allow_new_a_load || !release_a)
            $fatal(1, "Legacy A reuse did not return when channel tiling was disabled");

        enable_pool_channel_tiling = 1'b1;
        m_count = 0;
        #1;
        if (next_valid) $fatal(1, "Empty work must terminate");
        $display("TEST_PASS gemm_tile_order_pool_channel_tb");
        $finish;
    end
endmodule
