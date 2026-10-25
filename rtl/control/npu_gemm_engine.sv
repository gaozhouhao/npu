
module npu_gemm_engine #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned OPERAND_WORD_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1,
    parameter int unsigned K_TILE_SIZE = 256,
    parameter int unsigned A_BUFFER_COUNT = 2,
    parameter int unsigned B_BUFFER_COUNT = 2,
    parameter int unsigned PSUM_SLOT_COUNT = 4,
    parameter int unsigned A_REUSE_BLOCK_SIZE = 4,
    parameter int unsigned CONV_CACHE_LINES = 256,
    parameter bit CONV_CACHE_ENABLE = 1'b1,
    parameter int unsigned CONV_MAX_REQUEST_BEATS = 64,
    parameter int unsigned POOL_LINE_WORDS = 1024,
    parameter int unsigned POOL_OUTPUT_FIFO_DEPTH = 16,
    parameter int unsigned K_SIZE_WIDTH = $clog2(K_TILE_SIZE + 1),
    parameter int unsigned CORE_ADDR_WIDTH =
        ((K_TILE_SIZE > ROWS ? K_TILE_SIZE : ROWS) <= 1) ? 1 :
        $clog2(K_TILE_SIZE > ROWS ? K_TILE_SIZE : ROWS),
    parameter int unsigned ELEMS_PER_WORD =
        OPERAND_WORD_WIDTH / DATA_WIDTH,
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

    input logic cmd_valid,
    output logic cmd_ready,
    input logic [31:0] cmd_m,
    input logic [31:0] cmd_n,
    input logic [31:0] cmd_k,
    input logic [ADDR_WIDTH-1:0] cmd_a_base,
    input logic [ADDR_WIDTH-1:0] cmd_b_base,
    input logic [ADDR_WIDTH-1:0] cmd_c_base,
    input logic [31:0] cmd_a_stride_bytes,
    input logic [31:0] cmd_b_stride_bytes,
    input logic [31:0] cmd_c_stride_bytes,

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

    input logic cmd_bias_en,
    input logic cmd_requant_en,
    input logic cmd_relu_en,
    input logic cmd_per_channel_en,
    input logic cmd_multi_k_a_reuse,
    input logic cmd_b_stationary,
    input logic cmd_fuse_maxpool,
    input logic [31:0] cmd_pool_config,
    input logic [ADDR_WIDTH-1:0] cmd_param_base,

    output logic busy,
    output logic done,
    output logic error,
    output logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS],

    output logic [ID_WIDTH-1:0] operand64_arid,
    output logic [ADDR_WIDTH-1:0] operand64_araddr,
    output logic [7:0] operand64_arlen,
    output logic [2:0] operand64_arsize,
    output logic [1:0] operand64_arburst,
    output logic operand64_arvalid,
    input logic operand64_arready,
    input logic [ID_WIDTH-1:0] operand64_rid,
    input logic [63:0] operand64_rdata,
    input logic [1:0] operand64_rresp,
    input logic operand64_rlast,
    input logic operand64_rvalid,
    output logic operand64_rready,

    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input logic m_axi_arready,

    input logic [ID_WIDTH-1:0] m_axi_rid,
    input logic [MEM_WORD_WIDTH-1:0] m_axi_rdata,
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

    output logic [MEM_WORD_WIDTH-1:0] m_axi_wdata,
    output logic [(MEM_WORD_WIDTH/8)-1:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,

    input logic [ID_WIDTH-1:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);

    localparam int unsigned PARAM_BIAS_OFFSET = 16;
    localparam int unsigned BIAS_BYTES = ACC_WIDTH / 8;
    localparam int unsigned BIAS_TILE_BYTES = COLS * BIAS_BYTES;

    localparam int unsigned PSUM_SLOT_WIDTH =
        (PSUM_SLOT_COUNT <= 1) ? 1 : $clog2(PSUM_SLOT_COUNT);
    localparam bit ENABLE_MULTI_K_A_REUSE = 1'b1;

    localparam int unsigned PSUM_ROW_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS);
    localparam int unsigned PSUM_DATA_WIDTH = COLS * ACC_WIDTH;
    localparam int unsigned PSUM_TILE_WIDTH =
        ROWS * PSUM_DATA_WIDTH;

    typedef enum logic [1:0] {
        EX_IDLE,
        EX_LAUNCH,
        EX_RUN,
        EX_DONE
    } exec_state_t;

    exec_state_t exec_state;

    logic [ADDR_WIDTH-1:0] a_base_q;
    logic [ADDR_WIDTH-1:0] b_base_q;
    logic [ADDR_WIDTH-1:0] c_base_q;
    logic [ADDR_WIDTH-1:0] param_base_q;

    logic [31:0] a_stride_q;
    logic [31:0] b_stride_q;
    logic [31:0] c_stride_q;
    logic [31:0] logical_m_q, logical_n_q;
    logic [31:0] compute_valid_rows, compute_valid_cols;
    logic [31:0] load_valid_rows, load_valid_cols;

    function automatic logic [31:0] valid_extent(
        input logic [31:0] total,
        input logic [TILE_COUNT_WIDTH-1:0] tile_index,
        input int unsigned lanes
    );
        logic [63:0] base_index, remaining;
        begin
            base_index = 64'(tile_index) * 64'(lanes);
            remaining = 64'(total) > base_index ? 64'(total) - base_index : 64'd0;
            valid_extent = remaining >= 64'(lanes) ? 32'(lanes) : 32'(remaining);
        end
    endfunction

    logic bias_en_q;
    logic requant_en_q;
    logic relu_en_q;
    logic per_channel_en_q;
    logic multi_k_a_reuse_q;
    logic b_stationary_q;
    logic fuse_maxpool_q;
    logic pool_channel_tiling_q;
    logic fc_pool_q;
    logic [31:0] pool_config_q, fc_output_count_q;
    logic [31:0] fc_pool_h, fc_pool_w, fc_pool_c, fc_pool_batch;
    logic [31:0] fc_pool_kh, fc_pool_kw, fc_pool_sh, fc_pool_sw;
    logic [63:0] fc_pool_oh, fc_pool_ow;
    logic [95:0] fc_pool_elements, fc_pool_words, fc_pool_output_end;
    logic fc_pool_geometry_valid;
    logic [31:0] pool_config_for_calc;
    logic launch_ready, fc_pool_start;

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

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_calc;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_calc;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_calc;
    logic [63:0] m_tiles_wide, fc_n_tiles_wide, fc_k_tiles_wide;
    logic fc_tile_counts_valid, tile_counts_valid;

    logic [TILE_COUNT_WIDTH-1:0] m_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] n_tile_count_q;
    logic [TILE_COUNT_WIDTH-1:0] k_tile_count_q;

    logic [K_SIZE_WIDTH-1:0] last_k_size_calc;
    logic [K_SIZE_WIDTH-1:0] last_k_size_q;

    always_comb begin
        m_tile_count_calc =
            TILE_COUNT_WIDTH'(
                m_tiles_wide
            );

        n_tile_count_calc =
            TILE_COUNT_WIDTH'(
                fc_n_tiles_wide
            );

        k_tile_count_calc =
            TILE_COUNT_WIDTH'(
                fc_k_tiles_wide
            );

        if ((cmd_k % 32'(K_TILE_SIZE)) == 32'd0)
            last_k_size_calc = K_SIZE_WIDTH'(K_TILE_SIZE);
        else
            last_k_size_calc =
                K_SIZE_WIDTH'(cmd_k % 32'(K_TILE_SIZE));
    end

    logic command_invalid;
    logic [31:0] fused_kernel_h_calc, fused_kernel_w_calc;
    logic [31:0] fused_stride_h_calc, fused_stride_w_calc;
    logic [31:0] fused_input_h_calc;
    logic [95:0] fused_full_words_calc, fused_channel_words_calc;
    logic fused_pool_config_valid;

    // Check against the scheduler's actual counters before truncation can
    // turn a large matrix into a shorter, apparently legal operation.
    assign m_tiles_wide = (64'(cmd_m) + 64'(ROWS) - 64'd1) / 64'(ROWS);
    assign fc_n_tiles_wide = (64'(cmd_n) + 64'(COLS) - 64'd1) / 64'(COLS);
    assign fc_k_tiles_wide = (64'(cmd_k) + 64'(K_TILE_SIZE) - 64'd1) /
        64'(K_TILE_SIZE);
    assign fc_tile_counts_valid = fc_n_tiles_wide != 0 && fc_k_tiles_wide != 0 &&
        fc_n_tiles_wide == 64'(n_tile_count_calc) &&
        fc_k_tiles_wide == 64'(k_tile_count_calc);
    assign tile_counts_valid = fc_tile_counts_valid && m_tiles_wide != 0 &&
        m_tiles_wide == 64'(m_tile_count_calc);

    assign pool_config_for_calc = exec_state == EX_IDLE ? cmd_pool_config : pool_config_q;
    assign fused_kernel_h_calc = pool_config_for_calc == 0 ? 32'd2 :
        {24'd0, pool_config_for_calc[7:0]};
    assign fused_kernel_w_calc = pool_config_for_calc == 0 ? 32'd2 :
        {24'd0, pool_config_for_calc[15:8]};
    assign fused_stride_h_calc = pool_config_for_calc == 0 ? 32'd2 :
        {24'd0, pool_config_for_calc[23:16]};
    assign fused_stride_w_calc = pool_config_for_calc == 0 ? 32'd2 :
        {24'd0, pool_config_for_calc[31:24]};
    assign fused_pool_config_valid = fused_kernel_h_calc != 0 &&
        fused_kernel_w_calc != 0 && fused_stride_h_calc != 0 &&
        fused_stride_w_calc != 0;
    assign fused_input_h_calc = cmd_m /
        (cmd_conv_output_w == 0 ? 32'd1 : cmd_conv_output_w);
    // Preserve raw inputs for KH complete rows, independent of pool stride.
    // Keep all capacity products wide before comparing with physical SRAM.
    assign fused_full_words_calc = 96'(fused_kernel_h_calc) *
        96'(cmd_conv_output_w) * (96'(cmd_n) >> 2);
    // When all channels do not fit, finish one COLS-channel tile over the
    // complete image before reusing its pooling state for the next tile.
    assign fused_channel_words_calc = 96'(fused_kernel_h_calc) *
        96'(cmd_conv_output_w) * 96'(COLS / 4);

    assign command_invalid =
        (cmd_m == 32'd0) ||
        (cmd_n == 32'd0) ||
        (cmd_k == 32'd0) ||
        !tile_counts_valid ||
        (cmd_conv_mode && (cmd_conv_stride_h == 32'd0)) ||
        (cmd_conv_mode && (cmd_conv_stride_w == 32'd0)) ||
        (cmd_relu_en && !cmd_requant_en) ||
        (cmd_per_channel_en && !cmd_requant_en) ||
        (cmd_multi_k_a_reuse && cmd_b_stationary) ||
        (cmd_fuse_maxpool && (
            !cmd_requant_en || DATA_WIDTH != 8 ||
            MEM_WORD_WIDTH != 32 || COLS < 4 || COLS % 4 != 0 ||
            !fused_pool_config_valid ||
            cmd_n % 32'(COLS) != 0 ||
            cmd_n[1:0] != 0 || cmd_c_base[1:0] != 0 ||
            cmd_c_stride_bytes != cmd_n ||
            (cmd_conv_mode && (
                cmd_conv_output_w < fused_kernel_w_calc ||
                cmd_conv_output_positions != cmd_m ||
                cmd_m % (cmd_conv_output_w == 0 ? 32'd1 : cmd_conv_output_w) != 0 ||
                fused_input_h_calc < fused_kernel_h_calc ||
                fused_channel_words_calc > 96'(POOL_LINE_WORDS))) ||
            (!cmd_conv_mode && (cmd_m != 32'(ROWS) || !fc_tile_counts_valid))
        )) ||
        (
            cmd_b_stationary &&
            (cmd_k > 32'(K_TILE_SIZE))
        ) ||
        (
            (cmd_bias_en || cmd_requant_en) &&
            (cmd_param_base[1:0] != 2'b00)
        );

    // FC reshapes are explicit software metadata, never inferred from padding
    // rows or neuron count alone. Keep products wide until admission succeeds.
    assign fc_pool_kh = pool_config_q == 0 ? 32'd2 : {24'd0, pool_config_q[7:0]};
    assign fc_pool_kw = pool_config_q == 0 ? 32'd2 : {24'd0, pool_config_q[15:8]};
    assign fc_pool_sh = pool_config_q == 0 ? 32'd2 : {24'd0, pool_config_q[23:16]};
    assign fc_pool_sw = pool_config_q == 0 ? 32'd2 : {24'd0, pool_config_q[31:24]};
    assign fc_pool_oh = fc_pool_h >= fc_pool_kh && fc_pool_kh != 0 ?
        (64'(fc_pool_h) - 64'(fc_pool_kh)) /
            64'(fc_pool_sh == 0 ? 32'd1 : fc_pool_sh) + 1 : 0;
    assign fc_pool_ow = fc_pool_w >= fc_pool_kw && fc_pool_kw != 0 ?
        (64'(fc_pool_w) - 64'(fc_pool_kw)) /
            64'(fc_pool_sw == 0 ? 32'd1 : fc_pool_sw) + 1 : 0;
    assign fc_pool_elements = 96'(fc_pool_h) * 96'(fc_pool_w) * 96'(fc_pool_c);
    assign fc_pool_words = 96'(fc_pool_kh) * 96'(fc_pool_w) *
        (96'(fc_pool_c) >> 2);
    assign fc_pool_output_end = 96'(c_base_q) +
        96'(fc_pool_oh) * 96'(fc_pool_ow) * 96'(fc_pool_c);
    assign fc_pool_geometry_valid = fc_pool_batch == 1 &&
        fc_pool_h != 0 && fc_pool_w != 0 &&
        fc_pool_c >= 32'(COLS) && fc_pool_c % 32'(COLS) == 0 &&
        fc_pool_kh != 0 && fc_pool_kw != 0 &&
        fc_pool_sh != 0 && fc_pool_sw != 0 &&
        fc_pool_oh != 0 && fc_pool_ow != 0 &&
        fc_pool_elements == 96'(fc_output_count_q) &&
        fc_pool_words <= 96'(POOL_LINE_WORDS) &&
        fc_pool_output_end <= (96'd1 << ADDR_WIDTH);

    // ============================================================
    // Scheduler
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

    assign conv_m_start = 32'(load_m_tile_idx) * 32'(ROWS);
    assign conv_k_start = 32'(load_k_tile_idx) * 32'(K_TILE_SIZE);

    // ============================================================
    // A/B physical buffer managers
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

    logic a_wen;
    logic a_wbank;
    logic [A_LANE_WIDTH-1:0] a_wlane;
    logic [WORD_ADDR_WIDTH-1:0] a_waddr;
    logic [OPERAND_WORD_WIDTH-1:0] a_wdata;

    logic b_wen;
    logic b_wbank;
    logic [B_LANE_WIDTH-1:0] b_wlane;
    logic [WORD_ADDR_WIDTH-1:0] b_waddr;
    logic [OPERAND_WORD_WIDTH-1:0] b_wdata;

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
    logic [OPERAND_WORD_WIDTH-1:0] operand_axi_rdata;
    logic [1:0] operand_axi_rresp;
    logic operand_axi_rlast;
    logic operand_axi_rvalid;
    logic operand_axi_rready;

    // ============================================================
    // GEMM core and C SRAM
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

    logic use_psum_path;
    logic use_multi_k_a_reuse;
    logic matrix_done_effective;

    logic psum_start;
    logic psum_busy;
    logic psum_done;

    logic [PSUM_TILE_WIDTH-1:0] psum_pe_tile;
    logic psum_rd_en;
    logic psum_rd_valid;
    logic psum_wr_en;

    logic [PSUM_SLOT_WIDTH-1:0] psum_rd_slot;
    logic [PSUM_SLOT_WIDTH-1:0] psum_wr_slot;
    logic [PSUM_ROW_WIDTH-1:0] psum_rd_row;
    logic [PSUM_ROW_WIDTH-1:0] psum_wr_row;
    logic [PSUM_ROW_WIDTH-1:0] psum_sram_rd_row;
    logic psum_sram_rd_en;
    logic [PSUM_SLOT_WIDTH-1:0] psum_sram_rd_slot;
    logic [PSUM_SLOT_WIDTH-1:0] psum_target_slot;

    logic [PSUM_DATA_WIDTH-1:0] psum_sram_rd_data;
    logic [PSUM_DATA_WIDTH-1:0] psum_wr_data;
    logic [PSUM_DATA_WIDTH-1:0] psum_alu_a;
    logic [PSUM_DATA_WIDTH-1:0] psum_alu_b;
    logic [PSUM_DATA_WIDTH-1:0] psum_alu_sum;
    logic psum_alu_use;

    logic signed [ACC_WIDTH-1:0] pp_data [COLS];
    logic signed [ACC_WIDTH-1:0] pp_addend [COLS];

    assign use_multi_k_a_reuse =
        multi_k_a_reuse_q &&
        !pool_channel_tiling_q &&
        !b_stationary_q &&
        (A_REUSE_BLOCK_SIZE > 1) &&
        (k_tile_count_q > TILE_COUNT_WIDTH'(1)) &&
        (n_tile_count_q > TILE_COUNT_WIDTH'(1));

    assign use_psum_path = use_multi_k_a_reuse;

    assign psum_start = use_psum_path && core_done;

    assign matrix_done_effective =
        use_psum_path ? psum_done : core_done;

    // ============================================================
    // Epilogue parameters
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
    logic signed [7:0] input_zero_point;
    logic signed [7:0] output_zero_point;
    logic signed [ACC_WIDTH-1:0] bias_values [COLS];

    logic [31:0] loaded_multiplier_lane [COLS];
    logic [5:0] loaded_shift_lane [COLS];

    logic signed [31:0] bank_bias [COLS];
    logic [31:0] bank_multiplier [COLS];
    logic [5:0] bank_shift [COLS];

    logic [31:0] pp_multiplier [COLS];
    logic [5:0] pp_shift [COLS];

    logic [PSUM_SLOT_WIDTH-1:0] param_fill_slot_q;
    logic [TILE_COUNT_WIDTH-1:0] param_fill_n_tile_q;

    logic param_bank_fill_ready;
    logic param_bank_read_hit;
    logic param_bank_retire_hit;

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

    logic final_result_wait_q;
    logic c_tile_pending_q;
    logic c_write_tile_accept;
    logic c_write_busy;
    logic c_write_done;
    logic c_write_error;
    logic postprocess_ready;

    // Non-PSUM result snapshot and decoupled writeback.
    typedef enum logic [2:0] {
        SNAP_IDLE, SNAP_WAIT_PARAMS, SNAP_BEGIN,
        SNAP_READ_REQ, SNAP_READ_CAPTURE
    } snap_state_t;
    snap_state_t snap_state_q;
    logic [PSUM_ROW_WIDTH-1:0] snap_row_q;
    logic snapshot_start;
    logic snapshot_read_en;
    logic snapshot_row_valid;
    logic snapshot_row_ready;
    logic snapshot_done;
    logic snapshot_capture_ready;
    logic snapshot_valid;
    logic snapshot_busy;
    logic [ADDR_WIDTH-1:0] snapshot_addr;
    logic [31:0] snapshot_stride;
    logic [31:0] snapshot_valid_rows, snapshot_valid_cols;
    logic [31:0] bias_tile_valid_cols_q;
    logic [31:0] snapshot_spatial_base, snapshot_channel_base;
    logic snapshot_int8;
    logic [COLS*ACC_WIDTH-1:0] snapshot_dma_data;
    logic c_dma_ren;
    logic [CORE_ADDR_WIDTH-1:0] c_dma_raddr;

    // The result bank has exactly one consumer: external writeback or the
    // fused pool feeder.  Keep its ownership until that consumer finishes.
    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        logic [ADDR_WIDTH-1:0] addr;
        logic [7:0] len;
        logic [2:0] size;
        logic [1:0] burst;
        logic valid;
    } result_aw_t;
    typedef struct packed {
        logic [MEM_WORD_WIDTH-1:0] data;
        logic [MEM_WORD_WIDTH/8-1:0] strb;
        logic last;
        logic valid;
    } result_w_t;
    result_aw_t dma_aw, fused_aw;
    result_w_t dma_w, fused_w;
    logic dma_bready, fused_bready;
    logic dma_tile_accept, dma_busy, dma_done, dma_error;
    logic dma_ren;
    logic [CORE_ADDR_WIDTH-1:0] dma_raddr;

    typedef enum logic [2:0] {
        F_IDLE, F_READ, F_CAPTURE, F_SEND, F_DONE
    } fused_feed_state_t;
    fused_feed_state_t fused_feed_state_q;
    logic [PSUM_ROW_WIDTH-1:0] fused_row_q;
    logic [31:0] fused_spatial_base_q, fused_channel_base_q;
    logic [31:0] fused_valid_rows_q;
    logic [COLS*8-1:0] fused_row_data_q;
    logic pool_in_ready, fused_pool_busy, fused_pool_error;
    logic pool_coordinate_valid, pool_coordinate_error;
    logic fc_fire;
    logic [31:0] pool_spatial_index, pool_channel_base;
    logic result_source_valid;
    logic [ADDR_WIDTH-1:0] result_source_addr;
    logic [COLS*ACC_WIDTH-1:0] result_source_data;
    logic [31:0] result_source_valid_rows, result_source_valid_cols;
`ifdef NPU_PERF_ENABLE
    logic [31:0] perf_overlap_cycles_q;
    logic [31:0] perf_writeback_cycles_q;
    logic [31:0] perf_snapshot_wait_cycles_q;
    logic [31:0] perf_buffer_full_cycles_q;
    logic [31:0] perf_snapshot_dma_overlap_q;
    logic [31:0] perf_snapshot_tiles_q;
    logic [31:0] perf_dma_tiles_q;

    // Operand/compute pipeline instrumentation.
    logic [31:0] perf_exec_cycles_q;
    logic [31:0] perf_core_active_q;
    logic [31:0] perf_operand_busy_q;
    logic [31:0] perf_operand_compute_overlap_q;
    logic [31:0] perf_operand_only_q;
    logic [31:0] perf_compute_only_q;
    logic [31:0] perf_neither_active_q;
    logic [31:0] perf_a_load_req_wait_q;
    logic [31:0] perf_b_load_req_wait_q;
    logic [31:0] perf_a_acquire_wait_q;
    logic [31:0] perf_b_acquire_wait_q;
    logic [31:0] perf_a_load_accept_q;
    logic [31:0] perf_b_load_accept_q;
    logic [31:0] perf_a_load_done_q;
    logic [31:0] perf_b_load_done_q;
    logic [31:0] perf_matrix_start_q;
    logic [31:0] perf_operand_no_compute_q;

    // Measurement only: accepts/dones are pulses from the operand read path.
    // These metrics deliberately do not alter any data or scheduler handshake.
    logic [31:0] perf_a_latency_sum_q;
    logic [31:0] perf_b_latency_sum_q;
    logic [31:0] perf_a_latency_max_q;
    logic [31:0] perf_b_latency_max_q;
    logic [31:0] perf_a_inflight_age_q;
    logic [31:0] perf_b_inflight_age_q;
    logic perf_a_inflight_q;
    logic perf_b_inflight_q;
    logic [31:0] perf_a_pending_idle_q;
    logic [31:0] perf_b_pending_idle_q;
    logic [31:0] perf_b_pending_compute_q;

    // Gap is counted between consecutive core_done and matrix_start events.
    // This includes scheduler, snapshot, PSUM, and operand waits; it is not
    // solely a memory stall. No final trailing gap is counted.
    logic perf_gap_active_q;
    logic [31:0] perf_gap_age_q;
    logic [31:0] perf_gap_sum_q;
    logic [31:0] perf_gap_max_q;
    logic [31:0] perf_gap_count_q;
    logic [31:0] perf_gap_a_pending_q;
    logic [31:0] perf_gap_b_pending_q;
    logic [31:0] perf_gap_operand_busy_q;
    logic [31:0] perf_gap_writeback_busy_q;

`endif
    logic scheduler_finished_q;

    // ============================================================
    // Executor status
    // ============================================================

    assign cmd_ready = (exec_state == EX_IDLE);

    assign launch_ready = (!per_channel_en_q || global_param_ready_q) &&
        (!fc_pool_q || (global_param_ready_q && fc_pool_geometry_valid &&
                       !param_loader_error && !param_axi_error));
    assign scheduler_start = (exec_state == EX_LAUNCH) && launch_ready;
    assign fc_pool_start = scheduler_start && fc_pool_q;

    assign done = (exec_state == EX_DONE);

    assign postprocess_ready =
        per_channel_en_q
            ? param_bank_read_hit
            : (
                (!bias_en_q || bias_ready_q) &&
                (!requant_en_q || global_param_ready_q)
            );

    assign busy =
        (
            (exec_state != EX_IDLE) &&
            (exec_state != EX_DONE)
        ) ||
        scheduler_busy ||
        read_path_busy ||
        core_busy ||
        psum_busy ||
        c_write_busy ||
        param_loader_busy ||
        param_axi_busy ||
        param_axi_done ||
        global_param_request_pending_q ||
        bias_request_pending_q ||
        final_result_wait_q ||
        snapshot_busy ||
        (snap_state_q != SNAP_IDLE);

    // ============================================================
    // Tile Scheduler
    // ============================================================

    gemm_tile_scheduler #(
        .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH),
        .K_TILE_SIZE(K_TILE_SIZE),
        .K_SIZE_WIDTH(K_SIZE_WIDTH),
        .ENABLE_MULTI_K_A_REUSE(ENABLE_MULTI_K_A_REUSE),
        .A_REUSE_BLOCK_SIZE(A_REUSE_BLOCK_SIZE)
    ) u_gemm_tile_scheduler (
        .clk(clk),
        .reset(reset),
        .start(scheduler_start),
        .enable_multi_k_a_reuse(use_multi_k_a_reuse),
        .enable_b_stationary(b_stationary_q),
        .enable_pool_channel_tiling(pool_channel_tiling_q),

        .m_tile_count(m_tile_count_q),
        .n_tile_count(n_tile_count_q),
        .k_tile_count(k_tile_count_q),
        .last_k_size(last_k_size_q),

        .a_load_req(scheduler_a_load_req),
        .a_load_accept(scheduler_a_load_accept),
        .a_load_done(scheduler_a_load_done),

        .b_load_req(scheduler_b_load_req),
        .b_load_accept(scheduler_b_load_accept),
        .b_load_done(scheduler_b_load_done),

        .load_m_tile_idx(load_m_tile_idx),
        .load_n_tile_idx(load_n_tile_idx),
        .load_k_tile_idx(load_k_tile_idx),
        .load_k_size(scheduler_load_k_size),

        .a_compute_req(scheduler_a_compute_req),
        .a_compute_grant(scheduler_a_compute_grant),
        .a_compute_done(scheduler_a_compute_done),
        .a_release_bank(scheduler_a_release_bank),

        .b_compute_req(scheduler_b_compute_req),
        .b_compute_grant(scheduler_b_compute_grant),
        .b_compute_done(scheduler_b_compute_done),
        .b_release_bank(scheduler_b_release_bank),

        .matrix_start(scheduler_matrix_start),
        .matrix_done(matrix_done_effective),
        .writeback_done(
            use_psum_path ? c_write_done : snapshot_done
        ),
        .clear_acc(scheduler_clear_acc),
        .writeback_en(scheduler_writeback_en),

        .compute_k_size(scheduler_compute_k_size),
        .compute_m_tile_idx(compute_m_tile_idx),
        .compute_n_tile_idx(compute_n_tile_idx),

        .busy(scheduler_busy),
        .done(scheduler_done)
    );

    // ============================================================
    // Address generator
    // ============================================================

    // A is row-major [M,K]; weights are stored transposed [N,K].
    assign compute_valid_rows = valid_extent(logical_m_q, compute_m_tile_idx, ROWS);
    assign compute_valid_cols = valid_extent(logical_n_q, compute_n_tile_idx, COLS);
    assign load_valid_rows = valid_extent(logical_m_q, load_m_tile_idx, ROWS);
    assign load_valid_cols = valid_extent(logical_n_q, load_n_tile_idx, COLS);
    assign a_tile_addr = a_base_q
        + ADDR_WIDTH'(load_m_tile_idx) * ADDR_WIDTH'(ROWS) * ADDR_WIDTH'(a_stride_q)
        + ADDR_WIDTH'(load_k_tile_idx) * ADDR_WIDTH'(K_TILE_SIZE * DATA_WIDTH / 8);
    assign b_tile_addr = b_base_q
        + ADDR_WIDTH'(load_n_tile_idx) * ADDR_WIDTH'(COLS) * ADDR_WIDTH'(b_stride_q)
        + ADDR_WIDTH'(load_k_tile_idx) * ADDR_WIDTH'(K_TILE_SIZE * DATA_WIDTH / 8);
    assign c_tile_addr = c_base_q
        + ADDR_WIDTH'(compute_m_tile_idx) * ADDR_WIDTH'(ROWS) * ADDR_WIDTH'(c_stride_q)
        + ADDR_WIDTH'(compute_n_tile_idx) * ADDR_WIDTH'(COLS)
          * ADDR_WIDTH'(requant_en_q ? 1 : ACC_WIDTH / 8);

    // ============================================================
    // A/B buffer managers
    // ============================================================

    operand_bank_controller #(
        .BUFFER_COUNT(A_BUFFER_COUNT)
    ) u_a_buffer_manager (
        .clk(clk),
        .reset(reset),
        .load_req(a_bank_load_req),
        .load_grant(a_bank_load_grant),
        .load_bank(a_bank_load_bank),
        .load_done(a_bank_load_done),
        .compute_req(scheduler_a_compute_req),
        .compute_grant(scheduler_a_compute_grant),
        .compute_bank(a_compute_bank),
        .compute_done(scheduler_a_compute_done),
        .release_bank(scheduler_a_release_bank)
    );

    operand_bank_controller #(
        .BUFFER_COUNT(B_BUFFER_COUNT)
    ) u_b_buffer_manager (
        .clk(clk),
        .reset(reset),
        .load_req(b_bank_load_req),
        .load_grant(b_bank_load_grant),
        .load_bank(b_bank_load_bank),
        .load_done(b_bank_load_done),
        .compute_req(scheduler_b_compute_req),
        .compute_grant(scheduler_b_compute_grant),
        .compute_bank(b_compute_bank),
        .compute_done(scheduler_b_compute_done),
        .release_bank(scheduler_b_release_bank)
    );

    // ============================================================
    // GEMM/Conv operand read path
    // ============================================================

    operand_fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CONV_CACHE_LINES(CONV_CACHE_LINES),
        .CONV_CACHE_ENABLE(CONV_CACHE_ENABLE),
        .CONV_MAX_REQUEST_BEATS(CONV_MAX_REQUEST_BEATS),
        .ELEM_WIDTH(DATA_WIDTH),
        .MEM_WORD_WIDTH(OPERAND_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .A_LANE_COUNT(ROWS),
        .B_LANE_COUNT(COLS),
        .K_DEPTH(K_TILE_SIZE),
        .A_BUFFER_COUNT(A_BUFFER_COUNT),
        .B_BUFFER_COUNT(B_BUFFER_COUNT)
    ) u_read_path (
        .clk(clk),
        .reset(reset),
        .layer_start(cmd_valid && cmd_ready),

        .conv_mode(conv_mode_q),
        .conv_input_base(a_base_q),
        .conv_input_h(conv_input_h_q),
        .conv_input_w(conv_input_w_q),
        .conv_input_c(conv_input_c_q),
        .conv_kernel_h(conv_kernel_h_q),
        .conv_kernel_w(conv_kernel_w_q),
        .conv_stride_h(conv_stride_h_q),
        .conv_stride_w(conv_stride_w_q),
        .conv_pad_top(conv_pad_top_q),
        .conv_pad_left(conv_pad_left_q),
        .conv_pad_zero_point(requant_en_q ? input_zero_point : 8'sd0),
        .conv_output_w(conv_output_w_q),
        .conv_output_positions(conv_output_positions_q),
        .conv_m_start(conv_m_start),
        .conv_k_start(conv_k_start),

        .a_load_req(scheduler_a_load_req),
        .a_load_accept(scheduler_a_load_accept),
        .a_base_addr(a_tile_addr),
        .a_stride_bytes(a_stride_q),
        .a_load_size(scheduler_load_k_size),
        .a_valid_lanes(load_valid_rows),
        .a_load_done(scheduler_a_load_done),
        .a_load_error(a_load_error),

        .b_load_req(scheduler_b_load_req),
        .b_load_accept(scheduler_b_load_accept),
        .b_base_addr(b_tile_addr),
        .b_stride_bytes(b_stride_q),
        .b_load_size(scheduler_load_k_size),
        .b_valid_lanes(load_valid_cols),
        .b_load_done(scheduler_b_load_done),
        .b_load_error(b_load_error),

        .a_bank_load_req(a_bank_load_req),
        .a_bank_load_grant(a_bank_load_grant),
        .a_bank_load_bank(a_bank_load_bank),
        .a_bank_load_done(a_bank_load_done),

        .b_bank_load_req(b_bank_load_req),
        .b_bank_load_grant(b_bank_load_grant),
        .b_bank_load_bank(b_bank_load_bank),
        .b_bank_load_done(b_bank_load_done),

        .a_wen(a_wen),
        .a_wbank(a_wbank),
        .a_wlane(a_wlane),
        .a_waddr(a_waddr),
        .a_wdata(a_wdata),

        .b_wen(b_wen),
        .b_wbank(b_wbank),
        .b_wlane(b_wlane),
        .b_waddr(b_waddr),
        .b_wdata(b_wdata),

        .busy(read_path_busy),
        .error(read_path_error),

        .m_axi_arid(operand_axi_arid),
        .m_axi_araddr(operand_axi_araddr),
        .m_axi_arlen(operand_axi_arlen),
        .m_axi_arsize(operand_axi_arsize),
        .m_axi_arburst(operand_axi_arburst),
        .m_axi_arvalid(operand_axi_arvalid),
        .m_axi_arready(operand_axi_arready),

        .m_axi_rid(operand_axi_rid),
        .m_axi_rdata(operand_axi_rdata),
        .m_axi_rresp(operand_axi_rresp),
        .m_axi_rlast(operand_axi_rlast),
        .m_axi_rvalid(operand_axi_rvalid),
        .m_axi_rready(operand_axi_rready)
    );

    // ============================================================
    // Postprocess parameter loader
    // ============================================================

    quant_param_loader #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .COLS(COLS),
        .DATA_WIDTH(MEM_WORD_WIDTH),
        .BIAS_WIDTH(ACC_WIDTH)
    ) u_quant_param_loader (
        .clk(clk),
        .reset(reset),

        .global_load_req(global_param_request_pending_q),
        .global_load_accept(global_load_accept),
        .global_param_addr(param_base_q),
        .fc_pool_en(fc_pool_q),
        .global_load_done(global_load_done),

        .bias_load_req(bias_request_pending_q),
        .bias_load_accept(bias_load_accept),
        .bias_addr(bias_tile_addr_q),
        .per_channel_en(per_channel_en_q),
        .bias_valid_cols(bias_tile_valid_cols_q),
        .bias_load_done(bias_load_done),

        .multiplier_out(requant_multiplier),
        .shift_out(requant_shift),
        .input_zero_point_out(input_zero_point),
        .output_zero_point_out(output_zero_point),
        .fc_pool_h_out(fc_pool_h),
        .fc_pool_w_out(fc_pool_w),
        .fc_pool_c_out(fc_pool_c),
        .fc_pool_batch_out(fc_pool_batch),
        .bias_out(bias_values),
        .multiplier_lane_out(loaded_multiplier_lane),
        .shift_lane_out(loaded_shift_lane),

        .busy(param_loader_busy),
        .error(param_loader_error),

        .read_req_valid(param_read_req_valid),
        .read_req_ready(param_read_req_ready),
        .read_req_addr(param_read_req_addr),
        .read_req_beats(param_read_req_beats),
        .read_data_valid(param_read_data_valid),
        .read_data_ready(param_read_data_ready),
        .read_data(param_read_data),
        .read_data_last(param_read_data_last)
    );

    // ============================================================
    // Parameter AXI read master
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH)
    ) u_param_axi (
        .clk(clk),
        .reset(reset),
        .req_valid(param_read_req_valid),
        .req_ready(param_read_req_ready),
        .req_addr(param_read_req_addr),
        .req_beats(param_read_req_beats),
        .data_valid(param_read_data_valid),
        .data_ready(param_read_data_ready),
        .data(param_read_data),
        .data_last(param_read_data_last),
        .busy(param_axi_busy),
        .done(param_axi_done),
        .error(param_axi_error),

        .m_axi_arid(param_axi_arid),
        .m_axi_araddr(param_axi_araddr),
        .m_axi_arlen(param_axi_arlen),
        .m_axi_arsize(param_axi_arsize),
        .m_axi_arburst(param_axi_arburst),
        .m_axi_arvalid(param_axi_arvalid),
        .m_axi_arready(param_axi_arready),

        .m_axi_rid(param_axi_rid),
        .m_axi_rdata(param_axi_rdata),
        .m_axi_rresp(param_axi_rresp),
        .m_axi_rlast(param_axi_rlast),
        .m_axi_rvalid(param_axi_rvalid),
        .m_axi_rready(param_axi_rready)
    );

    // ============================================================
    // Executor read mux
    // ============================================================

    // Narrow 32-bit parameter read directly owns the legacy AXI port.
    assign m_axi_arid = param_axi_arid;
    assign m_axi_araddr = param_axi_araddr;
    assign m_axi_arlen = param_axi_arlen;
    assign m_axi_arsize = param_axi_arsize;
    assign m_axi_arburst = param_axi_arburst;
    assign m_axi_arvalid = param_axi_arvalid;
    assign param_axi_arready = m_axi_arready;
    assign param_axi_rid = m_axi_rid;
    assign param_axi_rdata = m_axi_rdata;
    assign param_axi_rresp = m_axi_rresp;
    assign param_axi_rlast = m_axi_rlast;
    assign param_axi_rvalid = m_axi_rvalid;
    assign m_axi_rready = param_axi_rready;

    // Native AXI64 operand read port; no AXI64->32 conversion.
    assign operand64_arid = operand_axi_arid;
    assign operand64_araddr = operand_axi_araddr;
    assign operand64_arlen = operand_axi_arlen;
    assign operand64_arsize = operand_axi_arsize;
    assign operand64_arburst = operand_axi_arburst;
    assign operand64_arvalid = operand_axi_arvalid;
    assign operand_axi_arready = operand64_arready;
    assign operand_axi_rid = operand64_rid;
    assign operand_axi_rdata = operand64_rdata;
    assign operand_axi_rresp = operand64_rresp;
    assign operand_axi_rlast = operand64_rlast;
    assign operand_axi_rvalid = operand64_rvalid;
    assign operand64_rready = operand_axi_rready;

    // ============================================================
    // Matrix engine
    // ============================================================

    gemm_tile_compute #(
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .A_BUFFER_COUNT(A_BUFFER_COUNT),
        .B_BUFFER_COUNT(B_BUFFER_COUNT),
        .DEPTH(K_TILE_SIZE),
        .ADDR_WIDTH(CORE_ADDR_WIDTH),
        .MEM_WORD_WIDTH(OPERAND_WORD_WIDTH)
    ) u_gemm_tile_compute (
        .clk(clk),
        .reset(reset),

        .start(scheduler_matrix_start),
        .tile_k_size(scheduler_compute_k_size),
        .clear_acc(
            use_psum_path ? 1'b1 : scheduler_clear_acc
        ),
        .writeback_en(
            use_psum_path ? 1'b0 : scheduler_writeback_en
        ),

        .busy(core_busy),
        .done(core_done),
        .c_base_addr('0),

        .a_wen(a_wen),
        .a_wlane(a_wlane),
        .a_waddr(a_waddr),
        .a_wdata(a_wdata),
        .a_wbank(a_wbank),
        .a_rbank(a_compute_bank),

        .b_wen(b_wen),
        .b_wlane(b_wlane),
        .b_waddr(b_waddr),
        .b_wdata(b_wdata),
        .b_wbank(b_wbank),
        .b_rbank(b_compute_bank),

        .c_ren(c_ren),
        .c_raddr(c_raddr),
        .c_rdata(c_rdata_raw),
        .acc_out(acc_out)
    );

    // ============================================================
    // Capture all PE accumulators
    // ============================================================

    for (genvar pr = 0; pr < ROWS; pr++) begin : gen_psum_rows
        for (genvar pc = 0; pc < COLS; pc++) begin : gen_psum_cols
            assign psum_pe_tile[
                (pr * COLS + pc) * ACC_WIDTH +: ACC_WIDTH
            ] = acc_out[pr][pc];
        end
    end

    // ============================================================
    // PSUM engine
    // ============================================================

    gemm_psum_accumulator #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ACC_WIDTH(ACC_WIDTH),
        .PSUM_SLOTS(PSUM_SLOT_COUNT)
    ) u_psum_engine (
        .clk(clk),
        .reset(reset),
        .start(psum_start),
        .first_k(scheduler_clear_acc),
        .slot(psum_target_slot),
        .pe_tile(psum_pe_tile),
        .busy(psum_busy),
        .done(psum_done),

        .sram_rd_en(psum_rd_en),
        .sram_rd_slot(psum_rd_slot),
        .sram_rd_row(psum_rd_row),
        .sram_rd_valid(psum_rd_valid),
        .sram_rd_data(psum_sram_rd_data),

        .sram_wr_en(psum_wr_en),
        .sram_wr_slot(psum_wr_slot),
        .sram_wr_row(psum_wr_row),
        .sram_wr_data(psum_wr_data),

        .alu_use_psum(psum_alu_use),
        .alu_a(psum_alu_a),
        .alu_b(psum_alu_b),
        .alu_sum(psum_alu_sum)
    );

    assign psum_target_slot =
        PSUM_SLOT_WIDTH'(
            compute_n_tile_idx %
            TILE_COUNT_WIDTH'(A_REUSE_BLOCK_SIZE)
        );

    assign psum_sram_rd_slot =
        psum_rd_en ? psum_rd_slot : psum_target_slot;

    assign psum_sram_rd_en =
        psum_rd_en ||
        (use_psum_path && c_ren);

    assign psum_sram_rd_row =
        psum_rd_en
            ? psum_rd_row
            : PSUM_ROW_WIDTH'(c_raddr);

    psum_sram #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ACC_WIDTH(ACC_WIDTH),
        .PSUM_SLOTS(PSUM_SLOT_COUNT)
    ) u_psum_sram (
        .clk(clk),
        .reset(reset),

        .rd_en(psum_sram_rd_en),
        .rd_slot(psum_sram_rd_slot),
        .rd_row(psum_sram_rd_row),
        .rd_valid(psum_rd_valid),
        .rd_data(psum_sram_rd_data),

        .wr_en(psum_wr_en),
        .wr_slot(psum_wr_slot),
        .wr_row(psum_wr_row),
        .wr_data(psum_wr_data)
    );

    // ============================================================
    // Postprocessing
    // ============================================================

    for (genvar lane = 0; lane < COLS; lane++) begin : gen_c_unpack
        assign c_lane_raw[lane] =
            c_rdata_raw[lane * ACC_WIDTH +: ACC_WIDTH];
    end

    for (genvar pl = 0; pl < COLS; pl++) begin : gen_psum_postprocess

        assign pp_data[pl] =
            psum_alu_use
                ? $signed(
                    psum_alu_a[
                        pl * ACC_WIDTH +: ACC_WIDTH
                    ]
                )
                : use_psum_path
                    ? $signed(
                        psum_sram_rd_data[
                            pl * ACC_WIDTH +: ACC_WIDTH
                        ]
                    )
                    : c_lane_raw[pl];

        assign pp_addend[pl] =
            psum_alu_use
                ? $signed(
                    psum_alu_b[
                        pl * ACC_WIDTH +: ACC_WIDTH
                    ]
                )
                : (
                    per_channel_en_q
                        ? bank_bias[pl]
                        : bias_values[pl]
                );

        assign psum_alu_sum[
            pl * ACC_WIDTH +: ACC_WIDTH
        ] = c_lane_int32[pl];
    end

    result_param_buffer #(
        .SLOTS(PSUM_SLOT_COUNT),
        .COLS(COLS),
        .TAG_WIDTH(TILE_COUNT_WIDTH)
    ) u_result_param_buffer (
        .clk(clk),
        .reset(reset),
        .clear(cmd_valid && cmd_ready),

        .fill_valid(per_channel_en_q && bias_load_done),
        .fill_ready(param_bank_fill_ready),
        .fill_slot(param_fill_slot_q),
        .fill_n_tile(param_fill_n_tile_q),
        .fill_bias(bias_values),
        .fill_multiplier(loaded_multiplier_lane),
        .fill_shift(loaded_shift_lane),

        .read_valid(per_channel_en_q && requant_en_q),
        .read_slot(psum_target_slot),
        .read_n_tile(compute_n_tile_idx),
        .read_hit(param_bank_read_hit),
        .read_bias(bank_bias),
        .read_multiplier(bank_multiplier),
        .read_shift(bank_shift),

        .retire_valid(per_channel_en_q &&
            (use_psum_path ? c_write_done : snapshot_done)),
        .retire_slot(psum_target_slot),
        .retire_n_tile(compute_n_tile_idx),
        .retire_hit(param_bank_retire_hit)
    );

    for (genvar pc = 0; pc < COLS; pc++) begin : gen_pc_select
        assign pp_multiplier[pc] =
            per_channel_en_q
                ? bank_multiplier[pc]
                : requant_multiplier;

        assign pp_shift[pc] =
            per_channel_en_q
                ? bank_shift[pc]
                : requant_shift;
    end

    gemm_postprocess #(
        .LANES(COLS),
        .ACC_WIDTH(ACC_WIDTH),
        .OUT_WIDTH(8)
    ) u_postprocess (
        .bias_en(bias_en_q || psum_alu_use),
        .requant_en(requant_en_q && !psum_alu_use),
        .relu_en(relu_en_q && !psum_alu_use),
        .data_in(pp_data),
        .bias(pp_addend),
        .multiplier(pp_multiplier),
        .shift(pp_shift),
        .output_zero_point(output_zero_point),
        .data_out_int32(c_lane_int32),
        .data_out_int8(c_lane_int8)
    );

    always_comb begin
        c_rdata_write = '0;

        if (requant_en_q) begin
            for (integer i = 0; i < COLS; i = i + 1)
                c_rdata_write[i * 8 +: 8] = c_lane_int8[i];
        end else begin
            for (integer i = 0; i < COLS; i = i + 1)
                c_rdata_write[i * ACC_WIDTH +: ACC_WIDTH] =
                    c_lane_int32[i];
        end
    end

    // ============================================================
    // Snapshot final non-PSUM tile after all parameters are ready.
    // The postprocessed value is stored, eliminating parameter-tag
    // lifetime dependence during the subsequent AXI writeback.
    // ============================================================

    assign snapshot_start =
        (snap_state_q == SNAP_BEGIN) && snapshot_capture_ready;
    assign snapshot_read_en = (snap_state_q == SNAP_READ_REQ);
    assign snapshot_row_valid = (snap_state_q == SNAP_READ_CAPTURE);

    // The original core C SRAM has a one-cycle synchronous read.
    // Read data requested in SNAP_READ_REQ is sampled during
    // SNAP_READ_CAPTURE, exactly like the original C DMA.
    always_ff @(posedge clk) begin
        if (reset) begin
            snap_state_q <= SNAP_IDLE;
            snap_row_q <= '0;
        end else if (cmd_valid && cmd_ready) begin
            snap_state_q <= SNAP_IDLE;
            snap_row_q <= '0;
        end else begin
            case (snap_state_q)
                SNAP_IDLE: begin
                    if (!use_psum_path &&
                        matrix_done_effective && scheduler_writeback_en)
                        snap_state_q <= SNAP_WAIT_PARAMS;
                end
                SNAP_WAIT_PARAMS: begin
                    if (postprocess_ready && snapshot_capture_ready)
                        snap_state_q <= SNAP_BEGIN;
                end
                SNAP_BEGIN: begin
                    if (snapshot_start) begin
                        snap_row_q <= '0;
                        snap_state_q <= SNAP_READ_REQ;
                    end
                end
                SNAP_READ_REQ: begin
                    snap_state_q <= SNAP_READ_CAPTURE;
                end
                SNAP_READ_CAPTURE: begin
                    if (snapshot_row_ready) begin
                        if (snap_row_q == PSUM_ROW_WIDTH'(ROWS-1))
                            snap_state_q <= SNAP_IDLE;
                        else begin
                            snap_row_q <= snap_row_q + 1'b1;
                            snap_state_q <= SNAP_READ_REQ;
                        end
                    end
                end
                default: snap_state_q <= SNAP_IDLE;
            endcase
        end
    end

    result_tile_buffer #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ACC_WIDTH(ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .C_ADDR_WIDTH(CORE_ADDR_WIDTH)
    ) u_result_tile_buffer (
        .clk(clk),
        .reset(reset),
        .clear(cmd_valid && cmd_ready),
        .capture_start(snapshot_start),
        .capture_ready(snapshot_capture_ready),
        .capture_addr(c_tile_addr),
        .capture_stride_bytes(c_stride_q),
        .capture_spatial_base(32'(compute_m_tile_idx) * 32'(ROWS)),
        .capture_channel_base(32'(compute_n_tile_idx) * 32'(COLS)),
        .capture_int8_mode(requant_en_q),
        .capture_valid_rows(compute_valid_rows),
        .capture_valid_cols(compute_valid_cols),
        .capture_row_valid(snapshot_row_valid),
        .capture_row_ready(snapshot_row_ready),
        .capture_row_index(snap_row_q),
        .capture_row_data(c_rdata_write),
        .capture_done(snapshot_done),
        .result_valid(snapshot_valid),
        .result_accept(!use_psum_path && c_write_tile_accept),
        .result_done(!use_psum_path && c_write_done),
        .result_addr(snapshot_addr),
        .result_stride_bytes(snapshot_stride),
        .result_spatial_base(snapshot_spatial_base),
        .result_channel_base(snapshot_channel_base),
        .result_int8_mode(snapshot_int8),
        .result_valid_rows(snapshot_valid_rows),
        .result_valid_cols(snapshot_valid_cols),
        .dma_ren(c_dma_ren && !use_psum_path),
        .dma_raddr(c_dma_raddr),
        .dma_rdata(snapshot_dma_data),
        .busy(snapshot_busy)
    );

    assign c_ren = use_psum_path ? c_dma_ren : snapshot_read_en;
    assign c_raddr = use_psum_path
        ? c_dma_raddr : CORE_ADDR_WIDTH'(snap_row_q);

    // Completion waits for both the scheduler and outstanding AXI writes.
    always_ff @(posedge clk) begin
        if (reset || (cmd_valid && cmd_ready))
            scheduler_finished_q <= 1'b0;
        else if (exec_state == EX_RUN && scheduler_done)
            scheduler_finished_q <= 1'b1;
    end

`ifdef NPU_PERF_ENABLE
    always_ff @(posedge clk) begin
        if (reset) begin
            perf_overlap_cycles_q <= '0;
            perf_writeback_cycles_q <= '0;
            perf_snapshot_wait_cycles_q <= '0;
            perf_buffer_full_cycles_q <= '0;
            perf_snapshot_dma_overlap_q <= '0;
            perf_snapshot_tiles_q <= '0;
            perf_dma_tiles_q <= '0;
            perf_exec_cycles_q <= '0;
            perf_core_active_q <= '0;
            perf_operand_busy_q <= '0;
            perf_operand_compute_overlap_q <= '0;
            perf_operand_only_q <= '0;
            perf_compute_only_q <= '0;
            perf_neither_active_q <= '0;
            perf_a_load_req_wait_q <= '0;
            perf_b_load_req_wait_q <= '0;
            perf_a_acquire_wait_q <= '0;
            perf_b_acquire_wait_q <= '0;
            perf_a_load_accept_q <= '0;
            perf_b_load_accept_q <= '0;
            perf_a_load_done_q <= '0;
            perf_b_load_done_q <= '0;
            perf_matrix_start_q <= '0;
            perf_operand_no_compute_q <= '0;
            perf_a_latency_sum_q <= '0;
            perf_b_latency_sum_q <= '0;
            perf_a_latency_max_q <= '0;
            perf_b_latency_max_q <= '0;
            perf_a_inflight_age_q <= '0;
            perf_b_inflight_age_q <= '0;
            perf_a_inflight_q <= 1'b0;
            perf_b_inflight_q <= 1'b0;
            perf_a_pending_idle_q <= '0;
            perf_b_pending_idle_q <= '0;
            perf_b_pending_compute_q <= '0;
            perf_gap_active_q <= 1'b0;
            perf_gap_age_q <= '0;
            perf_gap_sum_q <= '0;
            perf_gap_max_q <= '0;
            perf_gap_count_q <= '0;
            perf_gap_a_pending_q <= '0;
            perf_gap_b_pending_q <= '0;
            perf_gap_operand_busy_q <= '0;
            perf_gap_writeback_busy_q <= '0;
        end else begin
            if (cmd_valid && cmd_ready) begin
                perf_overlap_cycles_q <= '0;
                perf_writeback_cycles_q <= '0;
                perf_snapshot_wait_cycles_q <= '0;
                perf_buffer_full_cycles_q <= '0;
            perf_snapshot_dma_overlap_q <= '0;
            perf_snapshot_tiles_q <= '0;
                perf_dma_tiles_q <= '0;
                perf_exec_cycles_q <= '0;
                perf_core_active_q <= '0;
                perf_operand_busy_q <= '0;
                perf_operand_compute_overlap_q <= '0;
                perf_operand_only_q <= '0;
                perf_compute_only_q <= '0;
                perf_neither_active_q <= '0;
                perf_a_load_req_wait_q <= '0;
                perf_b_load_req_wait_q <= '0;
                perf_a_acquire_wait_q <= '0;
                perf_b_acquire_wait_q <= '0;
                perf_a_load_accept_q <= '0;
                perf_b_load_accept_q <= '0;
                perf_a_load_done_q <= '0;
                perf_b_load_done_q <= '0;
                perf_matrix_start_q <= '0;
                perf_operand_no_compute_q <= '0;
            perf_a_latency_sum_q <= '0;
            perf_b_latency_sum_q <= '0;
            perf_a_latency_max_q <= '0;
            perf_b_latency_max_q <= '0;
            perf_a_inflight_age_q <= '0;
            perf_b_inflight_age_q <= '0;
            perf_a_inflight_q <= 1'b0;
            perf_b_inflight_q <= 1'b0;
            perf_a_pending_idle_q <= '0;
            perf_b_pending_idle_q <= '0;
            perf_b_pending_compute_q <= '0;
            perf_gap_active_q <= 1'b0;
            perf_gap_age_q <= '0;
            perf_gap_sum_q <= '0;
            perf_gap_max_q <= '0;
            perf_gap_count_q <= '0;
            perf_gap_a_pending_q <= '0;
            perf_gap_b_pending_q <= '0;
            perf_gap_operand_busy_q <= '0;
            perf_gap_writeback_busy_q <= '0;
            end else if (exec_state == EX_RUN) begin
                perf_exec_cycles_q <= perf_exec_cycles_q + 1'b1;
                // Accept -> Done service latency (one in-flight request per
                // operand stream). Timestamp starts at zero on accept; a
                // following-cycle done therefore reports one cycle.
                if (scheduler_a_load_accept) begin
                    perf_a_inflight_q <= 1'b1;
                    perf_a_inflight_age_q <= '0;
                end else if (perf_a_inflight_q) begin
                    perf_a_inflight_age_q <= perf_a_inflight_age_q + 1'b1;
                end
                if (scheduler_a_load_done &&
                    (perf_a_inflight_q || scheduler_a_load_accept)) begin
                    perf_a_inflight_q <= 1'b0;
                    perf_a_latency_sum_q <= perf_a_latency_sum_q +
                        (scheduler_a_load_accept ? 32'd0 : perf_a_inflight_age_q + 32'd1);
                    if ((scheduler_a_load_accept ? 32'd0 : perf_a_inflight_age_q + 32'd1)
                        > perf_a_latency_max_q)
                        perf_a_latency_max_q <= scheduler_a_load_accept ?
                            32'd0 : perf_a_inflight_age_q + 32'd1;
                end

                if (scheduler_b_load_accept) begin
                    perf_b_inflight_q <= 1'b1;
                    perf_b_inflight_age_q <= '0;
                end else if (perf_b_inflight_q) begin
                    perf_b_inflight_age_q <= perf_b_inflight_age_q + 1'b1;
                end
                if (scheduler_b_load_done &&
                    (perf_b_inflight_q || scheduler_b_load_accept)) begin
                    perf_b_inflight_q <= 1'b0;
                    perf_b_latency_sum_q <= perf_b_latency_sum_q +
                        (scheduler_b_load_accept ? 32'd0 : perf_b_inflight_age_q + 32'd1);
                    if ((scheduler_b_load_accept ? 32'd0 : perf_b_inflight_age_q + 32'd1)
                        > perf_b_latency_max_q)
                        perf_b_latency_max_q <= scheduler_b_load_accept ?
                            32'd0 : perf_b_inflight_age_q + 32'd1;
                end

                // Pending-load correlations, not causal proof of stalls.
                if (!core_busy && perf_a_inflight_q)
                    perf_a_pending_idle_q <= perf_a_pending_idle_q + 1'b1;
                if (!core_busy && perf_b_inflight_q)
                    perf_b_pending_idle_q <= perf_b_pending_idle_q + 1'b1;
                if (core_busy && perf_b_inflight_q)
                    perf_b_pending_compute_q <= perf_b_pending_compute_q + 1'b1;

                if (core_done) begin
                    perf_gap_active_q <= 1'b1;
                    perf_gap_age_q <= '0;
                end else if (scheduler_matrix_start && perf_gap_active_q) begin
                    perf_gap_active_q <= 1'b0;
                    perf_gap_sum_q <= perf_gap_sum_q + perf_gap_age_q;
                    perf_gap_count_q <= perf_gap_count_q + 1'b1;
                    if (perf_gap_age_q > perf_gap_max_q)
                        perf_gap_max_q <= perf_gap_age_q;
                end else if (perf_gap_active_q) begin
                    perf_gap_age_q <= perf_gap_age_q + 1'b1;
                    if (perf_a_inflight_q)
                        perf_gap_a_pending_q <= perf_gap_a_pending_q + 1'b1;
                    if (perf_b_inflight_q)
                        perf_gap_b_pending_q <= perf_gap_b_pending_q + 1'b1;
                    if (read_path_busy)
                        perf_gap_operand_busy_q <= perf_gap_operand_busy_q + 1'b1;
                    if (c_write_busy)
                        perf_gap_writeback_busy_q <= perf_gap_writeback_busy_q + 1'b1;
                end


                if (core_busy)
                    perf_core_active_q <= perf_core_active_q + 1'b1;
                if (read_path_busy)
                    perf_operand_busy_q <= perf_operand_busy_q + 1'b1;
                if (core_busy && read_path_busy)
                    perf_operand_compute_overlap_q <=
                        perf_operand_compute_overlap_q + 1'b1;
                if (read_path_busy && !core_busy)
                    perf_operand_only_q <= perf_operand_only_q + 1'b1;
                if (core_busy && !read_path_busy)
                    perf_compute_only_q <= perf_compute_only_q + 1'b1;
                if (!core_busy && !read_path_busy)
                    perf_neither_active_q <= perf_neither_active_q + 1'b1;
                if (scheduler_a_load_req && !scheduler_a_load_accept)
                    perf_a_load_req_wait_q <= perf_a_load_req_wait_q + 1'b1;
                if (scheduler_b_load_req && !scheduler_b_load_accept)
                    perf_b_load_req_wait_q <= perf_b_load_req_wait_q + 1'b1;
                if (scheduler_a_compute_req && !scheduler_a_compute_grant)
                    perf_a_acquire_wait_q <= perf_a_acquire_wait_q + 1'b1;
                if (scheduler_b_compute_req && !scheduler_b_compute_grant)
                    perf_b_acquire_wait_q <= perf_b_acquire_wait_q + 1'b1;
                if (scheduler_a_load_accept)
                    perf_a_load_accept_q <= perf_a_load_accept_q + 1'b1;
                if (scheduler_b_load_accept)
                    perf_b_load_accept_q <= perf_b_load_accept_q + 1'b1;
                if (scheduler_a_load_done)
                    perf_a_load_done_q <= perf_a_load_done_q + 1'b1;
                if (scheduler_b_load_done)
                    perf_b_load_done_q <= perf_b_load_done_q + 1'b1;
                if (scheduler_matrix_start)
                    perf_matrix_start_q <= perf_matrix_start_q + 1'b1;
                if (scheduler_busy && read_path_busy && !core_busy)
                    perf_operand_no_compute_q <=
                        perf_operand_no_compute_q + 1'b1;
                if (!use_psum_path && snapshot_row_valid && c_write_busy)
                    perf_snapshot_dma_overlap_q <= perf_snapshot_dma_overlap_q + 1'b1;
                if (!use_psum_path && snapshot_done)
                    perf_snapshot_tiles_q <= perf_snapshot_tiles_q + 1'b1;
                if (!use_psum_path && c_write_tile_accept)
                    perf_dma_tiles_q <= perf_dma_tiles_q + 1'b1;
                if (core_busy && c_write_busy)
                    perf_overlap_cycles_q <= perf_overlap_cycles_q + 1'b1;
                if (c_write_busy)
                    perf_writeback_cycles_q <= perf_writeback_cycles_q + 1'b1;
                if (snap_state_q == SNAP_WAIT_PARAMS ||
                    snap_state_q == SNAP_BEGIN)
                    perf_snapshot_wait_cycles_q <= perf_snapshot_wait_cycles_q + 1'b1;
                if (snap_state_q == SNAP_WAIT_PARAMS &&
                    !snapshot_capture_ready)
                    perf_buffer_full_cycles_q <= perf_buffer_full_cycles_q + 1'b1;
            end
        end
    end

    // Print exactly once per command, after all writebacks drain.
    always_ff @(posedge clk) begin
        if (!reset && (exec_state == EX_DONE) && !error) begin
            $display(
                "NPU_DECOUPLED_PERF compute_dma_overlap=%0d writeback=%0d snapshot_wait=%0d buffer_full=%0d snapshot_dma_overlap=%0d snapshots=%0d dma_tiles=%0d",
                perf_overlap_cycles_q,
                perf_writeback_cycles_q,
                perf_snapshot_wait_cycles_q,
                perf_buffer_full_cycles_q,
                perf_snapshot_dma_overlap_q,
                perf_snapshot_tiles_q,
                perf_dma_tiles_q
            );
            $display(
                "NPU_OPERAND_PERF run=%0d core=%0d operand=%0d overlap=%0d operand_only=%0d compute_only=%0d neither=%0d",
                perf_exec_cycles_q, perf_core_active_q,
                perf_operand_busy_q, perf_operand_compute_overlap_q,
                perf_operand_only_q, perf_compute_only_q,
                perf_neither_active_q
            );
            $display(
                "NPU_OPERAND_STALL a_load_wait=%0d b_load_wait=%0d a_acquire_wait=%0d b_acquire_wait=%0d operand_no_compute=%0d",
                perf_a_load_req_wait_q, perf_b_load_req_wait_q,
                perf_a_acquire_wait_q, perf_b_acquire_wait_q,
                perf_operand_no_compute_q
            );
            $display(
                "NPU_OPERAND_EVENTS a_accept=%0d b_accept=%0d a_done=%0d b_done=%0d matrix_start=%0d",
                perf_a_load_accept_q, perf_b_load_accept_q,
                perf_a_load_done_q, perf_b_load_done_q,
                perf_matrix_start_q
            );
            $display(
                "NPU_LOAD_LATENCY a_sum=%0d a_max=%0d b_sum=%0d b_max=%0d a_idle_pending=%0d b_idle_pending=%0d b_compute_pending=%0d",
                perf_a_latency_sum_q, perf_a_latency_max_q,
                perf_b_latency_sum_q, perf_b_latency_max_q,
                perf_a_pending_idle_q, perf_b_pending_idle_q,
                perf_b_pending_compute_q
            );
            $display(
                "NPU_MATRIX_GAP count=%0d sum=%0d max=%0d a_pending=%0d b_pending=%0d operand_busy=%0d writeback_busy=%0d",
                perf_gap_count_q, perf_gap_sum_q, perf_gap_max_q,
                perf_gap_a_pending_q, perf_gap_b_pending_q,
                perf_gap_operand_busy_q, perf_gap_writeback_busy_q
            );
        end
    end
`endif

    // ============================================================
    // Result consumer: writeback or streaming 2x2 MaxPool
    // ============================================================

    assign result_source_valid = use_psum_path ? c_tile_pending_q : snapshot_valid;
    assign result_source_addr = use_psum_path ? c_tile_addr : snapshot_addr;
    assign result_source_data = use_psum_path ? c_rdata_write : snapshot_dma_data;
    assign result_source_valid_rows = use_psum_path ? compute_valid_rows : snapshot_valid_rows;
    assign result_source_valid_cols = use_psum_path ? compute_valid_cols : snapshot_valid_cols;

    assign c_write_tile_accept = fuse_maxpool_q
        ? ((fused_feed_state_q == F_IDLE) && result_source_valid)
        : dma_tile_accept;
    assign c_write_done = fuse_maxpool_q
        ? (fused_feed_state_q == F_DONE) : dma_done;
    assign c_write_busy = fuse_maxpool_q
        ? ((fused_feed_state_q != F_IDLE && fused_feed_state_q != F_DONE) ||
            fused_pool_busy) : dma_busy;
    assign c_write_error = fuse_maxpool_q ?
        (fused_pool_error || (fused_feed_state_q == F_SEND && pool_coordinate_error)) :
        dma_error;
    assign c_dma_ren = fuse_maxpool_q
        ? (fused_feed_state_q == F_READ) : dma_ren;
    assign c_dma_raddr = fuse_maxpool_q
        ? CORE_ADDR_WIDTH'(fused_row_q) : dma_raddr;

    // One handshake consumes all COLS lanes, including pixels outside any
    // pooling window. Padding rows and intermediate K results never fire.
    assign fc_fire = fc_pool_q && (fused_feed_state_q == F_SEND) &&
        pool_coordinate_valid && pool_in_ready;

    pool_coordinate_mapper #(.COLS(COLS)) u_pool_coordinate_mapper (
        .clk(clk),
        .reset(reset),
        .clear(cmd_valid && cmd_ready),
        .start(fc_pool_start),
        .fc_fire(fc_fire),
        .fc_mode(fc_pool_q),
        .source_spatial_index(fused_spatial_base_q + 32'(fused_row_q)),
        .source_channel_base(fused_channel_base_q),
        .fc_channels(fc_pool_c),
        .mapped_valid(pool_coordinate_valid),
        .mapped_spatial_index(pool_spatial_index),
        .mapped_channel_base(pool_channel_base),
        .mapping_error(pool_coordinate_error)
    );

    // FC admission restricts M to one physical tile. Both ordinary and
    // multi-K A-reuse traversal emit final N tiles in increasing order;
    // snapshot banks preserve that order. Protect the counter-based mapping
    // against future scheduling changes without adding hardware state.
    // synthesis translate_off
`ifndef SYNTHESIS
    logic [32:0] fc_received_outputs_q;
    always_ff @(posedge clk) begin
        if (reset || (cmd_valid && cmd_ready) || fc_pool_start) begin
            fc_received_outputs_q <= '0;
        end else if (fc_fire) begin
            assert ({1'b0, fused_channel_base_q} == fc_received_outputs_q)
                else $fatal(1, "FC pool output order: source=%0d accepted=%0d",
                    fused_channel_base_q, fc_received_outputs_q);
            assert (fc_received_outputs_q + 33'(COLS) <=
                    {1'b0, fc_output_count_q})
                else $fatal(1, "FC pool received more than the configured outputs");
            fc_received_outputs_q <= fc_received_outputs_q + 33'(COLS);
        end
    end
`endif
    // synthesis translate_on

    // Coordinates travel with the result bank rather than being recovered
    // from byte addresses using a wide divider. No unpooled address reaches AXI.
    always_ff @(posedge clk) begin
        if (reset || (cmd_valid && cmd_ready)) begin
            fused_feed_state_q <= F_IDLE;
            fused_row_q <= '0;
            fused_spatial_base_q <= '0;
            fused_channel_base_q <= '0;
            fused_valid_rows_q <= '0;
            fused_row_data_q <= '0;
        end else begin
            case (fused_feed_state_q)
                F_IDLE: if (fuse_maxpool_q && result_source_valid) begin
                    fused_spatial_base_q <=
                        use_psum_path ? (32'(compute_m_tile_idx) * 32'(ROWS))
                            : snapshot_spatial_base;
                    fused_channel_base_q <=
                        use_psum_path ? (32'(compute_n_tile_idx) * 32'(COLS))
                            : snapshot_channel_base;
                    fused_row_q <= '0;
                    fused_valid_rows_q <= result_source_valid_rows;
                    fused_feed_state_q <= F_READ;
                end
                F_READ: fused_feed_state_q <= F_CAPTURE;
                F_CAPTURE: begin
                    fused_row_data_q <= result_source_data[COLS*8-1:0];
                    fused_feed_state_q <= F_SEND;
                end
                F_SEND: if (!pool_coordinate_valid || pool_in_ready) begin
                    if (32'(fused_row_q) + 32'd1 == fused_valid_rows_q)
                        // All valid rows now belong to the pool's raw input
                        // buffer. Release this source tile independently of
                        // pending pool results and AXI write responses.
                        fused_feed_state_q <= F_DONE;
                    else begin
                        fused_row_q <= fused_row_q + 1'b1;
                        fused_feed_state_q <= F_READ;
                    end
                end
                F_DONE: fused_feed_state_q <= F_IDLE;
                default: fused_feed_state_q <= F_IDLE;
            endcase
        end
    end

    generate
        if (MEM_WORD_WIDTH == 32 && COLS >= 4 && COLS % 4 == 0) begin : gen_fused_pool
            stream_maxpool2x2 #(
                .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH),
                .COLS(COLS), .LINE_WORDS(POOL_LINE_WORDS),
                .OUTPUT_FIFO_DEPTH(POOL_OUTPUT_FIFO_DEPTH)
            ) u_pool (
                .clk(clk), .reset(reset),
                .start(fc_pool_start ||
                    (cmd_valid && cmd_ready && cmd_fuse_maxpool &&
                     cmd_conv_mode && !command_invalid)),
                .cfg_input_h(fc_pool_start ? fc_pool_h : fused_input_h_calc),
                .cfg_input_w(fc_pool_start ? fc_pool_w : cmd_conv_output_w),
                .cfg_channels(fc_pool_start ? fc_pool_c : cmd_n),
                .cfg_pool_config(fc_pool_start ? pool_config_q : cmd_pool_config),
                .cfg_output_base(fc_pool_start ? c_base_q : cmd_c_base),
                .in_valid(fuse_maxpool_q && fused_feed_state_q == F_SEND &&
                          pool_coordinate_valid),
                .in_ready(pool_in_ready), .in_data(fused_row_data_q),
                .in_spatial_index(pool_spatial_index),
                .in_channel_base(pool_channel_base),
                .busy(fused_pool_busy), .error(fused_pool_error),
                .m_axi_awid(fused_aw.id), .m_axi_awaddr(fused_aw.addr),
                .m_axi_awlen(fused_aw.len), .m_axi_awsize(fused_aw.size),
                .m_axi_awburst(fused_aw.burst), .m_axi_awvalid(fused_aw.valid),
                .m_axi_awready(fuse_maxpool_q && m_axi_awready),
                .m_axi_wdata(fused_w.data), .m_axi_wstrb(fused_w.strb),
                .m_axi_wlast(fused_w.last), .m_axi_wvalid(fused_w.valid),
                .m_axi_wready(fuse_maxpool_q && m_axi_wready),
                .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
                .m_axi_bvalid(fuse_maxpool_q && m_axi_bvalid),
                .m_axi_bready(fused_bready)
            );
        end else begin : gen_no_fused_pool
            assign pool_in_ready = 1'b0;
            assign fused_pool_busy = 1'b0;
            assign fused_pool_error = 1'b0;
            assign fused_aw = '0;
            assign fused_w = '0;
            assign fused_bready = 1'b0;
        end
    endgenerate

    assign {m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize,
            m_axi_awburst, m_axi_awvalid} = fuse_maxpool_q ? fused_aw : dma_aw;
    assign {m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wvalid} =
        fuse_maxpool_q ? fused_w : dma_w;
    assign m_axi_bready = fuse_maxpool_q ? fused_bready : dma_bready;

    result_write_dma #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .ROWS(ROWS),
        .COLS(COLS),
        .ACC_WIDTH(ACC_WIDTH),
        .AXI_DATA_WIDTH(MEM_WORD_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .C_ADDR_WIDTH(CORE_ADDR_WIDTH)
    ) u_result_write_dma (
        .clk(clk),
        .reset(reset),

        .tile_valid(!fuse_maxpool_q && result_source_valid),
        .tile_accept(dma_tile_accept),
        .tile_addr(result_source_addr),
        .tile_valid_rows(result_source_valid_rows),
        .tile_valid_cols(result_source_valid_cols),
        .tile_stride_bytes(use_psum_path ? c_stride_q : snapshot_stride),
        .int8_mode(use_psum_path ? requant_en_q : snapshot_int8),

        .c_ren(dma_ren),
        .c_raddr(dma_raddr),
        .c_rdata(result_source_data),

        .busy(dma_busy),
        .done(dma_done),
        .error(dma_error),

        .m_axi_awid(dma_aw.id),
        .m_axi_awaddr(dma_aw.addr),
        .m_axi_awlen(dma_aw.len),
        .m_axi_awsize(dma_aw.size),
        .m_axi_awburst(dma_aw.burst),
        .m_axi_awvalid(dma_aw.valid),
        .m_axi_awready(!fuse_maxpool_q && m_axi_awready),

        .m_axi_wdata(dma_w.data),
        .m_axi_wstrb(dma_w.strb),
        .m_axi_wlast(dma_w.last),
        .m_axi_wvalid(dma_w.valid),
        .m_axi_wready(!fuse_maxpool_q && m_axi_wready),

        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(!fuse_maxpool_q && m_axi_bvalid),
        .m_axi_bready(dma_bready)
    );

    // ============================================================
    // Epilogue scheduling
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin
            global_param_request_pending_q <= 1'b0;
            global_param_ready_q <= 1'b0;
            bias_request_pending_q <= 1'b0;
            bias_ready_q <= 1'b0;
            bias_tile_addr_q <= '0;
            bias_tile_valid_cols_q <= '0;
            param_fill_slot_q <= '0;
            param_fill_n_tile_q <= '0;

            final_result_wait_q <= 1'b0;
            c_tile_pending_q <= 1'b0;

        end else begin
            if (
                global_param_request_pending_q &&
                global_load_accept
            )
                global_param_request_pending_q <= 1'b0;

            if (global_load_done)
                global_param_ready_q <= 1'b1;

            if (
                scheduler_matrix_start &&
                (
                    use_multi_k_a_reuse
                        ? scheduler_writeback_en
                        : scheduler_clear_acc
                ) &&
                (bias_en_q || per_channel_en_q)
            ) begin
                bias_tile_addr_q <=
                    param_base_q +
                    ADDR_WIDTH'(fc_pool_q ? 32 : PARAM_BIAS_OFFSET) +
                    (
                        ADDR_WIDTH'(compute_n_tile_idx) *
                        ADDR_WIDTH'(
                            per_channel_en_q
                                ? (3 * BIAS_TILE_BYTES)
                                : BIAS_TILE_BYTES
                        )
                    );

                param_fill_slot_q <= psum_target_slot;
                param_fill_n_tile_q <= compute_n_tile_idx;

                bias_request_pending_q <= 1'b1;
                bias_tile_valid_cols_q <= compute_valid_cols;
                bias_ready_q <= 1'b0;
            end

            if (
                bias_request_pending_q &&
                bias_load_accept
            )
                bias_request_pending_q <= 1'b0;

            if (bias_load_done)
                bias_ready_q <= 1'b1;

            if (use_psum_path && matrix_done_effective && scheduler_writeback_en) begin
                if (postprocess_ready) begin
                    c_tile_pending_q <= 1'b1;
                    final_result_wait_q <= 1'b0;
                end else begin
                    final_result_wait_q <= 1'b1;
                end
            end

            if (
                use_psum_path &&
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
                global_param_request_pending_q <= cmd_requant_en && !command_invalid;
                global_param_ready_q <= 1'b0;

                bias_request_pending_q <= 1'b0;
                bias_ready_q <= 1'b0;
                bias_tile_addr_q <= '0;
                param_fill_slot_q <= '0;
                param_fill_n_tile_q <= '0;

                final_result_wait_q <= 1'b0;
                c_tile_pending_q <= 1'b0;
            end
        end
    end

    // ============================================================
    // Executor state machine
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
            logical_m_q <= '0;
            logical_n_q <= '0;

            bias_en_q <= 1'b0;
            requant_en_q <= 1'b0;
            relu_en_q <= 1'b0;
            per_channel_en_q <= 1'b0;
            multi_k_a_reuse_q <= 1'b0;
            b_stationary_q <= 1'b0;
            fuse_maxpool_q <= 1'b0;
            pool_channel_tiling_q <= 1'b0;
            fc_pool_q <= 1'b0;
            pool_config_q <= '0;
            fc_output_count_q <= '0;
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
                        fuse_maxpool_q <= cmd_fuse_maxpool && !command_invalid;
                        fc_pool_q <= cmd_fuse_maxpool && !cmd_conv_mode && !command_invalid;
                        pool_config_q <= cmd_pool_config;
                        fc_output_count_q <= cmd_n;
                        pool_channel_tiling_q <= cmd_fuse_maxpool && cmd_conv_mode &&
                            !command_invalid &&
                            (fused_full_words_calc > 96'(POOL_LINE_WORDS));

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
                            logical_m_q <= cmd_m;
                            logical_n_q <= cmd_n;

                            bias_en_q <= cmd_bias_en;
                            requant_en_q <= cmd_requant_en;
                            relu_en_q <= cmd_relu_en;
                            per_channel_en_q <= cmd_per_channel_en;

                            multi_k_a_reuse_q <=
                                cmd_multi_k_a_reuse;
                            b_stationary_q <= cmd_b_stationary;

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
                    if (fc_pool_q && global_param_ready_q &&
                        (!fc_pool_geometry_valid || param_loader_error || param_axi_error)) begin
                        error <= 1'b1;
                        exec_state <= EX_DONE;
                    end else if (launch_ready)
                        exec_state <= EX_RUN;
                end

                EX_RUN: begin
                    if (
                        read_path_error ||
                        a_load_error ||
                        b_load_error ||
                        param_loader_error ||
                        param_axi_error ||
                        c_write_error ||
                        (
                            per_channel_en_q &&
                            bias_load_done &&
                            !param_bank_fill_ready
                        ) ||
                        (
                            per_channel_en_q &&
                            (use_psum_path ? c_write_done : snapshot_done) &&
                            !param_bank_retire_hit
                        )
                    )
                        error <= 1'b1;

                    if (
                        (scheduler_finished_q || scheduler_done) &&
                        !snapshot_busy &&
                        (snap_state_q == SNAP_IDLE) &&
                        !c_write_busy &&
                        !c_tile_pending_q &&
                        !final_result_wait_q
                    )
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

endmodule
