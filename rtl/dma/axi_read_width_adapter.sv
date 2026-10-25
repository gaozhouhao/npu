// Converts aligned 32-bit INCR requests into 64-bit AXI read beats.
module axi_read_width_adapter #(
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
    logic [8:0] output_words_remaining_q;
    logic start_at_upper_word_q;
    logic read_beat_valid_q;
    logic select_upper_word_q;
    logic [63:0] read_beat_q;
    logic [ID_WIDTH-1:0] rid_q;
    logic [1:0] resp_q;
    logic [9:0] input_beats_calc;
    logic output_word_transfer;
    logic input_beat_transfer;

    assign input_beats_calc = ({2'b00, s_arlen} + 10'd1 + {9'd0, s_araddr[2]} + 10'd1) >> 1;

    assign s_arready = (state_q == ST_IDLE);
    assign m_arid = id_q;
    assign m_araddr = addr_q;
    assign m_arlen = len_q;
    assign m_arsize = 3'd3;
    assign m_arburst = 2'b01;
    assign m_arvalid = state_q == ST_AR;

    assign s_rid = rid_q;
    assign s_rdata = select_upper_word_q ? read_beat_q[63:32] : read_beat_q[31:0];
    assign s_rresp = resp_q;
    assign s_rlast = read_beat_valid_q && (output_words_remaining_q == 9'd1);
    assign s_rvalid = (state_q == ST_STREAM) && read_beat_valid_q;
    assign output_word_transfer = s_rvalid && s_rready;

    // The next 64-bit beat can enter on the same clock that
    // the old beat's upper 32 bits are consumed.
    assign m_rready = (state_q == ST_STREAM) &&
        (!read_beat_valid_q ||
         (output_word_transfer && select_upper_word_q && output_words_remaining_q > 9'd1));
    assign input_beat_transfer = m_rvalid && m_rready;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            id_q <= '0;
            addr_q <= '0;
            len_q <= '0;
            output_words_remaining_q <= '0;
            start_at_upper_word_q <= 1'b0;
            read_beat_valid_q <= 1'b0;
            select_upper_word_q <= 1'b0;
            read_beat_q <= '0;
            rid_q <= '0;
            resp_q <= '0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        id_q <= s_arid;
                        addr_q <= {s_araddr[ADDR_WIDTH-1:3],3'b000};
                        len_q <= 8'(input_beats_calc - 10'd1);
                        output_words_remaining_q <= {1'b0,s_arlen} + 9'd1;
                        start_at_upper_word_q <= s_araddr[2];
                        read_beat_valid_q <= 1'b0;
                        select_upper_word_q <= 1'b0;
                        state_q <= ST_AR;
                    end
                end
                ST_AR: begin
                    if (m_arvalid && m_arready)
                        state_q <= ST_STREAM;
                end
                ST_STREAM: begin
                    if (input_beat_transfer) begin
                        read_beat_q <= m_rdata;
                        rid_q <= m_rid;
                        resp_q <= m_rresp;
                        read_beat_valid_q <= 1'b1;
                        select_upper_word_q <= start_at_upper_word_q;
                        start_at_upper_word_q <= 1'b0;
                    end
                    if (output_word_transfer) begin
                        output_words_remaining_q <= output_words_remaining_q - 9'd1;
                        if (output_words_remaining_q == 9'd1) begin
                            read_beat_valid_q <= 1'b0;
                            state_q <= ST_IDLE;
                        end else if (select_upper_word_q) begin
                            if (!input_beat_transfer)
                                read_beat_valid_q <= 1'b0;
                        end else begin
                            select_upper_word_q <= 1'b1;
                        end
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
