module postprocess_param_loader #(
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

    output logic                  global_load_done,

    // ============================================================
    // Bias vector load
    // ============================================================

    input  logic                  bias_load_req,
    output logic                  bias_load_accept,

    input  logic [ADDR_WIDTH-1:0] bias_addr,
    input  logic per_channel_en,

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


    localparam int unsigned BIAS_INDEX_WIDTH =
        (COLS <= 1) ? 1 : $clog2(COLS);

    localparam int unsigned MAX_ITEMS =
        (3 * COLS > 2) ? (3 * COLS) : 2;

    localparam int unsigned INDEX_WIDTH =
        (MAX_ITEMS <= 1) ?
        1 :
        $clog2(MAX_ITEMS);


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


    state_t state;

    load_mode_t mode_q;


    logic [ADDR_WIDTH-1:0]
        req_addr_q;

    logic [31:0]
        req_beats_q;

    logic [INDEX_WIDTH-1:0]
        index_q;
    logic [INDEX_WIDTH-1:0] global_last_index_q;


    // ============================================================
    // Command arbitration
    //
    // Global parameter load has priority because it occurs once
    // at the beginning of a GEMM command.
    // ============================================================

    assign global_load_accept =
        (state == ST_IDLE) &&
        global_load_req;


    assign bias_load_accept =
        (state == ST_IDLE) &&
        !global_load_req &&
        bias_load_req;


    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);


    assign global_load_done =
        (state == ST_DONE) &&
        (mode_q == MODE_GLOBAL);


    assign bias_load_done =
        (state == ST_DONE) &&
        ((mode_q == MODE_BIAS) ||
         (mode_q == MODE_CHANNEL));


    // ============================================================
    // Generic read interface
    // ============================================================

    assign read_req_valid =
        (state == ST_REQ);


    assign read_req_addr =
        req_addr_q;


    assign read_req_beats =
        req_beats_q;


    assign read_data_ready =
        (state == ST_DATA);


    // ============================================================
    // FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <=
                ST_IDLE;

            mode_q <=
                MODE_GLOBAL;

            req_addr_q <=
                '0;

            req_beats_q <=
                '0;

            index_q <=
                '0;
            global_last_index_q <= '0;

            multiplier_out <=
                '0;

            shift_out <=
                '0;
            input_zero_point_out <= '0;
            output_zero_point_out <= '0;

            error <=
                1'b0;

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

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (global_load_req) begin
                        // Clear legacy tensor ZPs before each layer.
                        input_zero_point_out <= '0;
                        output_zero_point_out <= '0;

                        mode_q <=
                            MODE_GLOBAL;

                        req_addr_q <=
                            global_param_addr;

                        req_beats_q <=
                            per_channel_en ? 32'd4 : 32'd2;
                        global_last_index_q <=
                            per_channel_en ? INDEX_WIDTH'(3) : INDEX_WIDTH'(1);

                        index_q <=
                            '0;

                        error <=
                            1'b0;

                        state <=
                            ST_REQ;

                    end else if (bias_load_req) begin

                        mode_q <=
                            per_channel_en ?
                            MODE_CHANNEL : MODE_BIAS;

                        req_addr_q <=
                            bias_addr;

                        req_beats_q <=
                            per_channel_en ?
                            32'(3 * COLS) : 32'(COLS);

                        index_q <=
                            '0;

                        error <=
                            1'b0;

                        state <=
                            ST_REQ;

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

                        state <=
                            ST_DATA;

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

                                multiplier_out <=
                                    read_data;

                                if (read_data[31]) begin

                                    error <=
                                        1'b1;

                                end

                            end else if (index_q == INDEX_WIDTH'(1)) begin

                                shift_out <= read_data[5:0];
                                if (read_data > 32'd62)
                                    error <= 1'b1;

                            end else if (index_q == INDEX_WIDTH'(2)) begin

                                input_zero_point_out <= $signed(read_data[7:0]);
                                if (read_data[31:8] != {24{read_data[7]}})
                                    error <= 1'b1;

                            end else begin

                                output_zero_point_out <= $signed(read_data[7:0]);
                                if (read_data[31:8] != {24{read_data[7]}})
                                    error <= 1'b1;

                            end


                            if (
                                index_q == global_last_index_q
                            ) begin

                                if (!read_data_last) begin

                                    error <=
                                        1'b1;

                                end

                                state <=
                                    ST_DONE;

                            end else begin

                                if (read_data_last) begin

                                    error <=
                                        1'b1;

                                    state <=
                                        ST_DONE;

                                end else begin

                                    index_q <=
                                        index_q + 1'b1;

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

                            if (index_q == INDEX_WIDTH'(3 * COLS - 1)) begin
                                if (!read_data_last)
                                    error <= 1'b1;

                                state <= ST_DONE;

                            end else if (read_data_last) begin
                                error <= 1'b1;
                                state <= ST_DONE;

                            end else begin
                                index_q <= index_q + 1'b1;
                            end

                        end else begin

                            bias_out[BIAS_INDEX_WIDTH'(index_q)] <=
                                BIAS_WIDTH'(read_data);


                            if (
                                index_q ==
                                INDEX_WIDTH'(COLS - 1)
                            ) begin

                                if (!read_data_last) begin

                                    error <=
                                        1'b1;

                                end

                                state <=
                                    ST_DONE;

                            end else begin

                                if (read_data_last) begin

                                    error <=
                                        1'b1;

                                    state <=
                                        ST_DONE;

                                end else begin

                                    index_q <=
                                        index_q + 1'b1;

                                end

                            end

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

        if (COLS < 1) begin

            $fatal(
                1,
                "COLS must be >= 1"
            );

        end


        if (DATA_WIDTH != 32) begin

            $fatal(
                1,
                "postprocess_param_loader requires DATA_WIDTH == 32"
            );

        end


        if (BIAS_WIDTH != 32) begin

            $fatal(
                1,
                "postprocess_param_loader requires BIAS_WIDTH == 32"
            );

        end

    end

endmodule
