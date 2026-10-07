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
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // Debug accumulator
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
    // Locked GEMM command
    // ============================================================

    logic [ADDR_WIDTH-1:0] a_base_q;
    logic [ADDR_WIDTH-1:0] b_base_q;
    logic [ADDR_WIDTH-1:0] c_base_q;

    logic [31:0] a_stride_q;
    logic [31:0] b_stride_q;
    logic [31:0] c_stride_q;


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
                K_SIZE_WIDTH'(
                    K_TILE_SIZE
                );

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
    //
    // Zero-sized GEMM is not supported.
    //
    // M/N edge tiles currently rely on software/runtime padding.
    // ============================================================

    logic command_invalid;


    always_comb begin

        command_invalid =
            (cmd_m == 32'd0) ||
            (cmd_n == 32'd0) ||
            (cmd_k == 32'd0);

    end


    // ============================================================
    // Scheduler
    // ============================================================

    logic scheduler_start;

    logic scheduler_busy;
    logic scheduler_done;


    // ============================================================
    // Scheduler load stage
    // ============================================================

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


    // ============================================================
    // Scheduler compute stage
    // ============================================================

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
    // External-memory tile addresses
    // ============================================================

    logic [ADDR_WIDTH-1:0]
        a_tile_addr;

    logic [ADDR_WIDTH-1:0]
        b_tile_addr;

    logic [ADDR_WIDTH-1:0]
        c_tile_addr;


    // ============================================================
    // Read path <-> buffer manager load interfaces
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
    // Buffer-manager compute bank
    // ============================================================

    logic a_compute_bank;
    logic b_compute_bank;


    // ============================================================
    // DMA -> operand scratchpad
    // ============================================================

    logic
        a_wen;

    logic
        a_wbank;

    logic [A_LANE_WIDTH-1:0]
        a_wlane;

    logic [WORD_ADDR_WIDTH-1:0]
        a_waddr;

    logic [MEM_WORD_WIDTH-1:0]
        a_wdata;


    logic
        b_wen;

    logic
        b_wbank;

    logic [B_LANE_WIDTH-1:0]
        b_wlane;

    logic [WORD_ADDR_WIDTH-1:0]
        b_waddr;

    logic [MEM_WORD_WIDTH-1:0]
        b_wdata;


    // ============================================================
    // Read-path status
    // ============================================================

    logic read_path_busy;
    logic read_path_error;

    logic a_load_error;
    logic b_load_error;


    // ============================================================
    // GEMM core status
    // ============================================================

    logic core_busy;
    logic core_done;


    // ============================================================
    // Local C-buffer interface
    // ============================================================

    logic
        c_ren;

    logic [CORE_ADDR_WIDTH-1:0]
        c_raddr;

    logic [COLS*ACC_WIDTH-1:0]
        c_rdata;


    // ============================================================
    // C write DMA
    // ============================================================

    logic
        c_tile_pending_q;

    logic
        c_write_tile_accept;

    logic
        c_write_busy;

    logic
        c_write_done;

    logic
        c_write_error;


    // ============================================================
    // Command handshake
    // ============================================================

    assign cmd_ready =
        (exec_state == EX_IDLE);


    assign scheduler_start =
        (exec_state == EX_LAUNCH);


    // ============================================================
    // Overall status
    // ============================================================

    assign busy =
        (
            (exec_state != EX_IDLE) &&
            (exec_state != EX_DONE)
        ) ||
        scheduler_busy ||
        read_path_busy ||
        core_busy ||
        c_write_busy;


    assign done =
        (exec_state == EX_DONE);


    // ============================================================
    // Tile scheduler
    //
    // Load and compute stages are now independent.
    //
    // While compute tile i is running:
    //
    //     load tile i+1
    //
    // may proceed in parallel if an EMPTY operand bank exists.
    // ============================================================

    tile_scheduler #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),
        .K_TILE_SIZE      (K_TILE_SIZE),
        .K_SIZE_WIDTH     (K_SIZE_WIDTH)
    ) u_tile_scheduler (
        .clk                (clk),
        .reset              (reset),

        // --------------------------------------------------------
        // GEMM shape
        // --------------------------------------------------------

        .start              (scheduler_start),

        .m_tile_count       (m_tile_count_q),
        .n_tile_count       (n_tile_count_q),
        .k_tile_count       (k_tile_count_q),

        .last_k_size        (last_k_size_q),

        // --------------------------------------------------------
        // Load stage
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // A buffer manager - compute side
        // --------------------------------------------------------

        .a_compute_req      (scheduler_a_compute_req),
        .a_compute_grant    (scheduler_a_compute_grant),

        .a_compute_done     (scheduler_a_compute_done),
        .a_release_bank     (scheduler_a_release_bank),

        // --------------------------------------------------------
        // B buffer manager - compute side
        // --------------------------------------------------------

        .b_compute_req      (scheduler_b_compute_req),
        .b_compute_grant    (scheduler_b_compute_grant),

        .b_compute_done     (scheduler_b_compute_done),
        .b_release_bank     (scheduler_b_release_bank),

        // --------------------------------------------------------
        // GEMM compute
        //
        // matrix_done is RAW compute completion.
        //
        // writeback_done is external C-write completion.
        // --------------------------------------------------------

        .matrix_start       (scheduler_matrix_start),
        .matrix_done        (core_done),

        .writeback_done     (c_write_done),

        .clear_acc          (scheduler_clear_acc),
        .writeback_en       (scheduler_writeback_en),

        .compute_k_size     (scheduler_compute_k_size),

        .compute_m_tile_idx (compute_m_tile_idx),
        .compute_n_tile_idx (compute_n_tile_idx),

        // --------------------------------------------------------
        // Status
        // --------------------------------------------------------

        .busy               (scheduler_busy),
        .done               (scheduler_done)
    );


    // ============================================================
    // GEMM address generator
    //
    // A/B addresses:
    //     load-stage coordinates
    //
    // C address:
    //     compute-stage coordinates
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

        // Load tile
        .load_m_tile_idx    (load_m_tile_idx),
        .load_n_tile_idx    (load_n_tile_idx),
        .load_k_tile_idx    (load_k_tile_idx),

        // Compute tile
        .compute_m_tile_idx (compute_m_tile_idx),
        .compute_n_tile_idx (compute_n_tile_idx),

        // External addresses
        .a_tile_addr        (a_tile_addr),
        .b_tile_addr        (b_tile_addr),
        .c_tile_addr        (c_tile_addr)
    );


    // ============================================================
    // A buffer manager
    //
    // With BUFFER_COUNT=2:
    //
    // one bank may be COMPUTING while the other is LOADING.
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (A_BUFFER_COUNT)
    ) u_a_buffer_manager (
        .clk           (clk),
        .reset         (reset),

        // --------------------------------------------------------
        // Load side
        // --------------------------------------------------------

        .load_req      (a_bank_load_req),
        .load_grant    (a_bank_load_grant),
        .load_bank     (a_bank_load_bank),
        .load_done     (a_bank_load_done),

        // --------------------------------------------------------
        // Compute side
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // Load side
        // --------------------------------------------------------

        .load_req      (b_bank_load_req),
        .load_grant    (b_bank_load_grant),
        .load_bank     (b_bank_load_bank),
        .load_done     (b_bank_load_done),

        // --------------------------------------------------------
        // Compute side
        // --------------------------------------------------------

        .compute_req   (scheduler_b_compute_req),
        .compute_grant (scheduler_b_compute_grant),
        .compute_bank  (b_compute_bank),

        .compute_done  (scheduler_b_compute_done),
        .release_bank  (scheduler_b_release_bank)
    );


    // ============================================================
    // A/B Read DMA Path
    //
    // IMPORTANT:
    //
    // DMA uses LOAD-stage metadata, not compute-stage metadata.
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

        // ========================================================
        // A tile load
        // ========================================================

        .a_load_req        (scheduler_a_load_req),
        .a_load_accept     (scheduler_a_load_accept),

        .a_base_addr       (a_tile_addr),
        .a_stride_bytes    (a_stride_q),

        .a_load_size       (
            scheduler_load_k_size
        ),

        .a_load_done       (scheduler_a_load_done),
        .a_load_error      (a_load_error),

        // ========================================================
        // B tile load
        // ========================================================

        .b_load_req        (scheduler_b_load_req),
        .b_load_accept     (scheduler_b_load_accept),

        .b_base_addr       (b_tile_addr),
        .b_stride_bytes    (b_stride_q),

        .b_load_size       (
            scheduler_load_k_size
        ),

        .b_load_done       (scheduler_b_load_done),
        .b_load_error      (b_load_error),

        // ========================================================
        // A buffer-manager load interface
        // ========================================================

        .a_bank_load_req   (a_bank_load_req),
        .a_bank_load_grant (a_bank_load_grant),
        .a_bank_load_bank  (a_bank_load_bank),
        .a_bank_load_done  (a_bank_load_done),

        // ========================================================
        // B buffer-manager load interface
        // ========================================================

        .b_bank_load_req   (b_bank_load_req),
        .b_bank_load_grant (b_bank_load_grant),
        .b_bank_load_bank  (b_bank_load_bank),
        .b_bank_load_done  (b_bank_load_done),

        // ========================================================
        // A SRAM write
        // ========================================================

        .a_wen             (a_wen),
        .a_wbank           (a_wbank),
        .a_wlane           (a_wlane),
        .a_waddr           (a_waddr),
        .a_wdata           (a_wdata),

        // ========================================================
        // B SRAM write
        // ========================================================

        .b_wen             (b_wen),
        .b_wbank           (b_wbank),
        .b_wlane           (b_wlane),
        .b_waddr           (b_waddr),
        .b_wdata           (b_wdata),

        // ========================================================
        // Status
        // ========================================================

        .busy              (read_path_busy),
        .error             (read_path_error),

        // ========================================================
        // AXI Read Address
        // ========================================================

        .m_axi_arid        (m_axi_arid),
        .m_axi_araddr      (m_axi_araddr),
        .m_axi_arlen       (m_axi_arlen),
        .m_axi_arsize      (m_axi_arsize),
        .m_axi_arburst     (m_axi_arburst),
        .m_axi_arvalid     (m_axi_arvalid),
        .m_axi_arready     (m_axi_arready),

        // ========================================================
        // AXI Read Data
        // ========================================================

        .m_axi_rid         (m_axi_rid),
        .m_axi_rdata       (m_axi_rdata),
        .m_axi_rresp       (m_axi_rresp),
        .m_axi_rlast       (m_axi_rlast),
        .m_axi_rvalid      (m_axi_rvalid),
        .m_axi_rready      (m_axi_rready)
    );


    // ============================================================
    // GEMM Core
    //
    // Compute uses COMPUTE-stage K size.
    //
    // A/B read banks are selected by buffer_manager.
    //
    // DMA may simultaneously write the opposite banks.
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

        // --------------------------------------------------------
        // Compute control
        // --------------------------------------------------------

        .start        (scheduler_matrix_start),

        .tile_k_size  (
            scheduler_compute_k_size
        ),

        .clear_acc    (
            scheduler_clear_acc
        ),

        .writeback_en (
            scheduler_writeback_en
        ),

        .busy         (core_busy),
        .done         (core_done),

        // --------------------------------------------------------
        // Every local C tile starts from row address 0.
        // --------------------------------------------------------

        .c_base_addr  ('0),

        // ========================================================
        // A scratchpad
        // ========================================================

        // DMA write side
        .a_wen        (a_wen),
        .a_wlane      (a_wlane),
        .a_waddr      (a_waddr),
        .a_wdata      (a_wdata),
        .a_wbank      (a_wbank),

        // Compute read bank
        .a_rbank      (a_compute_bank),

        // ========================================================
        // B scratchpad
        // ========================================================

        // DMA write side
        .b_wen        (b_wen),
        .b_wlane      (b_wlane),
        .b_waddr      (b_waddr),
        .b_wdata      (b_wdata),
        .b_wbank      (b_wbank),

        // Compute read bank
        .b_rbank      (b_compute_bank),

        // ========================================================
        // C buffer
        // ========================================================

        .c_ren        (c_ren),
        .c_raddr      (c_raddr),
        .c_rdata      (c_rdata),

        // ========================================================
        // Debug
        // ========================================================

        .acc_out      (acc_out)
    );


    // ============================================================
    // C Write DMA
    //
    // C tile address is generated from COMPUTE-stage m/n.
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

        // --------------------------------------------------------
        // Completed C tile
        // --------------------------------------------------------

        .tile_valid        (
            c_tile_pending_q
        ),

        .tile_accept       (
            c_write_tile_accept
        ),

        .tile_addr         (
            c_tile_addr
        ),

        .tile_stride_bytes (
            c_stride_q
        ),

        // --------------------------------------------------------
        // Local C buffer
        // --------------------------------------------------------

        .c_ren             (c_ren),
        .c_raddr           (c_raddr),
        .c_rdata           (c_rdata),

        // --------------------------------------------------------
        // Status
        // --------------------------------------------------------

        .busy              (c_write_busy),
        .done              (c_write_done),
        .error             (c_write_error),

        // --------------------------------------------------------
        // AXI Write Address
        // --------------------------------------------------------

        .m_axi_awid        (m_axi_awid),
        .m_axi_awaddr      (m_axi_awaddr),
        .m_axi_awlen       (m_axi_awlen),
        .m_axi_awsize      (m_axi_awsize),
        .m_axi_awburst     (m_axi_awburst),
        .m_axi_awvalid     (m_axi_awvalid),
        .m_axi_awready     (m_axi_awready),

        // --------------------------------------------------------
        // AXI Write Data
        // --------------------------------------------------------

        .m_axi_wdata       (m_axi_wdata),
        .m_axi_wstrb       (m_axi_wstrb),
        .m_axi_wlast       (m_axi_wlast),
        .m_axi_wvalid      (m_axi_wvalid),
        .m_axi_wready      (m_axi_wready),

        // --------------------------------------------------------
        // AXI Write Response
        // --------------------------------------------------------

        .m_axi_bid         (m_axi_bid),
        .m_axi_bresp       (m_axi_bresp),
        .m_axi_bvalid      (m_axi_bvalid),
        .m_axi_bready      (m_axi_bready)
    );


    // ============================================================
    // Completed C tile pending
    //
    // IMPORTANT:
    //
    // A/B operand banks are released by tile_scheduler immediately
    // at core_done.
    //
    // C writeback is independent from those operand banks.
    //
    // Therefore:
    //
    //     C writeback
    //          ||
    //     next A/B prefetch
    //
    // may overlap.
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            c_tile_pending_q <=
                1'b0;

        end else begin

            // ----------------------------------------------------
            // Final K tile of current C tile has completed.
            // ----------------------------------------------------

            if (
                core_done &&
                scheduler_writeback_en
            ) begin

                c_tile_pending_q <=
                    1'b1;

            end


            // ----------------------------------------------------
            // C write DMA consumed the tile.
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

                            // -------------------------------------
                            // Lock external-memory layout.
                            // -------------------------------------

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


                            // -------------------------------------
                            // Lock calculated GEMM tiling.
                            // -------------------------------------

                            m_tile_count_q <=
                                m_tile_count_calc;

                            n_tile_count_q <=
                                n_tile_count_calc;

                            k_tile_count_q <=
                                k_tile_count_calc;

                            last_k_size_q <=
                                last_k_size_calc;


                            // -------------------------------------
                            // Scheduler starts next cycle.
                            // -------------------------------------

                            exec_state <=
                                EX_LAUNCH;

                        end

                    end

                end


                // =================================================
                // LAUNCH
                //
                // scheduler_start is high for this state.
                // =================================================

                EX_LAUNCH: begin

                    exec_state <=
                        EX_RUN;

                end


                // =================================================
                // RUN
                // =================================================

                EX_RUN: begin

                    // ---------------------------------------------
                    // Accumulate errors.
                    // ---------------------------------------------

                    if (
                        read_path_error ||
                        a_load_error ||
                        b_load_error ||
                        c_write_error
                    ) begin

                        error <=
                            1'b1;

                    end


                    // ---------------------------------------------
                    // Complete GEMM:
                    //
                    // all load / compute / writeback stages drained.
                    // ---------------------------------------------

                    if (scheduler_done) begin

                        exec_state <=
                            EX_DONE;

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion indication.
                // =================================================

                EX_DONE: begin

                    exec_state <=
                        EX_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

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

    end

endmodule
