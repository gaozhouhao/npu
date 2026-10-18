
module output_param_slot_bank_tb;

    localparam int unsigned COLS = 4;

    logic clk;
    logic reset;
    logic clear;

    logic fill_valid;
    logic fill_ready;
    logic [1:0] fill_slot;
    logic [15:0] fill_n_tile;

    logic signed [31:0] fill_bias [0:COLS-1];
    logic [31:0] fill_multiplier [0:COLS-1];
    logic [5:0] fill_shift [0:COLS-1];

    logic read_valid;
    logic [1:0] read_slot;
    logic [15:0] read_n_tile;
    logic read_hit;

    logic signed [31:0] read_bias [0:COLS-1];
    logic [31:0] read_multiplier [0:COLS-1];
    logic [5:0] read_shift [0:COLS-1];

    logic retire_valid;
    logic [1:0] retire_slot;
    logic [15:0] retire_n_tile;
    logic retire_hit;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    output_param_slot_bank #(
        .SLOTS(4),
        .COLS(COLS),
        .TAG_WIDTH(16)
    ) dut (
        .clk(clk),
        .reset(reset),
        .clear(clear),

        .fill_valid(fill_valid),
        .fill_ready(fill_ready),
        .fill_slot(fill_slot),
        .fill_n_tile(fill_n_tile),
        .fill_bias(fill_bias),
        .fill_multiplier(fill_multiplier),
        .fill_shift(fill_shift),

        .read_valid(read_valid),
        .read_slot(read_slot),
        .read_n_tile(read_n_tile),
        .read_hit(read_hit),
        .read_bias(read_bias),
        .read_multiplier(read_multiplier),
        .read_shift(read_shift),

        .retire_valid(retire_valid),
        .retire_slot(retire_slot),
        .retire_n_tile(retire_n_tile),
        .retire_hit(retire_hit)
    );

    task automatic fill(
        input int slot_id,
        input int n_tile,
        input bit uniform_scale
    );
        @(negedge clk);

        fill_valid = 1'b1;
        fill_slot = 2'(slot_id);
        fill_n_tile = 16'(n_tile);

        for (int i = 0; i < COLS; i++) begin
            fill_bias[i] = 32'(n_tile * 100 + i);

            fill_multiplier[i] = uniform_scale ?
                32'd12345 : 32'(n_tile * 10 + i + 1);

            fill_shift[i] = uniform_scale ?
                6'd17 : 6'(i + 1);
        end

        #1;
        if (!fill_ready)
            $fatal(1, "Fill blocked: slot=%0d tag=%0d",
                   slot_id, n_tile);

        @(posedge clk);
        #1;
        fill_valid = 1'b0;
    endtask

    task automatic check_read(
        input int slot_id,
        input int n_tile,
        input bit expect_hit,
        input bit uniform_scale
    );
        @(negedge clk);

        read_valid = 1'b1;
        read_slot = 2'(slot_id);
        read_n_tile = 16'(n_tile);

        #1;

        if (read_hit !== expect_hit)
            $fatal(1, "Hit mismatch: slot=%0d tag=%0d",
                   slot_id, n_tile);

        for (int i = 0; i < COLS; i++) begin
            if (expect_hit) begin
                if (read_bias[i] !== 32'(n_tile * 100 + i))
                    $fatal(1, "Bias mismatch lane=%0d", i);

                if (read_multiplier[i] !==
                    (uniform_scale ?
                     32'd12345 : 32'(n_tile * 10 + i + 1)))
                    $fatal(1, "Multiplier mismatch lane=%0d", i);

                if (read_shift[i] !==
                    (uniform_scale ? 6'd17 : 6'(i + 1)))
                    $fatal(1, "Shift mismatch lane=%0d", i);
            end else begin
                if (read_bias[i] !== 32'sd0 ||
                    read_multiplier[i] !== 32'd0 ||
                    read_shift[i] !== 6'd0)
                    $fatal(1, "Nonzero data on cache miss");
            end
        end

        read_valid = 1'b0;
    endtask

    task automatic retire(
        input int slot_id,
        input int n_tile,
        input bit expect_hit
    );
        @(negedge clk);

        retire_valid = 1'b1;
        retire_slot = 2'(slot_id);
        retire_n_tile = 16'(n_tile);

        #1;
        if (retire_hit !== expect_hit)
            $fatal(1, "Retire mismatch: slot=%0d tag=%0d",
                   slot_id, n_tile);

        @(posedge clk);
        #1;
        retire_valid = 1'b0;
    endtask

    initial begin
        reset = 1'b1;
        clear = 1'b0;

        fill_valid = 1'b0;
        fill_slot = '0;
        fill_n_tile = '0;

        read_valid = 1'b0;
        read_slot = '0;
        read_n_tile = '0;

        retire_valid = 1'b0;
        retire_slot = '0;
        retire_n_tile = '0;

        for (int i = 0; i < COLS; i++) begin
            fill_bias[i] = '0;
            fill_multiplier[i] = '0;
            fill_shift[i] = '0;
        end

        repeat (3) @(negedge clk);
        reset = 1'b0;

        // Four C slots receive four different N tiles.
        fill(0, 0, 1'b0);
        fill(1, 1, 1'b0);
        fill(2, 2, 1'b0);
        fill(3, 3, 1'b0);

        check_read(0, 0, 1'b1, 1'b0);
        check_read(1, 1, 1'b1, 1'b0);
        check_read(2, 2, 1'b1, 1'b0);
        check_read(3, 3, 1'b1, 1'b0);

        $display("FOUR SLOT FILL PASS");

        // A different N tile must not hit the old slot.
        check_read(0, 4, 1'b0, 1'b0);

        @(negedge clk);
        fill_slot = 2'd0;
        fill_n_tile = 16'd4;
        fill_valid = 1'b1;
        #1;

        if (fill_ready)
            $fatal(1, "Occupied slot was overwritten");

        fill_valid = 1'b0;

        $display("TAG PROTECTION PASS");

        // Wrong retirement tag must not release the slot.
        retire(0, 4, 1'b0);
        check_read(0, 0, 1'b1, 1'b0);

        // Correct retirement releases it.
        retire(0, 0, 1'b1);
        check_read(0, 0, 1'b0, 1'b0);

        // New N tile reuses the same physical slot.
        fill(0, 4, 1'b0);
        check_read(0, 4, 1'b1, 1'b0);

        $display("SLOT RETIRE AND REUSE PASS");

        // Per-tensor broadcast uses the same storage datapath.
        retire(0, 4, 1'b1);
        fill(0, 7, 1'b1);
        check_read(0, 7, 1'b1, 1'b1);

        $display("PER-TENSOR BROADCAST PASS");

        // A new command invalidates all parameter slots.
        @(negedge clk);
        clear = 1'b1;

        @(posedge clk);
        #1;
        clear = 1'b0;

        for (int s = 0; s < 4; s++) begin
            check_read(s, s, 1'b0, 1'b0);
        end
        check_read(0, 7, 1'b0, 1'b0);

        $display("COMMAND CLEAR PASS");
        $display("OUTPUT PARAM SLOT BANK PASS");

        $finish;
    end

endmodule
