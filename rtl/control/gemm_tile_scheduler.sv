
module gemm_tile_scheduler #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned K_TILE_SIZE = 256,
    parameter int unsigned K_SIZE_WIDTH = $clog2(K_TILE_SIZE + 1),
    parameter bit ENABLE_MULTI_K_A_REUSE = 1'b0,
    parameter int unsigned A_REUSE_BLOCK_SIZE = 4
) (
    input logic clk,
    input logic reset,

    input logic start,
    input logic enable_multi_k_a_reuse,
    input logic enable_b_stationary,
    input logic enable_pool_channel_tiling,

    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_count,
    input logic [K_SIZE_WIDTH-1:0] last_k_size,

    output logic a_load_req,
    input logic a_load_accept,
    input logic a_load_done,

    output logic b_load_req,
    input logic b_load_accept,
    input logic b_load_done,

    output logic [TILE_COUNT_WIDTH-1:0] load_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_n_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_k_tile_idx,
    output logic [K_SIZE_WIDTH-1:0] load_k_size,

    output logic a_compute_req,
    input logic a_compute_grant,
    output logic a_compute_done,
    output logic a_release_bank,

    output logic b_compute_req,
    input logic b_compute_grant,
    output logic b_compute_done,
    output logic b_release_bank,

    output logic matrix_start,
    input logic matrix_done,
    input logic writeback_done,

    output logic clear_acc,
    output logic writeback_en,
    output logic [K_SIZE_WIDTH-1:0] compute_k_size,

    output logic [TILE_COUNT_WIDTH-1:0] compute_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] compute_n_tile_idx,

    output logic busy,
    output logic done
);

    typedef logic [K_SIZE_WIDTH-1:0] k_size_t;

    localparam k_size_t FULL_K_SIZE = k_size_t'(K_TILE_SIZE);

    typedef enum logic [1:0] {
        LD_IDLE,
        LD_REQ,
        LD_WAIT
    } load_state_t;

    typedef enum logic [2:0] {
        CP_IDLE,
        CP_ACQUIRE,
        CP_LAUNCH,
        CP_RUN,
        CP_WAIT_WRITEBACK
    } compute_state_t;

    load_state_t load_state;
    compute_state_t compute_state;

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_q;
    k_size_t last_k_size_q;

    logic active_q;
    logic done_q;
    logic b_stationary_q;
    logic multi_k_a_reuse_q;
    logic pool_channel_tiling_q;

    // ============================================================
    // Traversal cursor
    // ============================================================

    logic next_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] next_m_q;
    logic [TILE_COUNT_WIDTH-1:0] next_n_q;
    logic [TILE_COUNT_WIDTH-1:0] next_k_q;

    logic [TILE_COUNT_WIDTH-1:0] policy_next_m;
    logic [TILE_COUNT_WIDTH-1:0] policy_next_n;
    logic [TILE_COUNT_WIDTH-1:0] policy_next_k;

    logic policy_next_valid;
    logic policy_reuse_a;
    logic policy_allow_a_load;
    logic policy_release_a;
    logic policy_a_reuse_enabled;

    // ============================================================
    // A residency: A(M,K)
    // ============================================================

    logic resident_a_valid_q;
    logic [TILE_COUNT_WIDTH-1:0] resident_a_m_q;
    logic [TILE_COUNT_WIDTH-1:0] resident_a_k_q;

    // ============================================================
    // B residency: B(N), K_tiles=1
    //
    // Keep the current N tile resident until its last M tile
    // completes. A different N tile loads after that release.
    // ============================================================

    logic resident_b_valid_q;
    logic [TILE_COUNT_WIDTH-1:0] resident_b_n_q;

    // ============================================================
    // Load pipeline
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] load_m_q;
    logic [TILE_COUNT_WIDTH-1:0] load_n_q;
    logic [TILE_COUNT_WIDTH-1:0] load_k_q;

    logic a_reuse_q;
    logic b_reuse_q;

    logic a_load_issued_q;
    logic b_load_issued_q;
    logic a_load_finished_q;
    logic b_load_finished_q;

    logic a_load_accept_effective;
    logic a_load_done_effective;
    logic b_load_accept_effective;
    logic b_load_done_effective;

    // ============================================================
    // Ready queue
    // ============================================================

    logic ready_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] ready_m_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_n_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_k_q;

    // ============================================================
    // Compute pipeline
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] compute_m_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_n_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_k_q;

    logic a_acquired_q;
    logic b_acquired_q;

    // ============================================================
    // Tile policy
    // ============================================================

    gemm_tile_order #(
        .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH),
        .ENABLE_MULTI_K_A_REUSE(ENABLE_MULTI_K_A_REUSE),
        .A_REUSE_BLOCK_SIZE(A_REUSE_BLOCK_SIZE)
    ) u_gemm_tile_order (
        .enable_multi_k_a_reuse(multi_k_a_reuse_q),
        .enable_b_stationary(b_stationary_q),
        .enable_pool_channel_tiling(pool_channel_tiling_q),

        .m_tile_count(m_tile_count_q),
        .n_tile_count(n_tile_count_q),
        .k_tile_count(k_tile_count_q),

        .cursor_m(next_m_q),
        .cursor_n(next_n_q),
        .cursor_k(next_k_q),

        .next_m(policy_next_m),
        .next_n(policy_next_n),
        .next_k(policy_next_k),
        .next_valid(policy_next_valid),

        .resident_a_valid(resident_a_valid_q),
        .resident_a_m(resident_a_m_q),
        .resident_a_k(resident_a_k_q),

        .reuse_a(policy_reuse_a),
        .allow_new_a_load(policy_allow_a_load),

        .compute_n(compute_n_q),
        .release_a(policy_release_a),

        .a_reuse_enabled(policy_a_reuse_enabled)
    );

    // ============================================================
    // Coordinates
    // ============================================================

    assign load_m_tile_idx = load_m_q;
    assign load_n_tile_idx = load_n_q;
    assign load_k_tile_idx = load_k_q;

    assign compute_m_tile_idx = compute_m_q;
    assign compute_n_tile_idx = compute_n_q;

    assign load_k_size =
        (
            (k_tile_count_q != '0) &&
            (
                load_k_q ==
                (k_tile_count_q - TILE_COUNT_WIDTH'(1))
            )
        )
            ? last_k_size_q
            : FULL_K_SIZE;

    assign compute_k_size =
        (
            (k_tile_count_q != '0) &&
            (
                compute_k_q ==
                (k_tile_count_q - TILE_COUNT_WIDTH'(1))
            )
        )
            ? last_k_size_q
            : FULL_K_SIZE;

    assign clear_acc = (compute_k_q == '0);

    assign writeback_en =
        (k_tile_count_q != '0) &&
        (
            compute_k_q ==
            (k_tile_count_q - TILE_COUNT_WIDTH'(1))
        );

    // ============================================================
    // A load
    // ============================================================

    assign a_load_req =
        (load_state == LD_REQ) &&
        !a_load_issued_q &&
        !a_reuse_q &&
        policy_allow_a_load;

    assign a_load_accept_effective =
        a_reuse_q || a_load_accept;

    assign a_load_done_effective =
        a_reuse_q || a_load_done;

    // ============================================================
    // B load
    //
    // In B-stationary mode, reuse the resident N tile across M.
    // Wait for its release before loading a different N tile.
    // ============================================================

    assign b_load_req =
        (load_state == LD_REQ) &&
        !b_load_issued_q &&
        !b_reuse_q &&
        (!b_stationary_q || !resident_b_valid_q);

    assign b_load_accept_effective =
        b_reuse_q || b_load_accept;

    assign b_load_done_effective =
        b_reuse_q || b_load_done;

    // ============================================================
    // Compute acquisition
    // ============================================================

    // Acquire each bank once, remembering grants until both arrive.
    assign a_compute_req =
        (compute_state == CP_ACQUIRE) && !a_acquired_q;

    assign b_compute_req =
        (compute_state == CP_ACQUIRE) && !b_acquired_q;

    assign matrix_start =
        (compute_state == CP_LAUNCH);

    assign a_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;

    assign b_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;

    assign a_release_bank = policy_release_a;

    // B stays resident across M tiles.
    // Release only on the last M tile of an N group.
    assign b_release_bank =
        !b_stationary_q ||
        (
            (m_tile_count_q != '0) &&
            (
                compute_m_q ==
                (m_tile_count_q - TILE_COUNT_WIDTH'(1))
            )
        );

    assign busy = active_q;
    assign done = done_q;

    // ============================================================
    // Scheduler state
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin

            m_tile_count_q <= '0;
            n_tile_count_q <= '0;
            k_tile_count_q <= '0;
            last_k_size_q <= '0;

            active_q <= 1'b0;
            done_q <= 1'b0;

            b_stationary_q <= 1'b0;
            multi_k_a_reuse_q <= 1'b0;
            pool_channel_tiling_q <= 1'b0;

            next_valid_q <= 1'b0;
            next_m_q <= '0;
            next_n_q <= '0;
            next_k_q <= '0;

            resident_a_valid_q <= 1'b0;
            resident_a_m_q <= '0;
            resident_a_k_q <= '0;

            resident_b_valid_q <= 1'b0;
            resident_b_n_q <= '0;

            load_state <= LD_IDLE;
            load_m_q <= '0;
            load_n_q <= '0;
            load_k_q <= '0;

            a_reuse_q <= 1'b0;
            b_reuse_q <= 1'b0;

            a_load_issued_q <= 1'b0;
            b_load_issued_q <= 1'b0;
            a_load_finished_q <= 1'b0;
            b_load_finished_q <= 1'b0;

            ready_valid_q <= 1'b0;
            ready_m_q <= '0;
            ready_n_q <= '0;
            ready_k_q <= '0;

            compute_state <= CP_IDLE;
            compute_m_q <= '0;
            compute_n_q <= '0;
            compute_k_q <= '0;

            a_acquired_q <= 1'b0;
            b_acquired_q <= 1'b0;

        end else begin

            done_q <= 1'b0;

            if (start && !active_q) begin

                m_tile_count_q <= m_tile_count;
                n_tile_count_q <= n_tile_count;
                k_tile_count_q <= k_tile_count;
                last_k_size_q <= last_k_size;

                active_q <= 1'b1;

                b_stationary_q <=
                    enable_b_stationary &&
                    (k_tile_count == TILE_COUNT_WIDTH'(1));

                multi_k_a_reuse_q <= enable_multi_k_a_reuse;
                pool_channel_tiling_q <= enable_pool_channel_tiling;

                next_valid_q <= 1'b1;
                next_m_q <= '0;
                next_n_q <= '0;
                next_k_q <= '0;

                resident_a_valid_q <= 1'b0;
                resident_a_m_q <= '0;
                resident_a_k_q <= '0;

                resident_b_valid_q <= 1'b0;
                resident_b_n_q <= '0;

                load_state <= LD_IDLE;

                a_reuse_q <= 1'b0;
                b_reuse_q <= 1'b0;

                a_load_issued_q <= 1'b0;
                b_load_issued_q <= 1'b0;
                a_load_finished_q <= 1'b0;
                b_load_finished_q <= 1'b0;

                ready_valid_q <= 1'b0;
                compute_state <= CP_IDLE;

                a_acquired_q <= 1'b0;
                b_acquired_q <= 1'b0;

            end else if (active_q) begin

                // ================================================
                // LOAD FSM
                // ================================================

                case (load_state)

                    LD_IDLE: begin
                        if (
                            next_valid_q &&
                            !ready_valid_q
                        ) begin
                            load_m_q <= next_m_q;
                            load_n_q <= next_n_q;
                            load_k_q <= next_k_q;

                            a_reuse_q <= policy_reuse_a;

                            b_reuse_q <=
                                b_stationary_q &&
                                resident_b_valid_q &&
                                (next_n_q == resident_b_n_q);

                            a_load_issued_q <= 1'b0;
                            b_load_issued_q <= 1'b0;
                            a_load_finished_q <= 1'b0;
                            b_load_finished_q <= 1'b0;

                            next_m_q <= policy_next_m;
                            next_n_q <= policy_next_n;
                            next_k_q <= policy_next_k;
                            next_valid_q <= policy_next_valid;

                            load_state <= LD_REQ;
                        end
                    end

                    LD_REQ: begin

                        if (a_load_done_effective)
                            a_load_finished_q <= 1'b1;

                        if (b_load_done_effective)
                            b_load_finished_q <= 1'b1;

                        if (a_load_accept_effective) begin
                            a_load_issued_q <= 1'b1;

                            if (
                                policy_a_reuse_enabled &&
                                !a_reuse_q &&
                                a_load_accept
                            ) begin
                                resident_a_valid_q <= 1'b1;
                                resident_a_m_q <= load_m_q;
                                resident_a_k_q <= load_k_q;
                            end
                        end

                        if (b_load_accept_effective) begin
                            b_load_issued_q <= 1'b1;

                            if (
                                b_stationary_q &&
                                !b_reuse_q &&
                                b_load_accept
                            ) begin
                                resident_b_valid_q <= 1'b1;
                                resident_b_n_q <= load_n_q;
                            end
                        end

                        if (
                            (
                                a_load_issued_q ||
                                a_load_accept_effective
                            ) &&
                            (
                                b_load_issued_q ||
                                b_load_accept_effective
                            )
                        ) begin
                            load_state <= LD_WAIT;
                        end
                    end

                    LD_WAIT: begin

                        if (a_load_done_effective)
                            a_load_finished_q <= 1'b1;

                        if (b_load_done_effective)
                            b_load_finished_q <= 1'b1;

                        if (
                            (
                                a_load_finished_q ||
                                a_load_done_effective
                            ) &&
                            (
                                b_load_finished_q ||
                                b_load_done_effective
                            )
                        ) begin
                            ready_valid_q <= 1'b1;

                            ready_m_q <= load_m_q;
                            ready_n_q <= load_n_q;
                            ready_k_q <= load_k_q;

                            a_load_issued_q <= 1'b0;
                            b_load_issued_q <= 1'b0;
                            a_load_finished_q <= 1'b0;
                            b_load_finished_q <= 1'b0;

                            load_state <= LD_IDLE;
                        end
                    end

                    default: begin
                        load_state <= LD_IDLE;
                    end

                endcase

                // ================================================
                // COMPUTE FSM
                // ================================================

                case (compute_state)

                    CP_IDLE: begin
                        if (ready_valid_q) begin
                            a_acquired_q <= 1'b0;
                            b_acquired_q <= 1'b0;
                            compute_state <= CP_ACQUIRE;
                        end
                    end

                    CP_ACQUIRE: begin

                        if (a_compute_grant)
                            a_acquired_q <= 1'b1;

                        if (b_compute_grant)
                            b_acquired_q <= 1'b1;

                        if (
                            (
                                a_acquired_q ||
                                a_compute_grant
                            ) &&
                            (
                                b_acquired_q ||
                                b_compute_grant
                            )
                        ) begin
                            compute_m_q <= ready_m_q;
                            compute_n_q <= ready_n_q;
                            compute_k_q <= ready_k_q;

                            ready_valid_q <= 1'b0;

                            a_acquired_q <= 1'b0;
                            b_acquired_q <= 1'b0;

                            compute_state <= CP_LAUNCH;
                        end
                    end

                    CP_LAUNCH: begin
                        compute_state <= CP_RUN;
                    end

                    CP_RUN: begin
                        if (matrix_done) begin

                            if (
                                policy_a_reuse_enabled &&
                                policy_release_a
                            ) begin
                                resident_a_valid_q <= 1'b0;
                            end

                            // Release the matching resident B tag
                            // after the last M tile completes.
                            if (
                                b_stationary_q &&
                                b_release_bank &&
                                resident_b_valid_q &&
                                (resident_b_n_q == compute_n_q)
                            ) begin
                                resident_b_valid_q <= 1'b0;
                            end

                            if (
                                (k_tile_count_q != '0) &&
                                (
                                    compute_k_q ==
                                    (
                                        k_tile_count_q -
                                        TILE_COUNT_WIDTH'(1)
                                    )
                                )
                            ) begin
                                compute_state <= CP_WAIT_WRITEBACK;
                            end else begin
                                compute_state <= CP_IDLE;
                            end
                        end
                    end

                    CP_WAIT_WRITEBACK: begin
                        if (writeback_done)
                            compute_state <= CP_IDLE;
                    end

                    default: begin
                        compute_state <= CP_IDLE;
                    end

                endcase

                // ================================================
                // Command completion
                // ================================================

                if (
                    !next_valid_q &&
                    (load_state == LD_IDLE) &&
                    !ready_valid_q &&
                    (compute_state == CP_IDLE)
                ) begin
                    active_q <= 1'b0;
                    done_q <= 1'b1;
                end

            end
        end
    end

endmodule
