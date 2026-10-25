module quant_param_loader #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned COLS       = 4,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned BIAS_WIDTH = 32
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Global per-tensor requant parameters
    //
    // param_base + 0x00 : multiplier
    // param_base + 0x04 : shift
    // ============================================================

    input  logic                  global_load_req,
    output logic                  global_load_accept,

    input  logic [ADDR_WIDTH-1:0] global_param_addr,
    // Fused FC extends the ordinary 16-byte header with explicit H/W/C/B.
    input  logic fc_pool_en,

    output logic                  global_load_done,

    // ============================================================
    // Bias vector load
    // ============================================================

    input  logic                  bias_load_req,
    output logic                  bias_load_accept,

    input  logic [ADDR_WIDTH-1:0] bias_addr,
    input  logic per_channel_en,
    input  logic [31:0] bias_valid_cols,

    output logic                  bias_load_done,

    // ============================================================
    // Loaded values
    // ============================================================

    output logic [31:0]
        multiplier_out,

    output logic [5:0]
        shift_out,

    output logic signed [7:0] input_zero_point_out,
    output logic signed [7:0] output_zero_point_out,
    output logic [31:0] fc_pool_h_out,
    output logic [31:0] fc_pool_w_out,
    output logic [31:0] fc_pool_c_out,
    output logic [31:0] fc_pool_batch_out,

    output logic signed [BIAS_WIDTH-1:0]
        bias_out [COLS],

    output logic [31:0] multiplier_lane_out [COLS],
    output logic [5:0] shift_lane_out [COLS],

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic error,

    // ============================================================
    // Generic read request
    // ============================================================

    output logic                  read_req_valid,
    input  logic                  read_req_ready,

    output logic [ADDR_WIDTH-1:0] read_req_addr,
    output logic [31:0]           read_req_beats,

    // ============================================================
    // Generic read data
    // ============================================================

    input  logic                  read_data_valid,
    output logic                  read_data_ready,

    input  logic [DATA_WIDTH-1:0] read_data,
    input  logic                  read_data_last
);

    localparam int unsigned BIAS_INDEX_WIDTH = (COLS <= 1) ? 1 : $clog2(COLS);

    localparam int unsigned MAX_ITEMS = (3 * COLS > 8) ? (3 * COLS) : 8;

    localparam int unsigned INDEX_WIDTH = (MAX_ITEMS <= 1) ? 1 : $clog2(MAX_ITEMS);

    typedef enum logic [1:0] {
        MODE_GLOBAL,
        MODE_BIAS,
        MODE_CHANNEL
    } load_mode_t;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_REQ,
        ST_DATA,
        ST_DONE
    } state_t;

    state_t state_q;

    load_mode_t mode_q;

    logic [ADDR_WIDTH-1:0] req_addr_q;

    logic [31:0] req_beats_q;

    logic [INDEX_WIDTH-1:0] index_q;
    logic [INDEX_WIDTH-1:0] global_last_index_q;
    logic [INDEX_WIDTH-1:0] bias_last_index_q;

    // ============================================================
    // Command arbitration
    //
    // Global parameter load has priority because it occurs once
    // at the beginning of a GEMM command.
    // ============================================================

    assign global_load_accept = (state_q == ST_IDLE) && global_load_req;

    assign bias_load_accept = (state_q == ST_IDLE) && !global_load_req && bias_load_req;

    assign busy = (state_q != ST_IDLE) && (state_q != ST_DONE);

    assign global_load_done = (state_q == ST_DONE) && (mode_q == MODE_GLOBAL);

    assign bias_load_done =
        (state_q == ST_DONE) &&
        ((mode_q == MODE_BIAS) ||
         (mode_q == MODE_CHANNEL));

    // ============================================================
    // Generic read interface
    // ============================================================

    assign read_req_valid = (state_q == ST_REQ);

    assign read_req_addr = req_addr_q;

    assign read_req_beats = req_beats_q;

    assign read_data_ready = (state_q == ST_DATA);

    // ============================================================
    // FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state_q <= ST_IDLE;

            mode_q <= MODE_GLOBAL;

            req_addr_q <= '0;

            req_beats_q <= '0;

            index_q <= '0;
            global_last_index_q <= '0;

            multiplier_out <= '0;

            shift_out <= '0;
            input_zero_point_out <= '0;
            output_zero_point_out <= '0;
            fc_pool_h_out <= '0;
            fc_pool_w_out <= '0;
            fc_pool_c_out <= '0;
            fc_pool_batch_out <= '0;
            bias_last_index_q <= '0;

            error <= 1'b0;

            for (
                integer i = 0;
                i < COLS;
                i = i + 1
            ) begin

                bias_out[i] <= '0;
                multiplier_lane_out[i] <= '0;
                shift_lane_out[i] <= '0;

            end

        end else begin

            case (state_q)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (global_load_req) begin
                        // Clear legacy tensor ZPs before each layer.
                        input_zero_point_out <= '0;
                        output_zero_point_out <= '0;
                        fc_pool_h_out <= '0;
                        fc_pool_w_out <= '0;
                        fc_pool_c_out <= '0;
                        fc_pool_batch_out <= '0;

                        mode_q <= MODE_GLOBAL;

                        req_addr_q <= global_param_addr;

                        req_beats_q <= fc_pool_en ? 32'd8 :
                            (per_channel_en ? 32'd4 : 32'd2);
                        global_last_index_q <= fc_pool_en ? INDEX_WIDTH'(7) :
                            (per_channel_en ? INDEX_WIDTH'(3) : INDEX_WIDTH'(1));

                        index_q <= '0;

                        error <= 1'b0;

                        state_q <= ST_REQ;

                    end else if (bias_load_req) begin

                        for (int lane = 0; lane < COLS; lane++) begin
                            bias_out[lane] <= '0;
                            multiplier_lane_out[lane] <= '0;
                            shift_lane_out[lane] <= '0;
                        end

                        mode_q <= per_channel_en ? MODE_CHANNEL : MODE_BIAS;

                        req_addr_q <= bias_addr;

                        req_beats_q <= per_channel_en ? 3 * bias_valid_cols : bias_valid_cols;
                        bias_last_index_q <= INDEX_WIDTH'(
                            (per_channel_en ? 3 * bias_valid_cols : bias_valid_cols) - 1);

                        index_q <= '0;

                        error <= bias_valid_cols == 0 || bias_valid_cols > 32'(COLS);

                        state_q <= (bias_valid_cols == 0 || bias_valid_cols > 32'(COLS))
                            ? ST_DONE : ST_REQ;

                    end

                end

                // =================================================
                // REQ
                // =================================================

                ST_REQ: begin

                    if (
                        read_req_valid &&
                        read_req_ready
                    ) begin

                        state_q <= ST_DATA;

                    end

                end

                // =================================================
                // DATA
                // =================================================

                ST_DATA: begin

                    if (
                        read_data_valid &&
                        read_data_ready
                    ) begin

                        if (
                            mode_q ==
                            MODE_GLOBAL
                        ) begin

                            if (
                                index_q ==
                                INDEX_WIDTH'(0)
                            ) begin

                                multiplier_out <= read_data;

                                if (read_data[31]) begin

                                    error <= 1'b1;

                                end

                            end else if (index_q == INDEX_WIDTH'(1)) begin

                                shift_out <= read_data[5:0];
                                if (read_data > 32'd62)
                                    error <= 1'b1;

                            end else if (index_q == INDEX_WIDTH'(2)) begin

                                input_zero_point_out <= $signed(read_data[7:0]);
                                if (read_data[31:8] != {24{read_data[7]}})
                                    error <= 1'b1;

                            end else if (index_q == INDEX_WIDTH'(3)) begin

                                output_zero_point_out <= $signed(read_data[7:0]);
                                if (read_data[31:8] != {24{read_data[7]}})
                                    error <= 1'b1;

                            end else begin
                                case (index_q)
                                    INDEX_WIDTH'(4): fc_pool_h_out <= read_data;
                                    INDEX_WIDTH'(5): fc_pool_w_out <= read_data;
                                    INDEX_WIDTH'(6): fc_pool_c_out <= read_data;
                                    INDEX_WIDTH'(7): fc_pool_batch_out <= read_data;
                                    default: error <= 1'b1;
                                endcase
                            end

                            if (
                                index_q == global_last_index_q
                            ) begin

                                if (!read_data_last) begin

                                    error <= 1'b1;

                                end

                                state_q <= ST_DONE;

                            end else begin

                                if (read_data_last) begin

                                    error <= 1'b1;

                                    state_q <= ST_DONE;

                                end else begin

                                    index_q <= index_q + 1'b1;

                                end

                            end

                        end else if (mode_q == MODE_CHANNEL) begin

                            // Each channel occupies three 32-bit words:
                            //   bias, multiplier, shift.
                            //
                            // Division/modulo by constant three
                            // is only in the parameter load path.

                            if ((int'($unsigned(index_q)) % 3) == 0) begin
                                bias_out[
                                    int'($unsigned(index_q)) / 3
                                ] <= BIAS_WIDTH'(read_data);

                            end else if (
                                (int'($unsigned(index_q)) % 3) == 1
                            ) begin
                                multiplier_lane_out[
                                    int'($unsigned(index_q)) / 3
                                ] <= read_data;

                                if (read_data[31])
                                    error <= 1'b1;

                            end else begin
                                shift_lane_out[
                                    int'($unsigned(index_q)) / 3
                                ] <= read_data[5:0];

                                if (read_data > 32'd62)
                                    error <= 1'b1;
                            end

                            if (index_q == bias_last_index_q) begin
                                if (!read_data_last)
                                    error <= 1'b1;

                                state_q <= ST_DONE;

                            end else if (read_data_last) begin
                                error <= 1'b1;
                                state_q <= ST_DONE;

                            end else begin
                                index_q <= index_q + 1'b1;
                            end

                        end else begin

                            bias_out[BIAS_INDEX_WIDTH'(index_q)] <= BIAS_WIDTH'(read_data);

                            if (
                                index_q ==
                                bias_last_index_q
                            ) begin

                                if (!read_data_last) begin

                                    error <= 1'b1;

                                end

                                state_q <= ST_DONE;

                            end else begin

                                if (read_data_last) begin

                                    error <= 1'b1;

                                    state_q <= ST_DONE;

                                end else begin

                                    index_q <= index_q + 1'b1;

                                end

                            end

                        end

                    end

                end

                // =================================================
                // DONE
                // =================================================

                ST_DONE: begin

                    state_q <= ST_IDLE;

                end

                default: begin

                    state_q <= ST_IDLE;

                end

            endcase

        end

    end

endmodule
