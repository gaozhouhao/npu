module command_frontend_tb;

    localparam int unsigned DESC_COUNT_WIDTH = 4;

    logic clk;
    logic reset;

    logic        start;
    logic [63:0] desc_base;
    logic [DESC_COUNT_WIDTH-1:0] desc_count;

    logic        mem_read_req;
    logic [63:0] mem_read_addr;
    logic        mem_read_ready;
    logic        mem_read_valid;
    logic [31:0] mem_read_data;

    logic        cmd_valid;
    logic        cmd_ready;

    logic [7:0]  cmd_opcode;
    logic [23:0] cmd_flags;

    logic [31:0] cfg_m;
    logic [31:0] cfg_n;
    logic [31:0] cfg_k;

    logic [63:0] cfg_a_base;
    logic [63:0] cfg_b_base;
    logic [63:0] cfg_c_base;

    logic [31:0] cfg_a_stride;
    logic [31:0] cfg_b_stride;
    logic [31:0] cfg_c_stride;

    logic [31:0] cfg_param0;
    logic [31:0] cfg_param1;

    logic exec_done;

    logic busy;
    logic done;


    // ============================================================
    // Simple descriptor memory
    //
    // 32 words = two 64-byte descriptors.
    //
    // Descriptor 0:
    // 0x1000 ~ 0x103c
    //
    // Descriptor 1:
    // 0x1040 ~ 0x107c
    // ============================================================

    logic [31:0] mem [0:31];

    logic        read_pending;
    logic [63:0] read_addr_q;


    // ============================================================
    // DUT
    // ============================================================

    command_frontend #(
        .DESC_COUNT_WIDTH (DESC_COUNT_WIDTH)
    ) dut (
        .clk              (clk),
        .reset            (reset),

        .start            (start),
        .desc_base        (desc_base),
        .desc_count       (desc_count),

        .mem_read_req     (mem_read_req),
        .mem_read_addr    (mem_read_addr),
        .mem_read_ready   (mem_read_ready),

        .mem_read_valid   (mem_read_valid),
        .mem_read_data    (mem_read_data),

        .cmd_valid        (cmd_valid),
        .cmd_ready        (cmd_ready),

        .cmd_opcode       (cmd_opcode),
        .cmd_flags        (cmd_flags),

        .cfg_m            (cfg_m),
        .cfg_n            (cfg_n),
        .cfg_k            (cfg_k),

        .cfg_a_base       (cfg_a_base),
        .cfg_b_base       (cfg_b_base),
        .cfg_c_base       (cfg_c_base),

        .cfg_a_stride     (cfg_a_stride),
        .cfg_b_stride     (cfg_b_stride),
        .cfg_c_stride     (cfg_c_stride),

        .cfg_param0       (cfg_param0),
        .cfg_param1       (cfg_param1),

        .exec_done        (exec_done),

        .busy             (busy),
        .done             (done)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    // ============================================================
    // Simple one-cycle-latency memory model
    //
    // Request accepted in cycle N.
    // Data returned with mem_read_valid in the following cycle.
    // ============================================================

    assign mem_read_ready = !reset;

    always_ff @(posedge clk) begin

        if (reset) begin

            read_pending   <= 1'b0;
            read_addr_q    <= '0;

            mem_read_valid <= 1'b0;
            mem_read_data  <= '0;

        end else begin

            // Response for the previous accepted request.

            mem_read_valid <= read_pending;

            if (read_pending) begin

                // This TB only models:
                //
                // 0x1000 ~ 0x107c
                //
                // All accesses must also be 32-bit aligned.

                if (
                    (read_addr_q < 64'h0000_0000_0000_1000) ||
                    (read_addr_q > 64'h0000_0000_0000_107c)
                ) begin

                    $fatal(
                        1,
                        "Descriptor memory address out of range: 0x%0h",
                        read_addr_q
                    );

                end

                if (read_addr_q[1:0] != 2'b00) begin

                    $fatal(
                        1,
                        "Unaligned descriptor memory read: 0x%0h",
                        read_addr_q
                    );

                end

                // 0x1000 is aligned to 128 bytes, so bits [6:2]
                // directly select word 0 ~ 31.
                //
                // Using a 5-bit index also avoids width truncation.

                mem_read_data <= mem[read_addr_q[6:2]];

            end


            // Capture a new request.

            read_pending <=
                mem_read_req &&
                mem_read_ready;

            if (mem_read_req && mem_read_ready) begin

                read_addr_q <= mem_read_addr;

            end

        end

    end


    // ============================================================
    // Reset DUT
    // ============================================================

    task automatic reset_dut;
        begin

            start     = 1'b0;
            cmd_ready = 1'b0;
            exec_done = 1'b0;

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
    // Check descriptor 0
    // ============================================================

    task automatic check_descriptor_0;
        begin

            wait (cmd_valid === 1'b1);

            #1;

            if (cmd_opcode !== 8'h01) begin
                $fatal(1, "descriptor0 opcode mismatch");
            end

            if (cmd_flags !== 24'h000123) begin
                $fatal(1, "descriptor0 flags mismatch");
            end

            if (cfg_m !== 32'd64) begin
                $fatal(1, "descriptor0 M mismatch");
            end

            if (cfg_n !== 32'd32) begin
                $fatal(1, "descriptor0 N mismatch");
            end

            if (cfg_k !== 32'd128) begin
                $fatal(1, "descriptor0 K mismatch");
            end

            if (
                cfg_a_base !==
                64'h0000_0000_0000_2000
            ) begin
                $fatal(1, "descriptor0 A base mismatch");
            end

            if (
                cfg_b_base !==
                64'h0000_0000_0000_3000
            ) begin
                $fatal(1, "descriptor0 B base mismatch");
            end

            if (
                cfg_c_base !==
                64'h0000_0000_0000_4000
            ) begin
                $fatal(1, "descriptor0 C base mismatch");
            end

            if (cfg_a_stride !== 32'd128) begin
                $fatal(1, "descriptor0 A stride mismatch");
            end

            if (cfg_b_stride !== 32'd32) begin
                $fatal(1, "descriptor0 B stride mismatch");
            end

            if (cfg_c_stride !== 32'd128) begin
                $fatal(1, "descriptor0 C stride mismatch");
            end

            if (cfg_param0 !== 32'h1111_1111) begin
                $fatal(1, "descriptor0 param0 mismatch");
            end

            if (cfg_param1 !== 32'h2222_2222) begin
                $fatal(1, "descriptor0 param1 mismatch");
            end

        end
    endtask


    // ============================================================
    // Check descriptor 1
    // ============================================================

    task automatic check_descriptor_1;
        begin

            wait (cmd_valid === 1'b1);

            #1;

            if (cmd_opcode !== 8'h01) begin
                $fatal(1, "descriptor1 opcode mismatch");
            end

            if (cmd_flags !== 24'h000000) begin
                $fatal(1, "descriptor1 flags mismatch");
            end

            if (cfg_m !== 32'd32) begin
                $fatal(1, "descriptor1 M mismatch");
            end

            if (cfg_n !== 32'd16) begin
                $fatal(1, "descriptor1 N mismatch");
            end

            if (cfg_k !== 32'd64) begin
                $fatal(1, "descriptor1 K mismatch");
            end

            if (
                cfg_a_base !==
                64'h0000_0000_0000_5000
            ) begin
                $fatal(1, "descriptor1 A base mismatch");
            end

            if (
                cfg_b_base !==
                64'h0000_0000_0000_6000
            ) begin
                $fatal(1, "descriptor1 B base mismatch");
            end

            if (
                cfg_c_base !==
                64'h0000_0000_0000_7000
            ) begin
                $fatal(1, "descriptor1 C base mismatch");
            end

            if (cfg_a_stride !== 32'd64) begin
                $fatal(1, "descriptor1 A stride mismatch");
            end

            if (cfg_b_stride !== 32'd16) begin
                $fatal(1, "descriptor1 B stride mismatch");
            end

            if (cfg_c_stride !== 32'd64) begin
                $fatal(1, "descriptor1 C stride mismatch");
            end

            if (cfg_param0 !== 32'h3333_3333) begin
                $fatal(1, "descriptor1 param0 mismatch");
            end

            if (cfg_param1 !== 32'h4444_4444) begin
                $fatal(1, "descriptor1 param1 mismatch");
            end

        end
    endtask


    // ============================================================
    // Test sequence
    // ============================================================

    initial begin

        reset = 1'b1;

        start     = 1'b0;
        cmd_ready = 1'b0;
        exec_done = 1'b0;

        desc_base  = 64'h0000_0000_0000_1000;
        desc_count = 4'd2;


        // ========================================================
        // Descriptor 0 @ 0x1000
        //
        // word 0:
        // [31:8] flags
        // [7:0]  opcode
        // ========================================================

        mem[0] = 32'h0001_2301;

        mem[1] = 32'd64;
        mem[2] = 32'd32;
        mem[3] = 32'd128;

        // A base = 0x2000
        mem[4] = 32'h0000_2000;
        mem[5] = 32'h0000_0000;

        // B base = 0x3000
        mem[6] = 32'h0000_3000;
        mem[7] = 32'h0000_0000;

        // C base = 0x4000
        mem[8] = 32'h0000_4000;
        mem[9] = 32'h0000_0000;

        mem[10] = 32'd128;
        mem[11] = 32'd32;
        mem[12] = 32'd128;

        mem[13] = 32'h1111_1111;
        mem[14] = 32'h2222_2222;

        // Reserved
        mem[15] = 32'h0000_0000;


        // ========================================================
        // Descriptor 1 @ 0x1040
        // ========================================================

        mem[16] = 32'h0000_0001;

        mem[17] = 32'd32;
        mem[18] = 32'd16;
        mem[19] = 32'd64;

        // A base = 0x5000
        mem[20] = 32'h0000_5000;
        mem[21] = 32'h0000_0000;

        // B base = 0x6000
        mem[22] = 32'h0000_6000;
        mem[23] = 32'h0000_0000;

        // C base = 0x7000
        mem[24] = 32'h0000_7000;
        mem[25] = 32'h0000_0000;

        mem[26] = 32'd64;
        mem[27] = 32'd16;
        mem[28] = 32'd64;

        mem[29] = 32'h3333_3333;
        mem[30] = 32'h4444_4444;

        // Reserved
        mem[31] = 32'h0000_0000;


        // ========================================================
        // Reset
        // ========================================================

        reset_dut();


        // ========================================================
        // Start command stream
        // ========================================================

        @(negedge clk);

        start = 1'b1;

        @(negedge clk);

        start = 1'b0;


        // ========================================================
        // Descriptor 0
        // ========================================================

        check_descriptor_0();


        // --------------------------------------------------------
        // cmd_valid must remain asserted until cmd_ready.
        // --------------------------------------------------------

        repeat (3) begin

            @(posedge clk);
            #1;

            if (cmd_valid !== 1'b1) begin

                $fatal(
                    1,
                    "cmd_valid must remain asserted before cmd_ready"
                );

            end

        end


        // --------------------------------------------------------
        // Execution side accepts descriptor 0.
        // --------------------------------------------------------

        @(negedge clk);

        cmd_ready = 1'b1;

        @(negedge clk);

        cmd_ready = 1'b0;


        // --------------------------------------------------------
        // Frontend must wait for exec_done.
        //
        // Descriptor 1 must not be issued yet.
        // --------------------------------------------------------

        repeat (5) begin

            @(posedge clk);
            #1;

            if (cmd_valid !== 1'b0) begin

                $fatal(
                    1,
                    "descriptor1 issued before exec_done"
                );

            end

        end


        // --------------------------------------------------------
        // Descriptor 0 execution completes.
        // --------------------------------------------------------

        @(negedge clk);

        exec_done = 1'b1;

        @(negedge clk);

        exec_done = 1'b0;


        // ========================================================
        // Descriptor 1
        // ========================================================

        check_descriptor_1();


        // --------------------------------------------------------
        // Accept descriptor 1.
        // --------------------------------------------------------

        @(negedge clk);

        cmd_ready = 1'b1;

        @(negedge clk);

        cmd_ready = 1'b0;


        // Pretend execution takes a few cycles.

        repeat (3) begin
            @(posedge clk);
        end


        // --------------------------------------------------------
        // Descriptor 1 execution completes.
        // --------------------------------------------------------

        @(negedge clk);

        exec_done = 1'b1;

        @(negedge clk);

        exec_done = 1'b0;


        // ========================================================
        // Entire command stream completed
        // ========================================================

        wait (done === 1'b1);

        #1;

        if (busy !== 1'b0) begin
            $fatal(
                1,
                "busy must be 0 when all descriptors are done"
            );
        end

        @(posedge clk);
        #1;

        if (done !== 1'b0) begin
            $fatal(
                1,
                "done must be a one-cycle pulse"
            );
        end


        $display(
            "All command_frontend tests passed."
        );

        $finish;

    end

endmodule
