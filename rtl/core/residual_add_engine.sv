module residual_add_engine #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1
) (
    input logic clk,
    input logic reset,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [ADDR_WIDTH-1:0] cmd_a_base,
    input logic [ADDR_WIDTH-1:0] cmd_b_base,
    input logic [ADDR_WIDTH-1:0] cmd_c_base,
    input logic [ADDR_WIDTH-1:0] cmd_param_base,
    input logic [31:0] cmd_elements,
    input logic cmd_relu,
    output logic busy,
    output logic done,
    output logic error,
    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [ID_WIDTH-1:0] m_axi_rid,
    input logic [31:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    input logic [ID_WIDTH-1:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);
    // Serialized AXI baseline: one 32-bit A read, one B read,
    // and one packed INT8 output write. No additional SRAM.
    typedef enum logic [3:0] {
        ST_IDLE, ST_PARAM_AR, ST_PARAM_R,
        ST_A_AR, ST_A_R, ST_B_AR, ST_B_R,
        ST_C_AW, ST_C_W, ST_C_B, ST_DONE
    } state_t;
    state_t state_q;

    logic [ADDR_WIDTH-1:0] a_base_q, b_base_q, c_base_q, param_base_q;
    logic [31:0] words_q, word_idx_q;
    logic [2:0] param_idx_q;
    logic relu_q;
    logic signed [7:0] za_q, zb_q, zc_q;
    logic [31:0] mult_a_q, mult_b_q;
    logic [5:0] shift_q;
    logic [31:0] a_data_q, b_data_q;
    logic [31:0] result_word;

    function automatic logic signed [63:0] round_away(
        input logic signed [63:0] x,
        input logic [5:0] shift_amt
    );
        logic [63:0] magnitude;
        logic [63:0] rounded;
        begin
            if (shift_amt == 6'd0) begin
                round_away = x;
            end else begin
                magnitude = (x < 64'sd0) ? $unsigned(-x) : $unsigned(x);
                rounded = (magnitude + (64'd1 << (shift_amt - 6'd1)))
                          >> shift_amt;
                round_away = (x < 64'sd0) ? -$signed(rounded) : $signed(rounded);
            end
        end
    endfunction

    for (genvar lane = 0; lane < 4; lane++) begin : gen_lanes
        logic signed [8:0] da, db;
        logic signed [63:0] wa, wb, total, quantized;
        logic signed [7:0] lane_result;
        logic signed [63:0] zc_ext;
        always_comb begin
            da = $signed({a_data_q[lane*8+7], a_data_q[lane*8 +: 8]}) -
                 $signed({za_q[7], za_q});
            db = $signed({b_data_q[lane*8+7], b_data_q[lane*8 +: 8]}) -
                 $signed({zb_q[7], zb_q});
            wa = 64'($signed(da)) * 64'($signed({1'b0, mult_a_q}));
            wb = 64'($signed(db)) * 64'($signed({1'b0, mult_b_q}));
            total = wa + wb;
            zc_ext = 64'($signed(zc_q));
            quantized = round_away(total, shift_q) + zc_ext;
            if (relu_q && quantized < zc_ext)
                quantized = zc_ext;
            if (quantized > 64'sd127)
                lane_result = 8'sd127;
            else if (quantized < -64'sd128)
                lane_result = -8'sd128;
            else
                lane_result = quantized[7:0];
        end
        assign result_word[lane*8 +: 8] = lane_result;
    end

    assign cmd_ready = (state_q == ST_IDLE);
    assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE);
    assign done = (state_q == ST_DONE);

    assign m_axi_arid = '0;
    assign m_axi_araddr = (state_q == ST_PARAM_AR) ? param_base_q :
                          ((state_q == ST_A_AR) ? a_base_q : b_base_q)
                          + (ADDR_WIDTH'(word_idx_q) << 2);
    assign m_axi_arlen = (state_q == ST_PARAM_AR) ? 8'd5 : 8'd0;
    assign m_axi_arsize = 3'd2;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (state_q == ST_PARAM_AR) ||
                           (state_q == ST_A_AR) || (state_q == ST_B_AR);
    assign m_axi_rready = (state_q == ST_PARAM_R) ||
                          (state_q == ST_A_R) || (state_q == ST_B_R);
    assign m_axi_awid = '0;
    assign m_axi_awaddr = c_base_q + (ADDR_WIDTH'(word_idx_q) << 2);
    assign m_axi_awlen = 8'd0;
    assign m_axi_awsize = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state_q == ST_C_AW);
    assign m_axi_wdata = result_word;
    assign m_axi_wstrb = 4'hf;
    assign m_axi_wlast = 1'b1;
    assign m_axi_wvalid = (state_q == ST_C_W);
    assign m_axi_bready = (state_q == ST_C_B);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            a_base_q <= '0;
            b_base_q <= '0;
            c_base_q <= '0;
            param_base_q <= '0;
            words_q <= '0;
            word_idx_q <= '0;
            param_idx_q <= '0;
            relu_q <= 1'b0;
            za_q <= '0;
            zb_q <= '0;
            zc_q <= '0;
            mult_a_q <= '0;
            mult_b_q <= '0;
            shift_q <= '0;
            a_data_q <= '0;
            b_data_q <= '0;
            error <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: if (cmd_valid) begin
                    error <= 1'b0;
                    a_base_q <= cmd_a_base;
                    b_base_q <= cmd_b_base;
                    c_base_q <= cmd_c_base;
                    param_base_q <= cmd_param_base;
                    words_q <= cmd_elements >> 2;
                    word_idx_q <= '0;
                    param_idx_q <= '0;
                    relu_q <= cmd_relu;
                    if ((cmd_elements == 32'd0) ||
                        (cmd_elements[1:0] != 2'b00) ||
                        (cmd_a_base[1:0] != 2'b00) ||
                        (cmd_b_base[1:0] != 2'b00) ||
                        (cmd_c_base[1:0] != 2'b00) ||
                        (cmd_param_base[1:0] != 2'b00)) begin
                        error <= 1'b1;
                        state_q <= ST_DONE;
                    end else
                        state_q <= ST_PARAM_AR;
                end
                ST_PARAM_AR: if (m_axi_arvalid && m_axi_arready)
                    state_q <= ST_PARAM_R;
                ST_PARAM_R: if (m_axi_rvalid && m_axi_rready) begin
                    if ((m_axi_rid != '0) || (m_axi_rresp != 2'b00) ||
                        (m_axi_rlast != (param_idx_q == 3'd5)))
                        error <= 1'b1;
                    case (param_idx_q)
                        3'd0: za_q <= m_axi_rdata[7:0];
                        3'd1: zb_q <= m_axi_rdata[7:0];
                        3'd2: zc_q <= m_axi_rdata[7:0];
                        3'd3: begin
                            mult_a_q <= m_axi_rdata;
                            if (m_axi_rdata[31]) error <= 1'b1;
                        end
                        3'd4: begin
                            mult_b_q <= m_axi_rdata;
                            if (m_axi_rdata[31]) error <= 1'b1;
                        end
                        3'd5: begin
                            shift_q <= m_axi_rdata[5:0];
                            if (m_axi_rdata > 32'd62) error <= 1'b1;
                        end
                        default: error <= 1'b1;
                    endcase
                    if (param_idx_q == 3'd5)
                        state_q <= ST_A_AR;
                    else
                        param_idx_q <= param_idx_q + 3'd1;
                end
                ST_A_AR: if (m_axi_arvalid && m_axi_arready)
                    state_q <= ST_A_R;
                ST_A_R: if (m_axi_rvalid && m_axi_rready) begin
                    if ((m_axi_rid != '0) || (m_axi_rresp != 2'b00) || !m_axi_rlast)
                        error <= 1'b1;
                    a_data_q <= m_axi_rdata;
                    state_q <= ST_B_AR;
                end
                ST_B_AR: if (m_axi_arvalid && m_axi_arready)
                    state_q <= ST_B_R;
                ST_B_R: if (m_axi_rvalid && m_axi_rready) begin
                    if ((m_axi_rid != '0) || (m_axi_rresp != 2'b00) || !m_axi_rlast)
                        error <= 1'b1;
                    b_data_q <= m_axi_rdata;
                    state_q <= ST_C_AW;
                end
                ST_C_AW: if (m_axi_awvalid && m_axi_awready)
                    state_q <= ST_C_W;
                ST_C_W: if (m_axi_wvalid && m_axi_wready)
                    state_q <= ST_C_B;
                ST_C_B: if (m_axi_bvalid && m_axi_bready) begin
                    if ((m_axi_bid != '0) || (m_axi_bresp != 2'b00))
                        error <= 1'b1;
                    if (word_idx_q == words_q - 32'd1)
                        state_q <= ST_DONE;
                    else begin
                        word_idx_q <= word_idx_q + 32'd1;
                        state_q <= ST_A_AR;
                    end
                end
                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if (ADDR_WIDTH != 64 || ID_WIDTH < 1)
            $fatal(1, "Unsupported residual_add_engine configuration");
    end
endmodule
