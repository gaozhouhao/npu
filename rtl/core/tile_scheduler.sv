module tile_scheduler #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned K_TILE_SIZE      = 256,
    parameter int unsigned K_SIZE_WIDTH     = $clog2(K_TILE_SIZE + 1)
) (
    input logic clk,
    input logic reset,

    // GEMM command
    input logic start,
    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_count,
    input logic [K_SIZE_WIDTH-1:0] last_k_size,

    // A load interface
    output logic a_load_req,
    input  logic a_load_accept,
    input  logic a_load_done,

    // B load interface
    output logic b_load_req,
    input  logic b_load_accept,
    input  logic b_load_done,

    // Load tile coordinates
    output logic [TILE_COUNT_WIDTH-1:0] load_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_n_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_k_tile_idx,
    output logic [K_SIZE_WIDTH-1:0] load_k_size,

    // A compute bank
    output logic a_compute_req,
    input  logic a_compute_grant,
    output logic a_compute_done,
    output logic a_release_bank,

    // B compute bank
    output logic b_compute_req,
    input  logic b_compute_grant,
    output logic b_compute_done,
    output logic b_release_bank,

    // Matrix core
    output logic matrix_start,
    input  logic matrix_done,
    input  logic writeback_done,

    output logic clear_acc,
    output logic writeback_en,
    output logic [K_SIZE_WIDTH-1:0] compute_k_size,

    // Compute tile coordinates
    output logic [TILE_COUNT_WIDTH-1:0] compute_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] compute_n_tile_idx,

    // Status
    output logic busy,
    output logic done
);

    typedef logic [K_SIZE_WIDTH-1:0] k_size_t;

    localparam k_size_t FULL_K_SIZE =
        k_size_t'(K_TILE_SIZE);

    // ============================================================
    // Load FSM
    // ============================================================

    typedef enum logic [1:0] {
        LD_IDLE,
        LD_REQ,
        LD_WAIT
    } load_state_t;

    load_state_t load_state;

    // ============================================================
    // Compute FSM
    // ============================================================

    typedef enum logic [2:0] {
        CP_IDLE,
        CP_ACQUIRE,
        CP_LAUNCH,
        CP_RUN,
        CP_WAIT_WRITEBACK
    } compute_state_t;

    compute_state_t compute_state;

    // ============================================================
    // Locked GEMM shape
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_q;

    k_size_t last_k_size_q;

    // ============================================================
    // Command status
    // ============================================================

    logic active_q;
    logic done_q;

    // ============================================================
    // Logical traversal cursor
    // ============================================================

    logic next_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] next_m_q;
    logic [TILE_COUNT_WIDTH-1:0] next_n_q;
    logic [TILE_COUNT_WIDTH-1:0] next_k_q;

    // ============================================================
    // Policy outputs
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] policy_next_m;
    logic [TILE_COUNT_WIDTH-1:0] policy_next_n;
    logic [TILE_COUNT_WIDTH-1:0] policy_next_k;

    logic policy_next_valid;
    logic policy_reuse_a;
    logic policy_allow_a_load;
    logic policy_release_a;
    logic policy_a_reuse_enabled;

    // ============================================================
    // Resident A tile tag
    //
    // Indicates a logical A(M,K) has entered the load path.
    // The bank manager owns physical READY/COMPUTING states.
    // ============================================================

    logic resident_a_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] resident_a_m_q;
    logic [TILE_COUNT_WIDTH-1:0] resident_a_k_q;

    // ============================================================
    // Load-stage metadata
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] load_m_q;
    logic [TILE_COUNT_WIDTH-1:0] load_n_q;
    logic [TILE_COUNT_WIDTH-1:0] load_k_q;

    logic a_reuse_q;

    logic a_load_issued_q;
    logic b_load_issued_q;

    logic a_load_finished_q;
    logic b_load_finished_q;

    logic a_load_accept_effective;
    logic a_load_done_effective;

    // ============================================================
    // One-entry ready queue
    // ============================================================

    logic ready_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] ready_m_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_n_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_k_q;

    // ============================================================
    // Compute-stage metadata
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] compute_m_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_n_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_k_q;

    logic a_acquired_q;
    logic b_acquired_q;

    // ============================================================
    // Policy Engine
    //
    // Pure decision logic.
    // No AXI or physical buffer control is implemented here.
    // ============================================================

    tile_policy #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH)
    ) u_tile_policy (
        .m_tile_count       (m_tile_count_q),
        .n_tile_count       (n_tile_count_q),
        .k_tile_count       (k_tile_count_q),

        .cursor_m           (next_m_q),
        .cursor_n           (next_n_q),
        .cursor_k           (next_k_q),

        .next_m             (policy_next_m),
        .next_n             (policy_next_n),
        .next_k             (policy_next_k),
        .next_valid         (policy_next_valid),

        .resident_a_valid   (resident_a_valid_q),
        .resident_a_m       (resident_a_m_q),
        .resident_a_k       (resident_a_k_q),

        .reuse_a            (policy_reuse_a),
        .allow_new_a_load   (policy_allow_a_load),

        .compute_n          (compute_n_q),
        .release_a          (policy_release_a),

        .a_reuse_enabled    (policy_a_reuse_enabled)
    );

    // ============================================================
    // Tile coordinates
    // ============================================================

    assign load_m_tile_idx = load_m_q;
    assign load_n_tile_idx = load_n_q;
    assign load_k_tile_idx = load_k_q;

    assign compute_m_tile_idx = compute_m_q;
    assign compute_n_tile_idx = compute_n_q;

    // ============================================================
    // K tile size
    // ============================================================

    assign load_k_size =
        (
            (k_tile_count_q != '0) &&
            (load_k_q == (k_tile_count_q - 1'b1))
        )
            ? last_k_size_q
            : FULL_K_SIZE;

    assign compute_k_size =
        (
            (k_tile_count_q != '0) &&
            (compute_k_q == (k_tile_count_q - 1'b1))
        )
            ? last_k_size_q
            : FULL_K_SIZE;

    // ============================================================
    // Accumulator control
    //
    // Existing output-stationary K accumulation is unchanged.
    // ============================================================

    assign clear_acc =
        (compute_k_q == '0);

    assign writeback_en =
        (
            (k_tile_count_q != '0) &&
            (compute_k_q == (k_tile_count_q - 1'b1))
        );

    // ============================================================
    // A Load
    //
    // Reuse hits do not generate a physical DMA request.
    //
    // When a different A tile is required, wait for the old
    // resident bank to be released before starting its load.
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
    // B Load
    //
    // V1 policy always loads B normally.
    // ============================================================

    assign b_load_req =
        (load_state == LD_REQ) &&
        !b_load_issued_q;

    // ============================================================
    // Compute bank acquisition
    // ============================================================

    assign a_compute_req =
        (compute_state == CP_ACQUIRE) &&
        !a_acquired_q;

    assign b_compute_req =
        (compute_state == CP_ACQUIRE) &&
        !b_acquired_q;

    // ============================================================
    // Matrix control
    // ============================================================

    assign matrix_start =
        (compute_state == CP_LAUNCH);

    assign a_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;

    assign b_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;

    // ============================================================
    // Bank release policy
    //
    // A:
    //   Intermediate N tile: COMPUTING -> READY
    //   Final N tile:        COMPUTING -> EMPTY
    //
    // B:
    //   COMPUTING -> EMPTY after every tile.
    // ============================================================

    assign a_release_bank =
        policy_release_a;

    assign b_release_bank =
        1'b1;

    // ============================================================
    // Status
    // ============================================================

    assign busy = active_q;
    assign done = done_q;

    // ============================================================
    // Main Scheduler
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            m_tile_count_q <= '0;
            n_tile_count_q <= '0;
            k_tile_count_q <= '0;
            last_k_size_q <= '0;

            active_q <= 1'b0;
            done_q <= 1'b0;

            next_valid_q <= 1'b0;
            next_m_q <= '0;
            next_n_q <= '0;
            next_k_q <= '0;

            resident_a_valid_q <= 1'b0;
            resident_a_m_q <= '0;
            resident_a_k_q <= '0;

            load_state <= LD_IDLE;
            load_m_q <= '0;
            load_n_q <= '0;
            load_k_q <= '0;

            a_reuse_q <= 1'b0;

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

            // ====================================================
            // Start new GEMM command
            // ====================================================

            if (start && !active_q) begin

                m_tile_count_q <= m_tile_count;
                n_tile_count_q <= n_tile_count;
                k_tile_count_q <= k_tile_count;
                last_k_size_q <= last_k_size;

                active_q <= 1'b1;

                next_valid_q <= 1'b1;
                next_m_q <= '0;
                next_n_q <= '0;
                next_k_q <= '0;

                resident_a_valid_q <= 1'b0;
                resident_a_m_q <= '0;
                resident_a_k_q <= '0;

                load_state <= LD_IDLE;
                a_reuse_q <= 1'b0;

                a_load_issued_q <= 1'b0;
                b_load_issued_q <= 1'b0;
                a_load_finished_q <= 1'b0;
                b_load_finished_q <= 1'b0;

                ready_valid_q <= 1'b0;

                compute_state <= CP_IDLE;

                a_acquired_q <= 1'b0;
                b_acquired_q <= 1'b0;

            end else if (active_q) begin

                // =================================================
                // LOAD PIPELINE
                // =================================================

                case (load_state)

                    // =============================================
                    // Select next logical tile.
                    // =============================================

                    LD_IDLE: begin

                        if (
                            next_valid_q &&
                            !ready_valid_q
                        ) begin

                            load_m_q <= next_m_q;
                            load_n_q <= next_n_q;
                            load_k_q <= next_k_q;

                            // Capture policy decision for this tile.
                            // Must remain stable while load runs.

                            a_reuse_q <= policy_reuse_a;

                            a_load_issued_q <= 1'b0;
                            b_load_issued_q <= 1'b0;

                            a_load_finished_q <= 1'b0;
                            b_load_finished_q <= 1'b0;

                            // Advance the traversal cursor
                            // according to the selected policy.

                            next_m_q <= policy_next_m;
                            next_n_q <= policy_next_n;
                            next_k_q <= policy_next_k;

                            next_valid_q <= policy_next_valid;

                            load_state <= LD_REQ;

                        end
                    end

                    // =============================================
                    // Issue A/B load requests independently.
                    //
                    // Reused A is treated as a logical load
                    // acceptance without activating its DMA.
                    // =============================================

                    LD_REQ: begin

                        if (a_load_accept_effective) begin

                            a_load_issued_q <= 1'b1;

                            if (
                                policy_a_reuse_enabled &&
                                !a_reuse_q &&
                                a_load_accept
                            ) begin

                                // New A tile has entered the
                                // physical loading pipeline.
                                // Record its logical identity.

                                resident_a_valid_q <= 1'b1;
                                resident_a_m_q <= load_m_q;
                                resident_a_k_q <= load_k_q;

                            end

                        end

                        if (b_load_accept) begin
                            b_load_issued_q <= 1'b1;
                        end

                        if (
                            (
                                a_load_issued_q ||
                                a_load_accept_effective
                            ) &&
                            (
                                b_load_issued_q ||
                                b_load_accept
                            )
                        ) begin

                            load_state <= LD_WAIT;

                        end

                    end

                    // =============================================
                    // Wait for logical A/B loading completion.
                    //
                    // A reuse hit means its previous SRAM data
                    // is retained. Actual bank ownership is
                    // still checked in CP_ACQUIRE.
                    // =============================================

                    LD_WAIT: begin

                        if (a_load_done_effective) begin
                            a_load_finished_q <= 1'b1;
                        end

                        if (b_load_done) begin
                            b_load_finished_q <= 1'b1;
                        end

                        if (
                            (
                                a_load_finished_q ||
                                a_load_done_effective
                            ) &&
                            (
                                b_load_finished_q ||
                                b_load_done
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

                // =================================================
                // COMPUTE PIPELINE
                // =================================================

                case (compute_state)

                    // =============================================
                    // A prefetched logical tile is ready.
                    // =============================================

                    CP_IDLE: begin

                        if (ready_valid_q) begin

                            a_acquired_q <= 1'b0;
                            b_acquired_q <= 1'b0;

                            compute_state <= CP_ACQUIRE;

                        end

                    end

                    // =============================================
                    // Acquire the actual physical A/B banks.
                    // =============================================

                    CP_ACQUIRE: begin

                        if (a_compute_grant) begin
                            a_acquired_q <= 1'b1;
                        end

                        if (b_compute_grant) begin
                            b_acquired_q <= 1'b1;
                        end

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

                    // =============================================
                    // One-cycle matrix start.
                    // =============================================

                    CP_LAUNCH: begin
                        compute_state <= CP_RUN;
                    end

                    // =============================================
                    // Wait for the GEMM core.
                    // =============================================

                    CP_RUN: begin

                        if (matrix_done) begin

                            // If this is the final N tile,
                            // the A buffer manager releases
                            // the resident bank on this edge.

                            if (
                                policy_a_reuse_enabled &&
                                policy_release_a
                            ) begin

                                resident_a_valid_q <= 1'b0;

                            end

                            if (
                                (k_tile_count_q != '0) &&
                                (
                                    compute_k_q ==
                                    (k_tile_count_q - 1'b1)
                                )
                            ) begin

                                compute_state <=
                                    CP_WAIT_WRITEBACK;

                            end else begin

                                compute_state <= CP_IDLE;

                            end
                        end

                    end

                    // =============================================
                    // Preserve original C writeback ordering.
                    // =============================================

                    CP_WAIT_WRITEBACK: begin

                        if (writeback_done) begin
                            compute_state <= CP_IDLE;
                        end

                    end

                    default: begin
                        compute_state <= CP_IDLE;
                    end

                endcase

                // =================================================
                // Entire GEMM completion
                // =================================================

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

    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (K_TILE_SIZE < 1)
            $fatal(1, "K_TILE_SIZE must be >= 1");

        if (TILE_COUNT_WIDTH < 1)
            $fatal(1, "TILE_COUNT_WIDTH must be >= 1");

    end

endmodule
