module read_request_arbiter #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 32
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Master 0: A operand_read_dma
    // ============================================================

    input  logic                  m0_req_valid,
    output logic                  m0_req_ready,
    input  logic [ADDR_WIDTH-1:0] m0_req_addr,
    input  logic [31:0]           m0_req_beats,

    output logic                  m0_data_valid,
    input  logic                  m0_data_ready,
    output logic [DATA_WIDTH-1:0] m0_data,
    output logic                  m0_data_last,

    output logic                  m0_done,
    output logic                  m0_error,

    // ============================================================
    // Master 1: B operand_read_dma
    // ============================================================

    input  logic                  m1_req_valid,
    output logic                  m1_req_ready,
    input  logic [ADDR_WIDTH-1:0] m1_req_addr,
    input  logic [31:0]           m1_req_beats,

    output logic                  m1_data_valid,
    input  logic                  m1_data_ready,
    output logic [DATA_WIDTH-1:0] m1_data,
    output logic                  m1_data_last,

    output logic                  m1_done,
    output logic                  m1_error,

    // ============================================================
    // Shared axi_read_master request side
    // ============================================================

    output logic                  s_req_valid,
    input  logic                  s_req_ready,
    output logic [ADDR_WIDTH-1:0] s_req_addr,
    output logic [31:0]           s_req_beats,

    // ============================================================
    // Shared axi_read_master response side
    // ============================================================

    input  logic                  s_data_valid,
    output logic                  s_data_ready,
    input  logic [DATA_WIDTH-1:0] s_data,
    input  logic                  s_data_last,

    input logic s_done,
    input logic s_error
);

    // ============================================================
    // Owner
    //
    // 0 -> master 0 / A
    // 1 -> master 1 / B
    // ============================================================

    logic owner_valid_q;
    logic owner_q;

    // ============================================================
    // Round-robin preference
    //
    // 0 -> prefer master 0 when both request
    // 1 -> prefer master 1 when both request
    // ============================================================

    logic rr_q;

    logic selected_valid;
    logic selected_owner;


    // ============================================================
    // Arbitration
    //
    // Only arbitrate when there is no active transaction.
    // ============================================================

    always_comb begin

        selected_valid = 1'b0;
        selected_owner = 1'b0;

        if (!owner_valid_q) begin

            if (m0_req_valid && m1_req_valid) begin

                selected_valid = 1'b1;
                selected_owner = rr_q;

            end else if (m0_req_valid) begin

                selected_valid = 1'b1;
                selected_owner = 1'b0;

            end else if (m1_req_valid) begin

                selected_valid = 1'b1;
                selected_owner = 1'b1;

            end

        end

    end


    // ============================================================
    // Shared request mux
    // ============================================================

    always_comb begin

        s_req_valid = 1'b0;
        s_req_addr  = '0;
        s_req_beats = '0;

        m0_req_ready = 1'b0;
        m1_req_ready = 1'b0;

        if (!owner_valid_q && selected_valid) begin

            s_req_valid = 1'b1;

            if (selected_owner == 1'b0) begin

                s_req_addr  = m0_req_addr;
                s_req_beats = m0_req_beats;

                m0_req_ready = s_req_ready;

            end else begin

                s_req_addr  = m1_req_addr;
                s_req_beats = m1_req_beats;

                m1_req_ready = s_req_ready;

            end

        end

    end


    // ============================================================
    // Response routing
    //
    // Data is only valid for the current owner.
    // ============================================================

    always_comb begin

        m0_data_valid = 1'b0;
        m1_data_valid = 1'b0;

        m0_data = s_data;
        m1_data = s_data;

        m0_data_last = 1'b0;
        m1_data_last = 1'b0;

        m0_done = 1'b0;
        m1_done = 1'b0;

        m0_error = 1'b0;
        m1_error = 1'b0;

        s_data_ready = 1'b0;

        if (owner_valid_q) begin

            if (owner_q == 1'b0) begin

                m0_data_valid = s_data_valid;
                m0_data_last  = s_data_last;

                m0_done  = s_done;
                m0_error = s_error;

                s_data_ready = m0_data_ready;

            end else begin

                m1_data_valid = s_data_valid;
                m1_data_last  = s_data_last;

                m1_done  = s_done;
                m1_error = s_error;

                s_data_ready = m1_data_ready;

            end

        end

    end


    // ============================================================
    // Owner tracking
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            owner_valid_q <= 1'b0;
            owner_q       <= 1'b0;

            rr_q <= 1'b0;

        end else begin

            // ----------------------------------------------------
            // A new request is accepted by axi_read_master.
            // Lock ownership until s_done.
            // ----------------------------------------------------

            if (
                !owner_valid_q &&
                selected_valid &&
                s_req_valid &&
                s_req_ready
            ) begin

                owner_valid_q <= 1'b1;
                owner_q       <= selected_owner;

                // Next simultaneous conflict prefers the other side.

                rr_q <= ~selected_owner;

            end


            // ----------------------------------------------------
            // Entire low-level read request completed.
            // ----------------------------------------------------

            if (
                owner_valid_q &&
                s_done
            ) begin

                owner_valid_q <= 1'b0;

            end

        end

    end

endmodule
