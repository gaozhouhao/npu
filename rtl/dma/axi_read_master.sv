module axi_read_master #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 1
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Read request
    //
    // req_addr must be aligned to DATA_WIDTH.
    // req_beats is the total number of full AXI data beats.
    //
    // One request may be automatically split into multiple
    // AXI bursts because of:
    //
    //   1. AXI maximum burst length: 256 beats
    //   2. AXI 4KB boundary rule
    // ============================================================

    input  logic                  req_valid,
    output logic                  req_ready,
    input  logic [ADDR_WIDTH-1:0] req_addr,
    input  logic [31:0]           req_beats,

    // ============================================================
    // Read data stream
    //
    // data_last marks the final beat of the complete DMA request,
    // not merely the final beat of one AXI burst.
    // ============================================================

    output logic                  data_valid,
    input  logic                  data_ready,
    output logic [DATA_WIDTH-1:0] data,
    output logic                  data_last,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // AXI4 read address channel
    // ============================================================

    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,

    // ============================================================
    // AXI4 read data channel
    // ============================================================

    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready
);

    // ============================================================
    // Constants
    // ============================================================

    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned AXI_SIZE_INT =
        $clog2(DATA_BYTES);

    localparam logic [2:0] AXI_SIZE =
        AXI_SIZE_INT[2:0];

    localparam logic [ADDR_WIDTH-1:0] ALIGN_MASK =
        ADDR_WIDTH'(DATA_BYTES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_AR,
        ST_R,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Request tracking
    // ============================================================

    logic [ADDR_WIDTH-1:0] current_addr_q;

    logic [31:0] remaining_beats_q;


    // ============================================================
    // Current AXI burst tracking
    //
    // 9 bits are required because AXI supports 1..256 beats.
    // ============================================================

    logic [8:0] burst_beats_q;
    logic [8:0] burst_remaining_q;


    // ============================================================
    // Burst calculation
    // ============================================================

    logic [31:0] beats_to_4k;
    logic [31:0] burst_beats_calc;

    logic [ADDR_WIDTH-1:0] burst_addr_increment;


    always_comb begin

        // Bytes remaining before reaching the next 4KB boundary.
        //
        // current_addr_q[11:0] gives the byte offset inside the
        // current 4KB page.
        //
        // Because requests are full-beat aligned, this value is
        // always an integer number of beats.

        beats_to_4k =
            (
                32'd4096 -
                {20'd0, current_addr_q[11:0]}
            ) >> AXI_SIZE_INT;


        // Start with all remaining beats.

        burst_beats_calc = remaining_beats_q;


        // AXI4 allows at most 256 beats in one INCR burst.

        if (burst_beats_calc > 32'd256) begin
            burst_beats_calc = 32'd256;
        end


        // An AXI burst must not cross a 4KB boundary.

        if (burst_beats_calc > beats_to_4k) begin
            burst_beats_calc = beats_to_4k;
        end

    end


    // ============================================================
    // Current burst address increment
    // ============================================================

    always_comb begin

        burst_addr_increment =
            (
                {{(ADDR_WIDTH - 9){1'b0}}, burst_beats_q}
                << AXI_SIZE_INT
            );

    end


    // ============================================================
    // Request interface
    // ============================================================

    assign req_ready =
        (state == ST_IDLE);


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);

    assign done =
        (state == ST_DONE);


    // ============================================================
    // AXI read address channel
    // ============================================================

    assign m_axi_arid =
        '0;

    assign m_axi_araddr =
        current_addr_q;

    assign m_axi_arsize =
        AXI_SIZE;

    assign m_axi_arburst =
        2'b01; // INCR

    assign m_axi_arvalid =
        (state == ST_AR);


    // ARLEN = number of beats - 1.
    //
    // 256 beats are encoded as ARLEN = 8'hff.

    always_comb begin

        if (burst_beats_calc == 32'd256) begin

            m_axi_arlen = 8'hff;

        end else begin

            m_axi_arlen =
                burst_beats_calc[7:0] - 8'd1;

        end

    end


    // ============================================================
    // AXI read data -> local data stream
    // ============================================================

    assign data_valid =
        (state == ST_R) &&
        m_axi_rvalid;

    assign data =
        m_axi_rdata;


    // Final beat of the complete request.

    assign data_last =
        (state == ST_R) &&
        m_axi_rvalid &&
        (remaining_beats_q == 32'd1);


    // Backpressure propagates directly to AXI.

    assign m_axi_rready =
        (state == ST_R) &&
        data_ready;


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= ST_IDLE;

            current_addr_q     <= '0;
            remaining_beats_q  <= '0;

            burst_beats_q      <= '0;
            burst_remaining_q  <= '0;

            error <= 1'b0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (req_valid) begin

                        // Start a fresh request.

                        error <= 1'b0;


                        // Zero-length request is treated as a
                        // legal no-op.

                        if (req_beats == 32'd0) begin

                            current_addr_q    <= req_addr;
                            remaining_beats_q <= '0;

                            state <= ST_DONE;

                        end else if (
                            (req_addr & ALIGN_MASK) !=
                            {ADDR_WIDTH{1'b0}}
                        ) begin

                            // Low-level AXI engine only accepts
                            // full-width aligned requests.
                            //
                            // The upper byte-range engine will
                            // handle arbitrary byte alignment.

                            current_addr_q    <= req_addr;
                            remaining_beats_q <= req_beats;

                            error <= 1'b1;

                            state <= ST_DONE;

                        end else begin

                            current_addr_q    <= req_addr;
                            remaining_beats_q <= req_beats;

                            state <= ST_AR;

                        end

                    end

                end


                // =================================================
                // AXI ADDRESS
                //
                // Hold ARVALID and all AR fields stable until
                // ARREADY is asserted.
                // =================================================

                ST_AR: begin

                    if (m_axi_arready) begin

                        burst_beats_q <=
                            burst_beats_calc[8:0];

                        burst_remaining_q <=
                            burst_beats_calc[8:0];

                        state <= ST_R;

                    end

                end


                // =================================================
                // AXI READ DATA
                // =================================================

                ST_R: begin

                    if (
                        m_axi_rvalid &&
                        m_axi_rready
                    ) begin

                        // -----------------------------------------
                        // Check AXI response.
                        // -----------------------------------------

                        if (m_axi_rresp != 2'b00) begin
                            error <= 1'b1;
                        end


                        // -----------------------------------------
                        // This implementation uses one fixed AXI ID.
                        // -----------------------------------------

                        if (m_axi_rid != {ID_WIDTH{1'b0}}) begin
                            error <= 1'b1;
                        end


                        // -----------------------------------------
                        // Check RLAST.
                        // -----------------------------------------

                        if (
                            burst_remaining_q == 9'd1
                        ) begin

                            if (!m_axi_rlast) begin
                                error <= 1'b1;
                            end

                        end else begin

                            if (m_axi_rlast) begin
                                error <= 1'b1;
                            end

                        end


                        // -----------------------------------------
                        // Consume one beat from the complete
                        // request.
                        // -----------------------------------------

                        remaining_beats_q <=
                            remaining_beats_q - 32'd1;


                        // -----------------------------------------
                        // Last beat of current AXI burst.
                        // -----------------------------------------

                        if (
                            burst_remaining_q == 9'd1
                        ) begin

                            burst_remaining_q <= '0;


                            // Last beat of the entire DMA request.

                            if (
                                remaining_beats_q == 32'd1
                            ) begin

                                state <= ST_DONE;

                            end else begin

                                // Move to the start address of
                                // the next burst.

                                current_addr_q <=
                                    current_addr_q +
                                    burst_addr_increment;

                                state <= ST_AR;

                            end

                        end else begin

                            burst_remaining_q <=
                                burst_remaining_q - 9'd1;

                        end

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion pulse.
                // =================================================

                ST_DONE: begin

                    state <= ST_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

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

        if ((DATA_WIDTH % 8) != 0) begin
            $fatal(
                1,
                "DATA_WIDTH must be byte aligned"
            );
        end

        if (
            (DATA_BYTES &
            (DATA_BYTES - 1)) != 0
        ) begin
            $fatal(
                1,
                "DATA_BYTES must be a power of two"
            );
        end

        if (DATA_BYTES > 4096) begin
            $fatal(
                1,
                "DATA_BYTES must be <= 4096"
            );
        end

        if (AXI_SIZE_INT > 7) begin
            $fatal(
                1,
                "AXI transfer size exceeds ARSIZE encoding"
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
