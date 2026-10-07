module c_write_dma #(
    parameter int unsigned ADDR_WIDTH     = 64,

    parameter int unsigned ROWS           = 4,
    parameter int unsigned COLS           = 4,

    parameter int unsigned ACC_WIDTH      = 32,
    parameter int unsigned AXI_DATA_WIDTH = 32,

    parameter int unsigned ID_WIDTH       = 1,

    // Local C-buffer address width.
    //
    // gemm_core currently uses its local DEPTH address space.
    parameter int unsigned C_ADDR_WIDTH   = 8,

    parameter int unsigned ROW_DATA_WIDTH =
        COLS * ACC_WIDTH,

    parameter int unsigned ROW_BEATS =
        ROW_DATA_WIDTH / AXI_DATA_WIDTH,

    parameter int unsigned ROW_INDEX_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS),

    parameter int unsigned BEAT_COUNT_WIDTH =
        (ROW_BEATS <= 1) ?
        1 :
        $clog2(ROW_BEATS + 1)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Completed C tile from GEMM executor
    //
    // tile_valid stays high until this DMA has completely written
    // the tile to system memory.
    //
    // tile_accept is asserted only after the whole tile has been
    // written successfully or aborted because of an error.
    // ============================================================

    input  logic                  tile_valid,
    output logic                  tile_accept,

    input  logic [ADDR_WIDTH-1:0] tile_addr,
    input  logic [31:0]           tile_stride_bytes,

    // ============================================================
    // Local C buffer read interface
    //
    // C buffer contains:
    //
    // address 0 -> output row 0
    // address 1 -> output row 1
    // ...
    //
    // Each read returns one complete packed C row:
    //
    // {C[row][COLS-1], ..., C[row][1], C[row][0]}
    // ============================================================

    output logic                      c_ren,
    output logic [C_ADDR_WIDTH-1:0]   c_raddr,
    input  logic [ROW_DATA_WIDTH-1:0] c_rdata,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

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

    output logic [AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output logic [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output logic                          m_axi_wlast,
    output logic                          m_axi_wvalid,
    input  logic                          m_axi_wready,

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

    localparam int unsigned AXI_BYTES =
        AXI_DATA_WIDTH / 8;

    localparam int unsigned ROW_BYTES =
        ROW_DATA_WIDTH / 8;

    localparam logic [ADDR_WIDTH-1:0] ALIGN_MASK =
        ADDR_WIDTH'(AXI_BYTES - 1);

    localparam logic [31:0] ALIGN_MASK_32 =
        32'(AXI_BYTES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_C_READ_REQ,
        ST_C_READ_CAPTURE,
        ST_WRITE_REQ,
        ST_WRITE_DATA,
        ST_WAIT_WRITE,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Locked tile information
    // ============================================================

    logic [31:0]           tile_stride_q;


    // ============================================================
    // Current row
    // ============================================================

    logic [ROW_INDEX_WIDTH-1:0]
        row_idx_q;

    logic [ADDR_WIDTH-1:0]
        row_addr_q;


    // ============================================================
    // Current packed C row
    //
    // We use a shift register instead of a variable part-select.
    //
    // Initial:
    //
    // {C3, C2, C1, C0}
    //
    // AXI beat 0:
    //
    // row_shift_q[31:0] = C0
    //
    // then shift right by AXI_DATA_WIDTH.
    // ============================================================

    logic [ROW_DATA_WIDTH-1:0]
        row_shift_q;

    logic [BEAT_COUNT_WIDTH-1:0]
        beat_idx_q;


    // ============================================================
    // AXI write-master internal interface
    // ============================================================

    logic                  wr_req_valid;
    logic                  wr_req_ready;
    logic [ADDR_WIDTH-1:0] wr_req_addr;
    logic [31:0]           wr_req_beats;

    logic                      wr_data_valid;
    logic                      wr_data_ready;
    logic [AXI_DATA_WIDTH-1:0] wr_data;

    logic wr_busy;
    logic wr_done;
    logic wr_error;


    // ============================================================
    // Command validation
    // ============================================================

    logic command_invalid;

    always_comb begin

        command_invalid =
            (
                (tile_addr & ALIGN_MASK) !=
                {ADDR_WIDTH{1'b0}}
            ) ||
            (
                (tile_stride_bytes & ALIGN_MASK_32) !=
                32'd0
            ) ||
            (
                tile_stride_bytes <
                32'(ROW_BYTES)
            );

    end


    // ============================================================
    // Tile completion handshake
    //
    // Executor keeps tile_valid asserted until tile_accept.
    // ============================================================

    assign tile_accept =
        (state == ST_DONE);

    assign done =
        (state == ST_DONE);


    // ============================================================
    // Overall busy
    // ============================================================

    assign busy =
        (
            (state != ST_IDLE) &&
            (state != ST_DONE)
        ) ||
        wr_busy;


    // ============================================================
    // C-buffer read
    //
    // SRAM read is synchronous.
    //
    // ST_C_READ_REQ:
    //   assert c_ren
    //
    // next cycle:
    //   c_rdata becomes valid
    //
    // ST_C_READ_CAPTURE:
    //   capture c_rdata
    // ============================================================

    assign c_ren =
        (state == ST_C_READ_REQ);

    assign c_raddr =
        C_ADDR_WIDTH'(row_idx_q);


    // ============================================================
    // AXI write request for current row
    //
    // Each row becomes one high-level write request.
    //
    // axi_write_master may further split it because of:
    //
    // - 256-beat AXI limit
    // - 4KB boundary
    // ============================================================

    assign wr_req_valid =
        (state == ST_WRITE_REQ);

    assign wr_req_addr =
        row_addr_q;

    assign wr_req_beats =
        32'(ROW_BEATS);


    // ============================================================
    // AXI write data stream
    // ============================================================

    assign wr_data_valid =
        (state == ST_WRITE_DATA);

    assign wr_data =
        row_shift_q[
            AXI_DATA_WIDTH-1
            :
            0
        ];


    // ============================================================
    // AXI write master
    // ============================================================

    axi_write_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (AXI_DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) u_axi_write_master (
        .clk           (clk),
        .reset         (reset),

        // --------------------------------------------------------
        // Internal request
        // --------------------------------------------------------

        .req_valid     (wr_req_valid),
        .req_ready     (wr_req_ready),

        .req_addr      (wr_req_addr),
        .req_beats     (wr_req_beats),

        // --------------------------------------------------------
        // Internal data stream
        // --------------------------------------------------------

        .data_valid    (wr_data_valid),
        .data_ready    (wr_data_ready),
        .data          (wr_data),

        // --------------------------------------------------------
        // Status
        // --------------------------------------------------------

        .busy          (wr_busy),
        .done          (wr_done),
        .error         (wr_error),

        // --------------------------------------------------------
        // AXI AW
        // --------------------------------------------------------

        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),

        // --------------------------------------------------------
        // AXI W
        // --------------------------------------------------------

        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),

        // --------------------------------------------------------
        // AXI B
        // --------------------------------------------------------

        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready)
    );


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <=
                ST_IDLE;

            tile_stride_q <=
                '0;

            row_idx_q <=
                '0;

            row_addr_q <=
                '0;

            row_shift_q <=
                '0;

            beat_idx_q <=
                '0;

            error <=
                1'b0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                //
                // Wait for one completed C tile.
                // =================================================

                ST_IDLE: begin

                    if (tile_valid) begin

                        error <=
                            1'b0;

                        tile_stride_q <=
                            tile_stride_bytes;

                        row_idx_q <=
                            '0;

                        row_addr_q <=
                            tile_addr;

                        beat_idx_q <=
                            '0;


                        if (command_invalid) begin

                            error <=
                                1'b1;

                            state <=
                                ST_DONE;

                        end else begin

                            state <=
                                ST_C_READ_REQ;

                        end

                    end

                end


                // =================================================
                // C READ REQUEST
                //
                // Assert synchronous SRAM read enable for current
                // output row.
                // =================================================

                ST_C_READ_REQ: begin

                    state <=
                        ST_C_READ_CAPTURE;

                end


                // =================================================
                // C READ CAPTURE
                //
                // c_rdata now contains the requested row.
                // =================================================

                ST_C_READ_CAPTURE: begin

                    row_shift_q <=
                        c_rdata;

                    beat_idx_q <=
                        '0;

                    state <=
                        ST_WRITE_REQ;

                end


                // =================================================
                // START AXI WRITE REQUEST
                // =================================================

                ST_WRITE_REQ: begin

                    if (
                        wr_req_valid &&
                        wr_req_ready
                    ) begin

                        state <=
                            ST_WRITE_DATA;

                    end

                end


                // =================================================
                // STREAM ONE C ROW TO AXI WRITE MASTER
                // =================================================

                ST_WRITE_DATA: begin

                    if (
                        wr_data_valid &&
                        wr_data_ready
                    ) begin

                        if (
                            beat_idx_q ==
                            BEAT_COUNT_WIDTH'(
                                ROW_BEATS - 1
                            )
                        ) begin

                            // -------------------------------------
                            // Last beat of current C row.
                            // -------------------------------------

                            state <=
                                ST_WAIT_WRITE;

                        end else begin

                            // -------------------------------------
                            // Move next packed C element(s) into
                            // the low AXI-data portion.
                            // -------------------------------------

                            row_shift_q <=
                                row_shift_q >>
                                AXI_DATA_WIDTH;

                            beat_idx_q <=
                                beat_idx_q +
                                BEAT_COUNT_WIDTH'(1);

                        end

                    end

                end


                // =================================================
                // WAIT FOR AXI BRESP / HIGH-LEVEL REQUEST DONE
                // =================================================

                ST_WAIT_WRITE: begin

                    if (wr_done) begin

                        if (wr_error) begin

                            error <=
                                1'b1;

                            state <=
                                ST_DONE;

                        end else if (
                            row_idx_q ==
                            ROW_INDEX_WIDTH'(
                                ROWS - 1
                            )
                        ) begin

                            // -------------------------------------
                            // Entire C tile written.
                            // -------------------------------------

                            state <=
                                ST_DONE;

                        end else begin

                            // -------------------------------------
                            // Advance to next output row.
                            // -------------------------------------

                            row_idx_q <=
                                row_idx_q +
                                ROW_INDEX_WIDTH'(1);

                            row_addr_q <=
                                row_addr_q +
                                ADDR_WIDTH'(
                                    tile_stride_q
                                );

                            state <=
                                ST_C_READ_REQ;

                        end

                    end

                end


                // =================================================
                // DONE
                //
                // tile_accept is asserted in this state.
                // Executor can now advance to the next C tile.
                // =================================================

                ST_DONE: begin

                    state <=
                        ST_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

                default: begin

                    state <=
                        ST_IDLE;

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


        if (ACC_WIDTH < 8) begin

            $fatal(
                1,
                "ACC_WIDTH must be >= 8"
            );

        end


        if ((ACC_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "ACC_WIDTH must be byte aligned"
            );

        end


        if (AXI_DATA_WIDTH < 8) begin

            $fatal(
                1,
                "AXI_DATA_WIDTH must be >= 8"
            );

        end


        if (
            (AXI_DATA_WIDTH % 8) !=
            0
        ) begin

            $fatal(
                1,
                "AXI_DATA_WIDTH must be byte aligned"
            );

        end


        if (
            (ROW_DATA_WIDTH % AXI_DATA_WIDTH) !=
            0
        ) begin

            $fatal(
                1,
                "C row width must be divisible by AXI data width"
            );

        end


        if (
            (
                AXI_BYTES &
                (AXI_BYTES - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "AXI byte width must be a power of two"
            );

        end


        if (C_ADDR_WIDTH < 1) begin

            $fatal(
                1,
                "C_ADDR_WIDTH must be >= 1"
            );

        end


        if (ID_WIDTH < 1) begin

            $fatal(
                1,
                "ID_WIDTH must be >= 1"
            );

        end

    end

endmodule
