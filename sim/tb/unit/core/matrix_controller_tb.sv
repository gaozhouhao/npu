`timescale 1ns/1ps

module matrix_controller_tb;
    localparam int DEPTH = 256;
    logic clk = 0;
    logic reset, start, clear_acc, writeback_en;
    logic [8:0] tile_k_size;
    logic clear, read_en, feed_valid, c_wen, busy, done;
    logic [7:0] read_addr;
    logic [1:0] c_row;
    logic previous_read;
    integer requests, responses, writes, clears;

    matrix_controller dut (.*);
    always #5 clk = ~clk;

    // Check the request/response contract at sampling edges, before NBA updates.
    always @(posedge clk) begin
        if (reset) previous_read <= 0;
        else begin
            if (feed_valid !== previous_read)
                $fatal(1, "SRAM response valid is not delayed by one cycle");
            previous_read <= read_en;
            if (read_en) begin
                if (read_addr !== 8'(requests))
                    $fatal(1, "K request address %0d expected %0d", read_addr, requests);
                requests++;
            end
            if (feed_valid) responses++;
            if (clear) clears++;
            if (c_wen) begin
                if (c_row !== 2'(writes)) $fatal(1, "Wrong writeback row");
                writes++;
            end
        end
    end

    task automatic run_case(input int k_size, input bit do_clear, do_writeback);
        bit legal_k;
        legal_k = k_size > 0 && k_size <= DEPTH;
        @(negedge clk);
        requests = 0; responses = 0; writes = 0; clears = 0;
        tile_k_size = 9'(k_size);
        clear_acc = do_clear; writeback_en = do_writeback; start = 1;
        @(negedge clk);
        start = 0;
        wait (done === 1'b1);
        #1;
        if (busy !== 1'b1) $fatal(1, "busy must remain high during DONE");
        if (requests != (legal_k ? k_size : 0) || responses != requests ||
            writes != ((legal_k && do_writeback) ? 4 : 0) ||
            clears != ((legal_k && do_clear) ? 1 : 0))
            $fatal(1, "K=%0d counts req/rsp/wb/clear=%0d/%0d/%0d/%0d",
                   k_size, requests, responses, writes, clears);
        @(posedge clk);
        #1;
        if (done !== 1'b0 || busy !== 1'b0) $fatal(1, "DONE must return to IDLE");
        $display("CONTROLLER_CASE K=%0d clear=%0b wb=%0b requests=%0d responses=%0d writes=%0d",
                 k_size, do_clear, do_writeback, requests, responses, writes);
    endtask

    initial begin
        reset = 1; start = 0; tile_k_size = 0; clear_acc = 0; writeback_en = 0;
        requests = 0; responses = 0; writes = 0; clears = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 0;
        run_case(3, 1, 0);
        run_case(3, 0, 1);
        run_case(1, 1, 1);
        run_case(DEPTH, 1, 1);
        run_case(0, 1, 1);
        run_case(DEPTH+1, 1, 1);
        $display("TEST_PASS matrix_controller_tb");
        $finish;
    end
    initial begin
        #20000;
        $fatal(1, "matrix controller timeout");
    end
endmodule
