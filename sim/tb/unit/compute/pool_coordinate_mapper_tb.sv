`timescale 1ns/1ps

module pool_coordinate_mapper_case #(
    parameter int unsigned COLS = 4
) (
    output logic done
);
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic reset, clear, start, fc_fire, fc_mode;
    logic [31:0] source_spatial_index, source_channel_base, fc_channels;
    logic mapped_valid, mapping_error;
    logic [31:0] mapped_spatial_index, mapped_channel_base;
    int unsigned checks, accepted_words, active_channels, unused_pixel_words;

    pool_coordinate_mapper #(.COLS(COLS)) dut (
        .clk(clk), .reset(reset), .clear(clear), .start(start),
        .fc_fire(fc_fire), .fc_mode(fc_mode),
        .source_spatial_index(source_spatial_index),
        .source_channel_base(source_channel_base), .fc_channels(fc_channels),
        .mapped_valid(mapped_valid),
        .mapped_spatial_index(mapped_spatial_index),
        .mapped_channel_base(mapped_channel_base), .mapping_error(mapping_error)
    );

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic expect_coordinate(
        input bit valid_expected,
        input bit error_expected,
        input logic [31:0] spatial_expected,
        input logic [31:0] channel_expected
    );
        #1;
        if (mapped_valid !== valid_expected ||
            mapping_error !== error_expected ||
            mapped_spatial_index !== spatial_expected ||
            mapped_channel_base !== channel_expected)
            $fatal(1, "COLS=%0d accepted=%0d fc=%0b src=(%0d,%0d) C=%0d expected=(%0b,%0b,%0d,%0d) got=(%0b,%0b,%0d,%0d)",
                COLS, accepted_words, fc_mode, source_spatial_index,
                source_channel_base, fc_channels, valid_expected,
                error_expected, spatial_expected, channel_expected,
                mapped_valid, mapping_error, mapped_spatial_index,
                mapped_channel_base);
        checks++;
    endtask

    // The reference derives coordinates from complete accepted source
    // words independently of the DUT's channel counter implementation.
    task automatic expect_current;
        expect_coordinate(1, 0,
            32'((accepted_words * COLS) / active_channels),
            32'((accepted_words * COLS) % active_channels));
    endtask

    task automatic start_fc(input int unsigned channels);
        fc_mode = 1'b1;
        fc_channels = 32'(channels);
        source_spatial_index = 32'd0;
        source_channel_base = 32'd0;
        fc_fire = 1'b0;
        clear = 1'b0;
        start = 1'b1;
        cycle();
        start = 1'b0;
        accepted_words = 0;
        active_channels = channels;
        if ((channels >= COLS) && ((channels % COLS) == 0))
            expect_current();
        else
            expect_coordinate(0, 1, 0, 0);
    endtask

    task automatic accept_word;
        source_spatial_index = 32'd0;
        source_channel_base = 32'(accepted_words * COLS);
        expect_current();
        // One fire accepts all COLS lanes. COLS=8's two internal pool
        // groups must never appear as two external receive events.
        fc_fire = 1'b1;
        cycle();
        fc_fire = 1'b0;
        accepted_words++;
        expect_current();
    endtask

    task automatic stall(input int unsigned cycles);
        source_spatial_index = 32'd0;
        source_channel_base = 32'(accepted_words * COLS);
        fc_fire = 1'b0;
        repeat (cycles) begin
            expect_current();
            cycle();
            expect_current();
        end
    endtask

    task automatic accept_new_command;
        // Command acceptance takes priority over an old pending fire.
        clear = 1'b1;
        fc_fire = 1'b1;
        cycle();
        clear = 1'b0;
        fc_fire = 1'b0;
        accepted_words = 0;
        source_spatial_index = 32'd0;
        expect_coordinate(0, 1, 0, 0);
    endtask

    initial begin
        done = 1'b0;
        checks = 0;
        accepted_words = 0;
        active_channels = 0;
        unused_pixel_words = 0;
        reset = 1'b1;
        clear = 1'b0;
        start = 1'b0;
        fc_fire = 1'b0;
        fc_mode = 1'b1;
        source_spatial_index = 32'd0;
        source_channel_base = 32'd0;
        fc_channels = 32'(3 * COLS);
        cycle();
        reset = 1'b0;
        expect_coordinate(0, 1, 0, 0);

        // A valid-looking shape alone cannot start a layer.
        fc_fire = 1'b1;
        repeat (2) cycle();
        fc_fire = 1'b0;
        expect_coordinate(0, 1, 0, 0);

        // Three channel words per pixel exercise every wrap boundary.
        start_fc(3 * COLS);
        for (int word_index = 0; word_index < 10; word_index++) begin
            stall((word_index % 3) + 1);
            accept_word();
        end

        // Padded physical rows are not logical pixels. Even a stray
        // fire must neither advance the counters nor report an error.
        for (int row = 1; row < 4; row++) begin
            source_spatial_index = 32'(row);
            source_channel_base = 32'hffff_ffff;
            fc_fire = 1'b1;
            expect_coordinate(0, 0, 0, 0);
            cycle();
            expect_coordinate(0, 0, 0, 0);
        end
        fc_fire = 1'b0;
        source_spatial_index = 32'd0;
        source_channel_base = 32'(accepted_words * COLS);
        expect_current();
        accept_word();

        // Source metadata no longer performs FC division or modulo.
        source_channel_base = 32'hffff_ffff;
        expect_current();
        cycle();
        expect_current();
        source_channel_base = 32'd1;
        expect_current();
        cycle();
        expect_current();

        // Start overrides an old-layer fire. A single-word pixel then
        // advances its spatial position exactly once per reception.
        start = 1'b1;
        fc_fire = 1'b1;
        fc_channels = 32'(COLS);
        cycle();
        start = 1'b0;
        fc_fire = 1'b0;
        accepted_words = 0;
        active_channels = COLS;
        expect_current();
        repeat (4) accept_word();

        // Consecutive FC -> Conv -> FC commands discard old position
        // and shape. Conv preserves every source bit regardless of C.
        accept_new_command();
        fc_mode = 1'b0;
        fc_channels = 32'd0;
        source_spatial_index = 32'hffff_ffff;
        source_channel_base = 32'hffff_ffff;
        fc_fire = 1'b1;
        expect_coordinate(1, 0, 32'hffff_ffff, 32'hffff_ffff);
        cycle();
        source_spatial_index = 32'd5;
        source_channel_base = 32'd12;
        expect_coordinate(1, 0, 5, 12);
        cycle();
        fc_fire = 1'b0;
        fc_mode = 1'b1;
        source_spatial_index = 32'd0;
        expect_coordinate(0, 1, 0, 0);
        accept_new_command();
        start_fc(2 * COLS);
        repeat (5) accept_word();

        // Partial K blocks may visit many source tiles, but only the
        // final accumulated results produce pool receive events.
        accept_new_command();
        start_fc(3 * COLS);
        for (int k_block = 0; k_block < 3; k_block++) begin
            for (int word_index = 0; word_index < 9; word_index++) begin
                source_channel_base = 32'(word_index * COLS);
                fc_fire = 1'b0;
                cycle();
                expect_coordinate(1, 0, 0, 0);
            end
        end
        for (int word_index = 0; word_index < 9; word_index++) begin
            stall(2);
            accept_word();
        end

        // On a 3x3 image a 2x2/stride-2 window uses only the top-left
        // four pixels. Accept all five unused pixels too, including
        // the final trailing pixel, and verify they all advance.
        accept_new_command();
        start_fc(2 * COLS);
        for (int pixel = 0; pixel < 9; pixel++) begin
            for (int group_index = 0; group_index < 2; group_index++) begin
                if ((pixel / 3 >= 2) || (pixel % 3 >= 2))
                    unused_pixel_words++;
                stall(1);
                accept_word();
            end
        end
        if (unused_pixel_words != 10)
            $fatal(1, "COLS=%0d missing unused-window pixel coverage", COLS);
        expect_coordinate(1, 0, 9, 0);

        // Reset discards an active layer and its configured shape.
        reset = 1'b1;
        fc_fire = 1'b1;
        cycle();
        reset = 1'b0;
        fc_fire = 1'b0;
        accepted_words = 0;
        expect_coordinate(0, 1, 0, 0);
        start_fc(COLS);
        accept_word();

        // Reject zero, incomplete and misaligned full channel groups.
        // Padded rows remain harmless even with an invalid shape.
        for (int invalid_case = 0; invalid_case < 4; invalid_case++) begin
            accept_new_command();
            case (invalid_case)
                0: start_fc(0);
                1: start_fc(COLS - 1);
                2: start_fc(COLS + 1);
                3: start_fc(12);
            endcase
            // Twelve channels are legal only for the four-lane case.
            if ((invalid_case == 3) && (COLS == 4)) begin
                repeat (3) accept_word();
            end else begin
                fc_fire = 1'b1;
                repeat (2) cycle();
                fc_fire = 1'b0;
                expect_coordinate(0, 1, 0, 0);
            end
            source_spatial_index = 32'd2;
            fc_fire = 1'b1;
            cycle();
            fc_fire = 1'b0;
            expect_coordinate(0, 0, 0, 0);
        end

        // Recover immediately with another task after an invalid C.
        accept_new_command();
        start_fc(2 * COLS);
        repeat (7) accept_word();
        stall(4);

        $display("pool_coordinate_mapper COLS=%0d checks=%0d accepted=%0d unused_window_words=%0d PASS",
            COLS, checks, accepted_words, unused_pixel_words);
        done = 1'b1;
    end
endmodule

module pool_coordinate_mapper_tb;
    logic done4, done8;
    pool_coordinate_mapper_case #(.COLS(4)) case4 (.done(done4));
    pool_coordinate_mapper_case #(.COLS(8)) case8 (.done(done8));

    initial begin
        wait (done4 && done8);
        $display("TEST_PASS pool_coordinate_mapper_tb COLS=4/8");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "pool_coordinate_mapper_tb timeout");
    end
endmodule
