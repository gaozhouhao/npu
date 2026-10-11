module axi_read_32to64 #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1
) (
    input logic clk,
    input logic reset,
    input logic [ID_WIDTH-1:0] s_arid,
    input logic [ADDR_WIDTH-1:0] s_araddr,
    input logic [7:0] s_arlen,
    input logic [2:0] s_arsize,
    input logic [1:0] s_arburst,
    input logic s_arvalid,
    output logic s_arready,
    output logic [ID_WIDTH-1:0] s_rid,
    output logic [31:0] s_rdata,
    output logic [1:0] s_rresp,
    output logic s_rlast,
    output logic s_rvalid,
    input logic s_rready,
    output logic [ID_WIDTH-1:0] m_arid,
    output logic [ADDR_WIDTH-1:0] m_araddr,
    output logic [7:0] m_arlen,
    output logic [2:0] m_arsize,
    output logic [1:0] m_arburst,
    output logic m_arvalid,
    input logic m_arready,
    input logic [ID_WIDTH-1:0] m_rid,
    input logic [63:0] m_rdata,
    input logic [1:0] m_rresp,
    input logic m_rlast,
    input logic m_rvalid,
    output logic m_rready
);
    typedef enum logic [1:0] {
        ST_IDLE, ST_AR, ST_STREAM
    } state_t;
    state_t state_q;
    logic [ID_WIDTH-1:0] id_q;
    logic [ADDR_WIDTH-1:0] addr_q;
    logic [7:0] len_q;
    logic [8:0] words_left_q;
    logic [8:0] beats_left_q;
    logic skip_low_q;
    logic word_valid_q;
    logic upper_q;
    logic [63:0] word_q;
    logic [ID_WIDTH-1:0] rid_q;
    logic [1:0] resp_q;
    logic [9:0] beats_calc;
    logic s_fire;
    logic m_fire;

    assign beats_calc =
        ({2'b00, s_arlen} + 10'd1 +
         {9'd0, s_araddr[2]} + 10'd1) >> 1;

    assign s_arready = (state_q == ST_IDLE);
    assign m_arid = id_q;
    assign m_araddr = addr_q;
    assign m_arlen = len_q;
    assign m_arsize = 3'd3;
    assign m_arburst = 2'b01;
    assign m_arvalid = state_q == ST_AR;

    assign s_rid = rid_q;
    assign s_rdata = upper_q ? word_q[63:32] : word_q[31:0];
    assign s_rresp = resp_q;
    assign s_rlast = word_valid_q && (words_left_q == 9'd1);
    assign s_rvalid = (state_q == ST_STREAM) && word_valid_q;
    assign s_fire = s_rvalid && s_rready;

    // The next 64-bit beat can enter on the same clock that
    // the old beat's upper 32 bits are consumed.
    assign m_rready = (state_q == ST_STREAM) &&
        (!word_valid_q ||
         (s_fire && upper_q && words_left_q > 9'd1));
    assign m_fire = m_rvalid && m_rready;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            id_q <= '0;
            addr_q <= '0;
            len_q <= '0;
            words_left_q <= '0;
            beats_left_q <= '0;
            skip_low_q <= 1'b0;
            word_valid_q <= 1'b0;
            upper_q <= 1'b0;
            word_q <= '0;
            rid_q <= '0;
            resp_q <= '0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        if (s_arsize != 3'd2 ||
                            s_arburst != 2'b01 ||
                            s_araddr[1:0] != 2'b00) begin
                            $fatal(1, "AXI32 request must be aligned INCR");
                        end
                        if (({1'b0, s_araddr[11:0]} +
                             (13'({1'b0,s_arlen} + 9'd1) << 2)) > 13'd4096)
                            $fatal(1, "AXI32 request crosses 4KB boundary");
                        // A legal AXI32 request may become an illegal
                        // AXI64 4KB crossing when its start is rounded down;
                        // reject that explicitly instead of silently corrupting.
                        if (({1'b0, s_araddr[11:3],3'b000} +
                             (13'(beats_calc) << 3)) > 13'd4096)
                            $fatal(1, "AXI64 request crosses 4KB boundary");
                        id_q <= s_arid;
                        addr_q <= {s_araddr[ADDR_WIDTH-1:3],3'b000};
                        len_q <= 8'(beats_calc - 10'd1);
                        words_left_q <= {1'b0,s_arlen} + 9'd1;
                        beats_left_q <= 9'(beats_calc);
                        skip_low_q <= s_araddr[2];
                        word_valid_q <= 1'b0;
                        upper_q <= 1'b0;
                        state_q <= ST_AR;
                    end
                end
                ST_AR: begin
                    if (m_arvalid && m_arready)
                        state_q <= ST_STREAM;
                end
                ST_STREAM: begin
                    if (m_fire) begin
                        if (beats_left_q == 9'd0 ||
                            m_rlast != (beats_left_q == 9'd1))
                            $fatal(1, "AXI64 RLAST mismatch");
                        beats_left_q <= beats_left_q - 9'd1;
                        word_q <= m_rdata;
                        rid_q <= m_rid;
                        resp_q <= m_rresp;
                        word_valid_q <= 1'b1;
                        upper_q <= skip_low_q;
                        skip_low_q <= 1'b0;
                    end
                    if (s_fire) begin
                        words_left_q <= words_left_q - 9'd1;
                        if (words_left_q == 9'd1) begin
                            if (beats_left_q != 9'd0)
                                $fatal(1, "AXI64 unused read beats");
                            word_valid_q <= 1'b0;
                            state_q <= ST_IDLE;
                        end else if (upper_q) begin
                            if (!m_fire)
                                word_valid_q <= 1'b0;
                        end else begin
                            upper_q <= 1'b1;
                        end
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if (ADDR_WIDTH < 12 || ID_WIDTH < 1)
            $fatal(1, "Invalid AXI bridge configuration");
    end
endmodule
