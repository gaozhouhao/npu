`timescale 1ns/1ps

module buffer_manager_tb;

    logic clk;

    // ============================================================
    // Single-buffer DUT
    // ============================================================

    logic s_reset;

    logic s_load_req;
    logic s_load_grant;
    logic s_load_bank;
    logic s_load_done;

    logic s_compute_req;
    logic s_compute_grant;
    logic s_compute_bank;
    logic s_compute_done;
    logic s_release_bank;


    // ============================================================
    // Double-buffer DUT
    // ============================================================

    logic d_reset;

    logic d_load_req;
    logic d_load_grant;
    logic d_load_bank;
    logic d_load_done;

    logic d_compute_req;
    logic d_compute_grant;
    logic d_compute_bank;
    logic d_compute_done;
    logic d_release_bank;


    // ============================================================
    // DUT: single buffer
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (1)
    ) dut_single (
        .clk           (clk),
        .reset         (s_reset),

        .load_req      (s_load_req),
        .load_grant    (s_load_grant),
        .load_bank     (s_load_bank),
        .load_done     (s_load_done),

        .compute_req   (s_compute_req),
        .compute_grant (s_compute_grant),
        .compute_bank  (s_compute_bank),

        .compute_done  (s_compute_done),
        .release_bank  (s_release_bank)
    );


    // ============================================================
    // DUT: double buffer
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (2)
    ) dut_double (
        .clk           (clk),
        .reset         (d_reset),

        .load_req      (d_load_req),
        .load_grant    (d_load_grant),
        .load_bank     (d_load_bank),
        .load_done     (d_load_done),

        .compute_req   (d_compute_req),
        .compute_grant (d_compute_grant),
        .compute_bank  (d_compute_bank),

        .compute_done  (d_compute_done),
        .release_bank  (d_release_bank)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // Init
        // --------------------------------------------------------

        s_reset = 1'b1;

        s_load_req     = 1'b0;
        s_load_done    = 1'b0;
        s_compute_req  = 1'b0;
        s_compute_done = 1'b0;
        s_release_bank      = 1'b1;


        d_reset = 1'b1;

        d_load_req     = 1'b0;
        d_load_done    = 1'b0;
        d_compute_req  = 1'b0;
        d_compute_done = 1'b0;
        d_release_bank         = 1'b1;


        // ========================================================
        // SINGLE BUFFER TEST
        // ========================================================

        repeat (3) @(posedge clk);

        @(negedge clk);
        s_reset = 1'b0;

        #1;

        assert (s_load_grant == 1'b0)
            else $fatal(1, "single: unexpected load_grant");

        assert (s_compute_grant == 1'b0)
            else $fatal(1, "single: unexpected compute_grant");

        assert (s_load_bank == 1'b0)
            else $fatal(1, "single: load_bank must be 0");

        assert (s_compute_bank == 1'b0)
            else $fatal(1, "single: compute_bank must be 0");


        // --------------------------------------------------------
        // Load tile into bank0
        // --------------------------------------------------------

        @(negedge clk);

        s_load_req = 1'b1;

        #1;

        assert (s_load_grant == 1'b1)
            else $fatal(1, "single: load request not granted");

        assert (s_load_bank == 1'b0)
            else $fatal(1, "single: wrong load bank");


        @(posedge clk);
        #1;

        @(negedge clk);

        s_load_req    = 1'b0;
        s_compute_req = 1'b1;

        #1;

        // Bank0 is LOADING, therefore compute cannot start.
        assert (s_compute_grant == 1'b0)
            else $fatal(
                1,
                "single: compute started while bank was loading"
            );


        // --------------------------------------------------------
        // Finish loading -> READY
        // --------------------------------------------------------

        @(negedge clk);

        s_compute_req = 1'b0;
        s_load_done   = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);

        s_load_done   = 1'b0;
        s_compute_req = 1'b1;

        #1;

        assert (s_compute_grant == 1'b1)
            else $fatal(1, "single: READY bank not granted");

        assert (s_compute_bank == 1'b0)
            else $fatal(1, "single: wrong compute bank");


        // --------------------------------------------------------
        // Start computing
        // --------------------------------------------------------

        @(posedge clk);
        #1;

        @(negedge clk);

        s_compute_req = 1'b0;
        s_load_req    = 1'b1;

        #1;

        // Single buffer is COMPUTING, so there is no EMPTY bank.
        assert (s_load_grant == 1'b0)
            else $fatal(
                1,
                "single: load overlapped with compute"
            );


        // --------------------------------------------------------
        // Finish compute but KEEP tile for reuse
        // --------------------------------------------------------

        @(negedge clk);

        s_load_req     = 1'b0;
        s_compute_done = 1'b1;
        s_release_bank      = 1'b0;

        @(posedge clk);
        #1;

        @(negedge clk);

        s_compute_done = 1'b0;
        s_compute_req  = 1'b1;

        #1;

        // release_bank=0 means COMPUTING -> READY
        assert (s_compute_grant == 1'b1)
            else $fatal(
                1,
                "single: retained tile was not reusable"
            );

        assert (s_compute_bank == 1'b0)
            else $fatal(
                1,
                "single: retained tile changed bank"
            );


        // --------------------------------------------------------
        // Compute again, then release tile
        // --------------------------------------------------------

        @(posedge clk);
        #1;

        @(negedge clk);

        s_compute_req  = 1'b0;
        s_compute_done = 1'b1;
        s_release_bank      = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);

        s_compute_done = 1'b0;
        s_load_req     = 1'b1;

        #1;

        // Bank should now be EMPTY again.
        assert (s_load_grant == 1'b1)
            else $fatal(
                1,
                "single: released bank did not become EMPTY"
            );

        assert (s_load_bank == 1'b0)
            else $fatal(
                1,
                "single: released bank should be bank0"
            );

        s_load_req = 1'b0;

        $display("Single-buffer test: PASS");


        // ========================================================
        // DOUBLE BUFFER TEST
        // ========================================================

        repeat (2) @(posedge clk);

        @(negedge clk);
        d_reset = 1'b0;


        // --------------------------------------------------------
        // First tile -> bank0
        // --------------------------------------------------------

        @(negedge clk);

        d_load_req = 1'b1;

        #1;

        assert (d_load_grant == 1'b1)
            else $fatal(
                1,
                "double: first load not granted"
            );

        assert (d_load_bank == 1'b0)
            else $fatal(
                1,
                "double: first load should select bank0"
            );


        @(posedge clk);
        #1;

        @(negedge clk);

        d_load_req  = 1'b0;
        d_load_done = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);

        d_load_done   = 1'b0;

        // --------------------------------------------------------
        // bank0 READY
        //
        // Start:
        // bank0 -> COMPUTE
        // bank1 -> LOAD
        //
        // simultaneously.
        // --------------------------------------------------------

        d_compute_req = 1'b1;
        d_load_req    = 1'b1;

        #1;

        assert (d_compute_grant == 1'b1)
            else $fatal(
                1,
                "double: compute bank not granted"
            );

        assert (d_compute_bank == 1'b0)
            else $fatal(
                1,
                "double: expected compute bank0"
            );

        assert (d_load_grant == 1'b1)
            else $fatal(
                1,
                "double: second bank not available for loading"
            );

        assert (d_load_bank == 1'b1)
            else $fatal(
                1,
                "double: expected load bank1"
            );


        @(posedge clk);
        #1;

        @(negedge clk);

        d_compute_req = 1'b0;
        d_load_req    = 1'b0;

        #1;

        // Bank selections must remain stable while operations active.
        assert (d_compute_bank == 1'b0)
            else $fatal(
                1,
                "double: compute bank changed while active"
            );

        assert (d_load_bank == 1'b1)
            else $fatal(
                1,
                "double: load bank changed while active"
            );


        // --------------------------------------------------------
        // Finish loading bank1 first.
        //
        // bank0 = COMPUTING
        // bank1 = READY
        // --------------------------------------------------------

        @(negedge clk);

        d_load_done = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);

        d_load_done = 1'b0;


        // --------------------------------------------------------
        // Finish bank0 compute and release it.
        //
        // bank0 = EMPTY
        // bank1 = READY
        // --------------------------------------------------------

        d_compute_done = 1'b1;
        d_release_bank      = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);

        d_compute_done = 1'b0;


        // --------------------------------------------------------
        // Ping-pong:
        //
        // bank1 -> COMPUTE
        // bank0 -> LOAD
        // --------------------------------------------------------

        d_compute_req = 1'b1;
        d_load_req    = 1'b1;

        #1;

        assert (d_compute_grant == 1'b1)
            else $fatal(
                1,
                "double: bank1 not available for compute"
            );

        assert (d_compute_bank == 1'b1)
            else $fatal(
                1,
                "double: expected compute bank1"
            );

        assert (d_load_grant == 1'b1)
            else $fatal(
                1,
                "double: bank0 not available for new load"
            );

        assert (d_load_bank == 1'b0)
            else $fatal(
                1,
                "double: expected new load into bank0"
            );


        @(posedge clk);
        #1;

        @(negedge clk);

        d_compute_req = 1'b0;
        d_load_req    = 1'b0;

        // Complete both active operations.
        d_compute_done = 1'b1;
        d_load_done    = 1'b1;
        d_release_bank      = 1'b1;

        @(posedge clk);
        #1;

        d_compute_done = 1'b0;
        d_load_done    = 1'b0;


        $display("Double-buffer ping-pong test: PASS");

        $display("");
        $display("========================================");
        $display("BUFFER MANAGER TEST PASSED");
        $display("========================================");
        $display("");

        #20;
        $finish;

    end


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        #20000;

        $fatal(
            1,
            "Timeout: buffer_manager test did not finish"
        );

    end


    // ============================================================
    // Waveform
    // ============================================================

    initial begin

        $dumpfile("buffer_manager_tb.vcd");
        $dumpvars(0, buffer_manager_tb);

    end

endmodule
