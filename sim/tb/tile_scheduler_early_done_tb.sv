
`timescale 1ns/1ps

module tile_scheduler_early_done_tb;

    localparam int unsigned W = 8;
    localparam int unsigned K_TILE_SIZE = 16;
    localparam int unsigned KW = $clog2(K_TILE_SIZE + 1);

    logic clk;
    logic reset;
    logic start;

    logic a_load_req;
    logic a_load_accept;
    logic a_load_done;

    logic b_load_req;
    logic b_load_accept;
    logic b_load_done;

    logic [W-1:0] load_m;
    logic [W-1:0] load_n;
    logic [W-1:0] load_k;
    logic [KW-1:0] load_k_size;

    logic a_compute_req;
    logic a_compute_grant;
    logic a_compute_done;
    logic a_release_bank;

    logic b_compute_req;
    logic b_compute_grant;
    logic b_compute_done;
    logic b_release_bank;

    logic matrix_start;
    logic matrix_done;
    logic writeback_done;

    logic clear_acc;
    logic writeback_en;
    logic [KW-1:0] compute_k_size;

    logic [W-1:0] compute_m;
    logic [W-1:0] compute_n;

    logic busy;
    logic done;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    tile_scheduler #(
        .TILE_COUNT_WIDTH (W),
        .K_TILE_SIZE      (K_TILE_SIZE),
        .K_SIZE_WIDTH     (KW)
    ) dut (
        .clk (clk),
        .reset (reset),
        .start (start),

        .m_tile_count (W'(1)),
        .n_tile_count (W'(1)),
        .k_tile_count (W'(1)),
        .last_k_size  (KW'(7)),

        .a_load_req    (a_load_req),
        .a_load_accept (a_load_accept),
        .a_load_done   (a_load_done),

        .b_load_req    (b_load_req),
        .b_load_accept (b_load_accept),
        .b_load_done   (b_load_done),

        .load_m_tile_idx (load_m),
        .load_n_tile_idx (load_n),
        .load_k_tile_idx (load_k),
        .load_k_size     (load_k_size),

        .a_compute_req   (a_compute_req),
        .a_compute_grant (a_compute_grant),
        .a_compute_done  (a_compute_done),
        .a_release_bank  (a_release_bank),

        .b_compute_req   (b_compute_req),
        .b_compute_grant (b_compute_grant),
        .b_compute_done  (b_compute_done),
        .b_release_bank  (b_release_bank),

        .matrix_start   (matrix_start),
        .matrix_done    (matrix_done),
        .writeback_done (writeback_done),

        .clear_acc      (clear_acc),
        .writeback_en   (writeback_en),
        .compute_k_size (compute_k_size),

        .compute_m_tile_idx (compute_m),
        .compute_n_tile_idx (compute_n),

        .busy (busy),
        .done (done)
    );

    initial begin
        #5000;
        $fatal(1, "Scheduler early-done test TIMEOUT");
    end

    initial begin
        reset = 1'b1;
        start = 1'b0;

        a_load_accept = 1'b0;
        a_load_done = 1'b0;
        b_load_accept = 1'b0;
        b_load_done = 1'b0;

        a_compute_grant = 1'b0;
        b_compute_grant = 1'b0;

        matrix_done = 1'b0;
        writeback_done = 1'b0;

        repeat (4) @(negedge clk);
        reset = 1'b0;

        @(negedge clk);
        start = 1'b1;

        @(negedge clk);
        start = 1'b0;

        wait (a_load_req && b_load_req);

        if (!busy)
            $fatal(1, "Scheduler should be busy");

        if (
            (load_m != '0) ||
            (load_n != '0) ||
            (load_k != '0) ||
            (load_k_size != KW'(7))
        )
            $fatal(1, "Invalid load tile");

        // A is accepted immediately.
        @(negedge clk);
        a_load_accept = 1'b1;

        @(negedge clk);
        a_load_accept = 1'b0;

        // A finishes while B has NOT been accepted.
        @(negedge clk);
        a_load_done = 1'b1;

        @(negedge clk);
        a_load_done = 1'b0;

        if (!b_load_req)
            $fatal(1, "Expected B to remain pending");

        $display("A completed before B was accepted");

        repeat (4) @(negedge clk);

        // B can finally begin loading.
        b_load_accept = 1'b1;

        @(negedge clk);
        b_load_accept = 1'b0;

        repeat (3) @(negedge clk);

        // B finishes after LD_WAIT has started.
        b_load_done = 1'b1;

        @(negedge clk);
        b_load_done = 1'b0;

        // Without the fix this wait never finishes.
        wait (a_compute_req && b_compute_req);

        $display("Scheduler preserved early A completion");

        @(negedge clk);
        a_compute_grant = 1'b1;
        b_compute_grant = 1'b1;

        @(negedge clk);
        a_compute_grant = 1'b0;
        b_compute_grant = 1'b0;

        wait (matrix_start);

        if (
            !clear_acc ||
            !writeback_en ||
            (compute_k_size != KW'(7)) ||
            (compute_m != '0) ||
            (compute_n != '0)
        )
            $fatal(1, "Invalid matrix control");

        repeat (3) @(negedge clk);

        matrix_done = 1'b1;

        #1;
        if (
            !a_compute_done ||
            !b_compute_done ||
            !a_release_bank ||
            !b_release_bank
        )
            $fatal(1, "Invalid compute completion");

        @(negedge clk);
        matrix_done = 1'b0;

        repeat (3) @(negedge clk);

        writeback_done = 1'b1;

        @(negedge clk);
        writeback_done = 1'b0;

        wait (done);

        $display("EARLY DMA DONE REGRESSION PASS");
        $finish;
    end

endmodule
