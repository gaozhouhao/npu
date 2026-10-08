module c_write_dma #(
    parameter int unsigned ADDR_WIDTH     = 64,

    parameter int unsigned ROWS           = 4,
    parameter int unsigned COLS           = 4,

    parameter int unsigned ACC_WIDTH      = 32,
    parameter int unsigned AXI_DATA_WIDTH = 32,

    parameter int unsigned ID_WIDTH       = 1,

    parameter int unsigned C_ADDR_WIDTH   = 8
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // C tile
    // ============================================================

    input  logic                  tile_valid,
    output logic                  tile_accept,

    input  logic [ADDR_WIDTH-1:0] tile_addr,

    input  logic [31:0]
        tile_stride_bytes,

    // 0 -> INT32 output
    // 1 -> packed INT8 output
    input logic
        int8_mode,

    // ============================================================
    // Local C row buffer
    //
    // In INT8 mode only the lowest COLS*8 bits are consumed.
    // ============================================================

    output logic
        c_ren,

    output logic [C_ADDR_WIDTH-1:0]
        c_raddr,

    input logic [COLS*ACC_WIDTH-1:0]
        c_rdata,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // AXI AW
    // ============================================================

    output logic [ID_WIDTH-1:0]
        m_axi_awid,

    output logic [ADDR_WIDTH-1:0]
        m_axi_awaddr,

    output logic [7:0]
        m_axi_awlen,

    output logic [2:0]
        m_axi_awsize,

    output logic [1:0]
        m_axi_awburst,

    output logic
        m_axi_awvalid,

    input logic
        m_axi_awready,

    // ============================================================
    // AXI W
    // ============================================================

    output logic [AXI_DATA_WIDTH-1:0]
        m_axi_wdata,

    output logic [(AXI_DATA_WIDTH/8)-1:0]
        m_axi_wstrb,

    output logic
        m_axi_wlast,

    output logic
        m_axi_wvalid,

    input logic
        m_axi_wready,

    // ============================================================
    // AXI B
    // ============================================================

    input logic [ID_WIDTH-1:0]
        m_axi_bid,

    input logic [1:0]
        m_axi_bresp,

    input logic
        m_axi_bvalid,

    output logic
        m_axi_bready
);


    localparam int unsigned AXI_BYTES =
        AXI_DATA_WIDTH / 8;

    localparam int unsigned AXI_SIZE =
        $clog2(AXI_BYTES);


    localparam int unsigned INT32_ROW_BITS =
        COLS * ACC_WIDTH;

    localparam int unsigned INT8_ROW_BITS =
        COLS * 8;


    localparam int unsigned INT32_ROW_BEATS =
        INT32_ROW_BITS /
        AXI_DATA_WIDTH;

    localparam int unsigned INT8_ROW_BEATS =
        INT8_ROW_BITS /
        AXI_DATA_WIDTH;


    localparam int unsigned MAX_ROW_BEATS =
        (INT32_ROW_BEATS > INT8_ROW_BEATS) ?
        INT32_ROW_BEATS :
        INT8_ROW_BEATS;


    localparam int unsigned ROW_INDEX_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS);


    localparam int unsigned BEAT_COUNT_WIDTH =
        (MAX_ROW_BEATS <= 1) ?
        1 :
        $clog2(MAX_ROW_BEATS + 1);


    typedef enum logic [3:0] {
        ST_IDLE,
        ST_READ_REQ,
        ST_READ_WAIT,
        ST_AW,
        ST_W,
        ST_B,
        ST_DONE
    } state_t;


    state_t state;


    logic [ADDR_WIDTH-1:0]
        tile_addr_q;

    logic [31:0]
        tile_stride_q;

    logic
        int8_mode_q;


    logic [ROW_INDEX_WIDTH-1:0]
        row_index_q;


    logic [BEAT_COUNT_WIDTH-1:0]
        row_beats_q;

    logic [BEAT_COUNT_WIDTH-1:0]
        beat_index_q;


    logic [COLS*ACC_WIDTH-1:0]
        row_data_q;


    // ============================================================
    // Status
    // ============================================================

    assign tile_accept =
        (state == ST_IDLE) &&
        tile_valid;


    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);


    assign done =
        (state == ST_DONE);


    // ============================================================
    // C-buffer read
    // ============================================================

    assign c_ren =
        (state == ST_READ_REQ);


    assign c_raddr =
        C_ADDR_WIDTH'(
            row_index_q
        );


    // ============================================================
    // AXI AW
    // ============================================================

    assign m_axi_awid =
        '0;


    assign m_axi_awaddr =
        tile_addr_q +
        (
            ADDR_WIDTH'(row_index_q) *
            ADDR_WIDTH'(tile_stride_q)
        );


    assign m_axi_awlen =
        8'(
            row_beats_q -
            BEAT_COUNT_WIDTH'(1)
        );


    assign m_axi_awsize =
        3'(AXI_SIZE);


    assign m_axi_awburst =
        2'b01;


    assign m_axi_awvalid =
        (state == ST_AW);


    // ============================================================
    // AXI W
    // ============================================================

    always_comb begin

        m_axi_wdata =
            AXI_DATA_WIDTH'(
                row_data_q >>
                (
                    beat_index_q *
                    AXI_DATA_WIDTH
                )
            );

    end


    assign m_axi_wstrb =
        {AXI_BYTES{1'b1}};


    assign m_axi_wlast =
        (
            beat_index_q ==
            (
                row_beats_q -
                BEAT_COUNT_WIDTH'(1)
            )
        );


    assign m_axi_wvalid =
        (state == ST_W);


    // ============================================================
    // AXI B
    // ============================================================

    assign m_axi_bready =
        (state == ST_B);


    // ============================================================
    // FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <=
                ST_IDLE;

            tile_addr_q <=
                '0;

            tile_stride_q <=
                '0;

            int8_mode_q <=
                1'b0;

            row_index_q <=
                '0;

            row_beats_q <=
                '0;

            beat_index_q <=
                '0;

            row_data_q <=
                '0;

            error <=
                1'b0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (
                        tile_valid &&
                        tile_accept
                    ) begin

                        tile_addr_q <=
                            tile_addr;

                        tile_stride_q <=
                            tile_stride_bytes;

                        int8_mode_q <=
                            int8_mode;

                        row_index_q <=
                            '0;

                        beat_index_q <=
                            '0;

                        error <=
                            1'b0;


                        if (int8_mode) begin

                            row_beats_q <=
                                BEAT_COUNT_WIDTH'(
                                    INT8_ROW_BEATS
                                );

                        end else begin

                            row_beats_q <=
                                BEAT_COUNT_WIDTH'(
                                    INT32_ROW_BEATS
                                );

                        end


                        state <=
                            ST_READ_REQ;

                    end

                end


                // =================================================
                // Request synchronous C-buffer read
                // =================================================

                ST_READ_REQ: begin

                    state <=
                        ST_READ_WAIT;

                end


                // =================================================
                // Capture returned row
                // =================================================

                ST_READ_WAIT: begin

                    row_data_q <=
                        c_rdata;

                    beat_index_q <=
                        '0;

                    state <=
                        ST_AW;

                end


                // =================================================
                // AXI write address
                // =================================================

                ST_AW: begin

                    if (
                        m_axi_awvalid &&
                        m_axi_awready
                    ) begin

                        state <=
                            ST_W;

                    end

                end


                // =================================================
                // AXI write data
                // =================================================

                ST_W: begin

                    if (
                        m_axi_wvalid &&
                        m_axi_wready
                    ) begin

                        if (m_axi_wlast) begin

                            state <=
                                ST_B;

                        end else begin

                            beat_index_q <=
                                beat_index_q +
                                BEAT_COUNT_WIDTH'(1);

                        end

                    end

                end


                // =================================================
                // AXI response
                // =================================================

                ST_B: begin

                    if (
                        m_axi_bvalid &&
                        m_axi_bready
                    ) begin

                        if (
                            (m_axi_bid != '0) ||
                            (m_axi_bresp != 2'b00)
                        ) begin

                            error <=
                                1'b1;

                        end


                        if (
                            row_index_q ==
                            ROW_INDEX_WIDTH'(ROWS - 1)
                        ) begin

                            state <=
                                ST_DONE;

                        end else begin

                            row_index_q <=
                                row_index_q +
                                ROW_INDEX_WIDTH'(1);

                            beat_index_q <=
                                '0;

                            state <=
                                ST_READ_REQ;

                        end

                    end

                end


                // =================================================
                // DONE
                // =================================================

                ST_DONE: begin

                    state <=
                        ST_IDLE;

                end


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


        if ((ACC_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "ACC_WIDTH must be byte aligned"
            );

        end


        if ((AXI_DATA_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "AXI_DATA_WIDTH must be byte aligned"
            );

        end


        if (
            (INT32_ROW_BITS % AXI_DATA_WIDTH) !=
            0
        ) begin

            $fatal(
                1,
                "INT32 C row must be an integer number of AXI beats"
            );

        end


        if (
            (INT8_ROW_BITS % AXI_DATA_WIDTH) !=
            0
        ) begin

            $fatal(
                1,
                "INT8 C row must be an integer number of AXI beats"
            );

        end

    end


    // Keep latched mode architecturally visible and checked.
    always_comb begin

        if (
            (state != ST_IDLE) &&
            (state != ST_DONE)
        ) begin

            if (
                int8_mode_q &&
                (
                    row_beats_q !=
                    BEAT_COUNT_WIDTH'(INT8_ROW_BEATS)
                )
            ) begin
                // synthesis translate_off
                $error(
                    "INT8 row beat count mismatch"
                );
                // synthesis translate_on
            end

        end

    end

endmodule
