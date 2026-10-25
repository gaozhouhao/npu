`timescale 1ns/1ps

// Check every replayed raw tap and consume the same stream with a SUM
// reducer. A buffer that stores maxima in place of original samples cannot
// satisfy either check, even if a downstream MaxPool happened to look right.
module pool_window_buffer_tb #(
    parameter int unsigned COLS = 4,
    parameter int unsigned LINE_WORDS = 64
);
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset, start;
    logic [31:0] cfg_input_h, cfg_input_w, cfg_channels, cfg_pool_config;
    logic in_valid, in_ready;
    logic [COLS*8-1:0] in_data;
    logic [31:0] in_spatial_index, in_channel_base;
    logic busy, error, sample_valid, sample_ready;
    logic [31:0] sample_data, sample_spatial_index, sample_channel_base;
    logic sample_first, sample_last;
    logic [31:0] output_width;
    logic channel_tiled;
    logic force_stall;
    integer cycle_q, checks_q, completed_q;
    logic previous_stall_q;
    logic [97:0] previous_sample_q;
    integer test_h, test_w, test_channels, test_seed;
    integer test_kh, test_kw, test_sh, test_sw, test_ow;
    integer expected_words;
    integer tap_count [0:4095];
    integer sums [0:16383];
    integer expected_sums [0:16383];

    pool_window_buffer #(.COLS(COLS), .LINE_WORDS(LINE_WORDS)) dut (.*);
    assign sample_ready = !force_stall && cycle_q % 5 != 0 && cycle_q % 7 != 0;

    function automatic integer raw_sample(
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

    always @(posedge clk) begin : raw_sample_scoreboard
        integer word_index, tap, y, x, expected_value;
        if (reset) begin
            cycle_q <= 0;
            checks_q = 0;
            completed_q = 0;
            previous_stall_q = 1'b0;
            previous_sample_q = '0;
        end else begin
            cycle_q <= cycle_q + 1;
            if (previous_stall_q &&
                (!sample_valid || !busy ||
                 {sample_data, sample_first, sample_last,
                    sample_spatial_index, sample_channel_base} !== previous_sample_q))
                $fatal(1, "Raw sample or metadata changed during backpressure");
            previous_stall_q = sample_valid && !sample_ready;
            previous_sample_q = {sample_data, sample_first, sample_last,
                sample_spatial_index, sample_channel_base};
            if (sample_valid && (!busy || in_ready))
                $fatal(1, "Raw reader released input before its samples drained");
            if (sample_valid && sample_ready) begin
                if (sample_channel_base[1:0] != 0 ||
                    sample_channel_base+4 > test_channels ||
                    sample_spatial_index >= expected_words/(test_channels/4))
                    $fatal(1, "Unexpected window coordinates");
                word_index = sample_spatial_index*(test_channels/4) +
                    sample_channel_base/4;
                tap = tap_count[word_index];
                if (tap >= test_kh*test_kw)
                    $fatal(1, "Duplicate raw window sample");
                if (sample_first !== (tap == 0) ||
                    sample_last !== (tap == test_kh*test_kw-1))
                    $fatal(1, "Incorrect first/last for raw tap %0d", tap);
                y = (sample_spatial_index/test_ow)*test_sh + tap/test_kw;
                x = (sample_spatial_index%test_ow)*test_sw + tap%test_kw;
                for (int lane = 0; lane < 4; lane++) begin
                    expected_value = raw_sample(y, x, sample_channel_base+lane, test_seed);
                    if (sample_data[lane*8 +: 8] !== 8'(expected_value))
                        $fatal(1,
                            "Raw tap mismatch: output=%0d c=%0d tap=%0d got=%0d expected=%0d",
                            sample_spatial_index, sample_channel_base+lane, tap,
                            $signed(sample_data[lane*8 +: 8]), expected_value);
                    sums[word_index*4+lane] = sums[word_index*4+lane] +
                        $signed(sample_data[lane*8 +: 8]);
                    if (sample_last && sums[word_index*4+lane] !=
                        expected_sums[word_index*4+lane])
                        $fatal(1, "Alternative SUM consumer received incorrect raw data");
                end
                tap_count[word_index] = tap + 1;
                checks_q = checks_q + 1;
                if (sample_last) completed_q = completed_q + 1;
            end
        end
    end

    task automatic configure(input integer h, width, channels,
                             input logic [31:0] config_word);
        @(negedge clk);
        while (busy) @(negedge clk);
        cfg_input_h = h;
        cfg_input_w = width;
        cfg_channels = channels;
        cfg_pool_config = config_word;
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
            in_data[lane*8 +: 8] = 8'(raw_sample(
                spatial/test_w, spatial%test_w, channel+lane, test_seed));
        in_valid = 1'b1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 1'b0;
    endtask

    task automatic run_case(input integer h, width, channels, seed, ordering,
                            input integer kh, kw, sh, sw, legacy);
        integer oh, full_words, tile_words;
        integer previous_checks, previous_completed, word_index;
        test_h = h;
        test_w = width;
        test_channels = channels;
        test_seed = seed;
        test_kh = kh;
        test_kw = kw;
        test_sh = sh;
        test_sw = sw;
        oh = (h-kh)/sh+1;
        test_ow = (width-kw)/sw+1;
        expected_words = oh*test_ow*(channels/4);
        full_words = kh*width*(channels/4);
        tile_words = kh*width*(COLS/4);
        for (int index = 0; index < 4096; index++) tap_count[index] = 0;
        for (int index = 0; index < 16384; index++) begin
            sums[index] = 0;
            expected_sums[index] = 0;
        end
        for (int y = 0; y < oh; y++)
            for (int x = 0; x < test_ow; x++)
                for (int c = 0; c < channels; c++) begin
                    word_index = (y*test_ow+x)*channels+c;
                    for (int dy = 0; dy < kh; dy++)
                        for (int dx = 0; dx < kw; dx++)
                            expected_sums[word_index] = expected_sums[word_index] +
                                raw_sample(y*sh+dy, x*sw+dx, c, seed);
                end
        previous_checks = checks_q;
        previous_completed = completed_q;
        configure(h, width, channels, legacy ? 32'd0 : pool_config(kh, kw, sh, sw));
        if (error || !in_ready || output_width != test_ow ||
            channel_tiled !== (full_words > LINE_WORDS))
            $fatal(1, "Valid raw-buffer configuration was rejected");
        if (tile_words > LINE_WORDS || (full_words > LINE_WORDS && ordering != 1))
            $fatal(1, "Test selected an unsupported raw-buffer input order/capacity");
        if (ordering == 0) begin
            // Conv M -> N: channel groups revisit a small spatial tile.
            for (int m = 0; m < h*width; m += 3)
                for (int c = 0; c < channels; c += COLS)
                    for (int row = 0; row < 3 && m+row < h*width; row++)
                        send_row(m+row, c);
        end else if (ordering == 1) begin
            // Conv N -> M: a channel tile owns the ring until all pixels drain.
            for (int c = 0; c < channels; c += COLS)
                for (int spatial = 0; spatial < h*width; spatial++)
                    send_row(spatial, c);
        end else begin
            // FC: each pixel's complete channel vector precedes the next pixel.
            for (int spatial = 0; spatial < h*width; spatial++)
                for (int c = 0; c < channels; c += COLS)
                    send_row(spatial, c);
        end
        if (seed == 77) begin
            // A start arriving while a raw window is stalled cannot replace
            // the active geometry or expose stale SRAM from another task.
            force_stall = 1'b1;
            while (!sample_valid) @(negedge clk);
            start = 1'b1;
            cfg_input_h = 0;
            cfg_input_w = 0;
            cfg_channels = 0;
            cfg_pool_config = 32'hffffffff;
            repeat (6) @(negedge clk);
            if (!busy || !sample_valid || in_ready || output_width != test_ow)
                $fatal(1, "Busy start changed the active raw-window configuration");
            start = 1'b0;
            force_stall = 1'b0;
        end
        @(negedge clk);
        while (busy) @(negedge clk);
        if (error || completed_q-previous_completed != expected_words ||
            checks_q-previous_checks != expected_words*kh*kw)
            $fatal(1, "Incorrect raw-buffer completion");
        for (int index = 0; index < expected_words; index++)
            if (tap_count[index] != kh*kw)
                $fatal(1, "Missing raw window word %0d", index);
        $display("RAW_POOL_CASE_PASS COLS=%0d h=%0d w=%0d c=%0d k=%0dx%0d s=%0dx%0d order=%0d taps=%0d tiled=%0d",
            COLS, h, width, channels, kh, kw, sh, sw, ordering,
            checks_q-previous_checks, channel_tiled);
    endtask

    task automatic rejected_config(input integer h, width, channels,
                                   input logic [31:0] config_word);
        integer old_checks;
        old_checks = checks_q;
        configure(h, width, channels, config_word);
        if (!error || in_ready || busy)
            $fatal(1, "Invalid raw-buffer configuration was accepted");
        in_valid = 1'b1;
        repeat (3) @(negedge clk);
        in_valid = 1'b0;
        if (!error || in_ready || busy || sample_valid || checks_q != old_checks)
            $fatal(1, "Rejected raw-buffer configuration consumed input");
    endtask

    initial begin
        reset = 1'b1;
        start = 1'b0;
        in_valid = 1'b0;
        in_data = 0;
        in_spatial_index = 0;
        in_channel_base = 0;
        cfg_input_h = 0;
        cfg_input_w = 0;
        cfg_channels = 0;
        cfg_pool_config = 0;
        force_stall = 1'b0;
        expected_words = 0;
        repeat (4) @(negedge clk);
        reset = 1'b0;

        run_case(4, 5, COLS*2, 1, 0, 2, 2, 2, 2, 1);
        run_case(5, 5, COLS, 2, 0, 3, 3, 1, 1, 0);
        run_case(9, 11, COLS*2, 3, 1, 2, 2, 3, 5, 0);
        run_case(7, 7, COLS, 4, 2, 3, 2, 2, 3, 0);
        run_case(5, 5, COLS*2, 5, 2, 2, 2, 2, 2, 1);
        run_case(3, 5, COLS*2, 6, 0, 1, 1, 1, 1, 0);
        run_case(9, 7, COLS, 7, 0, 4, 3, 2, 2, 0);
        run_case(7, 8, COLS*4, 8, 1, 3, 3, 1, 1, 0);
        run_case(7, 8, COLS*4, 1000, 1, 3, 3, 1, 1, 0);
        run_case(2, LINE_WORDS/(COLS/4), COLS, 9, 1, 1, 1, 1, 1, 0);
        run_case(2, 2, COLS, 77, 2, 2, 2, 2, 2, 1);

        // Exact full-channel capacity and one channel tile over that bound.
        configure(1, 1, (LINE_WORDS/(COLS/4))*COLS, pool_config(1, 1, 1, 1));
        if (error || channel_tiled || !in_ready)
            $fatal(1, "Exact full raw capacity was rejected");
        configure(1, 1, (LINE_WORDS/(COLS/4)+1)*COLS, pool_config(1, 1, 1, 1));
        if (error || !channel_tiled || !in_ready)
            $fatal(1, "Raw channel tiling was not selected");
        rejected_config(4, LINE_WORDS/(COLS/4)+1, COLS, 0);
        rejected_config(255, 1, COLS, pool_config(255, 1, 255, 255));
        rejected_config(0, 4, COLS, 0);
        rejected_config(4, 4, COLS+1, 0);
        rejected_config(2, 4, COLS, pool_config(3, 2, 1, 1));
        rejected_config(4, 2, COLS, pool_config(2, 3, 1, 1));
        rejected_config(32'hffffffff, 32'hffffffff, COLS, 0);
        for (int field = 0; field < 4; field++)
            rejected_config(4, 4, COLS,
                pool_config(2, 2, 2, 2) & ~(32'hff << (8*field)));

        // Sticky metadata/order errors discard malformed input and remain
        // drainable. A subsequent task replaces both geometry and epoch.
        test_h = 4;
        test_w = 4;
        test_seed = 10;
        configure(4, 4, COLS, 0);
        send_row(16, 0);
        send_row(0, 1);
        send_row(0, COLS);
        if (!error || !in_ready || busy)
            $fatal(1, "Malformed raw metadata did not drain with sticky error");
        test_h = 7;
        test_w = 8;
        configure(7, 8, COLS*4, pool_config(3, 3, 1, 1));
        send_row(0, 0);
        send_row(0, COLS);
        send_row(2, 0);
        if (!error || !in_ready || busy)
            $fatal(1, "Malformed raw tiled order did not drain with sticky error");
        run_case(4, 4, COLS*2, 11, 2, 2, 2, 2, 2, 1);
        run_case(3, 3, COLS, 12, 0, 2, 2, 1, 1, 0);
        $display("PASS pool_window_buffer_tb COLS=%0d raw_taps=%0d windows=%0d",
            COLS, checks_q, completed_q);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Timeout in pool_window_buffer_tb");
    end
endmodule
