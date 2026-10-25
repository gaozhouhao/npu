// FIFO scoreboard checks accepted words against bus transactions, not FIFO state.
// A held response must leave all queued slots available to the producer.
module pool_result_dma_tb;
    parameter int unsigned FIFO_DEPTH = 3;
    parameter logic [31:0] DATA_SEED = 32'h91c7_3ea5;
    localparam int MAX_WORDS = 4096;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1, clear = 0;
    logic in_valid = 0, in_ready, busy, error;
    logic [63:0] in_addr = 0;
    logic [31:0] in_data = 0;
    logic m_axi_awid, m_axi_awvalid, m_axi_awready;
    logic [63:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic [31:0] m_axi_wdata;
    logic [3:0] m_axi_wstrb;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic m_axi_bid = 0, m_axi_bvalid = 0, m_axi_bready;
    logic [1:0] m_axi_bresp = 0;
    logic response_hold = 0;
    int response_latency = 5;
    int error_response_index = -1;
    int bad_id_response_index = -1;

    logic [63:0] expected_addr [MAX_WORDS];
    logic [31:0] expected_data [MAX_WORDS];
    int accepted_count = 0, aw_count = 0, w_count = 0, b_count = 0;
    int cycle_count = 0, total_cycles = 0, next_word = 1;
    int total_accepted = 0, total_responses = 0, reset_discarded = 0;
    int aw_stall_cycles = 0, w_stall_cycles = 0, input_stall_cycles = 0;
    int full_turnovers = 0, delayed_response_enqueues = 0;
    int response_delay = 0;
    bit outstanding = 0, response_pending = 0;
    bit aw_stalled = 0, w_stalled = 0;
    logic held_awid;
    logic [63:0] held_awaddr;
    logic [7:0] held_awlen;
    logic [2:0] held_awsize;
    logic [1:0] held_awburst;
    logic [31:0] held_wdata;
    logic [3:0] held_wstrb;
    logic held_wlast;

    // Different periodic stalls exercise independent AXI address/data channels.
    assign m_axi_awready = !reset && cycle_count % 7 >= 3;
    assign m_axi_wready = !reset && cycle_count % 6 >= 4;

    pool_result_dma #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk(clk), .reset(reset), .clear(clear),
        .in_valid(in_valid), .in_ready(in_ready), .in_addr(in_addr), .in_data(in_data),
        .busy(busy), .error(error),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    function automatic logic [63:0] word_address(input int word_id);
        // High address bits and a permuted, noncontiguous sequence catch truncation
        // and any assumption that consecutive results have consecutive addresses.
        return 64'hc57a_8e31_0000_0ffc +
            64'((word_id * 73) % 257) * 64'd4 +
            64'(word_id % 7) * 64'h10000;
    endfunction

    function automatic logic [31:0] word_data(input int word_id);
        return DATA_SEED ^ (32'(word_id) * 32'h7f4a_7c15) ^
            {16'(word_id * 19), 16'(word_id * 37 + 11)};
    endfunction

    always @(posedge clk) begin : scoreboard_and_slave
        total_cycles = total_cycles + 1;
        if (total_cycles > 200000)
            $fatal(1, "Pool DMA global timeout");
        if (reset) begin
            cycle_count <= 0;
            reset_discarded = reset_discarded + accepted_count - b_count;
            accepted_count = 0; aw_count = 0; w_count = 0; b_count = 0;
            outstanding = 0; response_pending = 0; response_delay = 0;
            aw_stalled = 0; w_stalled = 0;
            m_axi_bvalid <= 0; m_axi_bresp <= 0; m_axi_bid <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            // The final B response is part of the outstanding work, even after W.
            if (accepted_count > b_count && !busy)
                $fatal(1, "busy fell before every accepted word received B");
            if (aw_stalled && (!m_axi_awvalid || m_axi_awid !== held_awid ||
                m_axi_awaddr !== held_awaddr || m_axi_awlen !== held_awlen ||
                m_axi_awsize !== held_awsize || m_axi_awburst !== held_awburst))
                $fatal(1, "AW payload changed while backpressured");
            if (w_stalled && (!m_axi_wvalid || m_axi_wdata !== held_wdata ||
                m_axi_wstrb !== held_wstrb || m_axi_wlast !== held_wlast))
                $fatal(1, "W payload changed while backpressured");
            aw_stalled = m_axi_awvalid && !m_axi_awready;
            w_stalled = m_axi_wvalid && !m_axi_wready;
            held_awid = m_axi_awid; held_awaddr = m_axi_awaddr;
            held_awlen = m_axi_awlen; held_awsize = m_axi_awsize;
            held_awburst = m_axi_awburst;
            held_wdata = m_axi_wdata; held_wstrb = m_axi_wstrb;
            held_wlast = m_axi_wlast;
            if (aw_stalled) aw_stall_cycles = aw_stall_cycles + 1;
            if (w_stalled) w_stall_cycles = w_stall_cycles + 1;
            if (in_valid && !in_ready) input_stall_cycles = input_stall_cycles + 1;

            if (in_valid && in_ready) begin
                if (accepted_count >= MAX_WORDS)
                    $fatal(1, "Scoreboard capacity exceeded");
                expected_addr[accepted_count] = in_addr;
                expected_data[accepted_count] = in_data;
                accepted_count = accepted_count + 1;
                total_accepted = total_accepted + 1;
                if (response_hold && response_pending)
                    delayed_response_enqueues = delayed_response_enqueues + 1;
                // Only coverage reads FIFO occupancy: all functional checks use
                // accepted input and AXI handshakes. Full acceptance proves the
                // same cycle dequeue/enqueue path was exercised at least once.
                if (int'(dut.count_q) == FIFO_DEPTH)
                    full_turnovers = full_turnovers + 1;
            end
            if (m_axi_awvalid && m_axi_awready) begin
                if (outstanding || aw_count >= accepted_count)
                    $fatal(1, "Unexpected/duplicate AW at transaction %0d", aw_count);
                if (m_axi_awaddr !== expected_addr[aw_count] || m_axi_awid !== 0 ||
                    m_axi_awlen !== 0 || m_axi_awsize !== 2 || m_axi_awburst !== 1)
                    $fatal(1, "AW mismatch transaction=%0d addr=%h expected=%h",
                        aw_count, m_axi_awaddr, expected_addr[aw_count]);
                outstanding = 1;
                aw_count = aw_count + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (!outstanding || response_pending || w_count >= aw_count)
                    $fatal(1, "Unexpected/duplicate W at transaction %0d", w_count);
                if (m_axi_wdata !== expected_data[w_count] ||
                    m_axi_wstrb !== 4'hf || m_axi_wlast !== 1)
                    $fatal(1, "W mismatch transaction=%0d data=%h expected=%h",
                        w_count, m_axi_wdata, expected_data[w_count]);
                w_count = w_count + 1;
                response_pending = 1;
                response_delay = response_latency;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (!outstanding || !response_pending || b_count >= w_count)
                    $fatal(1, "Unexpected/duplicate B at transaction %0d", b_count);
                b_count = b_count + 1;
                total_responses = total_responses + 1;
                outstanding = 0; response_pending = 0;
                m_axi_bvalid <= 0;
            end else if (response_pending && !m_axi_bvalid && !response_hold) begin
                if (response_delay == 0) begin
                    m_axi_bvalid <= 1;
                    m_axi_bresp <= b_count == error_response_index ? 2'b10 : 2'b00;
                    m_axi_bid <= b_count == bad_id_response_index;
                end else response_delay = response_delay - 1;
            end
        end
    end

    task automatic send_word;
        int waited;
        bit accepted;
        in_addr = word_address(next_word);
        in_data = word_data(next_word);
        in_valid = 1;
        waited = 0; accepted = 0;
        while (!accepted) begin
            @(posedge clk);
            accepted = in_ready;
            waited = waited + 1;
            if (waited > 10000) $fatal(1, "Producer timeout word=%0d", next_word);
        end
        @(negedge clk);
        in_valid = 0;
        next_word = next_word + 1;
    endtask

    task automatic wait_pending_response;
        int waited;
        waited = 0;
        while (!response_pending) begin
            @(negedge clk);
            waited = waited + 1;
            if (waited > 1000) $fatal(1, "No W transaction reached held B");
        end
    endtask

    task automatic drain;
        int waited;
        waited = 0;
        while (busy || b_count != accepted_count) begin
            @(negedge clk);
            waited = waited + 1;
            if (waited > 30000) $fatal(1, "Drain timeout accepted=%0d B=%0d",
                accepted_count, b_count);
        end
        repeat (4) @(negedge clk);
        if (accepted_count != aw_count || accepted_count != w_count ||
            accepted_count != b_count || m_axi_awvalid || m_axi_wvalid || m_axi_bvalid)
            $fatal(1, "Lost/duplicate transfer accepted/AW/W/B=%0d/%0d/%0d/%0d",
                accepted_count, aw_count, w_count, b_count);
    endtask

    task automatic clear_idle_error;
        if (busy) $fatal(1, "Test attempted busy clear");
        clear = 1;
        @(negedge clk);
        clear = 0;
        if (error || busy) $fatal(1, "Idle clear did not recover clean state");
    endtask

    initial begin : test
        int initial_accepted, initial_responses, waited;
        bit accepted;
        if (FIFO_DEPTH < 1 || FIFO_DEPTH > 128)
            $fatal(1, "Unsupported test FIFO_DEPTH=%0d", FIFO_DEPTH);
        repeat (4) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);
        if (busy || error || !in_ready) $fatal(1, "Bad idle state after reset");

        // Freeze the first B and fill every FIFO slot behind the active write.
        response_hold = 1;
        send_word();
        wait_pending_response();
        initial_accepted = accepted_count;
        initial_responses = b_count;
        repeat (FIFO_DEPTH) send_word();
        if (accepted_count != initial_accepted + FIFO_DEPTH || b_count != initial_responses)
            $fatal(1, "Delayed B prevented queuing all FIFO_DEPTH results");
        in_addr = word_address(next_word);
        in_data = word_data(next_word);
        in_valid = 1;
        repeat (12) begin
            @(posedge clk);
            if (in_ready || !busy) $fatal(1, "Full FIFO did not backpressure producer");
            @(negedge clk);
        end
        // Keep this blocked word valid through the full queue's first turnover.
        response_hold = 0;
        accepted = 0; waited = 0;
        while (!accepted) begin
            @(posedge clk);
            accepted = in_ready;
            waited = waited + 1;
            if (waited > 1000) $fatal(1, "Full FIFO did not recover after B");
        end
        @(negedge clk);
        in_valid = 0; next_word = next_word + 1;
        repeat (12 * FIFO_DEPTH + 37) send_word();
        drain();
        if (error) $fatal(1, "Unexpected error during backpressure/wrap test");
        if (full_turnovers == 0 || delayed_response_enqueues < FIFO_DEPTH ||
            aw_stall_cycles == 0 || w_stall_cycles == 0 || input_stall_cycles == 0)
            $fatal(1, "Missing full turnover, delayed B enqueue, or channel stall coverage");

        // A bus failure retires the transaction; its error stays sticky through
        // later successful writes until a new idle task clears it explicitly.
        error_response_index = b_count;
        send_word(); drain();
        if (!error) $fatal(1, "SLVERR did not set sticky error");
        error_response_index = -1;
        repeat (FIFO_DEPTH + 2) send_word();
        drain();
        if (!error) $fatal(1, "Successful writes cleared sticky SLVERR");
        clear_idle_error();
        repeat (FIFO_DEPTH + 3) send_word();
        drain();
        if (error) $fatal(1, "New task did not recover after clear");

        bad_id_response_index = b_count;
        send_word(); drain();
        if (!error) $fatal(1, "Incorrect BID did not set error");
        bad_id_response_index = -1;
        clear_idle_error();

        // Reset intentionally discards a withheld active write and queued words.
        // The slave model resets with the DUT; no stale response crosses epochs.
        response_hold = 1;
        send_word(); wait_pending_response();
        repeat (FIFO_DEPTH) send_word();
        reset = 1; in_valid = 0;
        repeat (3) @(negedge clk);
        response_hold = 0;
        reset = 0;
        repeat (5) @(negedge clk);
        if (busy || error || accepted_count != 0 || aw_count != 0 || w_count != 0)
            $fatal(1, "Reset failed to discard the interrupted task");
        repeat (FIFO_DEPTH + 5) send_word();
        drain();
        if (error) $fatal(1, "Clean transaction failed after reset discard");
        if (reset_discarded != FIFO_DEPTH + 1 ||
            total_accepted != total_responses + reset_discarded)
            $fatal(1, "Reset discard accounting mismatch accepted/B/discarded=%0d/%0d/%0d",
                total_accepted, total_responses, reset_discarded);
        $display("POOL_RESULT_DMA TEST PASS depth=%0d accepted=%0d responses=%0d reset_discarded=%0d held_B_enqueues=%0d full_turnovers=%0d AW_stalls=%0d W_stalls=%0d input_stalls=%0d",
            FIFO_DEPTH, total_accepted, total_responses, reset_discarded, delayed_response_enqueues,
            full_turnovers, aw_stall_cycles, w_stall_cycles, input_stall_cycles);
        $finish;
    end
endmodule
