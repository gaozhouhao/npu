
module gemm_read_path #(
    parameter int unsigned ADDR_WIDTH     = 64,
    parameter int unsigned ELEM_WIDTH     = 8,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned ID_WIDTH       = 1,
    parameter int unsigned A_LANE_COUNT   = 4,
    parameter int unsigned B_LANE_COUNT   = 4,
    parameter int unsigned K_DEPTH        = 256,
    parameter int unsigned A_BUFFER_COUNT = 2,
    parameter int unsigned B_BUFFER_COUNT = 2,

    parameter int unsigned K_SIZE_WIDTH =
        $clog2(K_DEPTH + 1),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / ELEM_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),

    parameter int unsigned A_LANE_WIDTH =
        (A_LANE_COUNT <= 1) ? 1 : $clog2(A_LANE_COUNT),

    parameter int unsigned B_LANE_WIDTH =
        (B_LANE_COUNT <= 1) ? 1 : $clog2(B_LANE_COUNT),

    parameter int unsigned A_BANK_WIDTH =
        (A_BUFFER_COUNT <= 1) ? 1 : $clog2(A_BUFFER_COUNT),

    parameter int unsigned B_BANK_WIDTH =
        (B_BUFFER_COUNT <= 1) ? 1 : $clog2(B_BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Conv A configuration
    // ============================================================

    input logic conv_mode,

    input logic [ADDR_WIDTH-1:0] conv_input_base,

    input logic [31:0] conv_input_h,
    input logic [31:0] conv_input_w,
    input logic [31:0] conv_input_c,

    input logic [31:0] conv_kernel_h,
    input logic [31:0] conv_kernel_w,

    input logic [31:0] conv_stride_h,
    input logic [31:0] conv_stride_w,

    input logic [31:0] conv_pad_top,
    input logic [31:0] conv_pad_left,
    input logic signed [7:0] conv_pad_zero_point,

    input logic [31:0] conv_output_w,
    input logic [31:0] conv_output_positions,

    input logic [31:0] conv_m_start,
    input logic [31:0] conv_k_start,

    // ============================================================
    // A tile load command
    // ============================================================

    input  logic                    a_load_req,
    output logic                    a_load_accept,

    input  logic [ADDR_WIDTH-1:0]   a_base_addr,
    input  logic [31:0]             a_stride_bytes,
    input  logic [K_SIZE_WIDTH-1:0] a_load_size,

    output logic a_load_done,
    output logic a_load_error,

    // ============================================================
    // B tile load command
    // ============================================================

    input  logic                    b_load_req,
    output logic                    b_load_accept,

    input  logic [ADDR_WIDTH-1:0]   b_base_addr,
    input  logic [31:0]             b_stride_bytes,
    input  logic [K_SIZE_WIDTH-1:0] b_load_size,

    output logic b_load_done,
    output logic b_load_error,

    // ============================================================
    // Buffer managers
    // ============================================================

    output logic                    a_bank_load_req,
    input  logic                    a_bank_load_grant,
    input  logic [A_BANK_WIDTH-1:0] a_bank_load_bank,
    output logic                    a_bank_load_done,

    output logic                    b_bank_load_req,
    input  logic                    b_bank_load_grant,
    input  logic [B_BANK_WIDTH-1:0] b_bank_load_bank,
    output logic                    b_bank_load_done,

    // ============================================================
    // SRAM write interface
    // ============================================================

    output logic                       a_wen,
    output logic [A_BANK_WIDTH-1:0]    a_wbank,
    output logic [A_LANE_WIDTH-1:0]    a_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] a_waddr,
    output logic [MEM_WORD_WIDTH-1:0]  a_wdata,

    output logic                       b_wen,
    output logic [B_BANK_WIDTH-1:0]    b_wbank,
    output logic [B_LANE_WIDTH-1:0]    b_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] b_waddr,
    output logic [MEM_WORD_WIDTH-1:0]  b_wdata,

    output logic busy,
    output logic error,

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
    output logic                      m_axi_rready
);

    // ============================================================
    // GEMM A loader
    // ============================================================

    logic gemm_a_load_accept;
    logic gemm_a_load_done;
    logic gemm_a_load_error;
    logic gemm_a_busy;

    logic gemm_a_bank_load_req;
    logic gemm_a_bank_load_done;

    logic gemm_a_wen;
    logic [A_BANK_WIDTH-1:0] gemm_a_wbank;
    logic [A_LANE_WIDTH-1:0] gemm_a_wlane;
    logic [WORD_ADDR_WIDTH-1:0] gemm_a_waddr;
    logic [MEM_WORD_WIDTH-1:0] gemm_a_wdata;

    logic gemm_a_rd_req_valid;
    logic gemm_a_rd_req_ready;
    logic [ADDR_WIDTH-1:0] gemm_a_rd_req_addr;
    logic [31:0] gemm_a_rd_req_beats;

    logic gemm_a_rd_data_valid;
    logic gemm_a_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] gemm_a_rd_data;
    logic gemm_a_rd_data_last;
    logic gemm_a_rd_done;
    logic gemm_a_rd_error;

    operand_read_dma #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ELEM_WIDTH     (ELEM_WIDTH),
        .LANE_COUNT     (A_LANE_COUNT),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH),
        .K_DEPTH        (K_DEPTH),
        .BUFFER_COUNT   (A_BUFFER_COUNT)
    ) u_a_read_dma (
        .clk             (clk),
        .reset           (reset),

        .load_req        (a_load_req && !conv_mode),
        .load_accept     (gemm_a_load_accept),
        .base_addr       (a_base_addr),
        .stride_bytes    (a_stride_bytes),
        .load_size       (a_load_size),
        .load_done       (gemm_a_load_done),
        .busy            (gemm_a_busy),
        .error           (gemm_a_load_error),

        .bank_load_req   (gemm_a_bank_load_req),
        .bank_load_grant (a_bank_load_grant),
        .bank_load_bank  (a_bank_load_bank),
        .bank_load_done  (gemm_a_bank_load_done),

        .rd_req_valid    (gemm_a_rd_req_valid),
        .rd_req_ready    (gemm_a_rd_req_ready),
        .rd_req_addr     (gemm_a_rd_req_addr),
        .rd_req_beats    (gemm_a_rd_req_beats),

        .rd_data_valid   (gemm_a_rd_data_valid),
        .rd_data_ready   (gemm_a_rd_data_ready),
        .rd_data         (gemm_a_rd_data),
        .rd_data_last    (gemm_a_rd_data_last),
        .rd_done         (gemm_a_rd_done),
        .rd_error        (gemm_a_rd_error),

        .buffer_wen      (gemm_a_wen),
        .buffer_wbank    (gemm_a_wbank),
        .buffer_wlane    (gemm_a_wlane),
        .buffer_waddr    (gemm_a_waddr),
        .buffer_wdata    (gemm_a_wdata)
    );

    // ============================================================
    // Conv A loader
    // ============================================================

    logic conv_a_load_accept;
    logic conv_a_load_done;
    logic conv_a_load_error;
    logic conv_a_busy;

    logic conv_a_bank_load_req;
    logic conv_a_bank_load_done;

    logic conv_a_wen;
    logic [A_BANK_WIDTH-1:0] conv_a_wbank;
    logic [A_LANE_WIDTH-1:0] conv_a_wlane;
    logic [WORD_ADDR_WIDTH-1:0] conv_a_waddr;
    logic [MEM_WORD_WIDTH-1:0] conv_a_wdata;

    logic conv_a_rd_req_valid;
    logic conv_a_rd_req_ready;
    logic [ADDR_WIDTH-1:0] conv_a_rd_req_addr;
    logic [31:0] conv_a_rd_req_beats;

    logic conv_a_rd_data_valid;
    logic conv_a_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] conv_a_rd_data;
    logic conv_a_rd_data_last;
    logic conv_a_rd_done;
    logic conv_a_rd_error;

    conv_patch_loader #(
        .ADDR_WIDTH   (ADDR_WIDTH),
        .ROWS         (A_LANE_COUNT),
        .K_DEPTH      (K_DEPTH),
        .BUFFER_COUNT (A_BUFFER_COUNT)
    ) u_conv_patch_loader (
        .clk              (clk),
        .reset            (reset),

        .load_req         (a_load_req && conv_mode),
        .load_accept      (conv_a_load_accept),

        .input_base       (conv_input_base),
        .input_h          (conv_input_h),
        .input_w          (conv_input_w),
        .input_c          (conv_input_c),
        .kernel_h         (conv_kernel_h),
        .kernel_w         (conv_kernel_w),
        .stride_h         (conv_stride_h),
        .stride_w         (conv_stride_w),
        .pad_top          (conv_pad_top),
        .pad_left         (conv_pad_left),
        .pad_zero_point   (conv_pad_zero_point),
        .output_w         (conv_output_w),
        .output_positions (conv_output_positions),
        .m_start          (conv_m_start),
        .k_start          (conv_k_start),
        .load_size        (a_load_size),

        .load_done        (conv_a_load_done),
        .busy             (conv_a_busy),
        .error            (conv_a_load_error),

        .bank_load_req    (conv_a_bank_load_req),
        .bank_load_grant  (a_bank_load_grant),
        .bank_load_bank   (a_bank_load_bank),
        .bank_load_done   (conv_a_bank_load_done),

        .rd_req_valid     (conv_a_rd_req_valid),
        .rd_req_ready     (conv_a_rd_req_ready),
        .rd_req_addr      (conv_a_rd_req_addr),
        .rd_req_beats     (conv_a_rd_req_beats),

        .rd_data_valid    (conv_a_rd_data_valid),
        .rd_data_ready    (conv_a_rd_data_ready),
        .rd_data          (conv_a_rd_data),
        .rd_data_last     (conv_a_rd_data_last),
        .rd_done          (conv_a_rd_done),
        .rd_error         (conv_a_rd_error),

        .buffer_wen       (conv_a_wen),
        .buffer_wbank     (conv_a_wbank),
        .buffer_wlane     (conv_a_wlane),
        .buffer_waddr     (conv_a_waddr),
        .buffer_wdata     (conv_a_wdata)
    );

    // ============================================================
    // A loader selection
    // ============================================================

    assign a_load_accept =
        conv_mode ? conv_a_load_accept : gemm_a_load_accept;

    assign a_load_done =
        conv_mode ? conv_a_load_done : gemm_a_load_done;

    assign a_load_error =
        conv_mode ? conv_a_load_error : gemm_a_load_error;

    assign a_bank_load_req =
        conv_mode ? conv_a_bank_load_req : gemm_a_bank_load_req;

    assign a_bank_load_done =
        conv_mode ? conv_a_bank_load_done : gemm_a_bank_load_done;

    assign a_wen =
        conv_mode ? conv_a_wen : gemm_a_wen;

    assign a_wbank =
        conv_mode ? conv_a_wbank : gemm_a_wbank;

    assign a_wlane =
        conv_mode ? conv_a_wlane : gemm_a_wlane;

    assign a_waddr =
        conv_mode ? conv_a_waddr : gemm_a_waddr;

    assign a_wdata =
        conv_mode ? conv_a_wdata : gemm_a_wdata;

    // ============================================================
    // B DMA (unchanged)
    // ============================================================

    logic b_dma_busy;

    logic b_rd_req_valid;
    logic b_rd_req_ready;
    logic [ADDR_WIDTH-1:0] b_rd_req_addr;
    logic [31:0] b_rd_req_beats;

    logic b_rd_data_valid;
    logic b_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] b_rd_data;
    logic b_rd_data_last;
    logic b_rd_done;
    logic b_rd_error;

    operand_read_dma #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ELEM_WIDTH     (ELEM_WIDTH),
        .LANE_COUNT     (B_LANE_COUNT),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH),
        .K_DEPTH        (K_DEPTH),
        .BUFFER_COUNT   (B_BUFFER_COUNT)
    ) u_b_read_dma (
        .clk             (clk),
        .reset           (reset),

        .load_req        (b_load_req),
        .load_accept     (b_load_accept),
        .base_addr       (b_base_addr),
        .stride_bytes    (b_stride_bytes),
        .load_size       (b_load_size),
        .load_done       (b_load_done),
        .busy            (b_dma_busy),
        .error           (b_load_error),

        .bank_load_req   (b_bank_load_req),
        .bank_load_grant (b_bank_load_grant),
        .bank_load_bank  (b_bank_load_bank),
        .bank_load_done  (b_bank_load_done),

        .rd_req_valid    (b_rd_req_valid),
        .rd_req_ready    (b_rd_req_ready),
        .rd_req_addr     (b_rd_req_addr),
        .rd_req_beats    (b_rd_req_beats),
        .rd_data_valid   (b_rd_data_valid),
        .rd_data_ready   (b_rd_data_ready),
        .rd_data         (b_rd_data),
        .rd_data_last    (b_rd_data_last),
        .rd_done         (b_rd_done),
        .rd_error        (b_rd_error),

        .buffer_wen      (b_wen),
        .buffer_wbank    (b_wbank),
        .buffer_wlane    (b_wlane),
        .buffer_waddr    (b_waddr),
        .buffer_wdata    (b_wdata)
    );

    // ============================================================
    // Selected A read interface
    // ============================================================

    logic a_rd_req_valid;
    logic a_rd_req_ready;
    logic [ADDR_WIDTH-1:0] a_rd_req_addr;
    logic [31:0] a_rd_req_beats;

    logic a_rd_data_valid;
    logic a_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] a_rd_data;
    logic a_rd_data_last;
    logic a_rd_done;
    logic a_rd_error;

    assign a_rd_req_valid =
        conv_mode ? conv_a_rd_req_valid : gemm_a_rd_req_valid;

    assign a_rd_req_addr =
        conv_mode ? conv_a_rd_req_addr : gemm_a_rd_req_addr;

    assign a_rd_req_beats =
        conv_mode ? conv_a_rd_req_beats : gemm_a_rd_req_beats;

    assign a_rd_data_ready =
        conv_mode ? conv_a_rd_data_ready : gemm_a_rd_data_ready;

    assign conv_a_rd_req_ready =
        conv_mode && a_rd_req_ready;

    assign gemm_a_rd_req_ready =
        !conv_mode && a_rd_req_ready;

    assign conv_a_rd_data_valid =
        conv_mode && a_rd_data_valid;

    assign gemm_a_rd_data_valid =
        !conv_mode && a_rd_data_valid;

    assign conv_a_rd_data = a_rd_data;
    assign gemm_a_rd_data = a_rd_data;

    assign conv_a_rd_data_last = a_rd_data_last;
    assign gemm_a_rd_data_last = a_rd_data_last;

    assign conv_a_rd_done =
        conv_mode && a_rd_done;

    assign gemm_a_rd_done =
        !conv_mode && a_rd_done;

    assign conv_a_rd_error =
        conv_mode && a_rd_error;

    assign gemm_a_rd_error =
        !conv_mode && a_rd_error;

    // ============================================================
    // Existing A/B read arbiter
    // ============================================================

    logic shared_req_valid;
    logic shared_req_ready;
    logic [ADDR_WIDTH-1:0] shared_req_addr;
    logic [31:0] shared_req_beats;

    logic shared_data_valid;
    logic shared_data_ready;
    logic [MEM_WORD_WIDTH-1:0] shared_data;
    logic shared_data_last;

    logic shared_done;
    logic shared_error;
    logic axi_busy;

    read_request_arbiter #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH)
    ) u_read_arbiter (
        .clk           (clk),
        .reset         (reset),

        .m0_req_valid  (a_rd_req_valid),
        .m0_req_ready  (a_rd_req_ready),
        .m0_req_addr   (a_rd_req_addr),
        .m0_req_beats  (a_rd_req_beats),

        .m0_data_valid (a_rd_data_valid),
        .m0_data_ready (a_rd_data_ready),
        .m0_data       (a_rd_data),
        .m0_data_last  (a_rd_data_last),
        .m0_done       (a_rd_done),
        .m0_error      (a_rd_error),

        .m1_req_valid  (b_rd_req_valid),
        .m1_req_ready  (b_rd_req_ready),
        .m1_req_addr   (b_rd_req_addr),
        .m1_req_beats  (b_rd_req_beats),

        .m1_data_valid (b_rd_data_valid),
        .m1_data_ready (b_rd_data_ready),
        .m1_data       (b_rd_data),
        .m1_data_last  (b_rd_data_last),
        .m1_done       (b_rd_done),
        .m1_error      (b_rd_error),

        .s_req_valid   (shared_req_valid),
        .s_req_ready   (shared_req_ready),
        .s_req_addr    (shared_req_addr),
        .s_req_beats   (shared_req_beats),

        .s_data_valid  (shared_data_valid),
        .s_data_ready  (shared_data_ready),
        .s_data       (shared_data),
        .s_data_last  (shared_data_last),
        .s_done        (shared_done),
        .s_error       (shared_error)
    );

    // ============================================================
    // Existing shared AXI read master
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_axi_read_master (
        .clk           (clk),
        .reset         (reset),

        .req_valid     (shared_req_valid),
        .req_ready     (shared_req_ready),
        .req_addr      (shared_req_addr),
        .req_beats     (shared_req_beats),

        .data_valid    (shared_data_valid),
        .data_ready    (shared_data_ready),
        .data          (shared_data),
        .data_last     (shared_data_last),

        .busy          (axi_busy),
        .done          (shared_done),
        .error         (shared_error),

        .m_axi_arid    (m_axi_arid),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),

        .m_axi_rid     (m_axi_rid),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );

    // ============================================================
    // Status
    // ============================================================

    assign busy =
        gemm_a_busy ||
        conv_a_busy ||
        b_dma_busy ||
        axi_busy;

    assign error =
        a_load_error ||
        b_load_error ||
        shared_error;

    initial begin

        if (ADDR_WIDTH != 64)
            $fatal(1, "ADDR_WIDTH must be 64");

        if (ELEM_WIDTH != 8)
            $fatal(1, "ELEM_WIDTH must be 8");

        if (MEM_WORD_WIDTH != 32)
            $fatal(1, "MEM_WORD_WIDTH must be 32");

        if (A_LANE_COUNT < 1 || B_LANE_COUNT < 1)
            $fatal(1, "Invalid lane count");

        if (K_DEPTH < 1)
            $fatal(1, "Invalid K_DEPTH");

    end

endmodule
