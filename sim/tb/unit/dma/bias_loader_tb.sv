module bias_loader_tb;

    localparam int unsigned ADDR_WIDTH = 64;
    localparam int unsigned COLS       = 4;
    localparam int unsigned BIAS_WIDTH = 32;
    localparam int unsigned DATA_WIDTH = 32;


    logic clk;
    logic reset;


    logic load_req;
    logic load_accept;

    logic [ADDR_WIDTH-1:0]
        bias_addr;

    logic busy;
    logic done;
    logic error;


    logic signed [BIAS_WIDTH-1:0]
        bias_out [COLS];


    logic read_req_valid;
    logic read_req_ready;

    logic [ADDR_WIDTH-1:0]
        read_req_addr;

    logic [31:0]
        read_req_beats;


    logic read_data_valid;
    logic read_data_ready;

    logic [DATA_WIDTH-1:0]
        read_data;

    logic read_data_last;


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    // ============================================================
    // DUT
    // ============================================================

    bias_loader #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .COLS       (COLS),
        .BIAS_WIDTH (BIAS_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_dut (
        .clk            (clk),
        .reset          (reset),

        .load_req       (load_req),
        .load_accept    (load_accept),

        .bias_addr      (bias_addr),

        .busy           (busy),
        .done           (done),
        .error          (error),

        .bias_out       (bias_out),

        .read_req_valid (read_req_valid),
        .read_req_ready (read_req_ready),

        .read_req_addr  (read_req_addr),
        .read_req_beats (read_req_beats),

        .read_data_valid(read_data_valid),
        .read_data_ready(read_data_ready),

        .read_data      (read_data),
        .read_data_last (read_data_last)
    );


    // ============================================================
    // Fake generic read responder
    // ============================================================

    typedef enum logic [1:0] {
        MEM_IDLE,
        MEM_DATA
    } mem_state_t;

    mem_state_t mem_state;

    logic [2:0]
        beat_index_q;


    assign read_req_ready =
        (mem_state == MEM_IDLE);


    always_ff @(posedge clk) begin

        if (reset) begin

            mem_state <=
                MEM_IDLE;

            beat_index_q <=
                '0;

            read_data_valid <=
                1'b0;

            read_data <=
                '0;

            read_data_last <=
                1'b0;

        end else begin

            read_data_valid <=
                1'b0;

            read_data_last <=
                1'b0;


            case (mem_state)

                MEM_IDLE: begin

                    if (
                        read_req_valid &&
                        read_req_ready
                    ) begin

                        if (
                            read_req_addr !=
                            64'h0000_0000_0000_5000
                        ) begin

                            $fatal(
                                1,
                                "Unexpected bias address"
                            );

                        end


                        if (
                            read_req_beats !=
                            32'd4
                        ) begin

                            $fatal(
                                1,
                                "Expected 4 bias beats, got %0d",
                                read_req_beats
                            );

                        end


                        beat_index_q <=
                            3'd0;

                        mem_state <=
                            MEM_DATA;

                    end

                end


                MEM_DATA: begin

                    if (read_data_ready) begin

                        read_data_valid <=
                            1'b1;


                        case (beat_index_q)

                            3'd0: begin
                                read_data <=
                                    32'(32'sd100);
                            end

                            3'd1: begin
                                read_data <=
                                    32'(-32'sd200);
                            end

                            3'd2: begin
                                read_data <=
                                    32'(32'sd300);
                            end

                            3'd3: begin
                                read_data <=
                                    32'(-32'sd400);
                            end

                            default: begin
                                read_data <=
                                    32'd0;
                            end

                        endcase


                        if (
                            beat_index_q ==
                            3'd3
                        ) begin

                            read_data_last <=
                                1'b1;

                            mem_state <=
                                MEM_IDLE;

                        end else begin

                            beat_index_q <=
                                beat_index_q + 1'b1;

                        end

                    end

                end


                default: begin

                    mem_state <=
                        MEM_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        reset =
            1'b1;

        load_req =
            1'b0;

        bias_addr =
            64'h0000_0000_0000_5000;


        repeat (4) begin
            @(posedge clk);
        end


        @(negedge clk);

        reset =
            1'b0;


        // --------------------------------------------------------
        // Start bias load
        // --------------------------------------------------------

        @(negedge clk);

        load_req =
            1'b1;


        wait (
            load_accept ===
            1'b1
        );


        @(negedge clk);

        load_req =
            1'b0;

        wait (busy === 1'b1);

        // --------------------------------------------------------
        // Wait for completion
        // --------------------------------------------------------

        wait (
            done ===
            1'b1
        );

        #1;


        if (error) begin

            $fatal(
                1,
                "bias_loader reported error"
            );

        end


        if (
            bias_out[0] !==
            32'sd100
        ) begin

            $fatal(
                1,
                "bias[0] mismatch: %0d",
                bias_out[0]
            );

        end


        if (
            bias_out[1] !==
            -32'sd200
        ) begin

            $fatal(
                1,
                "bias[1] mismatch: %0d",
                bias_out[1]
            );

        end


        if (
            bias_out[2] !==
            32'sd300
        ) begin

            $fatal(
                1,
                "bias[2] mismatch: %0d",
                bias_out[2]
            );

        end


        if (
            bias_out[3] !==
            -32'sd400
        ) begin

            $fatal(
                1,
                "bias[3] mismatch: %0d",
                bias_out[3]
            );

        end


        $display("");
        $display("========================================");
        $display("BIAS LOADER TEST PASSED");
        $display("========================================");

        $display(
            "bias[0] = %0d",
            bias_out[0]
        );

        $display(
            "bias[1] = %0d",
            bias_out[1]
        );

        $display(
            "bias[2] = %0d",
            bias_out[2]
        );

        $display(
            "bias[3] = %0d",
            bias_out[3]
        );

        $display("========================================");
        $display("");

        $finish;

    end

endmodule
