`timescale 1ns/1ps

module stream_maxpool2x2_tb #(
    parameter int unsigned COLS = 8
);
    parameter int unsigned LINE_WORDS = 64*(COLS/4);
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset, start;
    logic [31:0] cfg_input_h, cfg_input_w, cfg_channels, cfg_pool_config;
    logic [63:0] cfg_output_base;
    logic in_valid, in_ready;
    logic [COLS*8-1:0] in_data;
    logic [31:0] in_spatial_index, in_channel_base;
    logic busy, error;
    logic [0:0] awid, bid;
    logic [63:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst, bresp;
    logic awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic [31:0] wdata;
    logic [3:0] wstrb;

    integer cycle_q, response_delay_q, writes_q;
    logic address_pending_q, response_pending_q;
    logic [63:0] address_q;
    logic previous_aw_stall_q, previous_w_stall_q;
    logic [63:0] previous_awaddr_q;
    logic [31:0] previous_wdata_q;
    integer test_h, test_w, test_channels, test_seed, expected_words;
    logic [31:0] expected [0:1023];
    logic seen [0:1023];

    stream_maxpool2x2 #(
        .COLS(COLS), .LINE_WORDS(LINE_WORDS)
    ) dut (.*,
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    assign awready = !address_pending_q && !response_pending_q &&
        (cycle_q % 3 != 0);
    assign wready = address_pending_q && (cycle_q % 4 == 1);
    assign bvalid = response_pending_q && response_delay_q == 0;
    assign bid = '0;
    assign bresp = 2'b00;

    always @(posedge clk) begin : memory_model
        integer word_index;
        if (reset) begin
            cycle_q <= 0;
            response_delay_q <= 0;
            writes_q <= 0;
            address_pending_q <= 1'b0;
            response_pending_q <= 1'b0;
            address_q <= 0;
            previous_aw_stall_q <= 1'b0;
            previous_w_stall_q <= 1'b0;
        end else begin
            cycle_q <= cycle_q + 1;
            if (previous_aw_stall_q &&
                (!awvalid || awaddr !== previous_awaddr_q))
                $fatal(1, "AW changed under backpressure");
            if (previous_w_stall_q &&
                (!wvalid || wdata !== previous_wdata_q))
                $fatal(1, "W changed under backpressure");
            previous_aw_stall_q <= awvalid && !awready;
            previous_w_stall_q <= wvalid && !wready;
            previous_awaddr_q <= awaddr;
            previous_wdata_q <= wdata;

            if (awvalid && awready) begin
                if (awid != 0 || awlen != 0 || awsize != 2 ||
                    awburst != 1 || awaddr[1:0] != 0)
                    $fatal(1, "Invalid output AXI address request");
                address_pending_q <= 1'b1;
                address_q <= awaddr;
            end
            if (wvalid && wready) begin
                if (!wlast || wstrb != 4'hf)
                    $fatal(1, "Invalid output AXI word");
                if (address_q < cfg_output_base ||
                    address_q >= cfg_output_base + expected_words*4)
                    $fatal(1, "Unexpected output address %h", address_q);
                word_index = (address_q - cfg_output_base) >> 2;
                if (seen[word_index])
                    $fatal(1, "Duplicate output word %0d", word_index);
                if (wdata !== expected[word_index])
                    $fatal(1, "Output %0d: got %h expected %h", word_index,
                        wdata, expected[word_index]);
                seen[word_index] = 1'b1;
                writes_q <= writes_q + 1;
                address_pending_q <= 1'b0;
                response_pending_q <= 1'b1;
                response_delay_q <= (word_index == expected_words-1) ? 37 : 2 + writes_q % 5;
            end
            if (response_pending_q && !busy)
                $fatal(1, "Busy dropped before write response completed");
            if (response_pending_q && response_delay_q > 0)
                response_delay_q <= response_delay_q - 1;
            if (bvalid && bready)
                response_pending_q <= 1'b0;
        end
    end

    function automatic integer sample(
        input integer y, x, channel, seed
    );
        if (seed == 1000)
            return -128 + (y*7 + x*3 + channel*11) % 64;
        return (y*37 + x*19 + channel*11 + seed*23) % 256 - 128;
    endfunction

    function automatic logic [31:0] pool_config(
        input integer kh, kw, sh, sw
    );
        return {8'(sw), 8'(sh), 8'(kw), 8'(kh)};
    endfunction

    task automatic configure(input integer height, width, channels,
                             input logic [31:0] pool,
                             input logic [63:0] base);
        @(negedge clk);
        while (busy) @(negedge clk);
        cfg_input_h = height;
        cfg_input_w = width;
        cfg_channels = channels;
        cfg_pool_config = pool;
        cfg_output_base = base;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        #1;
    endtask

    task automatic send_row(input integer spatial, channel);
        @(negedge clk);
        in_spatial_index = spatial;
        in_channel_base = channel;
        for (int lane = 0; lane < COLS; lane++)
            in_data[lane*8 +: 8] = 8'(sample(
                spatial/test_w, spatial%test_w, channel+lane, test_seed));
        in_valid = 1'b1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 1'b0;
        if (spatial % 3 == 0) repeat (2) @(negedge clk);
    endtask

    task automatic run_case(input integer h, width, channels, seed, ordering,
                            input integer kh, kw, sh, sw, legacy,
                            input logic [63:0] base);
        integer maximum, candidate, word_index, previous_writes, oh, ow;
        integer full_line_words, tile_line_words;
        test_h = h;
        test_w = width;
        test_channels = channels;
        test_seed = seed;
        oh = (h-kh)/sh+1;
        ow = (width-kw)/sw+1;
        full_line_words = kh*width*(channels/4);
        tile_line_words = kh*width*(COLS/4);
        expected_words = oh*ow*(channels/4);
        for (int index = 0; index < 1024; index++) begin
            expected[index] = 0;
            seen[index] = 1'b0;
        end
        for (int y = 0; y < oh; y++)
            for (int x = 0; x < ow; x++)
                for (int c = 0; c < channels; c++) begin
                    maximum = -128;
                    for (int dy = 0; dy < kh; dy++)
                        for (int dx = 0; dx < kw; dx++) begin
                            candidate = sample(sh*y+dy, sw*x+dx, c, seed);
                            if (candidate > maximum) maximum = candidate;
                        end
                    word_index = ((y*ow+x)*channels+c)/4;
                    expected[word_index][(c%4)*8 +: 8] = 8'(maximum);
                end
        previous_writes = writes_q;
        configure(h, width, channels,
            legacy ? 32'd0 : pool_config(kh, kw, sh, sw), base);
        if (error || !in_ready)
            $fatal(1, "Valid configuration was rejected");
        if (full_line_words > LINE_WORDS && ordering != 1)
            $fatal(1, "Capacity-limited pooling must use channel-major input");
        if (ordering == 0) begin
            // M -> N: revisit three spatial positions for each channel tile.
            for (int m = 0; m < h*width; m += 3)
                for (int c = 0; c < channels; c += COLS)
                    for (int row = 0; row < 3 && m+row < h*width; row++)
                        send_row(m+row, c);
        end else begin
            // N -> M: finish all positions of one channel tile first.
            for (int c = 0; c < channels; c += COLS)
                for (int spatial = 0; spatial < h*width; spatial++)
                    send_row(spatial, c);
        end
        @(negedge clk);
        while (busy) @(negedge clk);
        if (error || writes_q-previous_writes != expected_words)
            $fatal(1, "Incorrect completion: error=%b words=%0d expected=%0d",
                error, writes_q-previous_writes, expected_words);
        for (int index = 0; index < expected_words; index++)
            if (!seen[index]) $fatal(1, "Missing output word %0d", index);
        $display("POOL_CASE_PASS h=%0d w=%0d c=%0d k=%0dx%0d s=%0dx%0d ordering=%0d words=%0d full_line=%0d tile_line=%0d",
            h, width, channels, kh, kw, sh, sw, ordering, expected_words,
            full_line_words, tile_line_words);
    endtask

    task automatic rejected_config(input integer h, w, channels,
                                   input logic [31:0] pool,
                                   input logic [63:0] base);
        integer previous_writes;
        previous_writes = writes_q;
        configure(h, w, channels, pool, base);
        if (!error || in_ready || busy)
            $fatal(1, "Invalid configuration was accepted");
        in_valid = 1'b1;
        repeat (4) @(negedge clk);
        in_valid = 1'b0;
        if (in_ready || busy || awvalid || wvalid || writes_q != previous_writes)
            $fatal(1, "Rejected configuration consumed input or wrote output");
    endtask

    initial begin
        reset = 1'b1;
        start = 1'b0;
        in_valid = 1'b0;
        in_data = '0;
        in_spatial_index = 0;
        in_channel_base = 0;
        cfg_input_h = 0;
        cfg_input_w = 0;
        cfg_channels = 0;
        cfg_pool_config = 0;
        cfg_output_base = 0;
        expected_words = 0;
        repeat (4) @(negedge clk);
        reset = 1'b0;

        run_case(4, 8, COLS*2, 0, 0, 2, 2, 2, 2, 1, 64'h1000);
        run_case(6, 6, COLS*2, 3, 1, 2, 2, 2, 2, 1, 64'h2000);
        run_case(2, 2, COLS, 7, 0, 2, 2, 2, 2, 1, 64'h3000);
        // Overlapping windows reread the same original samples.
        run_case(6, 7, COLS, 2, 0, 3, 3, 1, 1, 0, 64'h6000);
        run_case(7, 8, COLS*2, 4, 1, 3, 3, 3, 5, 0, 64'h7000);
        run_case(7, 7, COLS*2, 5, 0, 3, 2, 2, 3, 0, 64'h8000);
        // Strides larger than kernels leave input rows/columns unused.
        run_case(9, 11, COLS*2, 6, 1, 2, 2, 3, 5, 0, 64'h9000);
        run_case(3, 5, COLS*2, 8, 0, 1, 1, 1, 1, 0, 64'ha000);
        run_case(5, 7, COLS*2, 9, 1, 2, 2, 2, 2, 1, 64'hb000);
        // Taller asymmetric windows wrap ring rows repeatedly.
        run_case(9, 7, COLS, 12, 0, 4, 3, 2, 2, 0, 64'hc000);

        if (LINE_WORDS % (COLS/4) == 0)
            run_case(2, LINE_WORDS/(COLS/4), COLS, 14, 1,
                1, 1, 1, 1, 0, 64'he000);
        if (LINE_WORDS >= 255*(COLS/4))
            run_case(255, 1, COLS, 15, 0,
                255, 1, 255, 255, 0, 64'hf000);
        else
            rejected_config(255, 1, COLS,
                pool_config(255, 1, 255, 255), 64'hf000);
        run_case(255, 1, COLS, 16, 0,
            1, 1, 255, 255, 0, 64'hf000);

        // Full-channel raw inputs exceed SRAM, while one COLS-wide channel tile
        // fits. All channel tiles reuse the same slots; global HWC output
        // addresses and signed maxima must survive that reuse and AXI stalls.
        run_case(7, 8, COLS*4, 21, 1,
            3, 3, 1, 1, 0, 64'h10000);
        run_case(7, 8, COLS*4, 1000, 1,
            3, 3, 1, 1, 0, 64'h11000);
        // Stride gaps and the trailing unused input row must still advance
        // the raster tracker before the next channel tile reuses SRAM.
        run_case(9, 16, COLS*9, 23, 1,
            2, 2, 3, 2, 0, 64'h14000);

        // Use complete COLS-wide channel tiles on both sides of the capacity
        // boundary. When LINE_WORDS is divisible by COLS/4, the first case
        // exactly fills SRAM; otherwise it is the largest full-channel fit.
        configure(1, 1, (LINE_WORDS/(COLS/4))*COLS,
            pool_config(1, 1, 1, 1), 64'h4000);
        if (error || !in_ready || dut.channel_tiled_q)
            $fatal(1, "Full-channel capacity configuration was rejected");
        configure(1, 1, (LINE_WORDS/(COLS/4)+1)*COLS,
            pool_config(1, 1, 1, 1), 64'h4000);
        if (error || !in_ready || !dut.channel_tiled_q)
            $fatal(1, "Channel-tiled configuration was rejected");
        // Even one channel tile cannot fit: no narrower channel partition
        // exists at this interface, so this remains a configuration error.
        rejected_config(4, 2*(LINE_WORDS/(COLS/4)+1), COLS*2,
            0, 64'h4000);
        rejected_config(4, 8, 6, 0, 64'h4000);
        // The interface has no lane mask for a partial final channel tile.
        // In particular, COLS=8 must reject a 12-channel configuration.
        if (COLS > 4)
            rejected_config(4, 8, COLS+4, 0, 64'h4000);
        rejected_config(4, 8, COLS, 0, 64'h4001);
        rejected_config(2, 4, COLS, pool_config(3, 2, 1, 1), 64'h4000);
        rejected_config(4, 2, COLS, pool_config(2, 3, 1, 1), 64'h4000);
        rejected_config(0, 4, COLS, 0, 64'h4000);
        for (int field = 0; field < 4; field++)
            rejected_config(4, 4, COLS,
                pool_config(2, 2, 2, 2) & ~(32'hff << (8*field)), 64'h4000);

        // Consecutive start cycles must replace rejected configuration and
        // leave a valid, idle consumer without clearing the SRAM array.
        @(negedge clk);
        start = 1'b1;
        cfg_input_h = 0;
        @(negedge clk);
        cfg_input_h = 4;
        cfg_input_w = 4;
        cfg_channels = COLS;
        cfg_pool_config = 0;
        @(negedge clk);
        start = 1'b0;
        #1;
        if (error || !in_ready || busy)
            $fatal(1, "Consecutive start cycles failed to recover");

        // Invalid metadata is discarded with a sticky error while input
        // remains drainable. A fresh start clears the error and SRAM state.
        test_h = 4;
        test_w = 4;
        test_seed = 0;
        configure(4, 4, COLS, 0, 64'h4000);
        send_row(16, 0);
        send_row(0, 1);
        send_row(0, COLS);
        if (!error || !in_ready || busy)
            $fatal(1, "Invalid metadata did not report error and drain");

        // In tiled mode, changing channels before completing the current
        // raster would alias live original samples. Reject it without making writes,
        // continue accepting/draining input, then recover on a fresh start.
        test_h = 7;
        test_w = 8;
        test_seed = 21;
        configure(7, 8, COLS*4, pool_config(3, 3, 1, 1), 64'h12000);
        begin
            integer previous_writes;
            previous_writes = writes_q;
            send_row(0, 0);
            send_row(0, COLS);
            send_row(2, 0);
            while (busy) @(negedge clk);
            if (!error || !in_ready || writes_q != previous_writes)
                $fatal(1, "Invalid tiled order did not report error and drain");
        end
        run_case(7, 8, COLS*4, 22, 1,
            3, 3, 1, 1, 0, 64'h13000);
        run_case(4, 4, COLS*2, 11, 0, 2, 2, 2, 2, 1, 64'h5000);
        run_case(3, 3, COLS, 13, 1, 2, 2, 1, 1, 0, 64'hd000);
        $display("PASS stream_maxpool2x2_tb COLS=%0d writes=%0d", COLS, writes_q);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Timeout in stream_maxpool2x2_tb");
    end
endmodule
