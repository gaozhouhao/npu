
module conv_patch_loader_tb;

    localparam int unsigned ROWS = 4;
    localparam int unsigned MEMORY_WORDS = 1024;
    localparam int unsigned INPUT_BASE = 'h100;

    logic clk;
    logic reset;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic load_req;
    logic load_accept;
    logic load_done;
    logic busy;
    logic error;

    logic [31:0] input_h;
    logic [31:0] input_w;
    logic [31:0] input_c;
    logic [31:0] kernel_h;
    logic [31:0] kernel_w;
    logic [31:0] stride_h;
    logic [31:0] stride_w;
    logic [31:0] pad_top;
    logic [31:0] pad_left;
    logic [31:0] output_w;
    logic [31:0] output_positions;
    logic [31:0] m_start;
    logic [31:0] k_start;
    logic [8:0] load_size;

    logic bank_load_req;
    logic bank_load_grant;
    logic bank_load_bank;
    logic bank_load_done;
    logic bank_owned_q;

    logic rd_req_valid;
    logic rd_req_ready;
    logic [63:0] rd_req_addr;
    logic [31:0] rd_req_beats;
    logic rd_data_valid;
    logic rd_data_ready;
    logic [31:0] rd_data;
    logic rd_data_last;
    logic rd_done;
    logic rd_error;

    logic buffer_wen;
    logic buffer_wbank;
    logic [1:0] buffer_wlane;
    logic [5:0] buffer_waddr;
    logic [31:0] buffer_wdata;

    logic [31:0] memory [0:MEMORY_WORDS-1];

    logic read_pending_q;
    logic read_done_q;
    logic [63:0] read_addr_q;

    logic scoreboard_clear;
    logic [31:0] write_count_q;
    logic [31:0] words_per_lane;

    // ============================================================
    // DUT
    // ============================================================

    conv_patch_loader #(
        .ROWS         (ROWS),
        .K_DEPTH      (256),
        .BUFFER_COUNT (2)
    ) u_dut (
        .clk              (clk),
        .reset            (reset),

        .load_req         (load_req),
        .load_accept      (load_accept),

        .input_base       (64'(INPUT_BASE)),
        .input_h          (input_h),
        .input_w          (input_w),
        .input_c          (input_c),
        .kernel_h         (kernel_h),
        .kernel_w         (kernel_w),
        .stride_h         (stride_h),
        .stride_w         (stride_w),
        .pad_top          (pad_top),
        .pad_left         (pad_left),
        .output_w         (output_w),
        .output_positions (output_positions),
        .m_start          (m_start),
        .k_start          (k_start),
        .load_size        (load_size),

        .load_done        (load_done),
        .busy             (busy),
        .error            (error),

        .bank_load_req    (bank_load_req),
        .bank_load_grant  (bank_load_grant),
        .bank_load_bank   (bank_load_bank),
        .bank_load_done   (bank_load_done),

        .rd_req_valid     (rd_req_valid),
        .rd_req_ready     (rd_req_ready),
        .rd_req_addr      (rd_req_addr),
        .rd_req_beats     (rd_req_beats),
        .rd_data_valid    (rd_data_valid),
        .rd_data_ready    (rd_data_ready),
        .rd_data          (rd_data),
        .rd_data_last     (rd_data_last),
        .rd_done          (rd_done),
        .rd_error         (rd_error),

        .buffer_wen       (buffer_wen),
        .buffer_wbank     (buffer_wbank),
        .buffer_wlane     (buffer_wlane),
        .buffer_waddr     (buffer_waddr),
        .buffer_wdata     (buffer_wdata)
    );

    // ============================================================
    // Bank model
    // ============================================================

    assign bank_load_grant =
        bank_load_req && !bank_owned_q;

    assign bank_load_bank = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            bank_owned_q <= 1'b0;
        end else begin

            if (bank_load_req && bank_load_grant)
                bank_owned_q <= 1'b1;

            if (bank_load_done)
                bank_owned_q <= 1'b0;

        end
    end

    // ============================================================
    // Read model
    // ============================================================

    assign rd_req_ready =
        !read_pending_q && !read_done_q;

    assign rd_data_valid = read_pending_q;
    assign rd_data_last = read_pending_q;

    assign rd_data =
        memory[int'(read_addr_q >> 2)];

    assign rd_done = read_done_q;
    assign rd_error = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            read_pending_q <= 1'b0;
            read_done_q <= 1'b0;
            read_addr_q <= '0;
        end else begin

            read_done_q <= 1'b0;

            if (rd_req_valid && rd_req_ready) begin

                if (rd_req_beats != 32'd1)
                    $fatal(1, "Invalid beat count");

                if (rd_req_addr >= 64'(MEMORY_WORDS * 4))
                    $fatal(1, "Read address out of range");

                if (rd_req_addr[1:0] != 2'b00)
                    $fatal(1, "Unaligned read");

                read_addr_q <= rd_req_addr;
                read_pending_q <= 1'b1;

            end

            if (rd_data_valid && rd_data_ready) begin

                if (read_addr_q >= 64'(MEMORY_WORDS * 4))
                    $fatal(1, "Invalid response address");

                read_pending_q <= 1'b0;
                read_done_q <= 1'b1;

            end

        end
    end

    // ============================================================
    // Golden functions
    // ============================================================

    function automatic logic [7:0] input_value (
        input int h,
        input int w,
        input int c
    );

        return 8'(
            ((h * 13 + w * 7 + c * 5) % 127) - 63
        );

    endfunction

    function automatic logic [7:0] golden_byte (
        input int lane,
        input int local_k
    );

        int position;
        int flat_k;
        int oh;
        int ow;
        int channel;
        int spatial;
        int ky;
        int kx;
        int ih;
        int iw;

        position = int'(m_start) + lane;
        flat_k = int'(k_start) + local_k;

        oh = position / int'(output_w);
        ow = position % int'(output_w);

        channel = flat_k % int'(input_c);
        spatial = flat_k / int'(input_c);

        ky = spatial / int'(kernel_w);
        kx = spatial % int'(kernel_w);

        ih = oh * int'(stride_h) +
             ky - int'(pad_top);

        iw = ow * int'(stride_w) +
             kx - int'(pad_left);

        if (
            position >= int'(output_positions) ||
            ky >= int'(kernel_h) ||
            ih < 0 ||
            iw < 0 ||
            ih >= int'(input_h) ||
            iw >= int'(input_w)
        ) begin
            return 8'd0;
        end

        return input_value(ih, iw, channel);

    endfunction

    function automatic logic [31:0] golden_word (
        input int lane,
        input int word_idx
    );

        logic [31:0] result;
        int local_k;

        result = '0;

        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin

            local_k = word_idx * 4 + byte_idx;

            if (local_k < int'(load_size)) begin
                result[8*byte_idx +: 8] =
                    golden_byte(lane, local_k);
            end

        end

        return result;

    endfunction

    // ============================================================
    // Write scoreboard
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            write_count_q <= '0;

        end else if (scoreboard_clear) begin

            write_count_q <= '0;

        end else if (buffer_wen) begin

            if (buffer_wbank != 1'b0)
                $fatal(1, "Unexpected SRAM bank");

            if (
                32'(buffer_wlane) !=
                write_count_q / words_per_lane
            ) begin
                $fatal(1, "Incorrect lane order");
            end

            if (
                32'(buffer_waddr) !=
                write_count_q % words_per_lane
            ) begin
                $fatal(1, "Incorrect SRAM address");
            end

            if (
                buffer_wdata !==
                golden_word(
                    int'(buffer_wlane),
                    int'(buffer_waddr)
                )
            ) begin

                $fatal(
                    1,
                    "Mismatch lane=%0d addr=%0d got=%08h expected=%08h",
                    buffer_wlane,
                    buffer_waddr,
                    buffer_wdata,
                    golden_word(
                        int'(buffer_wlane),
                        int'(buffer_waddr)
                    )
                );

            end

            write_count_q <= write_count_q + 32'd1;

        end
    end

    // ============================================================
    // Input initialization
    // ============================================================

    task automatic initialize_input;

        int unsigned byte_addr;
        logic [7:0] value;

        for (int i = 0; i < MEMORY_WORDS; i++)
            memory[i] = '0;

        for (int h = 0; h < int'(input_h); h++) begin
            for (int w = 0; w < int'(input_w); w++) begin
                for (int c = 0; c < int'(input_c); c++) begin

                    byte_addr =
                        INPUT_BASE +
                        ((h * int'(input_w) + w) *
                         int'(input_c) + c);

                    value = input_value(h, w, c);

                    memory[byte_addr >> 2]
                          [8*(byte_addr % 4) +: 8] = value;

                end
            end
        end

    endtask

    // ============================================================
    // Test one tile
    // ============================================================

    task automatic run_tile;

        int cycles;

        words_per_lane =
            (32'(load_size) + 32'd3) >> 2;

        @(negedge clk);
        scoreboard_clear = 1'b1;

        @(negedge clk);
        scoreboard_clear = 1'b0;
        load_req = 1'b1;

        #1;

        if (!load_accept)
            $fatal(1, "Load request not accepted");

        @(negedge clk);
        load_req = 1'b0;

        if (!busy)
            $fatal(1, "Loader should be busy");

        cycles = 0;

        while (!load_done && cycles < 100000) begin
            @(negedge clk);
            cycles++;
        end

        if (!load_done)
            $fatal(1, "Conv loader timeout");

        if (error)
            $fatal(1, "Conv loader error");

        if (
            write_count_q !=
            32'(ROWS) * words_per_lane
        ) begin

            $fatal(
                1,
                "Incorrect write count: got=%0d expected=%0d",
                write_count_q,
                32'(ROWS) * words_per_lane
            );

        end

        $display(
            "Verified K_start=%0d K_size=%0d writes=%0d",
            k_start,
            load_size,
            write_count_q
        );

        @(negedge clk);

    endtask

    // ============================================================
    // Main
    // ============================================================

    initial begin

        reset = 1'b1;
        load_req = 1'b0;
        scoreboard_clear = 1'b0;

        input_h = 32'd4;
        input_w = 32'd4;
        input_c = 32'd8;

        kernel_h = 32'd3;
        kernel_w = 32'd3;

        stride_h = 32'd1;
        stride_w = 32'd1;

        pad_top = 32'd0;
        pad_left = 32'd0;

        output_w = 32'd2;
        output_positions = 32'd4;

        m_start = 32'd0;
        k_start = 32'd0;
        load_size = 9'd72;

        repeat (5) @(negedge clk);
        reset = 1'b0;

        initialize_input();
        run_tile();

        // K = 288, split into 256 + 32

        input_c = 32'd32;

        stride_h = 32'd2;
        stride_w = 32'd2;

        pad_top = 32'd1;
        pad_left = 32'd1;

        initialize_input();

        k_start = 32'd0;
        load_size = 9'd256;
        run_tile();

        k_start = 32'd256;
        load_size = 9'd32;
        run_tile();

        $display("Conv patch loader tests PASS");
        $finish;

    end

endmodule
