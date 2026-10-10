module conv_patch_loader #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ROWS = 4,
    parameter int unsigned K_DEPTH = 256,
    parameter int unsigned BUFFER_COUNT = 2,
    parameter int unsigned MAX_REQUEST_BEATS = 64,
    parameter int unsigned K_SIZE_WIDTH = $clog2(K_DEPTH + 1),
    parameter int unsigned WORD_DEPTH = (K_DEPTH + 3) / 4,
    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),
    parameter int unsigned LANE_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS),
    parameter int unsigned BANK_WIDTH =
        (BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)
) (
    input  logic                         clk,
    input  logic                         reset,

    input  logic                         load_req,
    output logic                         load_accept,
    input  logic [ADDR_WIDTH-1:0]        input_base,
    input  logic [31:0]                  input_h,
    input  logic [31:0]                  input_w,
    input  logic [31:0]                  input_c,
    input  logic [31:0]                  kernel_h,
    input  logic [31:0]                  kernel_w,
    input  logic [31:0]                  stride_h,
    input  logic [31:0]                  stride_w,
    input  logic [31:0]                  pad_top,
    input  logic [31:0]                  pad_left,
    input  logic signed [7:0]           pad_zero_point,
    input  logic [31:0]                  output_w,
    input  logic [31:0]                  output_positions,
    input  logic [31:0]                  m_start,
    input  logic [31:0]                  k_start,
    input  logic [K_SIZE_WIDTH-1:0]      load_size,

    output logic                         load_done,
    output logic                         busy,
    output logic                         error,

    output logic                         bank_load_req,
    input  logic                         bank_load_grant,
    input  logic [BANK_WIDTH-1:0]        bank_load_bank,
    output logic                         bank_load_done,

    output logic                         rd_req_valid,
    input  logic                         rd_req_ready,
    output logic [ADDR_WIDTH-1:0]        rd_req_addr,
    output logic [31:0]                  rd_req_beats,
    input  logic                         rd_data_valid,
    output logic                         rd_data_ready,
    input  logic [31:0]                  rd_data,
    input  logic                         rd_data_last,
    input  logic                         rd_done,
    input  logic                         rd_error,

    output logic                         buffer_wen,
    output logic [BANK_WIDTH-1:0]       buffer_wbank,
    output logic [LANE_WIDTH-1:0]       buffer_wlane,
    output logic [WORD_ADDR_WIDTH-1:0]  buffer_waddr,
    output logic [31:0]                  buffer_wdata
);

    // The read bus and destination SRAM word are both 32 bits.
    // Each accepted input event appends 1..4 logical K bytes.
    // A completed SRAM word is emitted with a ready/valid handshake.
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_WAIT_LOADER,
        ST_PREP,
        ST_RD_REQ,
        ST_RD_DATA,
        ST_RD_DONE,
        ST_FLUSH,
        ST_FINISH,
        ST_DONE
    } state_t;

    state_t state;

    logic [ADDR_WIDTH-1:0] input_base_q;
    logic [31:0] input_h_q, input_w_q, input_c_q;
    logic [31:0] kernel_h_q, kernel_w_q;
    logic [31:0] stride_h_q, stride_w_q;
    logic [31:0] pad_top_q, pad_left_q;
    logic [7:0] pad_zp_q;
    logic [31:0] output_w_q, output_positions_q;
    logic [31:0] m_start_q, k_start_q;
    logic [K_SIZE_WIDTH-1:0] load_size_q;

    logic [LANE_WIDTH-1:0] lane_q;
    logic [K_SIZE_WIDTH-1:0] index_q;

    // At most three uncommitted bytes, left-aligned in the sense
    // that the earliest byte occupies the least significant lane.
    logic [31:0] partial_word_q;
    logic [1:0]  fill_q;

    logic [ADDR_WIDTH-1:0] request_addr_q;
    logic [31:0] request_beats_q;
    logic [31:0] stream_beats_left_q;
    logic [31:0] stream_bytes_left_q;
    logic [1:0] stream_offset_q;

    logic loader_req, loader_accept, loader_done;
    logic loader_busy, loader_data_ready;
    logic loader_done_seen_q;
    logic loader_data_valid;
    logic [31:0] loader_data;

    logic invalid_command;
    assign invalid_command =
        (input_h == 32'd0) ||
        (input_w == 32'd0) ||
        (input_c == 32'd0) ||
        (kernel_h == 32'd0) ||
        (kernel_w == 32'd0) ||
        (stride_h == 32'd0) ||
        (stride_w == 32'd0) ||
        (output_w == 32'd0) ||
        (output_positions == 32'd0) ||
        (load_size == '0) ||
        (load_size > K_SIZE_WIDTH'(K_DEPTH));

    assign loader_req =
        (state == ST_IDLE) && load_req && !invalid_command;
    assign load_accept =
        (state == ST_IDLE) && load_req &&
        (invalid_command || loader_accept);
    assign load_done = (state == ST_DONE);
    assign busy =
        ((state != ST_IDLE) && (state != ST_DONE)) || loader_busy;

    operand_loader #(
        .ELEM_WIDTH     (8),
        .LANE_COUNT     (ROWS),
        .MEM_WORD_WIDTH (32),
        .K_DEPTH        (K_DEPTH),
        .BUFFER_COUNT   (BUFFER_COUNT)
    ) u_operand_loader (
        .clk             (clk),
        .reset           (reset),
        .load_req        (loader_req),
        .load_accept     (loader_accept),
        .load_size       (load_size),
        .load_done       (loader_done),
        .busy            (loader_busy),
        .bank_load_req   (bank_load_req),
        .bank_load_grant (bank_load_grant),
        .bank_load_bank  (bank_load_bank),
        .bank_load_done  (bank_load_done),
        .data_valid      (loader_data_valid),
        .data_ready      (loader_data_ready),
        .data            (loader_data),
        .buffer_wen      (buffer_wen),
        .buffer_wbank    (buffer_wbank),
        .buffer_wlane    (buffer_wlane),
        .buffer_waddr    (buffer_waddr),
        .buffer_wdata    (buffer_wdata)
    );

    // ============================================================
    // Logical A[m,k] -> original HWC feature-map byte address
    // ============================================================
    logic [63:0] position, flat_k;
    logic [63:0] output_y, output_x;
    logic [63:0] channel, spatial, kernel_y, kernel_x;
    logic signed [63:0] input_y, input_x;
    logic is_padding;
    logic [ADDR_WIDTH-1:0] byte_addr, word_addr;

    always_comb begin
        position = 64'(m_start_q) + 64'(lane_q);
        flat_k = 64'(k_start_q) + 64'(index_q);

        output_y = 64'd0;
        output_x = 64'd0;
        if (output_w_q != 0) begin
            output_y = position / 64'(output_w_q);
            output_x = position % 64'(output_w_q);
        end

        channel = 64'd0;
        spatial = 64'd0;
        if (input_c_q != 0) begin
            channel = flat_k % 64'(input_c_q);
            spatial = flat_k / 64'(input_c_q);
        end

        kernel_y = 64'd0;
        kernel_x = 64'd0;
        if (kernel_w_q != 0) begin
            kernel_y = spatial / 64'(kernel_w_q);
            kernel_x = spatial % 64'(kernel_w_q);
        end

        input_y =
            $signed(output_y * 64'(stride_h_q) + kernel_y) -
            $signed(64'(pad_top_q));
        input_x =
            $signed(output_x * 64'(stride_w_q) + kernel_x) -
            $signed(64'(pad_left_q));

        is_padding =
            (position >= 64'(output_positions_q)) ||
            (kernel_y >= 64'(kernel_h_q)) ||
            (input_y < 0) ||
            (input_x < 0) ||
            (input_y >= $signed(64'(input_h_q))) ||
            (input_x >= $signed(64'(input_w_q)));

        byte_addr =
            input_base_q +
            ADDR_WIDTH'(
                (64'(input_y) * 64'(input_w_q) +
                 64'(input_x)) * 64'(input_c_q) + channel
            );
        word_addr = {byte_addr[ADDR_WIDTH-1:2], 2'b00};
    end

    // ============================================================
    // Plan a physically contiguous segment, bounded by:
    // - the end of the local K tile,
    // - the current convolution-kernel row,
    // - the right edge of the valid input image,
    // - MAX_REQUEST_BEATS aligned AXI words.
    // No invalid padding byte is issued to external memory.
    // ============================================================
    logic [63:0] k_remaining;
    logic [63:0] kernel_row_remaining;
    logic [63:0] input_row_remaining;
    logic [63:0] segment_bytes;
    logic [63:0] max_segment_bytes;
    logic [31:0] planned_bytes;
    logic [31:0] planned_beats;

    always_comb begin
        k_remaining = 64'(load_size_q) - 64'(index_q);
        kernel_row_remaining =
            (64'(kernel_w_q) - kernel_x) * 64'(input_c_q) - channel;
        input_row_remaining =
            (64'(input_w_q) - $unsigned(input_x)) *
            64'(input_c_q) - channel;

        segment_bytes = k_remaining;
        if (kernel_row_remaining < segment_bytes)
            segment_bytes = kernel_row_remaining;
        if (input_row_remaining < segment_bytes)
            segment_bytes = input_row_remaining;

        max_segment_bytes =
            64'(MAX_REQUEST_BEATS) * 64'd4 - 64'(byte_addr[1:0]);
        if (max_segment_bytes < segment_bytes)
            segment_bytes = max_segment_bytes;

        planned_bytes = 32'(segment_bytes);
        planned_beats = 32'(
            (segment_bytes + 64'(byte_addr[1:0]) + 64'd3) >> 2
        );
    end

    assign rd_req_valid = (state == ST_RD_REQ);
    assign rd_req_addr = request_addr_q;
    assign rd_req_beats = request_beats_q;

    // ============================================================
    // 32-bit word assembler
    //
    // An event carries up to four *logical* bytes in low-to-high
    // order. An AXI beat may supply only 1..4 valid bytes because
    // of address alignment and the end of a contiguous segment.
    // A padding event supplies one logical zero byte.
    //
    // concatenated = partial | (incoming << (8 * fill))
    //
    // When 4+ bytes are available, emit the low 32 bits and keep
    // any excess bytes for the next SRAM word. Every emitted word
    // obeys data_valid/data_ready, so no write is lost on stalls.
    // ============================================================
    logic pad_event, read_event, append_valid;
    logic [2:0] bytes_available;
    logic [2:0] append_count;
    logic [31:0] append_data;
    logic [31:0] shifted_read_data;
    logic [4:0] append_shift;
    logic [63:0] merged_bytes;
    logic [3:0] merged_count;
    logic emits_word;
    logic event_ready;
    logic event_fire;

    assign pad_event =
        (state == ST_PREP) && (index_q < load_size_q) && is_padding;
    assign read_event = (state == ST_RD_DATA) && rd_data_valid;
    assign append_valid = pad_event || read_event;

    assign bytes_available = 3'd4 - {1'b0, stream_offset_q};

    assign shifted_read_data =
        rd_data >> {stream_offset_q, 3'b000};

    always_comb begin
        append_count = 3'd0;
        if (pad_event) begin
            append_count = 3'd1;
        end else if (read_event) begin
            if (stream_bytes_left_q < 32'(bytes_available))
                append_count = 3'(stream_bytes_left_q);
            else
                append_count = bytes_available;
        end

        // Mask trailing physical bytes that are not part of this
        // logical K segment. They must never enter partial_word_q.
        append_data = '0;
        if (pad_event) begin
            append_data = {24'd0, pad_zp_q};
        end else if (read_event) begin
            case (append_count)
                3'd1: append_data = shifted_read_data & 32'h000000ff;
                3'd2: append_data = shifted_read_data & 32'h0000ffff;
                3'd3: append_data = shifted_read_data & 32'h00ffffff;
                3'd4: append_data = shifted_read_data;
                default: append_data = '0;
            endcase
        end
    end

    assign append_shift = {fill_q, 3'b000};
    assign merged_bytes =
        {32'd0, partial_word_q} |
        ({32'd0, append_data} << append_shift);
    assign merged_count = {2'b00, fill_q} + {1'b0, append_count};
    assign emits_word = (merged_count >= 4'd4);
    assign event_ready = !emits_word || loader_data_ready;
    assign event_fire = append_valid && event_ready;

    assign loader_data_valid =
        ((state == ST_FLUSH) && (fill_q != 2'd0)) ||
        (append_valid && emits_word);

    assign loader_data =
        (state == ST_FLUSH) ? partial_word_q : merged_bytes[31:0];

    // Backpressure is applied directly to the shared read master.
    assign rd_data_ready =
        (state == ST_RD_DATA) && event_ready;

    // ============================================================
    // State and count updates
    // ============================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            input_base_q <= '0;
            input_h_q <= '0;
            input_w_q <= '0;
            input_c_q <= '0;
            kernel_h_q <= '0;
            kernel_w_q <= '0;
            stride_h_q <= '0;
            stride_w_q <= '0;
            pad_top_q <= '0;
            pad_left_q <= '0;
            pad_zp_q <= '0;
            output_w_q <= '0;
            output_positions_q <= '0;
            m_start_q <= '0;
            k_start_q <= '0;
            load_size_q <= '0;
            lane_q <= '0;
            index_q <= '0;
            partial_word_q <= '0;
            fill_q <= '0;
            request_addr_q <= '0;
            request_beats_q <= '0;
            stream_beats_left_q <= '0;
            stream_bytes_left_q <= '0;
            stream_offset_q <= '0;
            error <= 1'b0;
            loader_done_seen_q <= 1'b0;
        end else begin
            // The operand loader completes independently of the AXI
            // stream. Remember its one-cycle completion pulse until
            // the outer FSM reaches ST_FINISH.
            if (loader_done)
                loader_done_seen_q <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (load_req) begin
                        error <= 1'b0;
                        if (invalid_command) begin
                            error <= 1'b1;
                            state <= ST_DONE;
                        end else if (loader_accept) begin
                            loader_done_seen_q <= 1'b0;
                            input_base_q <= input_base;
                            input_h_q <= input_h;
                            input_w_q <= input_w;
                            input_c_q <= input_c;
                            kernel_h_q <= kernel_h;
                            kernel_w_q <= kernel_w;
                            stride_h_q <= stride_h;
                            stride_w_q <= stride_w;
                            pad_top_q <= pad_top;
                            pad_left_q <= pad_left;
                            pad_zp_q <= pad_zero_point;
                            output_w_q <= output_w;
                            output_positions_q <= output_positions;
                            m_start_q <= m_start;
                            k_start_q <= k_start;
                            load_size_q <= load_size;
                            lane_q <= '0;
                            index_q <= '0;
                            partial_word_q <= '0;
                            fill_q <= '0;
                            stream_beats_left_q <= '0;
                            stream_bytes_left_q <= '0;
                            state <= ST_WAIT_LOADER;
                        end
                    end
                end

                ST_WAIT_LOADER: begin
                    if (loader_data_ready)
                        state <= ST_PREP;
                end

                ST_PREP: begin
                    // Reaching the end of a lane either flushes an
                    // incomplete 32-bit word or starts the next lane.
                    if (index_q == load_size_q) begin
                        if (fill_q != 2'd0) begin
                            state <= ST_FLUSH;
                        end else if (32'(lane_q) == ROWS - 1) begin
                            state <= ST_FINISH;
                        end else begin
                            lane_q <= lane_q + 1'b1;
                            index_q <= '0;
                            partial_word_q <= '0;
                        end
                    end else if (is_padding) begin
                        // A zero byte goes through the *same*
                        // assembler as bytes coming from AXI.
                        if (event_fire) begin
                            index_q <= index_q + K_SIZE_WIDTH'(1);
                            fill_q <= merged_count[1:0];
                            if (emits_word)
                                partial_word_q <= merged_bytes[63:32];
                            else
                                partial_word_q <= merged_bytes[31:0];
                        end
                    end else begin
                        request_addr_q <= word_addr;
                        request_beats_q <= planned_beats;
                        stream_bytes_left_q <= planned_bytes;
                        stream_offset_q <= byte_addr[1:0];
                        state <= ST_RD_REQ;
                    end
                end

                ST_RD_REQ: begin
                    if (rd_req_ready) begin
                        stream_beats_left_q <= request_beats_q;
                        state <= ST_RD_DATA;
                    end
                end

                ST_RD_DATA: begin
                    if (event_fire) begin
                        index_q <= index_q + K_SIZE_WIDTH'(append_count);
                        fill_q <= merged_count[1:0];
                        if (emits_word)
                            partial_word_q <= merged_bytes[63:32];
                        else
                            partial_word_q <= merged_bytes[31:0];

                        stream_bytes_left_q <=
                            stream_bytes_left_q - 32'(append_count);
                        stream_beats_left_q <=
                            stream_beats_left_q - 32'd1;
                        stream_offset_q <= '0;

                        if (rd_data_last != (stream_beats_left_q == 32'd1))
                            error <= 1'b1;

                        if (stream_beats_left_q == 32'd1) begin
                            if (stream_bytes_left_q != 32'(append_count))
                                error <= 1'b1;
                            state <= ST_RD_DONE;
                        end
                    end
                end

                ST_RD_DONE: begin
                    if (rd_done) begin
                        if (rd_error)
                            error <= 1'b1;
                        state <= ST_PREP;
                    end
                end

                ST_FLUSH: begin
                    // High bytes are already zero in partial_word_q.
                    if (loader_data_ready) begin
                        partial_word_q <= '0;
                        fill_q <= '0;
                        if (32'(lane_q) == ROWS - 1) begin
                            state <= ST_FINISH;
                        end else begin
                            lane_q <= lane_q + 1'b1;
                            index_q <= '0;
                            state <= ST_PREP;
                        end
                    end
                end

                ST_FINISH: begin
                    if (loader_done_seen_q || loader_done)
                        state <= ST_DONE;
                end

                ST_DONE: begin
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (ADDR_WIDTH != 64)
            $fatal(1, "ADDR_WIDTH must be 64");
        if (ROWS < 1)
            $fatal(1, "ROWS must be >= 1");
        if (K_DEPTH < 1)
            $fatal(1, "K_DEPTH must be >= 1");
        if ((BUFFER_COUNT != 1) && (BUFFER_COUNT != 2))
            $fatal(1, "BUFFER_COUNT must be 1 or 2");
        if ((MAX_REQUEST_BEATS < 1) || (MAX_REQUEST_BEATS > 256))
            $fatal(1, "MAX_REQUEST_BEATS must be in [1,256]");
    end
endmodule
