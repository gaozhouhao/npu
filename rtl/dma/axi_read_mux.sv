module axi_read_mux #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 1
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Descriptor read master
    // ============================================================

    input  logic [ID_WIDTH-1:0]   desc_arid,
    input  logic [ADDR_WIDTH-1:0] desc_araddr,
    input  logic [7:0]            desc_arlen,
    input  logic [2:0]            desc_arsize,
    input  logic [1:0]            desc_arburst,
    input  logic                  desc_arvalid,
    output logic                  desc_arready,

    output logic [ID_WIDTH-1:0]   desc_rid,
    output logic [DATA_WIDTH-1:0] desc_rdata,
    output logic [1:0]            desc_rresp,
    output logic                  desc_rlast,
    output logic                  desc_rvalid,
    input  logic                  desc_rready,

    // ============================================================
    // GEMM read master
    // ============================================================

    input  logic [ID_WIDTH-1:0]   gemm_arid,
    input  logic [ADDR_WIDTH-1:0] gemm_araddr,
    input  logic [7:0]            gemm_arlen,
    input  logic [2:0]            gemm_arsize,
    input  logic [1:0]            gemm_arburst,
    input  logic                  gemm_arvalid,
    output logic                  gemm_arready,

    output logic [ID_WIDTH-1:0]   gemm_rid,
    output logic [DATA_WIDTH-1:0] gemm_rdata,
    output logic [1:0]            gemm_rresp,
    output logic                  gemm_rlast,
    output logic                  gemm_rvalid,
    input  logic                  gemm_rready,

    // ============================================================
    // Shared external AXI read interface
    // ============================================================

    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,

    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready
);


    // ============================================================
    // Current owner
    //
    // Once an AR request is accepted, ownership remains locked
    // until the corresponding RLAST beat is accepted.
    // ============================================================

    typedef enum logic [1:0] {
        OWNER_NONE,
        OWNER_DESC,
        OWNER_GEMM
    } owner_t;

    owner_t owner_q;


    // ============================================================
    // Combinational routing
    //
    // Descriptor gets priority only when the mux is idle.
    // Once one master owns the transaction, ownership cannot change
    // until RLAST handshake.
    // ============================================================

    always_comb begin

        // --------------------------------------------------------
        // Default upstream AR responses
        // --------------------------------------------------------

        desc_arready =
            1'b0;

        gemm_arready =
            1'b0;


        // --------------------------------------------------------
        // Default upstream R responses
        // --------------------------------------------------------

        desc_rid =
            '0;

        desc_rdata =
            '0;

        desc_rresp =
            2'b00;

        desc_rlast =
            1'b0;

        desc_rvalid =
            1'b0;


        gemm_rid =
            '0;

        gemm_rdata =
            '0;

        gemm_rresp =
            2'b00;

        gemm_rlast =
            1'b0;

        gemm_rvalid =
            1'b0;


        // --------------------------------------------------------
        // Default external AXI outputs
        // --------------------------------------------------------

        m_axi_arid =
            '0;

        m_axi_araddr =
            '0;

        m_axi_arlen =
            '0;

        m_axi_arsize =
            '0;

        m_axi_arburst =
            '0;

        m_axi_arvalid =
            1'b0;

        m_axi_rready =
            1'b0;


        case (owner_q)

            // ====================================================
            // No outstanding read transaction
            // ====================================================

            OWNER_NONE: begin

                // ------------------------------------------------
                // Descriptor fetch gets priority.
                // ------------------------------------------------

                if (desc_arvalid) begin

                    m_axi_arid =
                        desc_arid;

                    m_axi_araddr =
                        desc_araddr;

                    m_axi_arlen =
                        desc_arlen;

                    m_axi_arsize =
                        desc_arsize;

                    m_axi_arburst =
                        desc_arburst;

                    m_axi_arvalid =
                        desc_arvalid;

                    desc_arready =
                        m_axi_arready;

                end else if (gemm_arvalid) begin

                    m_axi_arid =
                        gemm_arid;

                    m_axi_araddr =
                        gemm_araddr;

                    m_axi_arlen =
                        gemm_arlen;

                    m_axi_arsize =
                        gemm_arsize;

                    m_axi_arburst =
                        gemm_arburst;

                    m_axi_arvalid =
                        gemm_arvalid;

                    gemm_arready =
                        m_axi_arready;

                end

            end


            // ====================================================
            // Descriptor owns R channel
            // ====================================================

            OWNER_DESC: begin

                desc_rid =
                    m_axi_rid;

                desc_rdata =
                    m_axi_rdata;

                desc_rresp =
                    m_axi_rresp;

                desc_rlast =
                    m_axi_rlast;

                desc_rvalid =
                    m_axi_rvalid;

                m_axi_rready =
                    desc_rready;

            end


            // ====================================================
            // GEMM owns R channel
            // ====================================================

            OWNER_GEMM: begin

                gemm_rid =
                    m_axi_rid;

                gemm_rdata =
                    m_axi_rdata;

                gemm_rresp =
                    m_axi_rresp;

                gemm_rlast =
                    m_axi_rlast;

                gemm_rvalid =
                    m_axi_rvalid;

                m_axi_rready =
                    gemm_rready;

            end


            default: begin
            end

        endcase

    end


    // ============================================================
    // Owner tracking
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            owner_q <=
                OWNER_NONE;

        end else begin

            case (owner_q)

                // ------------------------------------------------
                // Lock owner at successful AR handshake.
                // ------------------------------------------------

                OWNER_NONE: begin

                    if (
                        m_axi_arvalid &&
                        m_axi_arready
                    ) begin

                        if (desc_arvalid) begin

                            owner_q <=
                                OWNER_DESC;

                        end else begin

                            owner_q <=
                                OWNER_GEMM;

                        end

                    end

                end


                // ------------------------------------------------
                // Release descriptor ownership only on RLAST.
                // ------------------------------------------------

                OWNER_DESC: begin

                    if (
                        m_axi_rvalid &&
                        m_axi_rready &&
                        m_axi_rlast
                    ) begin

                        owner_q <=
                            OWNER_NONE;

                    end

                end


                // ------------------------------------------------
                // Release GEMM ownership only on RLAST.
                // ------------------------------------------------

                OWNER_GEMM: begin

                    if (
                        m_axi_rvalid &&
                        m_axi_rready &&
                        m_axi_rlast
                    ) begin

                        owner_q <=
                            OWNER_NONE;

                    end

                end


                default: begin

                    owner_q <=
                        OWNER_NONE;

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

        if (ID_WIDTH < 1) begin
            $fatal(
                1,
                "ID_WIDTH must be >= 1"
            );
        end

    end

endmodule
