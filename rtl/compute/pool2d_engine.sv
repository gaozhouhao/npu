
module pool2d_engine #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1
) (
    input  logic clk,
    input  logic reset,
    input  logic                  cmd_valid,
    output logic                  cmd_ready,
    input  logic [ADDR_WIDTH-1:0] cmd_input_base,
    input  logic [ADDR_WIDTH-1:0] cmd_output_base,
    input  logic [31:0]           cmd_input_h,
    input  logic [31:0]           cmd_input_w,
    input  logic [31:0]           cmd_channels,
    output logic busy,
    output logic done,
    output logic error,
    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [31:0]           m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    output logic [ID_WIDTH-1:0]   m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [31:0]           m_axi_wdata,
    output logic [3:0]            m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [ID_WIDTH-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready
);
    // 2x2, stride=2, padding=0, signed INT8, HWC.
    // One word contains four adjacent channels.
    typedef enum logic [3:0] {
        ST_IDLE, ST_RD_REQ, ST_RD_DATA, ST_RD_DONE,
        ST_WR_REQ, ST_WR_DATA, ST_WR_DONE, ST_DONE
    } state_t;
    state_t state_q;

    logic [ADDR_WIDTH-1:0] input_base_q, output_base_q;
    logic [31:0] input_w_q, channels_q, out_h_q, out_w_q;
    logic [31:0] oh_q, ow_q, cw_q;
    logic [1:0] sample_q;
    logic [31:0] max_word_q;

    logic rd_req_ready, rd_data_valid, rd_data_ready;
    logic [31:0] rd_data;
    logic rd_data_last, rd_done, rd_error, rd_busy;
    logic wr_req_ready, wr_data_ready, wr_done, wr_error, wr_busy;
    logic [ADDR_WIDTH-1:0] rd_addr, wr_addr;

    function automatic logic [31:0] max_signed4(
        input logic [31:0] a, input logic [31:0] b
    );
        logic [31:0] result;
        for (int i = 0; i < 4; i++) begin
            if ($signed(a[8*i +: 8]) >= $signed(b[8*i +: 8]))
                result[8*i +: 8] = a[8*i +: 8];
            else
                result[8*i +: 8] = b[8*i +: 8];
        end
        return result;
    endfunction

    // sample_q: 0=TL, 1=TR, 2=BL, 3=BR.
    assign rd_addr = input_base_q +
        (((((64'(oh_q) << 1) + 64'(sample_q[1])) * 64'(input_w_q)) +
          (64'(ow_q) << 1) + 64'(sample_q[0])) * 64'(channels_q)) +
        (64'(cw_q) << 2);
    assign wr_addr = output_base_q +
        (((64'(oh_q) * 64'(out_w_q)) + 64'(ow_q)) * 64'(channels_q)) +
        (64'(cw_q) << 2);

    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(32), .ID_WIDTH(ID_WIDTH)
    ) u_rd (
        .clk(clk), .reset(reset),
        .req_valid(state_q == ST_RD_REQ),
        .req_ready(rd_req_ready), .req_addr(rd_addr), .req_beats(32'd1),
        .data_valid(rd_data_valid), .data_ready(rd_data_ready),
        .data(rd_data), .data_last(rd_data_last),
        .busy(rd_busy), .done(rd_done), .error(rd_error),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );
    assign rd_data_ready = (state_q == ST_RD_DATA);

    axi_write_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(32), .ID_WIDTH(ID_WIDTH)
    ) u_wr (
        .clk(clk), .reset(reset),
        .req_valid(state_q == ST_WR_REQ),
        .req_ready(wr_req_ready), .req_addr(wr_addr), .req_beats(32'd1),
        .data_valid(state_q == ST_WR_DATA), .data_ready(wr_data_ready),
        .data(max_word_q), .busy(wr_busy), .done(wr_done), .error(wr_error),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    assign cmd_ready = (state_q == ST_IDLE);
    assign done = (state_q == ST_DONE);
    assign busy = ((state_q != ST_IDLE) && (state_q != ST_DONE)) ||
                  rd_busy || wr_busy;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            input_base_q <= '0;
            output_base_q <= '0;
            input_w_q <= '0;
            channels_q <= '0;
            out_h_q <= '0;
            out_w_q <= '0;
            oh_q <= '0;
            ow_q <= '0;
            cw_q <= '0;
            sample_q <= '0;
            max_word_q <= '0;
            error <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: if (cmd_valid) begin
                    error <= 1'b0;
                    if (cmd_input_h < 32'd2 || cmd_input_w < 32'd2 ||
                        cmd_channels == 32'd0 || cmd_channels[1:0] != 2'b00 ||
                        cmd_input_base[1:0] != 2'b00 ||
                        cmd_output_base[1:0] != 2'b00) begin
                        error <= 1'b1;
                        state_q <= ST_DONE;
                    end else begin
                        input_base_q <= cmd_input_base;
                        output_base_q <= cmd_output_base;
                        input_w_q <= cmd_input_w;
                        channels_q <= cmd_channels;
                        out_h_q <= cmd_input_h >> 1;
                        out_w_q <= cmd_input_w >> 1;
                        oh_q <= '0;
                        ow_q <= '0;
                        cw_q <= '0;
                        sample_q <= '0;
                        max_word_q <= '0;
                        state_q <= ST_RD_REQ;
                    end
                end
                ST_RD_REQ: if (rd_req_ready) state_q <= ST_RD_DATA;
                ST_RD_DATA: if (rd_data_valid && rd_data_ready) begin
                    if (!rd_data_last) begin
                        error <= 1'b1;
                        state_q <= ST_DONE;
                    end else begin
                        max_word_q <= (sample_q == 2'd0) ? rd_data :
                                      max_signed4(max_word_q, rd_data);
                        state_q <= ST_RD_DONE;
                    end
                end
                ST_RD_DONE: if (rd_done) begin
                    if (rd_error) begin
                        error <= 1'b1;
                        state_q <= ST_DONE;
                    end else if (sample_q == 2'd3) begin
                        state_q <= ST_WR_REQ;
                    end else begin
                        sample_q <= sample_q + 2'd1;
                        state_q <= ST_RD_REQ;
                    end
                end
                ST_WR_REQ: if (wr_req_ready) state_q <= ST_WR_DATA;
                ST_WR_DATA: if (wr_data_ready) state_q <= ST_WR_DONE;
                ST_WR_DONE: if (wr_done) begin
                    if (wr_error) begin
                        error <= 1'b1;
                        state_q <= ST_DONE;
                    end else if ((cw_q + 32'd1) < (channels_q >> 2)) begin
                        cw_q <= cw_q + 32'd1;
                        sample_q <= '0;
                        state_q <= ST_RD_REQ;
                    end else if ((ow_q + 32'd1) < out_w_q) begin
                        cw_q <= '0;
                        ow_q <= ow_q + 32'd1;
                        sample_q <= '0;
                        state_q <= ST_RD_REQ;
                    end else if ((oh_q + 32'd1) < out_h_q) begin
                        cw_q <= '0;
                        ow_q <= '0;
                        oh_q <= oh_q + 32'd1;
                        sample_q <= '0;
                        state_q <= ST_RD_REQ;
                    end else begin
                        state_q <= ST_DONE;
                    end
                end
                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if (ADDR_WIDTH != 64)
            $fatal(1, "pool2d_engine requires ADDR_WIDTH=64");
    end
endmodule
