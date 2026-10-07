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
        (K_DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    parameter int unsigned A_LANE_WIDTH =
        (A_LANE_COUNT <= 1) ?
        1 :
        $clog2(A_LANE_COUNT),

    parameter int unsigned B_LANE_WIDTH =
        (B_LANE_COUNT <= 1) ?
        1 :
        $clog2(B_LANE_COUNT),

    parameter int unsigned A_BANK_WIDTH =
        (A_BUFFER_COUNT <= 1) ?
        1 :
        $clog2(A_BUFFER_COUNT),

    parameter int unsigned B_BANK_WIDTH =
        (B_BUFFER_COUNT <= 1) ?
        1 :
        $clog2(B_BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // A tile load command
    //
    // base address has already been calculated by the upper-level
    // GEMM executor / address generator.
    //
    // For A:
    //
    // base =
    //     A_base
    //     + m_start * A_stride
    //     + k_start
    // ============================================================

    input  logic                    a_load_req,
    output logic                    a_load_accept,

    input  logic [ADDR_WIDTH-1:0]   a_base_addr,
    input  logic [31:0]             a_stride_bytes,
    input  logic [K_SIZE_WIDTH-1:0] a_load_size,

    output logic a_load_done,
    output logic a_load_error,

    // ============================================================
    // B^T tile load command
    //
    // For B^T:
    //
    // base =
    //     B_base
    //     + n_start * B_stride
    //     + k_start
    // ============================================================

    input  logic                    b_load_req,
    output logic                    b_load_accept,

    input  logic [ADDR_WIDTH-1:0]   b_base_addr,
    input  logic [31:0]             b_stride_bytes,
    input  logic [K_SIZE_WIDTH-1:0] b_load_size,

    output logic b_load_done,
    output logic b_load_error,

    // ============================================================
    // A buffer-manager load interface
    // ============================================================

    output logic                    a_bank_load_req,
    input  logic                    a_bank_load_grant,
    input  logic [A_BANK_WIDTH-1:0] a_bank_load_bank,
    output logic                    a_bank_load_done,

    // ============================================================
    // B buffer-manager load interface
    // ============================================================

    output logic                    b_bank_load_req,
    input  logic                    b_bank_load_grant,
    input  logic [B_BANK_WIDTH-1:0] b_bank_load_bank,
    output logic                    b_bank_load_done,

    // ============================================================
    // A scratchpad write interface
    //
    // One AXI word is written into one lane SRAM.
    // ============================================================

    output logic                         a_wen,
    output logic [A_BANK_WIDTH-1:0]      a_wbank,
    output logic [A_LANE_WIDTH-1:0]      a_wlane,
    output logic [WORD_ADDR_WIDTH-1:0]   a_waddr,
    output logic [MEM_WORD_WIDTH-1:0]    a_wdata,

    // ============================================================
    // B scratchpad write interface
    // ============================================================

    output logic                         b_wen,
    output logic [B_BANK_WIDTH-1:0]      b_wbank,
    output logic [B_LANE_WIDTH-1:0]      b_wlane,
    output logic [WORD_ADDR_WIDTH-1:0]   b_waddr,
    output logic [MEM_WORD_WIDTH-1:0]    b_wdata,

    // ============================================================
    // Overall status
    // ============================================================

    output logic busy,
    output logic error,

    // ============================================================
    // AXI4 Read Address Channel
    // ============================================================

    output logic [ID_WIDTH-1:0]          m_axi_arid,
    output logic [ADDR_WIDTH-1:0]        m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,

    // ============================================================
    // AXI4 Read Data Channel
    // ============================================================

    input  logic [ID_WIDTH-1:0]          m_axi_rid,
    input  logic [MEM_WORD_WIDTH-1:0]    m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready
);

    // ============================================================
    // A DMA -> arbiter
    // ============================================================

    logic                  a_rd_req_valid;
    logic                  a_rd_req_ready;
    logic [ADDR_WIDTH-1:0] a_rd_req_addr;
    logic [31:0]           a_rd_req_beats;

    logic                      a_rd_data_valid;
    logic                      a_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] a_rd_data;
    logic                      a_rd_data_last;

    logic a_rd_done;
    logic a_rd_error;

    logic a_dma_busy;


    // ============================================================
    // B DMA -> arbiter
    // ============================================================

    logic                  b_rd_req_valid;
    logic                  b_rd_req_ready;
    logic [ADDR_WIDTH-1:0] b_rd_req_addr;
    logic [31:0]           b_rd_req_beats;

    logic                      b_rd_data_valid;
    logic                      b_rd_data_ready;
    logic [MEM_WORD_WIDTH-1:0] b_rd_data;
    logic                      b_rd_data_last;

    logic b_rd_done;
    logic b_rd_error;

    logic b_dma_busy;


    // ============================================================
    // Arbiter -> AXI read master
    // ============================================================

    logic                  shared_req_valid;
    logic                  shared_req_ready;
    logic [ADDR_WIDTH-1:0] shared_req_addr;
    logic [31:0]           shared_req_beats;

    logic                      shared_data_valid;
    logic                      shared_data_ready;
    logic [MEM_WORD_WIDTH-1:0] shared_data;
    logic                      shared_data_last;

    logic shared_done;
    logic shared_error;

    logic axi_busy;


    // ============================================================
    // A Operand Read DMA
    // ============================================================

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

        .load_req        (a_load_req),
        .load_accept     (a_load_accept),

        .base_addr       (a_base_addr),
        .stride_bytes    (a_stride_bytes),
        .load_size       (a_load_size),

        .load_done       (a_load_done),
        .busy            (a_dma_busy),
        .error           (a_load_error),

        // --------------------------------------------------------
        // A buffer manager
        // --------------------------------------------------------

        .bank_load_req   (a_bank_load_req),
        .bank_load_grant (a_bank_load_grant),
        .bank_load_bank  (a_bank_load_bank),
        .bank_load_done  (a_bank_load_done),

        // --------------------------------------------------------
        // Shared read interface
        // --------------------------------------------------------

        .rd_req_valid    (a_rd_req_valid),
        .rd_req_ready    (a_rd_req_ready),

        .rd_req_addr     (a_rd_req_addr),
        .rd_req_beats    (a_rd_req_beats),

        .rd_data_valid   (a_rd_data_valid),
        .rd_data_ready   (a_rd_data_ready),
        .rd_data         (a_rd_data),
        .rd_data_last    (a_rd_data_last),

        .rd_done         (a_rd_done),
        .rd_error        (a_rd_error),

        // --------------------------------------------------------
        // A scratchpad
        // --------------------------------------------------------

        .buffer_wen      (a_wen),
        .buffer_wbank    (a_wbank),
        .buffer_wlane    (a_wlane),
        .buffer_waddr    (a_waddr),
        .buffer_wdata    (a_wdata)
    );


    // ============================================================
    // B Operand Read DMA
    // ============================================================

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

        // --------------------------------------------------------
        // B buffer manager
        // --------------------------------------------------------

        .bank_load_req   (b_bank_load_req),
        .bank_load_grant (b_bank_load_grant),
        .bank_load_bank  (b_bank_load_bank),
        .bank_load_done  (b_bank_load_done),

        // --------------------------------------------------------
        // Shared read interface
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // B scratchpad
        // --------------------------------------------------------

        .buffer_wen      (b_wen),
        .buffer_wbank    (b_wbank),
        .buffer_wlane    (b_wlane),
        .buffer_waddr    (b_waddr),
        .buffer_wdata    (b_wdata)
    );


    // ============================================================
    // A/B Read Request Arbiter
    //
    // Arbitration granularity:
    //
    // one complete row request
    //
    // If axi_read_master internally splits one row into multiple
    // AXI bursts, ownership is NOT released between those bursts.
    // ============================================================

    read_request_arbiter #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH)
    ) u_read_arbiter (
        .clk           (clk),
        .reset         (reset),

        // --------------------------------------------------------
        // Master 0 = A
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // Master 1 = B
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // Shared side
        // --------------------------------------------------------

        .s_req_valid   (shared_req_valid),
        .s_req_ready   (shared_req_ready),
        .s_req_addr    (shared_req_addr),
        .s_req_beats   (shared_req_beats),

        .s_data_valid  (shared_data_valid),
        .s_data_ready  (shared_data_ready),
        .s_data        (shared_data),
        .s_data_last   (shared_data_last),

        .s_done        (shared_done),
        .s_error       (shared_error)
    );


    // ============================================================
    // Shared AXI Read Master
    // ============================================================

    axi_read_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_axi_read_master (
        .clk           (clk),
        .reset         (reset),

        // --------------------------------------------------------
        // Internal request
        // --------------------------------------------------------

        .req_valid     (shared_req_valid),
        .req_ready     (shared_req_ready),

        .req_addr      (shared_req_addr),
        .req_beats     (shared_req_beats),

        // --------------------------------------------------------
        // Internal data stream
        // --------------------------------------------------------

        .data_valid    (shared_data_valid),
        .data_ready    (shared_data_ready),
        .data          (shared_data),
        .data_last     (shared_data_last),

        .busy          (axi_busy),
        .done          (shared_done),
        .error         (shared_error),

        // --------------------------------------------------------
        // AXI AR
        // --------------------------------------------------------

        .m_axi_arid    (m_axi_arid),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),

        // --------------------------------------------------------
        // AXI R
        // --------------------------------------------------------

        .m_axi_rid     (m_axi_rid),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );


    // ============================================================
    // Overall status
    // ============================================================

    assign busy =
        a_dma_busy ||
        b_dma_busy ||
        axi_busy;

    assign error =
        a_load_error ||
        b_load_error ||
        shared_error;


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


        if (ELEM_WIDTH < 8) begin

            $fatal(
                1,
                "ELEM_WIDTH must be >= 8"
            );

        end


        if ((ELEM_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "ELEM_WIDTH must be byte aligned"
            );

        end


        if (
            (MEM_WORD_WIDTH % ELEM_WIDTH) != 0
        ) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by ELEM_WIDTH"
            );

        end


        if (A_LANE_COUNT < 1) begin

            $fatal(
                1,
                "A_LANE_COUNT must be >= 1"
            );

        end


        if (B_LANE_COUNT < 1) begin

            $fatal(
                1,
                "B_LANE_COUNT must be >= 1"
            );

        end


        if (K_DEPTH < 1) begin

            $fatal(
                1,
                "K_DEPTH must be >= 1"
            );

        end

    end

endmodule
