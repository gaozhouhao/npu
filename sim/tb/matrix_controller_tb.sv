`timescale 1ns/1ps

module matrix_controller_tb;

    localparam int ROWS    = 4;
    localparam int COLS    = 4;
    localparam int K_WIDTH = 16;

    logic clk;
    logic reset;

    logic start;
    logic [K_WIDTH-1:0] k_size;

    logic clear;
    logic feed_valid;
    logic [K_WIDTH-1:0] k_index;
    logic busy;
    logic done;


    matrix_controller #(
        .ROWS    (ROWS),
        .COLS    (COLS),
        .K_WIDTH (K_WIDTH)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .start      (start),
        .k_size     (k_size),
        .clear      (clear),
        .feed_valid (feed_valid),
        .k_index    (k_index),
        .busy       (busy),
        .done       (done)
    );


    always #5 clk = ~clk;


    initial begin
        clk    = 0;
        reset  = 1;
        start  = 0;
        k_size = 3;

        // Reset
        repeat (2) @(posedge clk);
        reset = 0;

        // Start one tile
        @(negedge clk);
        start = 1;

        @(negedge clk);
        start = 0;


        // Wait for CLEAR
        wait (clear == 1);

        if (!busy)
            $fatal(1, "busy should be high during CLEAR");


        // Wait for FEED
        @(negedge clk);

        if (!feed_valid)
            $fatal(1, "feed_valid should be high");

        if (k_index != 0)
            $fatal(1, "Expected k_index=0, got %0d", k_index);


        @(negedge clk);

        if (!feed_valid || k_index != 1)
            $fatal(1, "Expected FEED k_index=1");


        @(negedge clk);

        if (!feed_valid || k_index != 2)
            $fatal(1, "Expected FEED k_index=2");


        // FEED should now finish
        @(negedge clk);

        if (feed_valid)
            $fatal(1, "feed_valid should be low during DRAIN");


        // Wait for completion
        wait (done == 1);

        if (!busy)
            $fatal(1, "busy should remain high during DONE");

        

        @(posedge clk);
        @(negedge clk);

        if (done)
            $fatal(1, "done should only stay high for one cycle");

        if (busy)
            $fatal(1, "busy should be low after returning to IDLE");


        $display("All tests passed.");
        $finish;
    end

endmodule