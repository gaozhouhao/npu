module bias_loader #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned COLS       = 4,
    parameter int unsigned BIAS_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Bias load command
    // ============================================================

    input  logic                  load_req,
    output logic                  load_accept,

    input  logic [ADDR_WIDTH-1:0] bias_addr,

    output logic                  busy,
    output logic                  done,
    output logic                  error,

    // ============================================================
    // Loaded bias vector
    // ============================================================

    output logic signed [BIAS_WIDTH-1:0]
        bias_out [COLS],

    // ============================================================
    // Generic read request
    //
    // This will later connect to the shared AXI read path.
    // ============================================================

    output logic                  read_req_valid,
    input  logic                  read_req_ready,

    output logic [ADDR_WIDTH-1:0] read_req_addr,
    output logic [31:0]           read_req_beats,

    // ============================================================
    // Generic read data stream
    // ============================================================

    input  logic                  read_data_valid,
    output logic                  read_data_ready,

    input  logic [DATA_WIDTH-1:0] read_data,
    input  logic                  read_data_last
);


    localparam int unsigned INDEX_WIDTH =
        (COLS <= 1) ?
        1 :
        $clog2(COLS);


    typedef enum logic [1:0] {
        ST_IDLE,
        ST_REQ,
        ST_DATA,
        ST_DONE
    } state_t;

    state_t state;


    logic [ADDR_WIDTH-1:0]
        bias_addr_q;

    logic [INDEX_WIDTH-1:0]
        bias_index_q;


    // ============================================================
    // Command interface
    // ============================================================

    assign load_accept =
        (state == ST_IDLE);


    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);


    assign done =
        (state == ST_DONE);


    // ============================================================
    // Read request
    // ============================================================

    assign read_req_valid =
        (state == ST_REQ);


    assign read_req_addr =
        bias_addr_q;


    // One INT32 bias per beat.
    assign read_req_beats =
        32'(COLS);


    // ============================================================
    // Read stream
    // ============================================================

    assign read_data_ready =
        (state == ST_DATA);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <=
                ST_IDLE;

            bias_addr_q <=
                '0;

            bias_index_q <=
                '0;

            error <=
                1'b0;

            for (
                integer i = 0;
                i < COLS;
                i = i + 1
            ) begin

                bias_out[i] <=
                    '0;

            end

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (load_req) begin

                        bias_addr_q <=
                            bias_addr;

                        bias_index_q <=
                            '0;

                        error <=
                            1'b0;

                        state <=
                            ST_REQ;

                    end

                end


                // =================================================
                // Issue one contiguous read request
                // =================================================

                ST_REQ: begin

                    if (read_req_ready) begin

                        state <=
                            ST_DATA;

                    end

                end


                // =================================================
                // Receive COLS bias words
                // =================================================

                ST_DATA: begin

                    if (
                        read_data_valid &&
                        read_data_ready
                    ) begin

                        bias_out[bias_index_q] <=
                            BIAS_WIDTH'(read_data);


                        // -----------------------------------------
                        // Last expected bias element
                        // -----------------------------------------

                        if (
                            bias_index_q ==
                            INDEX_WIDTH'(COLS - 1)
                        ) begin

                            if (!read_data_last) begin

                                error <=
                                    1'b1;

                            end

                            state <=
                                ST_DONE;

                        end else begin

                            // -------------------------------------
                            // RLAST must not arrive early.
                            // -------------------------------------

                            if (read_data_last) begin

                                error <=
                                    1'b1;

                                state <=
                                    ST_DONE;

                            end else begin

                                bias_index_q <=
                                    bias_index_q + 1'b1;

                            end

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


        if (BIAS_WIDTH != DATA_WIDTH) begin

            $fatal(
                1,
                "Current bias_loader requires BIAS_WIDTH == DATA_WIDTH"
            );

        end


        if (DATA_WIDTH != 32) begin

            $fatal(
                1,
                "Current bias_loader requires DATA_WIDTH == 32"
            );

        end


        if (ADDR_WIDTH < 12) begin

            $fatal(
                1,
                "ADDR_WIDTH must be >= 12"
            );

        end

    end

endmodule
