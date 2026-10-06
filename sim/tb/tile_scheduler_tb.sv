module tile_scheduler_tb;

    localparam int unsigned TILE_COUNT_WIDTH = 4;
    localparam int unsigned K_TILE_SIZE      = 256;
    localparam int unsigned K_SIZE_WIDTH     = $clog2(K_TILE_SIZE + 1);

    typedef logic [TILE_COUNT_WIDTH-1:0] tile_count_t;
    typedef logic [K_SIZE_WIDTH-1:0]     k_size_t;


    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic reset;


    // ============================================================
    // GEMM command
    // ============================================================

    logic start;

    tile_count_t m_tile_count;
    tile_count_t n_tile_count;
    tile_count_t k_tile_count;

    k_size_t last_k_size;


    // ============================================================
    // Loader interface
    // ============================================================

    logic a_load_req;
    logic a_load_accept;
    logic a_load_done;

    logic b_load_req;
    logic b_load_accept;
    logic b_load_done;


    // ============================================================
    // Buffer manager interface
    // ============================================================

    logic a_compute_req;
    logic a_compute_grant;
    logic a_compute_done;
    logic a_release_bank;

    logic b_compute_req;
    logic b_compute_grant;
    logic b_compute_done;
    logic b_release_bank;


    // ============================================================
    // Matrix controller interface
    // ============================================================

    logic matrix_start;
    logic matrix_done;

    logic clear_acc;
    logic writeback_en;

    k_size_t current_k_size;


    // ============================================================
    // Tile coordinates
    // ============================================================

    tile_count_t m_tile_idx;
    tile_count_t n_tile_idx;
    tile_count_t k_tile_idx;


    // ============================================================
    // Status
    // ============================================================

    logic busy;
    logic done;


    // ============================================================
    // Loop variables
    // ============================================================

    integer m_i;
    integer n_i;
    integer k_i;


    // ============================================================
    // DUT
    // ============================================================

    tile_scheduler #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),
        .K_TILE_SIZE      (K_TILE_SIZE),
        .K_SIZE_WIDTH     (K_SIZE_WIDTH)
    ) dut (
        .clk             (clk),
        .reset           (reset),

        .start           (start),

        .m_tile_count    (m_tile_count),
        .n_tile_count    (n_tile_count),
        .k_tile_count    (k_tile_count),

        .last_k_size     (last_k_size),

        .a_load_req      (a_load_req),
        .a_load_accept   (a_load_accept),
        .a_load_done     (a_load_done),

        .b_load_req      (b_load_req),
        .b_load_accept   (b_load_accept),
        .b_load_done     (b_load_done),

        .a_compute_req   (a_compute_req),
        .a_compute_grant (a_compute_grant),
        .a_compute_done  (a_compute_done),
        .a_release_bank  (a_release_bank),

        .b_compute_req   (b_compute_req),
        .b_compute_grant (b_compute_grant),
        .b_compute_done  (b_compute_done),
        .b_release_bank  (b_release_bank),

        .matrix_start    (matrix_start),
        .matrix_done     (matrix_done),

        .clear_acc       (clear_acc),
        .writeback_en    (writeback_en),

        .current_k_size  (current_k_size),

        .m_tile_idx      (m_tile_idx),
        .n_tile_idx      (n_tile_idx),
        .k_tile_idx      (k_tile_idx),

        .busy            (busy),
        .done            (done)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    // ============================================================
    // Clear all driven response signals
    // ============================================================

    task automatic clear_drivers;
        begin

            start = 1'b0;

            a_load_accept = 1'b0;
            a_load_done   = 1'b0;

            b_load_accept = 1'b0;
            b_load_done   = 1'b0;

            a_compute_grant = 1'b0;
            b_compute_grant = 1'b0;

            matrix_done = 1'b0;

        end
    endtask


    // ============================================================
    // Reset DUT
    // ============================================================

    task automatic reset_dut;
        begin

            clear_drivers();

            m_tile_count = '0;
            n_tile_count = '0;
            k_tile_count = '0;
            last_k_size  = '0;

            reset = 1'b1;

            repeat (3) begin
                @(posedge clk);
            end

            @(negedge clk);
            reset = 1'b0;

            @(posedge clk);
            #1;

            if (busy !== 1'b0) begin
                $fatal(1, "busy must be 0 after reset");
            end

            if (done !== 1'b0) begin
                $fatal(1, "done must be 0 after reset");
            end

        end
    endtask


    // ============================================================
    // Start one complete GEMM
    // ============================================================

    task automatic start_gemm(
        input tile_count_t m_count,
        input tile_count_t n_count,
        input tile_count_t k_count,
        input k_size_t     final_k_size
    );
        begin

            @(negedge clk);

            m_tile_count = m_count;
            n_tile_count = n_count;
            k_tile_count = k_count;
            last_k_size  = final_k_size;

            start = 1'b1;

            @(negedge clk);

            start = 1'b0;

        end
    endtask


    // ============================================================
    // Service and verify one (m,n,k) local GEMM
    //
    // Intentionally stagger A and B responses.
    // This verifies that the scheduler correctly remembers
    // independently completed handshakes.
    // ============================================================

    task automatic service_tile(
        input tile_count_t exp_m,
        input tile_count_t exp_n,
        input tile_count_t exp_k,
        input logic        exp_clear,
        input logic        exp_writeback,
        input k_size_t     exp_k_size
    );
        begin

            // ----------------------------------------------------
            // Wait for load requests.
            // ----------------------------------------------------

            wait (a_load_req === 1'b1);

            #1;

            if (
                (m_tile_idx !== exp_m) ||
                (n_tile_idx !== exp_n) ||
                (k_tile_idx !== exp_k)
            ) begin
                $fatal(
                    1,
                    "Wrong tile during load: got (%0d,%0d,%0d), expected (%0d,%0d,%0d)",
                    m_tile_idx,
                    n_tile_idx,
                    k_tile_idx,
                    exp_m,
                    exp_n,
                    exp_k
                );
            end

            if (busy !== 1'b1) begin
                $fatal(1, "Scheduler must be busy while processing a tile");
            end


            // Accept A first.

            @(negedge clk);
            a_load_accept = 1'b1;

            @(negedge clk);
            a_load_accept = 1'b0;


            // B is deliberately accepted later.

            wait (b_load_req === 1'b1);

            @(negedge clk);
            b_load_accept = 1'b1;

            @(negedge clk);
            b_load_accept = 1'b0;


            // ----------------------------------------------------
            // Simulate load completion.
            //
            // A and B finish at different times.
            // ----------------------------------------------------

            @(negedge clk);
            a_load_done = 1'b1;

            @(negedge clk);
            a_load_done = 1'b0;

            @(negedge clk);
            b_load_done = 1'b1;

            @(negedge clk);
            b_load_done = 1'b0;


            // ----------------------------------------------------
            // Acquire compute banks.
            // ----------------------------------------------------

            wait (a_compute_req === 1'b1);

            @(negedge clk);
            a_compute_grant = 1'b1;

            @(negedge clk);
            a_compute_grant = 1'b0;


            wait (b_compute_req === 1'b1);

            @(negedge clk);
            b_compute_grant = 1'b1;

            @(negedge clk);
            b_compute_grant = 1'b0;


            // ----------------------------------------------------
            // Matrix launch.
            // ----------------------------------------------------

            wait (matrix_start === 1'b1);

            #1;

            if (
                (m_tile_idx !== exp_m) ||
                (n_tile_idx !== exp_n) ||
                (k_tile_idx !== exp_k)
            ) begin
                $fatal(
                    1,
                    "Wrong tile during launch: got (%0d,%0d,%0d), expected (%0d,%0d,%0d)",
                    m_tile_idx,
                    n_tile_idx,
                    k_tile_idx,
                    exp_m,
                    exp_n,
                    exp_k
                );
            end

            if (clear_acc !== exp_clear) begin
                $fatal(
                    1,
                    "clear_acc wrong at (%0d,%0d,%0d)",
                    exp_m,
                    exp_n,
                    exp_k
                );
            end

            if (writeback_en !== exp_writeback) begin
                $fatal(
                    1,
                    "writeback_en wrong at (%0d,%0d,%0d)",
                    exp_m,
                    exp_n,
                    exp_k
                );
            end

            if (current_k_size !== exp_k_size) begin
                $fatal(
                    1,
                    "current_k_size wrong at (%0d,%0d,%0d): got %0d expected %0d",
                    exp_m,
                    exp_n,
                    exp_k,
                    current_k_size,
                    exp_k_size
                );
            end

            if (
                (a_release_bank !== 1'b1) ||
                (b_release_bank !== 1'b1)
            ) begin
                $fatal(
                    1,
                    "Phase-1 scheduler must release both operand banks"
                );
            end

            if (done !== 1'b0) begin
                $fatal(1, "done asserted before entire GEMM completed");
            end


            // ----------------------------------------------------
            // Simulate matrix computation completion.
            // ----------------------------------------------------

            @(negedge clk);
            matrix_done = 1'b1;

            #1;

            if (
                (a_compute_done !== 1'b1) ||
                (b_compute_done !== 1'b1)
            ) begin
                $fatal(
                    1,
                    "Buffer compute_done signals missing"
                );
            end

            @(negedge clk);
            matrix_done = 1'b0;

        end
    endtask


    // ============================================================
    // Verify final scheduler done pulse
    // ============================================================

    task automatic finish_gemm;
        begin

            wait (done === 1'b1);

            #1;

            if (busy !== 1'b0) begin
                $fatal(1, "busy must be 0 in DONE state");
            end

            @(posedge clk);
            #1;

            if (done !== 1'b0) begin
                $fatal(1, "done must be a one-cycle pulse");
            end

        end
    endtask


    // ============================================================
    // Test sequence
    // ============================================================

    initial begin

        reset = 1'b1;

        clear_drivers();

        m_tile_count = '0;
        n_tile_count = '0;
        k_tile_count = '0;
        last_k_size  = '0;


        // ========================================================
        // TEST 1
        //
        // M tiles = 2
        // N tiles = 2
        // K tiles = 3
        //
        // K:
        // 256 + 256 + 16
        //
        // Expected total local GEMMs:
        // 2 * 2 * 3 = 12
        // ========================================================

        $display("TEST 1: 2x2x3 tiling with K remainder");

        reset_dut();

        start_gemm(
            tile_count_t'(2),
            tile_count_t'(2),
            tile_count_t'(3),
            k_size_t'(16)
        );

        for (m_i = 0; m_i < 2; m_i = m_i + 1) begin

            for (n_i = 0; n_i < 2; n_i = n_i + 1) begin

                for (k_i = 0; k_i < 3; k_i = k_i + 1) begin

                    service_tile(
                        tile_count_t'(m_i),
                        tile_count_t'(n_i),
                        tile_count_t'(k_i),

                        (k_i == 0),
                        (k_i == 2),

                        (k_i == 2)
                            ? k_size_t'(16)
                            : k_size_t'(K_TILE_SIZE)
                    );

                end

            end

        end

        finish_gemm();


        // ========================================================
        // TEST 2
        //
        // Single tile in every dimension.
        //
        // The same K tile must be BOTH first and last:
        //
        // clear_acc    = 1
        // writeback_en = 1
        // ========================================================

        $display("TEST 2: 1x1x1 boundary case");

        reset_dut();

        start_gemm(
            tile_count_t'(1),
            tile_count_t'(1),
            tile_count_t'(1),
            k_size_t'(16)
        );

        service_tile(
            tile_count_t'(0),
            tile_count_t'(0),
            tile_count_t'(0),
            1'b1,
            1'b1,
            k_size_t'(16)
        );

        finish_gemm();


        // ========================================================
        // TEST 3
        //
        // K exactly divisible by K_TILE_SIZE:
        //
        // K = 512
        // = 256 + 256
        //
        // Final K size must be 256, NOT 0.
        // ========================================================

        $display("TEST 3: exact K division");

        reset_dut();

        start_gemm(
            tile_count_t'(1),
            tile_count_t'(1),
            tile_count_t'(2),
            k_size_t'(K_TILE_SIZE)
        );

        service_tile(
            tile_count_t'(0),
            tile_count_t'(0),
            tile_count_t'(0),
            1'b1,
            1'b0,
            k_size_t'(K_TILE_SIZE)
        );

        service_tile(
            tile_count_t'(0),
            tile_count_t'(0),
            tile_count_t'(1),
            1'b0,
            1'b1,
            k_size_t'(K_TILE_SIZE)
        );

        finish_gemm();


        // ========================================================
        // PASS
        // ========================================================

        $display("All tile_scheduler tests passed.");

        $finish;

    end

endmodule
