
module conv_patch_loader #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ROWS = 4,
    parameter int unsigned K_DEPTH = 256,
    parameter int unsigned BUFFER_COUNT = 2,

    parameter int unsigned K_SIZE_WIDTH =
        $clog2(K_DEPTH + 1),

    parameter int unsigned WORD_DEPTH =
        (K_DEPTH + 3) / 4,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),

    parameter int unsigned LANE_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS),

    parameter int unsigned BANK_WIDTH =
        (BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Tile load command
    // ============================================================

    input  logic                    load_req,
    output logic                    load_accept,

    input  logic [ADDR_WIDTH-1:0]   input_base,
    input  logic [31:0]             input_h,
    input  logic [31:0]             input_w,
    input  logic [31:0]             input_c,

    input  logic [31:0]             kernel_h,
    input  logic [31:0]             kernel_w,

    input  logic [31:0]             stride_h,
    input  logic [31:0]             stride_w,

    input  logic [31:0]             pad_top,
    input  logic [31:0]             pad_left,

    input  logic [31:0]             output_w,
    input  logic [31:0]             output_positions,

    input  logic [31:0]             m_start,
    input  logic [31:0]             k_start,
    input  logic [K_SIZE_WIDTH-1:0] load_size,

    output logic load_done,
    output logic busy,
    output logic error,

    // ============================================================
    // A buffer manager
    // ============================================================

    output logic                    bank_load_req,
    input  logic                    bank_load_grant,
    input  logic [BANK_WIDTH-1:0]   bank_load_bank,
    output logic                    bank_load_done,

    // ============================================================
    // Shared read interface
    // ============================================================

    output logic                    rd_req_valid,
    input  logic                    rd_req_ready,
    output logic [ADDR_WIDTH-1:0]   rd_req_addr,
    output logic [31:0]             rd_req_beats,

    input  logic                    rd_data_valid,
    output logic                    rd_data_ready,
    input  logic [31:0]             rd_data,
    input  logic                    rd_data_last,

    input  logic                    rd_done,
    input  logic                    rd_error,

    // ============================================================
    // A SRAM write interface
    // ============================================================

    output logic                       buffer_wen,
    output logic [BANK_WIDTH-1:0]      buffer_wbank,
    output logic [LANE_WIDTH-1:0]      buffer_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] buffer_waddr,
    output logic [31:0]                buffer_wdata
);

    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_WAIT_LOADER,
        ST_PREP,
        ST_RD_REQ,
        ST_RD_DATA,
        ST_RD_DONE,
        ST_BYTE,
        ST_WORD,
        ST_ADVANCE,
        ST_FINISH,
        ST_DONE
    } state_t;

    state_t state;

    // ============================================================
    // Locked command
    // ============================================================

    logic [ADDR_WIDTH-1:0] input_base_q;

    logic [31:0] input_h_q;
    logic [31:0] input_w_q;
    logic [31:0] input_c_q;

    logic [31:0] kernel_h_q;
    logic [31:0] kernel_w_q;

    logic [31:0] stride_h_q;
    logic [31:0] stride_w_q;

    logic [31:0] pad_top_q;
    logic [31:0] pad_left_q;

    logic [31:0] output_w_q;
    logic [31:0] output_positions_q;

    logic [31:0] m_start_q;
    logic [31:0] k_start_q;

    logic [K_SIZE_WIDTH-1:0] load_size_q;

    // ============================================================
    // Current element
    // ============================================================

    logic [LANE_WIDTH-1:0] lane_q;
    logic [K_SIZE_WIDTH-1:0] index_q;

    logic [31:0] packed_word_q;
    logic [7:0] fetched_byte_q;

    logic [1:0] byte_select_q;

    // ============================================================
    // Operand loader
    // ============================================================

    logic loader_req;
    logic loader_accept;
    logic loader_done;
    logic loader_busy;

    logic loader_data_valid;
    logic loader_data_ready;

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
        (state == ST_IDLE) &&
        load_req &&
        !invalid_command;

    assign load_accept =
        (state == ST_IDLE) &&
        load_req &&
        (
            invalid_command ||
            loader_accept
        );

    assign loader_data_valid =
        (state == ST_WORD);

    assign load_done =
        (state == ST_DONE);

    assign busy =
        (
            (state != ST_IDLE) &&
            (state != ST_DONE)
        ) ||
        loader_busy;

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
        .data            (packed_word_q),

        .buffer_wen      (buffer_wen),
        .buffer_wbank    (buffer_wbank),
        .buffer_wlane    (buffer_wlane),
        .buffer_waddr    (buffer_waddr),
        .buffer_wdata    (buffer_wdata)
    );

    // ============================================================
    // HWC address generation
    // ============================================================

    logic [63:0] position;
    logic [63:0] flat_k;

    logic [63:0] output_y;
    logic [63:0] output_x;

    logic [63:0] channel;
    logic [63:0] kernel_y;
    logic [63:0] kernel_x;
    logic [63:0] spatial;

    logic signed [63:0] input_y;
    logic signed [63:0] input_x;

    logic is_padding;

    logic [ADDR_WIDTH-1:0] byte_addr;

    always_comb begin

        position =
            64'(m_start_q) +
            64'(lane_q);

        flat_k =
            64'(k_start_q) +
            64'(index_q);

        output_y = 64'd0;
        output_x = 64'd0;

        channel = 64'd0;
        spatial = 64'd0;

        kernel_y = 64'd0;
        kernel_x = 64'd0;

        if (output_w_q != 0) begin

            output_y =
                position / 64'(output_w_q);

            output_x =
                position % 64'(output_w_q);

        end

        if (input_c_q != 0) begin

            channel =
                flat_k % 64'(input_c_q);

            spatial =
                flat_k / 64'(input_c_q);

        end

        if (kernel_w_q != 0) begin

            kernel_y =
                spatial / 64'(kernel_w_q);

            kernel_x =
                spatial % 64'(kernel_w_q);

        end

        input_y =
            $signed(
                output_y * 64'(stride_h_q) +
                kernel_y
            ) -
            $signed(64'(pad_top_q));

        input_x =
            $signed(
                output_x * 64'(stride_w_q) +
                kernel_x
            ) -
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
                (
                    64'(input_y) * 64'(input_w_q) +
                    64'(input_x)
                ) * 64'(input_c_q) +
                channel
            );

    end

    // ============================================================
    // Shared read request
    // ============================================================

    assign rd_req_valid =
        (state == ST_RD_REQ);

    assign rd_req_addr = {
        byte_addr[ADDR_WIDTH-1:2],
        2'b00
    };

    assign rd_req_beats = 32'd1;

    assign rd_data_ready =
        (state == ST_RD_DATA);

    // ============================================================
    // Main FSM
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

            output_w_q <= '0;
            output_positions_q <= '0;

            m_start_q <= '0;
            k_start_q <= '0;
            load_size_q <= '0;

            lane_q <= '0;
            index_q <= '0;

            packed_word_q <= '0;
            fetched_byte_q <= '0;
            byte_select_q <= '0;

            error <= 1'b0;

        end else begin

            case (state)

                ST_IDLE: begin

                    if (load_req) begin

                        error <= 1'b0;

                        if (invalid_command) begin

                            error <= 1'b1;
                            state <= ST_DONE;

                        end else if (loader_accept) begin

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

                            output_w_q <= output_w;
                            output_positions_q <= output_positions;

                            m_start_q <= m_start;
                            k_start_q <= k_start;
                            load_size_q <= load_size;

                            lane_q <= '0;
                            index_q <= '0;

                            packed_word_q <= '0;

                            state <= ST_WAIT_LOADER;

                        end

                    end

                end

                ST_WAIT_LOADER: begin

                    if (loader_data_ready) begin
                        state <= ST_PREP;
                    end

                end

                ST_PREP: begin

                    if (is_padding) begin

                        fetched_byte_q <= 8'd0;
                        state <= ST_BYTE;

                    end else begin

                        byte_select_q <= byte_addr[1:0];
                        state <= ST_RD_REQ;

                    end

                end

                ST_RD_REQ: begin

                    if (rd_req_ready) begin
                        state <= ST_RD_DATA;
                    end

                end

                ST_RD_DATA: begin

                    if (rd_data_valid && rd_data_ready) begin

                        fetched_byte_q <=
                            rd_data[8*byte_select_q +: 8];

                        if (!rd_data_last) begin
                            error <= 1'b1;
                        end

                        state <= ST_RD_DONE;

                    end

                end

                ST_RD_DONE: begin

                    if (rd_done) begin

                        if (rd_error) begin
                            error <= 1'b1;
                        end

                        state <= ST_BYTE;

                    end

                end

                ST_BYTE: begin

                    packed_word_q[8*index_q[1:0] +: 8] <=
                        fetched_byte_q;

                    if (
                        (index_q[1:0] == 2'd3) ||
                        (index_q + 1'b1 == load_size_q)
                    ) begin

                        state <= ST_WORD;

                    end else begin

                        state <= ST_ADVANCE;

                    end

                end

                ST_WORD: begin

                    if (loader_data_ready) begin

                        packed_word_q <= '0;

                        // Last word: synchronize with operand_loader
                        // completion without an extra ADVANCE cycle.

                        if (
                            (index_q + 1'b1 == load_size_q) &&
                            (32'(lane_q) == ROWS - 1)
                        ) begin

                            state <= ST_FINISH;

                        end else begin

                            state <= ST_ADVANCE;

                        end

                    end

                end

                ST_ADVANCE: begin

                    if (
                        index_q + 1'b1 == load_size_q
                    ) begin

                        index_q <= '0;

                        if (32'(lane_q) == ROWS - 1) begin

                            state <= ST_FINISH;

                        end else begin

                            lane_q <= lane_q + 1'b1;
                            state <= ST_PREP;

                        end

                    end else begin

                        index_q <= index_q + 1'b1;
                        state <= ST_PREP;

                    end

                end

                ST_FINISH: begin

                    if (loader_done) begin
                        state <= ST_DONE;
                    end

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

    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ADDR_WIDTH != 64) begin
            $fatal(1, "ADDR_WIDTH must be 64");
        end

        if (K_DEPTH < 1) begin
            $fatal(1, "K_DEPTH must be >= 1");
        end

        if (ROWS < 1) begin
            $fatal(1, "ROWS must be >= 1");
        end

    end

endmodule
