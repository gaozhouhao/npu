
module npu_pool_engine #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1
) (
    input logic clk,
    input logic reset,

    input logic cmd_valid,
    output logic cmd_ready,

    // 0: configurable MaxPool with explicit padding
    // 1: Global Average Pooling
    input logic cmd_global_avg,

    input logic [ADDR_WIDTH-1:0] cmd_input_base,
    input logic [ADDR_WIDTH-1:0] cmd_output_base,
    input logic [31:0] cmd_input_h,
    input logic [31:0] cmd_input_w,
    input logic [31:0] cmd_channels,
    // Zero preserves 2x2, stride 2. Otherwise: {SW, SH, KW, KH}.
    input logic [31:0] cmd_pool_config,
    // Descriptor word 10: {right, bottom, left, top}, one byte per side.
    // Padding is geometry only; out-of-input samples never issue reads.
    input logic [31:0] cmd_pool_padding,

    output logic busy,
    output logic done,
    output logic error,

    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input logic m_axi_arready,

    input logic [ID_WIDTH-1:0] m_axi_rid,
    input logic [31:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    input logic m_axi_rvalid,
    output logic m_axi_rready,

    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,

    output logic [31:0] m_axi_wdata,
    output logic [3:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,

    input logic [ID_WIDTH-1:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_SAMPLE_CHECK,
        ST_SAMPLE_NEXT,
        ST_RD_REQ,
        ST_RD_DATA,
        ST_RD_DONE,
        ST_WR_REQ,
        ST_WR_DATA,
        ST_WR_DONE,
        ST_DONE
    } state_t;

    state_t state_q;

    logic global_avg_q;

    logic [ADDR_WIDTH-1:0] input_base_q;
    logic [ADDR_WIDTH-1:0] output_base_q;

    logic [31:0] input_h_q, input_w_q;
    logic [31:0] channels_q;
    logic [31:0] out_h_q;
    logic [31:0] out_w_q;

    // Used by the MaxPool path. Coordinates count positions inside a window;
    // top/left padding translates them back to the real input tensor.
    logic [31:0] oh_q, ow_q, cw_q;
    logic [7:0] kernel_h_q, kernel_w_q;
    logic [7:0] stride_h_q, stride_w_q;
    logic [7:0] pad_top_q, pad_left_q;
    logic padding_q;
    logic [7:0] sample_y_q, sample_x_q;
    logic [31:0] max_word_q;
    logic max_valid_q;
    logic [7:0] command_kernel_h, command_kernel_w;
    logic [7:0] command_stride_h, command_stride_w;
    logic [7:0] command_pad_top, command_pad_left;
    logic [7:0] command_pad_bottom, command_pad_right;
    logic command_geometry_valid, command_pool_valid;
    logic [63:0] command_padded_h, command_padded_w;
    logic [63:0] command_out_h_calc, command_out_w_calc;
    logic [31:0] command_out_h, command_out_w;
    logic signed [63:0] sample_input_y, sample_input_x;
    logic sample_valid;

    // Used by Global Average path.
    logic [31:0] spatial_q;
    logic [31:0] pixel_count_q;
    logic signed [31:0] sum_q [0:3];
    logic [31:0] avg_word;

    logic [63:0] command_pixel_count;
    logic [95:0] command_input_bytes, command_output_bytes;
    logic [96:0] command_input_last, command_output_last;
    logic command_addresses_valid;

    logic rd_req_ready, rd_data_valid, rd_data_ready;
    logic [31:0] rd_data;
    logic rd_data_last, rd_done, rd_error, rd_busy;

    logic wr_req_ready, wr_data_ready;
    logic wr_done, wr_error, wr_busy;

    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [ADDR_WIDTH-1:0] wr_addr;

    // ============================================================
    // Arithmetic
    // ============================================================

    function automatic logic [31:0] max_signed4(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic [31:0] result;

        for (int i = 0; i < 4; i++) begin
            if (
                $signed(a[8*i +: 8]) >=
                $signed(b[8*i +: 8])
            )
                result[8*i +: 8] = a[8*i +: 8];
            else
                result[8*i +: 8] = b[8*i +: 8];
        end

        return result;
    endfunction

    // Integer average with round-half-away-from-zero.
    //
    // Note: a variable division is synthesized here.
    // This is a functional baseline, not a PPA-optimized
    // reciprocal-multiply / iterative-divider design.

    function automatic logic [7:0] rounded_average(
        input logic signed [31:0] total,
        input logic [31:0] count
    );
        logic signed [63:0] signed_total;
        logic signed [63:0] divisor;
        logic signed [63:0] quotient;

        signed_total = 64'(total);
        divisor = $signed({32'd0, count});
        quotient = '0;

        if (count != 32'd0) begin
            if (signed_total < 0) begin
                quotient = -(
                    ((-signed_total) + (divisor >>> 1))
                    / divisor
                );
            end else begin
                quotient = (
                    signed_total + (divisor >>> 1)
                ) / divisor;
            end
        end

        // Check full quotient before INT8 conversion.
        // A correct average is naturally within INT8 range.
        if (quotient > 64'sd127)
            return 8'h7f;
        if (quotient < -64'sd128)
            return 8'h80;

        return 8'(quotient);
    endfunction

    always_comb begin
        avg_word = '0;

        for (int i = 0; i < 4; i++) begin
            avg_word[8*i +: 8] =
                rounded_average(sum_q[i], pixel_count_q);
        end
    end

    // ============================================================
    // Address generation
    // ============================================================

    assign command_pixel_count =
        64'(cmd_input_h) * 64'(cmd_input_w);

    assign command_kernel_h =
        (cmd_pool_config == 32'd0) ? 8'd2 : cmd_pool_config[7:0];
    assign command_kernel_w =
        (cmd_pool_config == 32'd0) ? 8'd2 : cmd_pool_config[15:8];
    assign command_stride_h =
        (cmd_pool_config == 32'd0) ? 8'd2 : cmd_pool_config[23:16];
    assign command_stride_w =
        (cmd_pool_config == 32'd0) ? 8'd2 : cmd_pool_config[31:24];
    assign command_pad_top = cmd_pool_padding[7:0];
    assign command_pad_left = cmd_pool_padding[15:8];
    assign command_pad_bottom = cmd_pool_padding[23:16];
    assign command_pad_right = cmd_pool_padding[31:24];
    assign command_padded_h = 64'(cmd_input_h) +
        64'(command_pad_top) + 64'(command_pad_bottom);
    assign command_padded_w = 64'(cmd_input_w) +
        64'(command_pad_left) + 64'(command_pad_right);
    // Each window must overlap the real input. Requiring padding < kernel
    // prevents wholly padded windows, including with input < kernel.
    assign command_geometry_valid =
        (cmd_input_h != 32'd0) && (cmd_input_w != 32'd0) &&
        (command_kernel_h != 8'd0) &&
        (command_kernel_w != 8'd0) &&
        (command_stride_h != 8'd0) &&
        (command_stride_w != 8'd0) &&
        (command_pad_top < command_kernel_h) &&
        (command_pad_bottom < command_kernel_h) &&
        (command_pad_left < command_kernel_w) &&
        (command_pad_right < command_kernel_w) &&
        (command_padded_h >= 64'(command_kernel_h)) &&
        (command_padded_w >= 64'(command_kernel_w));
    // Guard malformed commands before subtracting or dividing.
    assign command_out_h_calc = command_geometry_valid ?
        ((command_padded_h - 64'(command_kernel_h)) /
         64'(command_stride_h)) + 64'd1 : 64'd0;
    assign command_out_w_calc = command_geometry_valid ?
        ((command_padded_w - 64'(command_kernel_w)) /
         64'(command_stride_w)) + 64'd1 : 64'd0;
    assign command_pool_valid = command_geometry_valid &&
        command_out_h_calc <= 64'hffff_ffff &&
        command_out_w_calc <= 64'hffff_ffff;
    assign command_out_h = 32'(command_out_h_calc);
    assign command_out_w = 32'(command_out_w_calc);

    // The HWC tensor span can require 96 bits even though each dimension
    // is only 32 bits. Check before narrowing addresses for the AXI port.
    assign command_input_bytes =
        96'(cmd_input_h) * 96'(cmd_input_w) * 96'(cmd_channels);
    assign command_output_bytes = cmd_global_avg ? 96'(cmd_channels) :
        96'(command_out_h) * 96'(command_out_w) * 96'(cmd_channels);
    assign command_input_last = 97'(cmd_input_base) +
        97'(command_input_bytes) - 97'd1;
    assign command_output_last = 97'(cmd_output_base) +
        97'(command_output_bytes) - 97'd1;
    assign command_addresses_valid =
        ((command_input_last >> ADDR_WIDTH) == 97'd0) &&
        ((command_output_last >> ADDR_WIDTH) == 97'd0);

    // Global Average uses:
    //   read pixel 0, channel group 0
    //   read pixel 1, channel group 0
    //   ...
    //   then channel group 1
    //
    // Each group contains 4 adjacent INT8 channels.

    // Signed, widened coordinates preserve negative top/left positions and
    // avoid wrapping a boundary sample into a valid-looking AXI address.
    assign sample_input_y =
        $signed({32'd0, oh_q}) * $signed({56'd0, stride_h_q}) +
        $signed({56'd0, sample_y_q}) - $signed({56'd0, pad_top_q});
    assign sample_input_x =
        $signed({32'd0, ow_q}) * $signed({56'd0, stride_w_q}) +
        $signed({56'd0, sample_x_q}) - $signed({56'd0, pad_left_q});
    assign sample_valid =
        sample_input_y >= 64'sd0 && sample_input_x >= 64'sd0 &&
        sample_input_y < $signed({32'd0, input_h_q}) &&
        sample_input_x < $signed({32'd0, input_w_q});

    assign rd_addr =
        global_avg_q
        ? input_base_q +
          ADDR_WIDTH'(
              64'(spatial_q) * 64'(channels_q) +
              (64'(cw_q) << 2)
          )
        : !sample_valid ? input_base_q : input_base_q +
          ADDR_WIDTH'(
              (
                  $unsigned(sample_input_y) * 64'(input_w_q) +
                  $unsigned(sample_input_x)
              ) * 64'(channels_q) +
              (64'(cw_q) << 2)
          );

    assign wr_addr =
        global_avg_q
        ? output_base_q +
          ADDR_WIDTH'(64'(cw_q) << 2)
        : output_base_q +
          ADDR_WIDTH'(
              (
                  64'(oh_q) * 64'(out_w_q) +
                  64'(ow_q)
              ) * 64'(channels_q) +
              (64'(cw_q) << 2)
          );

    // ============================================================
    // AXI read
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(32),
        .ID_WIDTH(ID_WIDTH)
    ) u_rd (
        .clk(clk),
        .reset(reset),

        .req_valid((state_q == ST_RD_REQ) && (global_avg_q || sample_valid)),
        .req_ready(rd_req_ready),
        .req_addr(rd_addr),
        .req_beats(32'd1),

        .data_valid(rd_data_valid),
        .data_ready(rd_data_ready),
        .data(rd_data),
        .data_last(rd_data_last),

        .busy(rd_busy),
        .done(rd_done),
        .error(rd_error),

        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),

        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    assign rd_data_ready =
        (state_q == ST_RD_DATA);

    // ============================================================
    // AXI write
    // ============================================================

    axi_write_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(32),
        .ID_WIDTH(ID_WIDTH)
    ) u_wr (
        .clk(clk),
        .reset(reset),

        .req_valid(state_q == ST_WR_REQ),
        .req_ready(wr_req_ready),
        .req_addr(wr_addr),
        .req_beats(32'd1),

        .data_valid(state_q == ST_WR_DATA),
        .data_ready(wr_data_ready),
        .data(global_avg_q ? avg_word : max_word_q),

        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error),

        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),

        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),

        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    assign cmd_ready = (state_q == ST_IDLE);
    assign done = (state_q == ST_DONE);

    assign busy =
        ((state_q != ST_IDLE) && (state_q != ST_DONE)) ||
        rd_busy || wr_busy;

    // ============================================================
    // Control FSM
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;

            global_avg_q <= 1'b0;

            input_base_q <= '0;
            output_base_q <= '0;

            input_h_q <= '0;
            input_w_q <= '0;
            channels_q <= '0;
            out_h_q <= '0;
            out_w_q <= '0;

            oh_q <= '0;
            ow_q <= '0;
            cw_q <= '0;

            kernel_h_q <= '0;
            kernel_w_q <= '0;
            stride_h_q <= '0;
            stride_w_q <= '0;
            pad_top_q <= '0;
            pad_left_q <= '0;
            padding_q <= 1'b0;
            sample_y_q <= '0;
            sample_x_q <= '0;
            max_word_q <= '0;
            max_valid_q <= 1'b0;

            spatial_q <= '0;
            pixel_count_q <= '0;

            for (int i = 0; i < 4; i++)
                sum_q[i] <= '0;

            error <= 1'b0;
        end else begin
            case (state_q)

                // ================================================
                // Receive command
                // ================================================

                ST_IDLE: begin
                    if (cmd_valid) begin
                        error <= 1'b0;

                        if (
                            cmd_input_h == 32'd0 ||
                            cmd_input_w == 32'd0 ||
                            cmd_channels == 32'd0 ||
                            cmd_channels[1:0] != 2'b00 ||
                            cmd_input_base[1:0] != 2'b00 ||
                            cmd_output_base[1:0] != 2'b00 ||
                            !command_addresses_valid ||
                            (
                                !cmd_global_avg &&
                                !command_pool_valid
                            ) ||
                            (
                                cmd_global_avg &&
                                (cmd_pool_config != 32'd0 ||
                                 cmd_pool_padding != 32'd0 ||
                                 command_pixel_count >
                                    64'd16_777_215)
                            )
                        ) begin
                            error <= 1'b1;
                            state_q <= ST_DONE;
                        end else begin
                            global_avg_q <= cmd_global_avg;

                            input_base_q <= cmd_input_base;
                            output_base_q <= cmd_output_base;

                            input_h_q <= cmd_input_h;
                            input_w_q <= cmd_input_w;
                            channels_q <= cmd_channels;

                            out_h_q <= command_out_h;
                            out_w_q <= command_out_w;
                            kernel_h_q <= command_kernel_h;
                            kernel_w_q <= command_kernel_w;
                            stride_h_q <= command_stride_h;
                            stride_w_q <= command_stride_w;
                            pad_top_q <= command_pad_top;
                            pad_left_q <= command_pad_left;
                            padding_q <= cmd_pool_padding != 32'd0;

                            oh_q <= '0;
                            ow_q <= '0;
                            cw_q <= '0;

                            sample_y_q <= '0;
                            sample_x_q <= '0;
                            max_word_q <= '0;
                            max_valid_q <= 1'b0;

                            spatial_q <= '0;
                            pixel_count_q <=
                                32'(command_pixel_count);

                            for (int i = 0; i < 4; i++)
                                sum_q[i] <= '0;

                            // Keep the original no-padding command timing.
                            state_q <= (cmd_global_avg || cmd_pool_padding == 0)
                                ? ST_RD_REQ : ST_SAMPLE_CHECK;
                        end
                    end
                end

                // ================================================
                // Check one window position before issuing any memory request.
                // ================================================

                ST_SAMPLE_CHECK: begin
                    state_q <= sample_valid ? ST_RD_REQ : ST_SAMPLE_NEXT;
                end

                // A skipped padding sample has no read completion to wait for.
                // Advance it here using the same window order as ST_RD_DONE.
                ST_SAMPLE_NEXT: begin
                    if (sample_y_q == kernel_h_q - 8'd1 &&
                        sample_x_q == kernel_w_q - 8'd1) begin
                        if (max_valid_q)
                            state_q <= ST_WR_REQ;
                        else begin
                            error <= 1'b1;
                            state_q <= ST_DONE;
                        end
                    end else begin
                        if (sample_x_q == kernel_w_q - 8'd1) begin
                            sample_x_q <= '0;
                            sample_y_q <= sample_y_q + 8'd1;
                        end else begin
                            sample_x_q <= sample_x_q + 8'd1;
                        end
                        state_q <= ST_SAMPLE_CHECK;
                    end
                end

                // ================================================
                // Issue AXI read for a real input position
                // ================================================

                ST_RD_REQ: begin
                    if (rd_req_ready)
                        state_q <= ST_RD_DATA;
                end

                // ================================================
                // Receive one word, four INT8 channels
                // ================================================

                ST_RD_DATA: begin
                    if (rd_data_valid && rd_data_ready) begin

                        if (!rd_data_last) begin
                            error <= 1'b1;
                            state_q <= ST_DONE;
                        end else begin

                            if (global_avg_q) begin

                                for (int i = 0; i < 4; i++) begin
                                    sum_q[i] <= sum_q[i] +
                                        32'($signed(
                                            rd_data[8*i +: 8]
                                        ));
                                end

                            end else begin

                                max_word_q <=
                                    !max_valid_q
                                    ? rd_data
                                    : max_signed4(
                                        max_word_q, rd_data
                                    );
                                max_valid_q <= 1'b1;
                            end

                            state_q <= ST_RD_DONE;
                        end
                    end
                end

                // ================================================
                // Wait for AXI read transaction completion
                // ================================================

                ST_RD_DONE: begin
                    if (rd_done) begin

                        if (rd_error) begin
                            error <= 1'b1;
                            state_q <= ST_DONE;

                        end else if (global_avg_q) begin

                            if (
                                (spatial_q + 32'd1) <
                                pixel_count_q
                            ) begin
                                spatial_q <= spatial_q + 32'd1;
                                state_q <= ST_RD_REQ;
                            end else begin
                                state_q <= ST_WR_REQ;
                            end

                        end else if (
                            sample_y_q == kernel_h_q - 8'd1 &&
                            sample_x_q == kernel_w_q - 8'd1
                        ) begin
                            state_q <= ST_WR_REQ;
                        end else begin
                            if (sample_x_q == kernel_w_q - 8'd1) begin
                                sample_x_q <= '0;
                                sample_y_q <= sample_y_q + 8'd1;
                            end else begin
                                sample_x_q <= sample_x_q + 8'd1;
                            end
                            state_q <= padding_q ? ST_SAMPLE_CHECK : ST_RD_REQ;
                        end
                    end
                end

                // ================================================
                // Write one output word
                // ================================================

                ST_WR_REQ: begin
                    if (wr_req_ready)
                        state_q <= ST_WR_DATA;
                end

                ST_WR_DATA: begin
                    if (wr_data_ready)
                        state_q <= ST_WR_DONE;
                end

                ST_WR_DONE: begin
                    if (wr_done) begin

                        if (wr_error) begin
                            error <= 1'b1;
                            state_q <= ST_DONE;

                        end else if (
                            (cw_q + 32'd1) <
                            (channels_q >> 2)
                        ) begin

                            // Next group of four channels.
                            cw_q <= cw_q + 32'd1;
                            sample_y_q <= '0;
                            sample_x_q <= '0;
                            max_valid_q <= 1'b0;
                            spatial_q <= '0;

                            for (int i = 0; i < 4; i++)
                                sum_q[i] <= '0;

                            state_q <= (global_avg_q || !padding_q)
                                ? ST_RD_REQ : ST_SAMPLE_CHECK;

                        end else if (global_avg_q) begin

                            // One result for every channel.
                            state_q <= ST_DONE;

                        end else if (
                            (ow_q + 32'd1) < out_w_q
                        ) begin

                            cw_q <= '0;
                            ow_q <= ow_q + 32'd1;
                            sample_y_q <= '0;
                            sample_x_q <= '0;
                            max_valid_q <= 1'b0;
                            state_q <= padding_q ? ST_SAMPLE_CHECK : ST_RD_REQ;

                        end else if (
                            (oh_q + 32'd1) < out_h_q
                        ) begin

                            cw_q <= '0;
                            ow_q <= '0;
                            oh_q <= oh_q + 32'd1;
                            sample_y_q <= '0;
                            sample_x_q <= '0;
                            max_valid_q <= 1'b0;
                            state_q <= padding_q ? ST_SAMPLE_CHECK : ST_RD_REQ;

                        end else begin
                            state_q <= ST_DONE;
                        end
                    end
                end

                ST_DONE: begin
                    state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
