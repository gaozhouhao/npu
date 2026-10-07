module command_frontend #(
    parameter int unsigned DESC_COUNT_WIDTH = 16
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // CPU / testbench command
    // ============================================================

    input logic        start,
    input logic [63:0] desc_base,
    input logic [DESC_COUNT_WIDTH-1:0] desc_count,


    // ============================================================
    // External memory read interface
    //
    // Temporary simple interface.
    // This will later be replaced by an AXI read path.
    // ============================================================

    output logic        mem_read_req,
    output logic [63:0] mem_read_addr,
    input  logic        mem_read_ready,

    input  logic        mem_read_valid,
    input  logic [31:0] mem_read_data,


    // ============================================================
    // Decoded command
    
    // cmd_valid remains asserted until cmd_ready.
    // ============================================================

    output logic        cmd_valid,
    input  logic        cmd_ready,

    output logic [7:0]  cmd_opcode,
    output logic [23:0] cmd_flags,

    output logic [31:0] cfg_m,
    output logic [31:0] cfg_n,
    output logic [31:0] cfg_k,

    output logic [63:0] cfg_a_base,
    output logic [63:0] cfg_b_base,
    output logic [63:0] cfg_c_base,

    output logic [31:0] cfg_a_stride,
    output logic [31:0] cfg_b_stride,
    output logic [31:0] cfg_c_stride,

    output logic [31:0] cfg_param0,
    output logic [31:0] cfg_param1,


    // ============================================================
    // Execution completion
    //
    // Asserted by the execution engine after the current
    // descriptor has completely finished.
    // ============================================================

    input logic exec_done,


    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done
);


    // ============================================================
    // Descriptor constants
    // ============================================================

    localparam logic [63:0] DESC_SIZE_BYTES = 64'd64;

    localparam logic [3:0] DESC_LAST_WORD = 4'd15;


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_REQ,
        ST_READ_WAIT,
        ST_ISSUE,
        ST_WAIT_EXEC,
        ST_ADVANCE,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Descriptor tracking
    // ============================================================

    logic [63:0] current_desc_addr;

    logic [DESC_COUNT_WIDTH-1:0] desc_remaining;

    logic [3:0] word_index;


    // ============================================================
    // Memory request
    // ============================================================

    assign mem_read_req =
        (state == ST_READ_REQ);

    assign mem_read_addr =
        current_desc_addr +
        {58'd0, word_index, 2'b00};


    // ============================================================
    // Command output handshake
    // ============================================================

    assign cmd_valid =
        (state == ST_ISSUE);


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);

    assign done =
        (state == ST_DONE);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= ST_IDLE;

            current_desc_addr <= '0;
            desc_remaining    <= '0;
            word_index        <= '0;

            cmd_opcode <= '0;
            cmd_flags  <= '0;

            cfg_m <= '0;
            cfg_n <= '0;
            cfg_k <= '0;

            cfg_a_base <= '0;
            cfg_b_base <= '0;
            cfg_c_base <= '0;

            cfg_a_stride <= '0;
            cfg_b_stride <= '0;
            cfg_c_stride <= '0;

            cfg_param0 <= '0;
            cfg_param1 <= '0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                //
                // CPU gives:
                //
                // desc_base
                // desc_count
                // start
                // =================================================

                ST_IDLE: begin

                    if (start) begin

                        current_desc_addr <= desc_base;
                        desc_remaining    <= desc_count;
                        word_index        <= '0;

                        if (desc_count == '0) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_READ_REQ;
                        end

                    end

                end


                // =================================================
                // READ REQUEST
                //
                // Request one 32-bit descriptor word.
                // =================================================

                ST_READ_REQ: begin

                    if (mem_read_ready) begin
                        state <= ST_READ_WAIT;
                    end

                end


                // =================================================
                // READ WAIT
                //
                // Wait for the 32-bit word to return.
                // =================================================

                ST_READ_WAIT: begin

                    if (mem_read_valid) begin

                        case (word_index)

                            4'd0: begin
                                cmd_opcode <= mem_read_data[7:0];
                                cmd_flags  <= mem_read_data[31:8];
                            end

                            4'd1: begin
                                cfg_m <= mem_read_data;
                            end

                            4'd2: begin
                                cfg_n <= mem_read_data;
                            end

                            4'd3: begin
                                cfg_k <= mem_read_data;
                            end

                            4'd4: begin
                                cfg_a_base[31:0] <= mem_read_data;
                            end

                            4'd5: begin
                                cfg_a_base[63:32] <= mem_read_data;
                            end

                            4'd6: begin
                                cfg_b_base[31:0] <= mem_read_data;
                            end

                            4'd7: begin
                                cfg_b_base[63:32] <= mem_read_data;
                            end

                            4'd8: begin
                                cfg_c_base[31:0] <= mem_read_data;
                            end

                            4'd9: begin
                                cfg_c_base[63:32] <= mem_read_data;
                            end

                            4'd10: begin
                                cfg_a_stride <= mem_read_data;
                            end

                            4'd11: begin
                                cfg_b_stride <= mem_read_data;
                            end

                            4'd12: begin
                                cfg_c_stride <= mem_read_data;
                            end

                            4'd13: begin
                                cfg_param0 <= mem_read_data;
                            end

                            4'd14: begin
                                cfg_param1 <= mem_read_data;
                            end

                            4'd15: begin
                                // Reserved word.
                            end

                            default: begin
                            end

                        endcase


                        if (word_index == DESC_LAST_WORD) begin

                            word_index <= '0;
                            state      <= ST_ISSUE;

                        end else begin

                            word_index <= word_index + 1'b1;
                            state      <= ST_READ_REQ;

                        end

                    end

                end


                // =================================================
                // ISSUE
                //
                // A complete 64-byte descriptor has been decoded.
                //
                // Hold cmd_valid until the execution side accepts it.
                // =================================================

                ST_ISSUE: begin

                    if (cmd_ready) begin
                        state <= ST_WAIT_EXEC;
                    end

                end


                // =================================================
                // WAIT EXECUTION
                //
                // The tile scheduler / DMA / GEMM pipeline is now
                // executing the current command.
                // =================================================

                ST_WAIT_EXEC: begin

                    if (exec_done) begin
                        state <= ST_ADVANCE;
                    end

                end


                // =================================================
                // ADVANCE
                //
                // Move to the next 64-byte descriptor.
                // =================================================

                ST_ADVANCE: begin

                    if (desc_remaining == 1) begin

                        desc_remaining <= '0;

                        state <= ST_DONE;

                    end else begin

                        desc_remaining <=
                            desc_remaining - 1'b1;

                        current_desc_addr <=
                            current_desc_addr + DESC_SIZE_BYTES;

                        word_index <= '0;

                        state <= ST_READ_REQ;

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion pulse.
                // =================================================

                ST_DONE: begin

                    state <= ST_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

                default: begin

                    state <= ST_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (DESC_COUNT_WIDTH < 1) begin
            $fatal(1, "DESC_COUNT_WIDTH must be >= 1");
        end

    end

endmodule
