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
        (K_TILE_SIZE <= 1) ?
        1 :
        $clog2(K_TILE_SIZE),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / DATA_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_TILE_SIZE + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    parameter int unsigned A_LANE_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS),

    parameter int unsigned B_LANE_WIDTH =
        (COLS <= 1) ?
        1 :
        $clog2(COLS)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // GEMM command
    // ============================================================

    input  logic                  cmd_valid,
    output logic                  cmd_ready,

    input  logic [31:0]           cmd_m,
    input  logic [31:0]           cmd_n,
    input  logic [31:0]           cmd_k,

    input  logic [ADDR_WIDTH-1:0] cmd_a_base,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base,

    input  logic [31:0]           cmd_a_stride_bytes,
    input  logic [31:0]           cmd_b_stride_bytes,
    input  logic [31:0]           cmd_c_stride_bytes,

    // ============================================================
    // Optional GEMM epilogue
    // ============================================================

    input  logic                  cmd_bias_en,
    input  logic [ADDR_WIDTH-1:0] cmd_bias_base,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // Debug RAW accumulator
    // ============================================================

    output logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS],

    // ============================================================
    // AXI4 Read Address Channel
    // ============================================================

    output logic [ID_WIDTH-1:0]       m_axi_arid,
    output logic [ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    // ============================================================
    // AXI4 Read Data Channel
    // ============================================================

    input  logic [ID_WIDTH-1:0]       m_axi_rid,
    input  logic [MEM_WORD_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready,

    // ============================================================
    // AXI4 Write Address Channel
    // ============================================================

    output logic [ID_WIDTH-1:0]       m_axi_awid,
    output logic [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    // ============================================================
    // AXI4 Write Data Channel
    // ============================================================

    output logic [MEM_WORD_WIDTH-1:0]
        m_axi_wdata,

    output logic [(MEM_WORD_WIDTH/8)-1:0]
        m_axi_wstrb,

    output logic
        m_axi_wlast,

    output logic
        m_axi_wvalid,

    input logic
        m_axi_wready,

    // ============================================================
    // AXI4 Write Response Channel
    // ============================================================

    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [1:0]          m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready
);


    // ============================================================
    // Constants
    // ============================================================

    localparam int unsigned BIAS_BYTES =
        ACC_WIDTH / 8;

    localparam int unsigned BIAS_TILE_BYTES =
        COLS * BIAS_BYTES;


    // ============================================================
    // Executor FSM
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

    logic                  bias_en_q;
    logic [ADDR_WIDTH-1:0] bias_base_q;


    // ============================================================
    // Tile-count calculation
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0]
        m_tile_count_calc;

    logic [TILE_COUNT_WIDTH-1:0]
        n_tile_count_calc;

    logic [TILE_COUNT_WIDTH-1:0]
        k_tile_count_calc;

    logic [K_SIZE_WIDTH-1:0]
        last_k_size_calc;


    always_comb begin

        m_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (
                    cmd_m +
                    32'(ROWS - 1)
                ) /
                32'(ROWS)
            );


        n_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (
                    cmd_n +
                    32'(COLS - 1)
                ) /
                32'(COLS)
            );


        k_tile_count_calc =
            TILE_COUNT_WIDTH'(
                (
                    cmd_k +
                    32'(K_TILE_SIZE - 1)
                ) /
                32'(K_TILE_SIZE)
            );


        if (
            (
                cmd_k %
                32'(K_TILE_SIZE)
            ) ==
            32'd0
        ) begin

            last_k_size_calc =
                K_SIZE_WIDTH'(K_TILE_SIZE);

        end else begin

            last_k_size_calc =
                K_SIZE_WIDTH'(
                    cmd_k %
                    32'(K_TILE_SIZE)
                );

        end

    end


    // ============================================================
    // Locked tiling parameters
    // ============================================================

    logic [TILE_COUNT_WIDTH-1:0]
        m_tile_count_q;

    logic [TILE_COUNT_WIDTH-1:0]
        n_tile_count_q;

    logic [TILE_COUNT_WIDTH-1:0]
        k_tile_count_q;

    logic [K_SIZE_WIDTH-1:0]
        last_k_size_q;


    // ============================================================
    // Command validation
    // ============================================================

    logic command_invalid;


    always_comb begin

        command_invalid =
            (cmd_m == 32'd0) ||
            (cmd_n == 32'd0) ||
            (cmd_k == 32'd0) ||
            (
                cmd_bias_en &&
                (cmd_bias_base[1:0] != 2'b00)
            );

    end


    // ============================================================
    // Scheduler
    // ============================================================

    logic scheduler_start;

    logic scheduler_busy;
    logic scheduler_done;


    // Load stage

    logic scheduler_a_load_req;
    logic scheduler_a_load_accept;
    logic scheduler_a_load_done;

    logic scheduler_b_load_req;
    logic scheduler_b_load_accept;
    logic scheduler_b_load_done;


    logic [TILE_COUNT_WIDTH-1:0]
        load_m_tile_idx;

    logic [TILE_COUNT_WIDTH-1:0]
        load_n_tile_idx;

    logic [TILE_COUNT_WIDTH-1:0]
        load_k_tile_idx;


    logic [K_SIZE_WIDTH-1:0]
        scheduler_load_k_size;


    // Compute stage

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

    logic [K_SIZE_WIDTH-1:0]
        scheduler_compute_k_size;

    logic [TILE_COUNT_WIDTH-1:0]
        compute_m_tile_idx;

    logic [TILE_COUNT_WIDTH-1:0]
        compute_n_tile_idx;


    // ============================================================
    // Tile addresses
    // ============================================================

    logic [ADDR_WIDTH-1:0]
        a_tile_addr;

    logic [ADDR_WIDTH-1:0]
        b_tile_addr;

    logic [ADDR_WIDTH-1:0]
        c_tile_addr;


    // ============================================================
    // Buffer-manager load interfaces
    // ============================================================

    logic a_bank_load_req;
    logic a_bank_load_grant;
    logic a_bank_load_bank;
    logic a_bank_load_done;

    logic b_bank_load_req;
    logic b_bank_load_grant;
    logic b_bank_load_bank;
    logic b_bank_load_done;


    // ============================================================
    // Compute banks
    // ============================================================

    logic a_compute_bank;
    logic b_compute_bank;


    // ============================================================
    // DMA -> operand SRAM
    // ============================================================

    logic a_wen;
    logic a_wbank;

    logic [A_LANE_WIDTH-1:0]
        a_wlane;

    logic [WORD_ADDR_WIDTH-1:0]
        a_waddr;

    logic [MEM_WORD_WIDTH-1:0]
        a_wdata;


    logic b_wen;
    logic b_wbank;

    logic [B_LANE_WIDTH-1:0]
        b_wlane;

    logic [WORD_ADDR_WIDTH-1:0]
        b_waddr;

    logic [MEM_WORD_WIDTH-1:0]
        b_wdata;


    // ============================================================
    // A/B read-path status
    // ============================================================

    logic read_path_busy;
    logic read_path_error;

    logic a_load_error;
    logic b_load_error;


    // ============================================================
    // A/B read-path AXI side
    // ============================================================

    logic [ID_WIDTH-1:0]
        operand_axi_arid;

    logic [ADDR_WIDTH-1:0]
        operand_axi_araddr;

    logic [7:0]
        operand_axi_arlen;

    logic [2:0]
        operand_axi_arsize;

    logic [1:0]
        operand_axi_arburst;

    logic operand_axi_arvalid;
    logic operand_axi_arready;


    logic [ID_WIDTH-1:0]
        operand_axi_rid;

    logic [MEM_WORD_WIDTH-1:0]
        operand_axi_rdata;

    logic [1:0]
        operand_axi_rresp;

    logic operand_axi_rlast;
    logic operand_axi_rvalid;
    logic operand_axi_rready;


    // ============================================================
    // GEMM core
    // ============================================================

    logic core_busy;
    logic core_done;


    // ============================================================
    // Local C-buffer
    // ============================================================

    logic c_ren;

    logic [CORE_ADDR_WIDTH-1:0]
        c_raddr;

    logic [COLS*ACC_WIDTH-1:0]
        c_rdata_raw;

    logic [COLS*ACC_WIDTH-1:0]
        c_rdata_post;


    logic signed [ACC_WIDTH-1:0]
        c_lane_raw [COLS];

    logic signed [ACC_WIDTH-1:0]
        c_lane_post [COLS];


    // ============================================================
    // Bias loader
    // ============================================================

    logic bias_load_accept;
    logic bias_loader_busy;
    logic bias_load_done;
    logic bias_loader_error;

    logic signed [ACC_WIDTH-1:0]
        bias_values [COLS];

    logic bias_request_pending_q;
    logic bias_ready_q;

    logic [ADDR_WIDTH-1:0]
        bias_tile_addr_q;


    // ============================================================
    // Bias loader generic read interface
    // ============================================================

    logic bias_read_req_valid;
    logic bias_read_req_ready;

    logic [ADDR_WIDTH-1:0]
        bias_read_req_addr;

    logic [31:0]
        bias_read_req_beats;

    logic bias_read_data_valid;
    logic bias_read_data_ready;

    logic [MEM_WORD_WIDTH-1:0]
        bias_read_data;

    logic bias_read_data_last;


    // ============================================================
    // Bias AXI master
    // ============================================================

    logic bias_axi_busy;
    logic bias_axi_done;
    logic bias_axi_error;


    logic [ID_WIDTH-1:0]
        bias_axi_arid;

    logic [ADDR_WIDTH-1:0]
        bias_axi_araddr;

    logic [7:0]
        bias_axi_arlen;

    logic [2:0]
        bias_axi_arsize;

    logic [1:0]
        bias_axi_arburst;

    logic bias_axi_arvalid;
    logic bias_axi_arready;


    logic [ID_WIDTH-1:0]
        bias_axi_rid;

    logic [MEM_WORD_WIDTH-1:0]
        bias_axi_rdata;

    logic [1:0]
        bias_axi_rresp;

    logic bias_axi_rlast;
    logic bias_axi_rvalid;
    logic bias_axi_rready;


    // ============================================================
    // C write DMA
    // ============================================================

    logic final_result_wait_q;
    logic c_tile_pending_q;

    logic c_write_tile_accept;
    logic c_write_busy;
    logic c_write_done;
    logic c_write_error;


    // ============================================================
    // Command/status
    // ============================================================

    assign cmd_ready =
        (exec_state == EX_IDLE);


    assign scheduler_start =
        (exec_state == EX_LAUNCH);


    assign busy =
        (
            (exec_state != EX_IDLE) &&
            (exec_state != EX_DONE)
        ) ||
        scheduler_busy ||
        read_path_busy ||
        core_busy ||
        c_write_busy ||
        bias_loader_busy ||
        bias_axi_busy ||
        bias_axi_done ||
        bias_request_pending_q ||
        final_result_wait_q;


    assign done =
        (exec_state == EX_DONE);


    // ============================================================
    // Scheduler
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
    // Address generator
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

        .a_tile_addr        (a_tile_addr),
        .b_tile_addr        (b_tile_addr),
        .c_tile_addr        (c_tile_addr)
    );


    // ============================================================
    // A buffer manager
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (A_BUFFER_COUNT)
    ) u_a_buffer_manager (
        .clk           (clk),
        .reset         (reset),

        .load_req      (a_bank_load_req),
        .load_grant    (a_bank_load_grant),
        .load_bank     (a_bank_load_bank),
        .load_done     (a_bank_load_done),

        .compute_req   (scheduler_a_compute_req),
        .compute_grant (scheduler_a_compute_grant),
        .compute_bank  (a_compute_bank),

        .compute_done  (scheduler_a_compute_done),
        .release_bank  (scheduler_a_release_bank)
    );


    // ============================================================
    // B buffer manager
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (B_BUFFER_COUNT)
    ) u_b_buffer_manager (
        .clk           (clk),
        .reset         (reset),

        .load_req      (b_bank_load_req),
        .load_grant    (b_bank_load_grant),
        .load_bank     (b_bank_load_bank),
        .load_done     (b_bank_load_done),

        .compute_req   (scheduler_b_compute_req),
        .compute_grant (scheduler_b_compute_grant),
        .compute_bank  (b_compute_bank),

        .compute_done  (scheduler_b_compute_done),
        .release_bank  (scheduler_b_release_bank)
    );


    // ============================================================
    // A/B operand read path
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
        .clk               (clk),
        .reset             (reset),

        .a_load_req        (scheduler_a_load_req),
        .a_load_accept     (scheduler_a_load_accept),

        .a_base_addr       (a_tile_addr),
        .a_stride_bytes    (a_stride_q),
        .a_load_size       (scheduler_load_k_size),

        .a_load_done       (scheduler_a_load_done),
        .a_load_error      (a_load_error),

        .b_load_req        (scheduler_b_load_req),
        .b_load_accept     (scheduler_b_load_accept),

        .b_base_addr       (b_tile_addr),
        .b_stride_bytes    (b_stride_q),
        .b_load_size       (scheduler_load_k_size),

        .b_load_done       (scheduler_b_load_done),
        .b_load_error      (b_load_error),

        .a_bank_load_req   (a_bank_load_req),
        .a_bank_load_grant (a_bank_load_grant),
        .a_bank_load_bank  (a_bank_load_bank),
        .a_bank_load_done  (a_bank_load_done),

        .b_bank_load_req   (b_bank_load_req),
        .b_bank_load_grant (b_bank_load_grant),
        .b_bank_load_bank  (b_bank_load_bank),
        .b_bank_load_done  (b_bank_load_done),

        .a_wen             (a_wen),
        .a_wbank           (a_wbank),
        .a_wlane           (a_wlane),
        .a_waddr           (a_waddr),
        .a_wdata           (a_wdata),

        .b_wen             (b_wen),
        .b_wbank           (b_wbank),
        .b_wlane           (b_wlane),
        .b_waddr           (b_waddr),
        .b_wdata           (b_wdata),

        .busy              (read_path_busy),
        .error             (read_path_error),

        .m_axi_arid        (operand_axi_arid),
        .m_axi_araddr      (operand_axi_araddr),
        .m_axi_arlen       (operand_axi_arlen),
        .m_axi_arsize      (operand_axi_arsize),
        .m_axi_arburst     (operand_axi_arburst),
        .m_axi_arvalid     (operand_axi_arvalid),
        .m_axi_arready     (operand_axi_arready),

        .m_axi_rid         (operand_axi_rid),
        .m_axi_rdata       (operand_axi_rdata),
        .m_axi_rresp       (operand_axi_rresp),
        .m_axi_rlast       (operand_axi_rlast),
        .m_axi_rvalid      (operand_axi_rvalid),
        .m_axi_rready      (operand_axi_rready)
    );


    // ============================================================
    // Bias loader
    // ============================================================

    bias_loader #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .COLS       (COLS),
        .BIAS_WIDTH (ACC_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH)
    ) u_bias_loader (
        .clk             (clk),
        .reset           (reset),

        .load_req        (bias_request_pending_q),
        .load_accept     (bias_load_accept),

        .bias_addr       (bias_tile_addr_q),

        .busy            (bias_loader_busy),
        .done            (bias_load_done),
        .error           (bias_loader_error),

        .bias_out        (bias_values),

        .read_req_valid  (bias_read_req_valid),
        .read_req_ready  (bias_read_req_ready),

        .read_req_addr   (bias_read_req_addr),
        .read_req_beats  (bias_read_req_beats),

        .read_data_valid (bias_read_data_valid),
        .read_data_ready (bias_read_data_ready),

        .read_data       (bias_read_data),
        .read_data_last  (bias_read_data_last)
    );


    // ============================================================
    // Bias AXI master
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_bias_read_master (
        .clk          (clk),
        .reset        (reset),

        .req_valid    (bias_read_req_valid),
        .req_ready    (bias_read_req_ready),

        .req_addr     (bias_read_req_addr),
        .req_beats    (bias_read_req_beats),

        .data_valid   (bias_read_data_valid),
        .data_ready   (bias_read_data_ready),
        .data         (bias_read_data),
        .data_last    (bias_read_data_last),

        .busy         (bias_axi_busy),
        .done         (bias_axi_done),
        .error        (bias_axi_error),

        .m_axi_arid   (bias_axi_arid),
        .m_axi_araddr (bias_axi_araddr),
        .m_axi_arlen  (bias_axi_arlen),
        .m_axi_arsize (bias_axi_arsize),
        .m_axi_arburst(bias_axi_arburst),
        .m_axi_arvalid(bias_axi_arvalid),
        .m_axi_arready(bias_axi_arready),

        .m_axi_rid    (bias_axi_rid),
        .m_axi_rdata  (bias_axi_rdata),
        .m_axi_rresp  (bias_axi_rresp),
        .m_axi_rlast  (bias_axi_rlast),
        .m_axi_rvalid (bias_axi_rvalid),
        .m_axi_rready (bias_axi_rready)
    );


    // ============================================================
    // Executor-local AXI read mux
    //
    // High-priority input = Bias.
    // Other input         = A/B operand path.
    // ============================================================

    axi_read_mux #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_executor_read_mux (
        .clk          (clk),
        .reset        (reset),

        .desc_arid    (bias_axi_arid),
        .desc_araddr  (bias_axi_araddr),
        .desc_arlen   (bias_axi_arlen),
        .desc_arsize  (bias_axi_arsize),
        .desc_arburst (bias_axi_arburst),
        .desc_arvalid (bias_axi_arvalid),
        .desc_arready (bias_axi_arready),

        .desc_rid     (bias_axi_rid),
        .desc_rdata   (bias_axi_rdata),
        .desc_rresp   (bias_axi_rresp),
        .desc_rlast   (bias_axi_rlast),
        .desc_rvalid  (bias_axi_rvalid),
        .desc_rready  (bias_axi_rready),

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
    // GEMM core
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
    // C-row unpack / Postprocess / repack
    // ============================================================

    genvar post_lane;

    generate

        for (
            post_lane = 0;
            post_lane < COLS;
            post_lane = post_lane + 1
        ) begin : gen_postprocess_pack

            assign c_lane_raw[post_lane] =
                c_rdata_raw[
                    (post_lane * ACC_WIDTH)
                    +: ACC_WIDTH
                ];


            assign c_rdata_post[
                (post_lane * ACC_WIDTH)
                +: ACC_WIDTH
            ] =
                c_lane_post[post_lane];

        end

    endgenerate


    postprocess_unit #(
        .LANES     (COLS),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_postprocess_unit (
        .bias_en  (bias_en_q),
        .data_in  (c_lane_raw),
        .bias     (bias_values),
        .data_out (c_lane_post)
    );


    // ============================================================
    // C Write DMA
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

        .c_ren             (c_ren),
        .c_raddr           (c_raddr),
        .c_rdata           (c_rdata_post),

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
    // Bias + final writeback scheduling
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            bias_request_pending_q <=
                1'b0;

            bias_ready_q <=
                1'b0;

            bias_tile_addr_q <=
                '0;

            final_result_wait_q <=
                1'b0;

            c_tile_pending_q <=
                1'b0;

        end else begin

            // ----------------------------------------------------
            // First K tile of every output C tile:
            //
            // preload corresponding Bias vector.
            //
            // Bias depends only on output column / N tile.
            // ----------------------------------------------------

            if (
                scheduler_matrix_start &&
                scheduler_clear_acc &&
                bias_en_q
            ) begin

                bias_tile_addr_q <=
                    bias_base_q +
                    (
                        ADDR_WIDTH'(compute_n_tile_idx) *
                        ADDR_WIDTH'(BIAS_TILE_BYTES)
                    );

                bias_request_pending_q <=
                    1'b1;

                bias_ready_q <=
                    1'b0;

            end


            // ----------------------------------------------------
            // Bias loader accepts the command.
            // ----------------------------------------------------

            if (
                bias_request_pending_q &&
                bias_load_accept
            ) begin

                bias_request_pending_q <=
                    1'b0;

            end


            // ----------------------------------------------------
            // Complete Bias vector loaded.
            // ----------------------------------------------------

            if (bias_load_done) begin

                bias_ready_q <=
                    1'b1;

            end


            // ----------------------------------------------------
            // Final K tile completed.
            // ----------------------------------------------------

            if (
                core_done &&
                scheduler_writeback_en
            ) begin

                if (
                    !bias_en_q ||
                    bias_ready_q
                ) begin

                    c_tile_pending_q <=
                        1'b1;

                    final_result_wait_q <=
                        1'b0;

                end else begin

                    final_result_wait_q <=
                        1'b1;

                end

            end


            // ----------------------------------------------------
            // Short GEMM:
            //
            // compute may finish before Bias DMA.
            // ----------------------------------------------------

            if (
                final_result_wait_q &&
                bias_ready_q &&
                !c_tile_pending_q
            ) begin

                final_result_wait_q <=
                    1'b0;

                c_tile_pending_q <=
                    1'b1;

            end


            // ----------------------------------------------------
            // Write DMA consumed current C tile.
            // ----------------------------------------------------

            if (c_write_tile_accept) begin

                c_tile_pending_q <=
                    1'b0;

            end


            // ----------------------------------------------------
            // New GEMM command.
            // ----------------------------------------------------

            if (
                cmd_valid &&
                cmd_ready
            ) begin

                bias_request_pending_q <=
                    1'b0;

                bias_ready_q <=
                    1'b0;

                bias_tile_addr_q <=
                    '0;

                final_result_wait_q <=
                    1'b0;

                c_tile_pending_q <=
                    1'b0;

            end

        end

    end


    // ============================================================
    // Executor FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            exec_state <=
                EX_IDLE;


            a_base_q <=
                '0;

            b_base_q <=
                '0;

            c_base_q <=
                '0;


            a_stride_q <=
                '0;

            b_stride_q <=
                '0;

            c_stride_q <=
                '0;


            bias_en_q <=
                1'b0;

            bias_base_q <=
                '0;


            m_tile_count_q <=
                '0;

            n_tile_count_q <=
                '0;

            k_tile_count_q <=
                '0;

            last_k_size_q <=
                '0;


            error <=
                1'b0;

        end else begin

            case (exec_state)

                // =================================================
                // IDLE
                // =================================================

                EX_IDLE: begin

                    if (
                        cmd_valid &&
                        cmd_ready
                    ) begin

                        error <=
                            1'b0;


                        if (command_invalid) begin

                            error <=
                                1'b1;

                            exec_state <=
                                EX_DONE;

                        end else begin

                            a_base_q <=
                                cmd_a_base;

                            b_base_q <=
                                cmd_b_base;

                            c_base_q <=
                                cmd_c_base;


                            a_stride_q <=
                                cmd_a_stride_bytes;

                            b_stride_q <=
                                cmd_b_stride_bytes;

                            c_stride_q <=
                                cmd_c_stride_bytes;


                            bias_en_q <=
                                cmd_bias_en;

                            bias_base_q <=
                                cmd_bias_base;


                            m_tile_count_q <=
                                m_tile_count_calc;

                            n_tile_count_q <=
                                n_tile_count_calc;

                            k_tile_count_q <=
                                k_tile_count_calc;

                            last_k_size_q <=
                                last_k_size_calc;


                            exec_state <=
                                EX_LAUNCH;

                        end

                    end

                end


                // =================================================
                // LAUNCH
                // =================================================

                EX_LAUNCH: begin

                    exec_state <=
                        EX_RUN;

                end


                // =================================================
                // RUN
                // =================================================

                EX_RUN: begin

                    if (
                        read_path_error ||
                        a_load_error ||
                        b_load_error ||
                        bias_loader_error ||
                        bias_axi_error ||
                        c_write_error
                    ) begin

                        error <=
                            1'b1;

                    end


                    if (scheduler_done) begin

                        exec_state <=
                            EX_DONE;

                    end

                end


                // =================================================
                // DONE
                // =================================================

                EX_DONE: begin

                    exec_state <=
                        EX_IDLE;

                end


                default: begin

                    exec_state <=
                        EX_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ADDR_WIDTH < 12) begin

            $fatal(
                1,
                "ADDR_WIDTH must be >= 12"
            );

        end


        if (TILE_COUNT_WIDTH < 1) begin

            $fatal(
                1,
                "TILE_COUNT_WIDTH must be >= 1"
            );

        end


        if (ROWS < 1) begin

            $fatal(
                1,
                "ROWS must be >= 1"
            );

        end


        if (COLS < 1) begin

            $fatal(
                1,
                "COLS must be >= 1"
            );

        end


        if (K_TILE_SIZE < 1) begin

            $fatal(
                1,
                "K_TILE_SIZE must be >= 1"
            );

        end


        if (
            (DATA_WIDTH % 8) !=
            0
        ) begin

            $fatal(
                1,
                "DATA_WIDTH must be byte aligned"
            );

        end


        if (
            (ACC_WIDTH % 8) !=
            0
        ) begin

            $fatal(
                1,
                "ACC_WIDTH must be byte aligned"
            );

        end


        if (
            (MEM_WORD_WIDTH % DATA_WIDTH) !=
            0
        ) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by DATA_WIDTH"
            );

        end


        if (
            (A_BUFFER_COUNT != 1) &&
            (A_BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "A_BUFFER_COUNT must be 1 or 2"
            );

        end


        if (
            (B_BUFFER_COUNT != 1) &&
            (B_BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "B_BUFFER_COUNT must be 1 or 2"
            );

        end


        if (ACC_WIDTH != 32) begin

            $fatal(
                1,
                "Current Bias epilogue requires ACC_WIDTH == 32"
            );

        end


        if (MEM_WORD_WIDTH != 32) begin

            $fatal(
                1,
                "Current Bias loader requires MEM_WORD_WIDTH == 32"
            );

        end

    end

endmodule
