module axi_write_master #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 1
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Internal write request
    //
    // One request describes req_beats contiguous AXI beats.
    //
    // The module automatically splits the request because of:
    //
    // - AXI4 maximum 256 beats / burst
    // - AXI4 4KB boundary
    //
    // req_addr must be DATA_BYTES aligned.
    // ============================================================

    input  logic                  req_valid,
    output logic                  req_ready,

    input  logic [ADDR_WIDTH-1:0] req_addr,
    input  logic [31:0]           req_beats,

    // ============================================================
    // Internal write-data stream
    //
    // The caller provides exactly req_beats beats.
    //
    // No internal data_last is needed because this module keeps
    // track of the beat count.
    // ============================================================

    input  logic                  data_valid,
    output logic                  data_ready,
    input  logic [DATA_WIDTH-1:0] data,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // AXI4 Write Address Channel
    // ============================================================

    output logic [ID_WIDTH-1:0]   m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,

    // ============================================================
    // AXI4 Write Data Channel
    // ============================================================

    output logic [DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [(DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

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

    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned BYTE_SHIFT =
        $clog2(DATA_BYTES);

    localparam logic [ADDR_WIDTH-1:0] ALIGN_MASK =
        ADDR_WIDTH'(DATA_BYTES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_SEND_AW,
        ST_SEND_W,
        ST_WAIT_B,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Complete request state
    // ============================================================

    logic [ADDR_WIDTH-1:0] current_addr_q;
    logic [31:0]           remaining_beats_q;


    // ============================================================
    // Current AXI burst state
    // ============================================================

    logic [8:0] burst_beats_q;
    logic [8:0] burst_sent_q;


    // ============================================================
    // 4KB boundary calculation
    // ============================================================

    logic [11:0] current_page_offset;

    logic [12:0] bytes_to_4k;

    logic [31:0] beats_to_4k;

    logic [31:0] burst_beats_calc;


    always_comb begin

        current_page_offset =
            current_addr_q[11:0];

        bytes_to_4k =
            13'd4096 -
            {1'b0, current_page_offset};

        beats_to_4k =
            32'(bytes_to_4k) >>
            BYTE_SHIFT;


        // --------------------------------------------------------
        // Start with the remaining request length.
        // --------------------------------------------------------

        burst_beats_calc =
            remaining_beats_q;


        // --------------------------------------------------------
        // AXI4 maximum:
        // 256 beats per burst.
        // --------------------------------------------------------

        if (
            burst_beats_calc >
            32'd256
        ) begin

            burst_beats_calc =
                32'd256;

        end


        // --------------------------------------------------------
        // Burst may not cross a 4KB boundary.
        // --------------------------------------------------------

        if (
            burst_beats_calc >
            beats_to_4k
        ) begin

            burst_beats_calc =
                beats_to_4k;

        end

    end


    // ============================================================
    // Internal request interface
    // ============================================================

    assign req_ready =
        (state == ST_IDLE);


    // ============================================================
    // AXI Write Address Channel
    // ============================================================

    assign m_axi_awid =
        '0;

    assign m_axi_awaddr =
        current_addr_q;

    assign m_axi_awlen =
        8'(
            burst_beats_calc -
            32'd1
        );

    assign m_axi_awsize =
        3'(BYTE_SHIFT);

    assign m_axi_awburst =
        2'b01;

    assign m_axi_awvalid =
        (state == ST_SEND_AW);


    // ============================================================
    // AXI Write Data Channel
    // ============================================================

    assign m_axi_wdata =
        data;

    assign m_axi_wstrb =
        {DATA_BYTES{1'b1}};

    assign m_axi_wvalid =
        (state == ST_SEND_W) &&
        data_valid;

    assign data_ready =
        (state == ST_SEND_W) &&
        m_axi_wready;


    // ------------------------------------------------------------
    // burst_sent_q is zero based.
    //
    // Example:
    //
    // 4-beat burst:
    //
    // beat 0
    // beat 1
    // beat 2
    // beat 3 -> WLAST
    // ------------------------------------------------------------

    assign m_axi_wlast =
        (state == ST_SEND_W) &&
        (
            burst_sent_q ==
            (
                burst_beats_q -
                9'd1
            )
        );


    // ============================================================
    // AXI Write Response Channel
    // ============================================================

    assign m_axi_bready =
        (state == ST_WAIT_B);


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);

    assign done =
        (state == ST_DONE);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <=
                ST_IDLE;

            current_addr_q <=
                '0;

            remaining_beats_q <=
                '0;

            burst_beats_q <=
                '0;

            burst_sent_q <=
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
                        req_valid &&
                        req_ready
                    ) begin

                        error <=
                            1'b0;

                        current_addr_q <=
                            req_addr;

                        remaining_beats_q <=
                            req_beats;


                        // -----------------------------------------
                        // Empty request
                        // -----------------------------------------

                        if (
                            req_beats ==
                            32'd0
                        ) begin

                            state <=
                                ST_DONE;


                        // -----------------------------------------
                        // Address must be aligned to one AXI beat.
                        // -----------------------------------------

                        end else if (
                            (req_addr & ALIGN_MASK) !=
                            {ADDR_WIDTH{1'b0}}
                        ) begin

                            error <=
                                1'b1;

                            state <=
                                ST_DONE;

                        end else begin

                            state <=
                                ST_SEND_AW;

                        end

                    end

                end


                // =================================================
                // SEND AW
                // =================================================

                ST_SEND_AW: begin

                    if (
                        m_axi_awvalid &&
                        m_axi_awready
                    ) begin

                        // -----------------------------------------
                        // Lock current burst size.
                        // -----------------------------------------

                        burst_beats_q <=
                            9'(
                                burst_beats_calc
                            );

                        burst_sent_q <=
                            9'd0;

                        state <=
                            ST_SEND_W;

                    end

                end


                // =================================================
                // SEND W
                // =================================================

                ST_SEND_W: begin

                    if (
                        m_axi_wvalid &&
                        m_axi_wready
                    ) begin

                        if (
                            burst_sent_q ==
                            (
                                burst_beats_q -
                                9'd1
                            )
                        ) begin

                            // -------------------------------------
                            // Last beat of this AXI burst.
                            // -------------------------------------

                            state <=
                                ST_WAIT_B;

                        end else begin

                            burst_sent_q <=
                                burst_sent_q +
                                9'd1;

                        end

                    end

                end


                // =================================================
                // WAIT B
                // =================================================

                ST_WAIT_B: begin

                    if (
                        m_axi_bvalid &&
                        m_axi_bready
                    ) begin

                        // -----------------------------------------
                        // Check AXI response.
                        // -----------------------------------------

                        if (
                            (m_axi_bresp != 2'b00) ||
                            (m_axi_bid != '0)
                        ) begin

                            error <=
                                1'b1;

                            state <=
                                ST_DONE;

                        end else if (
                            remaining_beats_q ==
                            32'(burst_beats_q)
                        ) begin

                            // -------------------------------------
                            // Entire high-level request complete.
                            // -------------------------------------

                            remaining_beats_q <=
                                '0;

                            state <=
                                ST_DONE;

                        end else begin

                            // -------------------------------------
                            // More data remains.
                            //
                            // Advance to next legal AXI burst.
                            // -------------------------------------

                            remaining_beats_q <=
                                remaining_beats_q -
                                32'(burst_beats_q);

                            current_addr_q <=
                                current_addr_q +
                                (
                                    ADDR_WIDTH'(
                                        burst_beats_q
                                    ) <<
                                    BYTE_SHIFT
                                );

                            state <=
                                ST_SEND_AW;

                        end

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion pulse.
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


        if (DATA_WIDTH < 8) begin

            $fatal(
                1,
                "DATA_WIDTH must be >= 8"
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
            (
                DATA_BYTES &
                (DATA_BYTES - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "DATA_BYTES must be a power of two"
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
