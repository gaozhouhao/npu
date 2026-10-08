
module gemm_executor #(
    parameter int unsigned ADDR_WIDTH       = 64,
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned ROWS             = 4,
    parameter int unsigned COLS             = 4,
    parameter int unsigned DATA_WIDTH       = 8,
    parameter int unsigned ACC_WIDTH        = 32,
    parameter int unsigned MEM_WORD_WIDTH   = 32,
    parameter int unsigned ID_WIDTH         = 1,
    parameter int unsigned K_TILE_SIZE      = 256,
    parameter int unsigned A_BUFFER_COUNT   = 2,
    parameter int unsigned B_BUFFER_COUNT   = 2,

    parameter int unsigned K_SIZE_WIDTH =
        $clog2(K_TILE_SIZE + 1),

    parameter int unsigned CORE_ADDR_WIDTH =
        (K_TILE_SIZE <= 1) ? 1 : $clog2(K_TILE_SIZE),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / DATA_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_TILE_SIZE + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),

    parameter int unsigned A_LANE_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS),

    parameter int unsigned B_LANE_WIDTH =
        (COLS <= 1) ? 1 : $clog2(COLS)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // GEMM / Conv command
    // ============================================================

    input  logic                  cmd_valid,
    output logic                  cmd_ready,

    input  logic [31:0]           cmd_m,
    input  logic [31:0]           cmd_n,
    input  logic [31:0]           cmd_k,

    input  logic [ADDR_WIDTH-1:0] cmd_a_base,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base,

    input  logic [31:0] cmd_a_stride_bytes,
    input  logic [31:0] cmd_b_stride_bytes,
    input  logic [31:0] cmd_c_stride_bytes,

    input logic cmd_conv_mode,
    input logic [31:0] cmd_conv_input_h,
    input logic [31:0] cmd_conv_input_w,
    input logic [31:0] cmd_conv_input_c,
    input logic [31:0] cmd_conv_kernel_h,
    input logic [31:0] cmd_conv_kernel_w,
    input logic [31:0] cmd_conv_stride_h,
    input logic [31:0] cmd_conv_stride_w,
    input logic [31:0] cmd_conv_pad_top,
    input logic [31:0] cmd_conv_pad_left,
    input logic [31:0] cmd_conv_output_w,
    input logic [31:0] cmd_conv_output_positions,

    // ============================================================
    // Epilogue configuration
    // ============================================================

    input logic cmd_bias_en,
    input logic cmd_requant_en,
    input logic cmd_relu_en,
    input logic [ADDR_WIDTH-1:0] cmd_param_base,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    output logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS],

    // ============================================================
    // AXI read
    // ============================================================

    output logic [ID_WIDTH-1:0]       m_axi_arid,
    output logic [ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    input  logic [ID_WIDTH-1:0]       m_axi_rid,
    input  logic [MEM_WORD_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready,

    // ============================================================
    // AXI write
    // ============================================================

    output logic [ID_WIDTH-1:0]       m_axi_awid,
    output logic [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    output logic [MEM_WORD_WIDTH-1:0] m_axi_wdata,
    output logic [(MEM_WORD_WIDTH/8)-1:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input  logic m_axi_wready,

    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [1:0]          m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready
);

    localparam int unsigned PARAM_BIAS_OFFSET = 16;
    localparam int unsigned BIAS_BYTES = ACC_WIDTH / 8;
    localparam int unsigned BIAS_TILE_BYTES = COLS * BIAS_BYTES;

    // ============================================================
    // Executor state
    // ============================================================

    typedef enum logic [1:0] {
        EX_IDLE,
        EX_LAUNCH,
        EX_RUN,
        EX_DONE
    } exec_state_t;

    exec_state_t exec_state;

    // ============================================================
    // Locked command
    // ============================================================

    logic [ADDR_WIDTH-1:0] a_base_q;
    logic [ADDR_WIDTH-1:0] b_base_q;
    logic [ADDR_WIDTH-1:0] c_base_q;

    logic [31:0] a_stride_q;
    logic [31:0] b_stride_q;
    logic [31:0] c_stride_q;

    logic bias_en_q;
    logic requant_en_q;
    logic relu_en_q;

    logic [ADDR_WIDTH-1:0] param_base_q;

    logic conv_mode_q;

    logic [31:0] conv_input_h_q;
    logic [31:0] conv_input_w_q;
    logic [31:0] conv_input_c_q;
    logic [31:0] conv_kernel_h_q;
    logic [31:0] conv_kernel_w_q;
    logic [31:0] conv_stride_h_q;
    logic [31:0] conv_stride_w_q;
    logic [31:0] conv_pad_top_q;
    logic [31:0] conv_pad_left_q;
    logic [31:0] conv_output_w_q;
    logic [31:0] conv_output_positions_q;

    // ============================================================
    // Tile count
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_calc;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_calc;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_calc;
    logic [K_SIZE_WIDTH-1:0] last_k_size_calc;

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_q;
    logic [K_SIZE_WIDTH-1:0] last_k_size_q;

    always_comb begin

        m_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (cmd_m + 32'(ROWS - 1)) / 32'(ROWS)
            );

        n_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (cmd_n + 32'(COLS - 1)) / 32'(COLS)
            );

        k_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (cmd_k + 32'(K_TILE_SIZE - 1)) /
                32'(K_TILE_SIZE)
            );

        if ((cmd_k % 32'(K_TILE_SIZE)) == 32'd0) begin

            last_k_size_calc =
                K_SIZE_WIDTH'(K_TILE_SIZE);

        end else begin

            last_k_size_calc =
                K_SIZE_WIDTH'(cmd_k % 32'(K_TILE_SIZE));

        end

    end

    logic command_invalid;

    assign command_invalid =
        (cmd_m == 32'd0) ||
        (cmd_n == 32'd0) ||
        (cmd_k == 32'd0) ||
        (cmd_relu_en && !cmd_requant_en) ||
        (
            (cmd_bias_en || cmd_requant_en) &&
            (cmd_param_base[1:0] != 2'b00)
        );

    // ============================================================
    // Tile scheduler signals
    // ============================================================

    logic scheduler_start;
    logic scheduler_busy;
    logic scheduler_done;

    logic scheduler_a_load_req;
    logic scheduler_a_load_accept;
    logic scheduler_a_load_done;

    logic scheduler_b_load_req;
    logic scheduler_b_load_accept;
    logic scheduler_b_load_done;

    logic [TILE_COUNT_WIDTH-1:0] load_m_tile_idx;
    logic [TILE_COUNT_WIDTH-1:0] load_n_tile_idx;
    logic [TILE_COUNT_WIDTH-1:0] load_k_tile_idx;

    logic [K_SIZE_WIDTH-1:0] scheduler_load_k_size;

    logic scheduler_a_compute_req;
    logic scheduler_a_compute_grant;
    logic scheduler_a_compute_done;
    logic scheduler_a_release_bank;

    logic scheduler_b_compute_req;
    logic scheduler_b_compute_grant;
    logic scheduler_b_compute_done;
    logic scheduler_b_release_bank;

    logic scheduler_matrix_start;
    logic scheduler_clear_acc;
    logic scheduler_writeback_en;

    logic [K_SIZE_WIDTH-1:0] scheduler_compute_k_size;

    logic [TILE_COUNT_WIDTH-1:0] compute_m_tile_idx;
    logic [TILE_COUNT_WIDTH-1:0] compute_n_tile_idx;

    // ============================================================
    // Address generation
    // ============================================================

    logic [ADDR_WIDTH-1:0] a_tile_addr;
    logic [ADDR_WIDTH-1:0] b_tile_addr;
    logic [ADDR_WIDTH-1:0] c_tile_addr;

    logic [31:0] conv_m_start;
    logic [31:0] conv_k_start;

    assign conv_m_start =
        32'(load_m_tile_idx) * 32'(ROWS);

    assign conv_k_start =
        32'(load_k_tile_idx) * 32'(K_TILE_SIZE);

    // ============================================================
    // Buffer managers
    // ============================================================

    logic a_bank_load_req;
    logic a_bank_load_grant;
    logic a_bank_load_bank;
    logic a_bank_load_done;

    logic b_bank_load_req;
    logic b_bank_load_grant;
    logic b_bank_load_bank;
    logic b_bank_load_done;

    logic a_compute_bank;
    logic b_compute_bank;

    // ============================================================
    // DMA -> SRAM
    // ============================================================

    logic a_wen;
    logic a_wbank;
    logic [A_LANE_WIDTH-1:0] a_wlane;
    logic [WORD_ADDR_WIDTH-1:0] a_waddr;
    logic [MEM_WORD_WIDTH-1:0] a_wdata;

    logic b_wen;
    logic b_wbank;
    logic [B_LANE_WIDTH-1:0] b_wlane;
    logic [WORD_ADDR_WIDTH-1:0] b_waddr;
    logic [MEM_WORD_WIDTH-1:0] b_wdata;

    logic read_path_busy;
    logic read_path_error;
    logic a_load_error;
    logic b_load_error;

    // ============================================================
    // Operand AXI
    // ============================================================

    logic [ID_WIDTH-1:0] operand_axi_arid;
    logic [ADDR_WIDTH-1:0] operand_axi_araddr;
    logic [7:0] operand_axi_arlen;
    logic [2:0] operand_axi_arsize;
    logic [1:0] operand_axi_arburst;
    logic operand_axi_arvalid;
    logic operand_axi_arready;

    logic [ID_WIDTH-1:0] operand_axi_rid;
    logic [MEM_WORD_WIDTH-1:0] operand_axi_rdata;
    logic [1:0] operand_axi_rresp;
    logic operand_axi_rlast;
    logic operand_axi_rvalid;
    logic operand_axi_rready;

    // ============================================================
    // GEMM core / C SRAM
    // ============================================================

    logic core_busy;
    logic core_done;

    logic c_ren;
    logic [CORE_ADDR_WIDTH-1:0] c_raddr;
    logic [COLS*ACC_WIDTH-1:0] c_rdata_raw;
    logic [COLS*ACC_WIDTH-1:0] c_rdata_write;

    logic signed [ACC_WIDTH-1:0] c_lane_raw [COLS];
    logic signed [ACC_WIDTH-1:0] c_lane_int32 [COLS];
    logic signed [7:0] c_lane_int8 [COLS];

    // ============================================================
    // Epilogue parameter loading
    // ============================================================

    logic global_param_request_pending_q;
    logic global_param_ready_q;
    logic bias_request_pending_q;
    logic bias_ready_q;

    logic global_load_accept;
    logic global_load_done;
    logic bias_load_accept;
    logic bias_load_done;

    logic param_loader_busy;
    logic param_loader_error;

    logic [31:0] requant_multiplier;
    logic [5:0] requant_shift;
    logic signed [ACC_WIDTH-1:0] bias_values [COLS];

    logic [ADDR_WIDTH-1:0] bias_tile_addr_q;

    logic param_read_req_valid;
    logic param_read_req_ready;
    logic [ADDR_WIDTH-1:0] param_read_req_addr;
    logic [31:0] param_read_req_beats;

    logic param_read_data_valid;
    logic param_read_data_ready;
    logic [MEM_WORD_WIDTH-1:0] param_read_data;
    logic param_read_data_last;

    logic param_axi_busy;
    logic param_axi_done;
    logic param_axi_error;

    logic [ID_WIDTH-1:0] param_axi_arid;
    logic [ADDR_WIDTH-1:0] param_axi_araddr;
    logic [7:0] param_axi_arlen;
    logic [2:0] param_axi_arsize;
    logic [1:0] param_axi_arburst;
    logic param_axi_arvalid;
    logic param_axi_arready;

    logic [ID_WIDTH-1:0] param_axi_rid;
    logic [MEM_WORD_WIDTH-1:0] param_axi_rdata;
    logic [1:0] param_axi_rresp;
    logic param_axi_rlast;
    logic param_axi_rvalid;
    logic param_axi_rready;

    // ============================================================
    // C writeback
    // ============================================================

    logic final_result_wait_q;
    logic c_tile_pending_q;
    logic c_write_tile_accept;
    logic c_write_busy;
    logic c_write_done;
    logic c_write_error;
    logic postprocess_ready;

    // ============================================================
    // Command/status
    // ============================================================

    assign cmd_ready = (exec_state == EX_IDLE);
    assign scheduler_start = (exec_state == EX_LAUNCH);
    assign done = (exec_state == EX_DONE);

    assign postprocess_ready =
        (!bias_en_q || bias_ready_q) &&
        (!requant_en_q || global_param_ready_q);

    assign busy =
        (
            (exec_state != EX_IDLE) &&
            (exec_state != EX_DONE)
        ) ||
        scheduler_busy ||
        read_path_busy ||
        core_busy ||
        c_write_busy ||
        param_loader_busy ||
        param_axi_busy ||
        param_axi_done ||
        global_param_request_pending_q ||
        bias_request_pending_q ||
        final_result_wait_q;

    // ============================================================
    // Tile Scheduler
    // ============================================================

    tile_scheduler #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),
        .K_TILE_SIZE      (K_TILE_SIZE),
        .K_SIZE_WIDTH     (K_SIZE_WIDTH)
    ) u_tile_scheduler (
        .clk                (clk),
        .reset              (reset),
        .start              (scheduler_start),

        .m_tile_count       (m_tile_count_q),
        .n_tile_count       (n_tile_count_q),
        .k_tile_count       (k_tile_count_q),
        .last_k_size        (last_k_size_q),

        .a_load_req         (scheduler_a_load_req),
        .a_load_accept      (scheduler_a_load_accept),
        .a_load_done        (scheduler_a_load_done),

        .b_load_req         (scheduler_b_load_req),
        .b_load_accept      (scheduler_b_load_accept),
        .b_load_done        (scheduler_b_load_done),

        .load_m_tile_idx    (load_m_tile_idx),
        .load_n_tile_idx    (load_n_tile_idx),
        .load_k_tile_idx    (load_k_tile_idx),
        .load_k_size        (scheduler_load_k_size),

        .a_compute_req      (scheduler_a_compute_req),
        .a_compute_grant    (scheduler_a_compute_grant),
        .a_compute_done     (scheduler_a_compute_done),
        .a_release_bank     (scheduler_a_release_bank),

        .b_compute_req      (scheduler_b_compute_req),
        .b_compute_grant    (scheduler_b_compute_grant),
        .b_compute_done     (scheduler_b_compute_done),
        .b_release_bank     (scheduler_b_release_bank),

        .matrix_start       (scheduler_matrix_start),
        .matrix_done        (core_done),

        .writeback_done     (c_write_done),
        .clear_acc          (scheduler_clear_acc),
        .writeback_en       (scheduler_writeback_en),

        .compute_k_size     (scheduler_compute_k_size),
        .compute_m_tile_idx (compute_m_tile_idx),
        .compute_n_tile_idx (compute_n_tile_idx),

        .busy               (scheduler_busy),
        .done               (scheduler_done)
    );

    // ============================================================
    // Address Generator
    // ============================================================

    gemm_address_generator #(
        .ADDR_WIDTH       (ADDR_WIDTH),
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),
        .ROWS             (ROWS),
        .COLS             (COLS),
        .DATA_WIDTH       (DATA_WIDTH),
        .ACC_WIDTH        (ACC_WIDTH),
        .K_TILE           (K_TILE_SIZE)
    ) u_address_generator (
        .a_base             (a_base_q),
        .b_base             (b_base_q),
        .c_base             (c_base_q),

        .a_stride_bytes     (a_stride_q),
        .b_stride_bytes     (b_stride_q),
        .c_stride_bytes     (c_stride_q),

        .load_m_tile_idx    (load_m_tile_idx),
        .load_n_tile_idx    (load_n_tile_idx),
        .load_k_tile_idx    (load_k_tile_idx),

        .compute_m_tile_idx (compute_m_tile_idx),
        .compute_n_tile_idx (compute_n_tile_idx),
        .c_int8_mode        (requant_en_q),

        .a_tile_addr        (a_tile_addr),
        .b_tile_addr        (b_tile_addr),
        .c_tile_addr        (c_tile_addr)
    );

    // ============================================================
    // A/B Buffer Managers
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (A_BUFFER_COUNT)
    ) u_a_buffer_manager (
        .clk          (clk),
        .reset        (reset),

        .load_req     (a_bank_load_req),
        .load_grant   (a_bank_load_grant),
        .load_bank    (a_bank_load_bank),
        .load_done    (a_bank_load_done),

        .compute_req  (scheduler_a_compute_req),
        .compute_grant(scheduler_a_compute_grant),
        .compute_bank (a_compute_bank),
        .compute_done (scheduler_a_compute_done),
        .release_bank (scheduler_a_release_bank)
    );

    buffer_manager #(
        .BUFFER_COUNT (B_BUFFER_COUNT)
    ) u_b_buffer_manager (
        .clk          (clk),
        .reset        (reset),

        .load_req     (b_bank_load_req),
        .load_grant   (b_bank_load_grant),
        .load_bank    (b_bank_load_bank),
        .load_done    (b_bank_load_done),

        .compute_req  (scheduler_b_compute_req),
        .compute_grant(scheduler_b_compute_grant),
        .compute_bank (b_compute_bank),
        .compute_done (scheduler_b_compute_done),
        .release_bank (scheduler_b_release_bank)
    );

    // ============================================================
    // GEMM / Conv Operand Read Path
    // ============================================================

    gemm_read_path #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ELEM_WIDTH     (DATA_WIDTH),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH       (ID_WIDTH),
        .A_LANE_COUNT   (ROWS),
        .B_LANE_COUNT   (COLS),
        .K_DEPTH        (K_TILE_SIZE),
        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT)
    ) u_read_path (
        .clk                   (clk),
        .reset                 (reset),

        .conv_mode             (conv_mode_q),
        .conv_input_base       (a_base_q),
        .conv_input_h          (conv_input_h_q),
        .conv_input_w          (conv_input_w_q),
        .conv_input_c          (conv_input_c_q),
        .conv_kernel_h         (conv_kernel_h_q),
        .conv_kernel_w         (conv_kernel_w_q),
        .conv_stride_h         (conv_stride_h_q),
        .conv_stride_w         (conv_stride_w_q),
        .conv_pad_top          (conv_pad_top_q),
        .conv_pad_left         (conv_pad_left_q),
        .conv_output_w         (conv_output_w_q),
        .conv_output_positions (conv_output_positions_q),
        .conv_m_start          (conv_m_start),
        .conv_k_start          (conv_k_start),

        .a_load_req            (scheduler_a_load_req),
        .a_load_accept         (scheduler_a_load_accept),
        .a_base_addr           (a_tile_addr),
        .a_stride_bytes        (a_stride_q),
        .a_load_size           (scheduler_load_k_size),
        .a_load_done           (scheduler_a_load_done),
        .a_load_error          (a_load_error),

        .b_load_req            (scheduler_b_load_req),
        .b_load_accept         (scheduler_b_load_accept),
        .b_base_addr           (b_tile_addr),
        .b_stride_bytes        (b_stride_q),
        .b_load_size           (scheduler_load_k_size),
        .b_load_done           (scheduler_b_load_done),
        .b_load_error          (b_load_error),

        .a_bank_load_req       (a_bank_load_req),
        .a_bank_load_grant     (a_bank_load_grant),
        .a_bank_load_bank      (a_bank_load_bank),
        .a_bank_load_done      (a_bank_load_done),

        .b_bank_load_req       (b_bank_load_req),
        .b_bank_load_grant     (b_bank_load_grant),
        .b_bank_load_bank      (b_bank_load_bank),
        .b_bank_load_done      (b_bank_load_done),

        .a_wen                 (a_wen),
        .a_wbank               (a_wbank),
        .a_wlane               (a_wlane),
        .a_waddr               (a_waddr),
        .a_wdata               (a_wdata),

        .b_wen                 (b_wen),
        .b_wbank               (b_wbank),
        .b_wlane               (b_wlane),
        .b_waddr               (b_waddr),
        .b_wdata               (b_wdata),

        .busy                  (read_path_busy),
        .error                 (read_path_error),

        .m_axi_arid            (operand_axi_arid),
        .m_axi_araddr          (operand_axi_araddr),
        .m_axi_arlen           (operand_axi_arlen),
        .m_axi_arsize          (operand_axi_arsize),
        .m_axi_arburst         (operand_axi_arburst),
        .m_axi_arvalid         (operand_axi_arvalid),
        .m_axi_arready         (operand_axi_arready),

        .m_axi_rid             (operand_axi_rid),
        .m_axi_rdata           (operand_axi_rdata),
        .m_axi_rresp           (operand_axi_rresp),
        .m_axi_rlast           (operand_axi_rlast),
        .m_axi_rvalid          (operand_axi_rvalid),
        .m_axi_rready          (operand_axi_rready)
    );

    // ============================================================
    // Existing postprocess parameter loader
    // ============================================================

    postprocess_param_loader #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .COLS       (COLS),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .BIAS_WIDTH (ACC_WIDTH)
    ) u_postprocess_param_loader (
        .clk                (clk),
        .reset              (reset),

        .global_load_req    (global_param_request_pending_q),
        .global_load_accept (global_load_accept),
        .global_param_addr  (param_base_q),
        .global_load_done   (global_load_done),

        .bias_load_req      (bias_request_pending_q),
        .bias_load_accept   (bias_load_accept),
        .bias_addr          (bias_tile_addr_q),
        .bias_load_done     (bias_load_done),

        .multiplier_out     (requant_multiplier),
        .shift_out          (requant_shift),
        .bias_out           (bias_values),

        .busy               (param_loader_busy),
        .error              (param_loader_error),

        .read_req_valid     (param_read_req_valid),
        .read_req_ready     (param_read_req_ready),
        .read_req_addr      (param_read_req_addr),
        .read_req_beats     (param_read_req_beats),
        .read_data_valid    (param_read_data_valid),
        .read_data_ready    (param_read_data_ready),
        .read_data          (param_read_data),
        .read_data_last     (param_read_data_last)
    );

    // ============================================================
    // Parameter AXI Read Master
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_param_axi (
        .clk          (clk),
        .reset        (reset),

        .req_valid    (param_read_req_valid),
        .req_ready    (param_read_req_ready),
        .req_addr     (param_read_req_addr),
        .req_beats    (param_read_req_beats),

        .data_valid   (param_read_data_valid),
        .data_ready   (param_read_data_ready),
        .data         (param_read_data),
        .data_last    (param_read_data_last),

        .busy         (param_axi_busy),
        .done         (param_axi_done),
        .error        (param_axi_error),

        .m_axi_arid   (param_axi_arid),
        .m_axi_araddr (param_axi_araddr),
        .m_axi_arlen  (param_axi_arlen),
        .m_axi_arsize (param_axi_arsize),
        .m_axi_arburst(param_axi_arburst),
        .m_axi_arvalid(param_axi_arvalid),
        .m_axi_arready(param_axi_arready),

        .m_axi_rid    (param_axi_rid),
        .m_axi_rdata  (param_axi_rdata),
        .m_axi_rresp  (param_axi_rresp),
        .m_axi_rlast  (param_axi_rlast),
        .m_axi_rvalid (param_axi_rvalid),
        .m_axi_rready (param_axi_rready)
    );

    // ============================================================
    // Executor AXI Read Mux
    // ============================================================

    axi_read_mux #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_executor_read_mux (
        .clk          (clk),
        .reset        (reset),

        .desc_arid    (param_axi_arid),
        .desc_araddr  (param_axi_araddr),
        .desc_arlen   (param_axi_arlen),
        .desc_arsize  (param_axi_arsize),
        .desc_arburst (param_axi_arburst),
        .desc_arvalid (param_axi_arvalid),
        .desc_arready (param_axi_arready),

        .desc_rid     (param_axi_rid),
        .desc_rdata   (param_axi_rdata),
        .desc_rresp   (param_axi_rresp),
        .desc_rlast   (param_axi_rlast),
        .desc_rvalid  (param_axi_rvalid),
        .desc_rready  (param_axi_rready),

        .gemm_arid    (operand_axi_arid),
        .gemm_araddr  (operand_axi_araddr),
        .gemm_arlen   (operand_axi_arlen),
        .gemm_arsize  (operand_axi_arsize),
        .gemm_arburst (operand_axi_arburst),
        .gemm_arvalid (operand_axi_arvalid),
        .gemm_arready (operand_axi_arready),

        .gemm_rid     (operand_axi_rid),
        .gemm_rdata   (operand_axi_rdata),
        .gemm_rresp   (operand_axi_rresp),
        .gemm_rlast   (operand_axi_rlast),
        .gemm_rvalid  (operand_axi_rvalid),
        .gemm_rready  (operand_axi_rready),

        .m_axi_arid   (m_axi_arid),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),

        .m_axi_rid    (m_axi_rid),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rresp  (m_axi_rresp),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rready (m_axi_rready)
    );

    // ============================================================
    // GEMM Core
    // ============================================================

    gemm_core #(
        .ROWS           (ROWS),
        .COLS           (COLS),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT),
        .DEPTH          (K_TILE_SIZE),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH)
    ) u_gemm_core (
        .clk          (clk),
        .reset        (reset),

        .start        (scheduler_matrix_start),
        .tile_k_size  (scheduler_compute_k_size),
        .clear_acc    (scheduler_clear_acc),
        .writeback_en (scheduler_writeback_en),

        .busy         (core_busy),
        .done         (core_done),
        .c_base_addr  ('0),

        .a_wen        (a_wen),
        .a_wlane      (a_wlane),
        .a_waddr      (a_waddr),
        .a_wdata      (a_wdata),
        .a_wbank      (a_wbank),
        .a_rbank      (a_compute_bank),

        .b_wen        (b_wen),
        .b_wlane      (b_wlane),
        .b_waddr      (b_waddr),
        .b_wdata      (b_wdata),
        .b_wbank      (b_wbank),
        .b_rbank      (b_compute_bank),

        .c_ren        (c_ren),
        .c_raddr      (c_raddr),
        .c_rdata      (c_rdata_raw),
        .acc_out      (acc_out)
    );

    // ============================================================
    // Existing postprocess
    // ============================================================

    genvar lane;

    generate

        for (lane = 0; lane < COLS; lane = lane + 1) begin : gen_c_unpack

            assign c_lane_raw[lane] =
                c_rdata_raw[lane * ACC_WIDTH +: ACC_WIDTH];

        end

    endgenerate

    postprocess_unit #(
        .LANES     (COLS),
        .ACC_WIDTH (ACC_WIDTH),
        .OUT_WIDTH (8)
    ) u_postprocess (
        .bias_en        (bias_en_q),
        .requant_en     (requant_en_q),
        .relu_en        (relu_en_q),

        .data_in        (c_lane_raw),
        .bias           (bias_values),
        .multiplier     (requant_multiplier),
        .shift          (requant_shift),

        .data_out_int32 (c_lane_int32),
        .data_out_int8  (c_lane_int8)
    );

    // ============================================================
    // Pack output data
    // ============================================================

    always_comb begin

        c_rdata_write = '0;

        if (requant_en_q) begin

            for (integer i = 0; i < COLS; i = i + 1) begin

                c_rdata_write[i * 8 +: 8] =
                    c_lane_int8[i];

            end

        end else begin

            for (integer i = 0; i < COLS; i = i + 1) begin

                c_rdata_write[i * ACC_WIDTH +: ACC_WIDTH] =
                    c_lane_int32[i];

            end

        end

    end

    // ============================================================
    // Existing C write DMA
    // ============================================================

    c_write_dma #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ROWS           (ROWS),
        .COLS           (COLS),
        .ACC_WIDTH      (ACC_WIDTH),
        .AXI_DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH       (ID_WIDTH),
        .C_ADDR_WIDTH   (CORE_ADDR_WIDTH)
    ) u_c_write_dma (
        .clk               (clk),
        .reset             (reset),

        .tile_valid        (c_tile_pending_q),
        .tile_accept       (c_write_tile_accept),
        .tile_addr         (c_tile_addr),
        .tile_stride_bytes (c_stride_q),
        .int8_mode         (requant_en_q),

        .c_ren             (c_ren),
        .c_raddr           (c_raddr),
        .c_rdata           (c_rdata_write),

        .busy              (c_write_busy),
        .done              (c_write_done),
        .error             (c_write_error),

        .m_axi_awid        (m_axi_awid),
        .m_axi_awaddr      (m_axi_awaddr),
        .m_axi_awlen       (m_axi_awlen),
        .m_axi_awsize      (m_axi_awsize),
        .m_axi_awburst     (m_axi_awburst),
        .m_axi_awvalid     (m_axi_awvalid),
        .m_axi_awready     (m_axi_awready),

        .m_axi_wdata       (m_axi_wdata),
        .m_axi_wstrb       (m_axi_wstrb),
        .m_axi_wlast       (m_axi_wlast),
        .m_axi_wvalid      (m_axi_wvalid),
        .m_axi_wready      (m_axi_wready),

        .m_axi_bid         (m_axi_bid),
        .m_axi_bresp       (m_axi_bresp),
        .m_axi_bvalid      (m_axi_bvalid),
        .m_axi_bready      (m_axi_bready)
    );

    // ============================================================
    // Epilogue parameter / writeback scheduling
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            global_param_request_pending_q <= 1'b0;
            global_param_ready_q <= 1'b0;
            bias_request_pending_q <= 1'b0;
            bias_ready_q <= 1'b0;
            bias_tile_addr_q <= '0;

            final_result_wait_q <= 1'b0;
            c_tile_pending_q <= 1'b0;

        end else begin

            if (
                global_param_request_pending_q &&
                global_load_accept
            ) begin

                global_param_request_pending_q <= 1'b0;

            end

            if (global_load_done)
                global_param_ready_q <= 1'b1;

            if (
                scheduler_matrix_start &&
                scheduler_clear_acc &&
                bias_en_q
            ) begin

                bias_tile_addr_q <=
                    param_base_q +
                    ADDR_WIDTH'(PARAM_BIAS_OFFSET) +
                    (
                        ADDR_WIDTH'(compute_n_tile_idx) *
                        ADDR_WIDTH'(BIAS_TILE_BYTES)
                    );

                bias_request_pending_q <= 1'b1;
                bias_ready_q <= 1'b0;

            end

            if (
                bias_request_pending_q &&
                bias_load_accept
            ) begin

                bias_request_pending_q <= 1'b0;

            end

            if (bias_load_done)
                bias_ready_q <= 1'b1;

            if (core_done && scheduler_writeback_en) begin

                if (postprocess_ready) begin

                    c_tile_pending_q <= 1'b1;
                    final_result_wait_q <= 1'b0;

                end else begin

                    final_result_wait_q <= 1'b1;

                end

            end

            if (
                final_result_wait_q &&
                postprocess_ready &&
                !c_tile_pending_q
            ) begin

                final_result_wait_q <= 1'b0;
                c_tile_pending_q <= 1'b1;

            end

            if (c_write_tile_accept)
                c_tile_pending_q <= 1'b0;

            if (cmd_valid && cmd_ready) begin

                global_param_request_pending_q <= cmd_requant_en;
                global_param_ready_q <= 1'b0;

                bias_request_pending_q <= 1'b0;
                bias_ready_q <= 1'b0;
                bias_tile_addr_q <= '0;

                final_result_wait_q <= 1'b0;
                c_tile_pending_q <= 1'b0;

            end

        end

    end

    // ============================================================
    // Executor FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            exec_state <= EX_IDLE;

            a_base_q <= '0;
            b_base_q <= '0;
            c_base_q <= '0;

            a_stride_q <= '0;
            b_stride_q <= '0;
            c_stride_q <= '0;

            bias_en_q <= 1'b0;
            requant_en_q <= 1'b0;
            relu_en_q <= 1'b0;
            param_base_q <= '0;

            conv_mode_q <= 1'b0;
            conv_input_h_q <= '0;
            conv_input_w_q <= '0;
            conv_input_c_q <= '0;
            conv_kernel_h_q <= '0;
            conv_kernel_w_q <= '0;
            conv_stride_h_q <= '0;
            conv_stride_w_q <= '0;
            conv_pad_top_q <= '0;
            conv_pad_left_q <= '0;
            conv_output_w_q <= '0;
            conv_output_positions_q <= '0;

            m_tile_count_q <= '0;
            n_tile_count_q <= '0;
            k_tile_count_q <= '0;
            last_k_size_q <= '0;

            error <= 1'b0;

        end else begin

            case (exec_state)

                EX_IDLE: begin

                    if (cmd_valid && cmd_ready) begin

                        error <= 1'b0;

                        if (command_invalid) begin

                            error <= 1'b1;
                            exec_state <= EX_DONE;

                        end else begin

                            a_base_q <= cmd_a_base;
                            b_base_q <= cmd_b_base;
                            c_base_q <= cmd_c_base;

                            a_stride_q <= cmd_a_stride_bytes;
                            b_stride_q <= cmd_b_stride_bytes;
                            c_stride_q <= cmd_c_stride_bytes;

                            bias_en_q <= cmd_bias_en;
                            requant_en_q <= cmd_requant_en;
                            relu_en_q <= cmd_relu_en;
                            param_base_q <= cmd_param_base;

                            conv_mode_q <= cmd_conv_mode;
                            conv_input_h_q <= cmd_conv_input_h;
                            conv_input_w_q <= cmd_conv_input_w;
                            conv_input_c_q <= cmd_conv_input_c;
                            conv_kernel_h_q <= cmd_conv_kernel_h;
                            conv_kernel_w_q <= cmd_conv_kernel_w;
                            conv_stride_h_q <= cmd_conv_stride_h;
                            conv_stride_w_q <= cmd_conv_stride_w;
                            conv_pad_top_q <= cmd_conv_pad_top;
                            conv_pad_left_q <= cmd_conv_pad_left;
                            conv_output_w_q <= cmd_conv_output_w;
                            conv_output_positions_q <=
                                cmd_conv_output_positions;

                            m_tile_count_q <= m_tile_count_calc;
                            n_tile_count_q <= n_tile_count_calc;
                            k_tile_count_q <= k_tile_count_calc;
                            last_k_size_q <= last_k_size_calc;

                            exec_state <= EX_LAUNCH;

                        end

                    end

                end

                EX_LAUNCH: begin

                    exec_state <= EX_RUN;

                end

                EX_RUN: begin

                    if (
                        read_path_error ||
                        a_load_error ||
                        b_load_error ||
                        param_loader_error ||
                        param_axi_error ||
                        c_write_error
                    ) begin

                        error <= 1'b1;

                    end

                    if (scheduler_done)
                        exec_state <= EX_DONE;

                end

                EX_DONE: begin

                    exec_state <= EX_IDLE;

                end

                default: begin

                    exec_state <= EX_IDLE;

                end

            endcase

        end

    end

    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ADDR_WIDTH < 12)
            $fatal(1, "ADDR_WIDTH must be >= 12");

        if ((ROWS < 1) || (COLS < 1))
            $fatal(1, "Invalid array dimensions");

        if (ACC_WIDTH != 32)
            $fatal(1, "ACC_WIDTH must be 32");

        if (MEM_WORD_WIDTH != 32)
            $fatal(1, "MEM_WORD_WIDTH must be 32");

        if (
            (A_BUFFER_COUNT != 1) &&
            (A_BUFFER_COUNT != 2)
        ) begin

            $fatal(1, "A_BUFFER_COUNT must be 1 or 2");

        end

        if (
            (B_BUFFER_COUNT != 1) &&
            (B_BUFFER_COUNT != 2)
        ) begin

            $fatal(1, "B_BUFFER_COUNT must be 1 or 2");

        end

    end

endmodule
