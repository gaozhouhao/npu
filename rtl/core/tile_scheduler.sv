module tile_scheduler #(
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned K_TILE_SIZE      = 256,
    parameter int unsigned K_SIZE_WIDTH     = $clog2(K_TILE_SIZE + 1)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // GEMM command
    // ============================================================

    input logic start,

    input logic [TILE_COUNT_WIDTH-1:0] m_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_count,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_count,

    input logic [K_SIZE_WIDTH-1:0] last_k_size,


    // ============================================================
    // Load stage
    // ============================================================

    output logic a_load_req,
    input  logic a_load_accept,
    input  logic a_load_done,

    output logic b_load_req,
    input  logic b_load_accept,
    input  logic b_load_done,

    output logic [TILE_COUNT_WIDTH-1:0] load_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_n_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] load_k_tile_idx,

    output logic [K_SIZE_WIDTH-1:0] load_k_size,


    // ============================================================
    // A buffer manager - compute side
    // ============================================================

    output logic a_compute_req,
    input  logic a_compute_grant,

    output logic a_compute_done,
    output logic a_release_bank,


    // ============================================================
    // B buffer manager - compute side
    // ============================================================

    output logic b_compute_req,
    input  logic b_compute_grant,

    output logic b_compute_done,
    output logic b_release_bank,


    // ============================================================
    // Matrix core
    //
    // matrix_done = raw GEMM-core completion.
    //
    // writeback_done = final C tile has been written to external
    // memory.
    // ============================================================

    output logic matrix_start,
    input  logic matrix_done,

    input  logic writeback_done,

    output logic clear_acc,
    output logic writeback_en,

    output logic [K_SIZE_WIDTH-1:0] compute_k_size,

    output logic [TILE_COUNT_WIDTH-1:0] compute_m_tile_idx,
    output logic [TILE_COUNT_WIDTH-1:0] compute_n_tile_idx,


    // ============================================================
    // Status
    // ============================================================

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
    // Scheduler active
    // ============================================================

    logic active_q;
    logic done_q;


    // ============================================================
    // Next tile waiting to enter load stage
    // ============================================================

    logic next_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] next_m_q;
    logic [TILE_COUNT_WIDTH-1:0] next_n_q;
    logic [TILE_COUNT_WIDTH-1:0] next_k_q;


    // ============================================================
    // Load-stage tile metadata
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] load_m_q;
    logic [TILE_COUNT_WIDTH-1:0] load_n_q;
    logic [TILE_COUNT_WIDTH-1:0] load_k_q;

    logic a_load_issued_q;
    logic b_load_issued_q;

    logic a_load_finished_q;
    logic b_load_finished_q;


    // ============================================================
    // Ready tile metadata
    //
    // Exactly one prefetched tile may wait here.
    // ============================================================

    logic ready_valid_q;

    logic [TILE_COUNT_WIDTH-1:0] ready_m_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_n_q;
    logic [TILE_COUNT_WIDTH-1:0] ready_k_q;


    // ============================================================
    // Compute-stage tile metadata
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] compute_m_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_n_q;
    logic [TILE_COUNT_WIDTH-1:0] compute_k_q;

    logic a_acquired_q;
    logic b_acquired_q;


    // ============================================================
    // External tile-coordinate outputs
    // ============================================================

    assign load_m_tile_idx =
        load_m_q;

    assign load_n_tile_idx =
        load_n_q;

    assign load_k_tile_idx =
        load_k_q;


    assign compute_m_tile_idx =
        compute_m_q;

    assign compute_n_tile_idx =
        compute_n_q;

    // ============================================================
    // K sizes
    // ============================================================

    assign load_k_size =
        (
            (k_tile_count_q != '0) &&
            (
                load_k_q ==
                (k_tile_count_q - 1'b1)
            )
        )
            ? last_k_size_q
            : FULL_K_SIZE;


    assign compute_k_size =
        (
            (k_tile_count_q != '0) &&
            (
                compute_k_q ==
                (k_tile_count_q - 1'b1)
            )
        )
            ? last_k_size_q
            : FULL_K_SIZE;


    // ============================================================
    // Compute control
    // ============================================================

    assign clear_acc =
        (compute_k_q == '0);


    assign writeback_en =
        (
            (k_tile_count_q != '0) &&
            (
                compute_k_q ==
                (k_tile_count_q - 1'b1)
            )
        );


    // ============================================================
    // Loader handshakes
    // ============================================================

    assign a_load_req =
        (load_state == LD_REQ) &&
        !a_load_issued_q;

    assign b_load_req =
        (load_state == LD_REQ) &&
        !b_load_issued_q;


    // ============================================================
    // Compute-bank acquisition
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


    // ============================================================
    // Operand banks can be released immediately when the core
    // finishes consuming them.
    //
    // Do NOT wait for C writeback.
    // ============================================================

    assign a_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;

    assign b_compute_done =
        (compute_state == CP_RUN) &&
        matrix_done;


    assign a_release_bank =
        1'b1;

    assign b_release_bank =
        1'b1;


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        active_q;

    assign done =
        done_q;


    // ============================================================
    // Main scheduler
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            m_tile_count_q <=
                '0;

            n_tile_count_q <=
                '0;

            k_tile_count_q <=
                '0;

            last_k_size_q <=
                '0;


            active_q <=
                1'b0;

            done_q <=
                1'b0;


            next_valid_q <=
                1'b0;

            next_m_q <=
                '0;

            next_n_q <=
                '0;

            next_k_q <=
                '0;


            load_state <=
                LD_IDLE;

            load_m_q <=
                '0;

            load_n_q <=
                '0;

            load_k_q <=
                '0;

            a_load_issued_q <=
                1'b0;

            b_load_issued_q <=
                1'b0;

            a_load_finished_q <=
                1'b0;

            b_load_finished_q <=
                1'b0;


            ready_valid_q <=
                1'b0;

            ready_m_q <=
                '0;

            ready_n_q <=
                '0;

            ready_k_q <=
                '0;


            compute_state <=
                CP_IDLE;

            compute_m_q <=
                '0;

            compute_n_q <=
                '0;

            compute_k_q <=
                '0;

            a_acquired_q <=
                1'b0;

            b_acquired_q <=
                1'b0;

        end else begin

            done_q <=
                1'b0;


            // ====================================================
            // Start a new GEMM
            // ====================================================

            if (
                start &&
                !active_q
            ) begin

                m_tile_count_q <=
                    m_tile_count;

                n_tile_count_q <=
                    n_tile_count;

                k_tile_count_q <=
                    k_tile_count;

                last_k_size_q <=
                    last_k_size;


                active_q <=
                    1'b1;


                next_valid_q <=
                    1'b1;

                next_m_q <=
                    '0;

                next_n_q <=
                    '0;

                next_k_q <=
                    '0;


                load_state <=
                    LD_IDLE;

                a_load_issued_q <=
                    1'b0;

                b_load_issued_q <=
                    1'b0;

                a_load_finished_q <=
                    1'b0;

                b_load_finished_q <=
                    1'b0;


                ready_valid_q <=
                    1'b0;


                compute_state <=
                    CP_IDLE;

                a_acquired_q <=
                    1'b0;

                b_acquired_q <=
                    1'b0;

            end else if (active_q) begin


                // =================================================
                // LOAD PIPELINE
                // =================================================

                case (load_state)

                    // =============================================
                    // Start loading the next logical tile whenever
                    // the one-entry ready queue is free.
                    // =============================================

                    LD_IDLE: begin

                        if (
                            next_valid_q &&
                            !ready_valid_q
                        ) begin

                            load_m_q <=
                                next_m_q;

                            load_n_q <=
                                next_n_q;

                            load_k_q <=
                                next_k_q;


                            a_load_issued_q <=
                                1'b0;

                            b_load_issued_q <=
                                1'b0;

                            a_load_finished_q <=
                                1'b0;

                            b_load_finished_q <=
                                1'b0;


                            // -------------------------------------
                            // Advance logical next-tile pointer.
                            //
                            // Traversal:
                            //
                            // for m
                            //   for n
                            //     for k
                            // -------------------------------------

                            if (
                                next_k_q !=
                                (k_tile_count_q - 1'b1)
                            ) begin

                                next_k_q <=
                                    next_k_q + 1'b1;

                            end else begin

                                next_k_q <=
                                    '0;


                                if (
                                    next_n_q !=
                                    (n_tile_count_q - 1'b1)
                                ) begin

                                    next_n_q <=
                                        next_n_q + 1'b1;

                                end else begin

                                    next_n_q <=
                                        '0;


                                    if (
                                        next_m_q !=
                                        (m_tile_count_q - 1'b1)
                                    ) begin

                                        next_m_q <=
                                            next_m_q + 1'b1;

                                    end else begin

                                        next_valid_q <=
                                            1'b0;

                                    end

                                end

                            end


                            load_state <=
                                LD_REQ;

                        end

                    end


                    // =============================================
                    // A/B DMA commands may be accepted
                    // independently.
                    // =============================================

                    LD_REQ: begin

                        if (a_load_accept) begin

                            a_load_issued_q <=
                                1'b1;

                        end


                        if (b_load_accept) begin

                            b_load_issued_q <=
                                1'b1;

                        end


                        if (
                            (
                                a_load_issued_q ||
                                a_load_accept
                            ) &&
                            (
                                b_load_issued_q ||
                                b_load_accept
                            )
                        ) begin

                            load_state <=
                                LD_WAIT;

                        end

                    end


                    // =============================================
                    // Wait until both A and B have reached their
                    // respective local banks.
                    // =============================================

                    LD_WAIT: begin

                        if (a_load_done) begin

                            a_load_finished_q <=
                                1'b1;

                        end


                        if (b_load_done) begin

                            b_load_finished_q <=
                                1'b1;

                        end


                        if (
                            (
                                a_load_finished_q ||
                                a_load_done
                            ) &&
                            (
                                b_load_finished_q ||
                                b_load_done
                            )
                        ) begin

                            ready_valid_q <=
                                1'b1;

                            ready_m_q <=
                                load_m_q;

                            ready_n_q <=
                                load_n_q;

                            ready_k_q <=
                                load_k_q;


                            a_load_issued_q <=
                                1'b0;

                            b_load_issued_q <=
                                1'b0;

                            a_load_finished_q <=
                                1'b0;

                            b_load_finished_q <=
                                1'b0;


                            load_state <=
                                LD_IDLE;

                        end

                    end


                    default: begin

                        load_state <=
                            LD_IDLE;

                    end

                endcase


                // =================================================
                // COMPUTE PIPELINE
                // =================================================

                case (compute_state)

                    // =============================================
                    // A prefetched tile is ready.
                    // =============================================

                    CP_IDLE: begin

                        if (ready_valid_q) begin

                            a_acquired_q <=
                                1'b0;

                            b_acquired_q <=
                                1'b0;

                            compute_state <=
                                CP_ACQUIRE;

                        end

                    end


                    // =============================================
                    // Acquire matching READY A/B banks.
                    // =============================================

                    CP_ACQUIRE: begin

                        if (a_compute_grant) begin

                            a_acquired_q <=
                                1'b1;

                        end


                        if (b_compute_grant) begin

                            b_acquired_q <=
                                1'b1;

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

                            compute_m_q <=
                                ready_m_q;

                            compute_n_q <=
                                ready_n_q;

                            compute_k_q <=
                                ready_k_q;


                            ready_valid_q <=
                                1'b0;


                            a_acquired_q <=
                                1'b0;

                            b_acquired_q <=
                                1'b0;


                            compute_state <=
                                CP_LAUNCH;

                        end

                    end


                    // =============================================
                    // One-cycle matrix_start.
                    //
                    // At the same time, ready_valid is already
                    // clear, so the load pipeline may begin
                    // prefetching the next logical tile.
                    // =============================================

                    CP_LAUNCH: begin

                        compute_state <=
                            CP_RUN;

                    end


                    // =============================================
                    // Current tile is being consumed by GEMM core.
                    //
                    // Load pipeline runs independently in parallel.
                    // =============================================

                    CP_RUN: begin

                        if (matrix_done) begin

                            if (
                                (
                                    k_tile_count_q != '0
                                ) &&
                                (
                                    compute_k_q ==
                                    (
                                        k_tile_count_q -
                                        1'b1
                                    )
                                )
                            ) begin

                                // ---------------------------------
                                // Last K tile of current C tile.
                                //
                                // Operand banks are released NOW,
                                // but the next compute must wait
                                // until C writeback completes.
                                // ---------------------------------

                                compute_state <=
                                    CP_WAIT_WRITEBACK;

                            end else begin

                                compute_state <=
                                    CP_IDLE;

                            end

                        end

                    end


                    // =============================================
                    // C Write DMA may overlap with a still-running
                    // A/B prefetch.
                    // =============================================

                    CP_WAIT_WRITEBACK: begin

                        if (writeback_done) begin

                            compute_state <=
                                CP_IDLE;

                        end

                    end


                    default: begin

                        compute_state <=
                            CP_IDLE;

                    end

                endcase


                // =================================================
                // Entire GEMM complete
                //
                // No tile remains:
                // - not waiting to load
                // - not being loaded
                // - not prefetched
                // - not computing / writing back
                // =================================================

                if (
                    !next_valid_q &&
                    (load_state == LD_IDLE) &&
                    !ready_valid_q &&
                    (compute_state == CP_IDLE)
                ) begin

                    active_q <=
                        1'b0;

                    done_q <=
                        1'b1;

                end

            end

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (K_TILE_SIZE < 1) begin
            $fatal(
                1,
                "K_TILE_SIZE must be >= 1"
            );
        end


        if (TILE_COUNT_WIDTH < 1) begin
            $fatal(
                1,
                "TILE_COUNT_WIDTH must be >= 1"
            );
        end

    end

endmodule
