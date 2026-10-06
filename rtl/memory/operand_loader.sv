module operand_loader #(
    parameter int unsigned WORD_WIDTH = 32,
    parameter int unsigned DEPTH      = 256,
    parameter int unsigned ADDR_WIDTH =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int unsigned SIZE_WIDTH =
        $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Tile scheduler
    // ============================================================

    // Request loading of one operand tile.
    input  logic load_req,

    // Request has been accepted by this loader.
    output logic load_accept,

    // Number of SRAM words in this tile.
    // For the current architecture this is current_k_size.
    input logic [SIZE_WIDTH-1:0] load_size,

    // Entire tile has been written into the operand buffer.
    output logic load_done,


    // ============================================================
    // Buffer manager
    // ============================================================

    // Ask for one EMPTY bank.
    output logic bank_load_req,

    // Buffer manager has allocated a bank.
    input logic bank_load_grant,

    // Bank selected by the buffer manager.
    input logic bank_load_bank,

    // Tell the buffer manager that loading has completed.
    output logic bank_load_done,


    // ============================================================
    // Input data stream
    //
    // Data is already packed into the local SRAM word format.
    // ============================================================

    input  logic                  data_valid,
    input  logic [WORD_WIDTH-1:0] data,
    output logic                  data_ready,


    // ============================================================
    // Operand buffer write port
    // ============================================================

    output logic                  buffer_wen,
    output logic                  buffer_wbank,
    output logic [ADDR_WIDTH-1:0] buffer_waddr,
    output logic [WORD_WIDTH-1:0] buffer_wdata,


    // ============================================================
    // Status
    // ============================================================

    output logic busy
);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [1:0] {
        IDLE,
        ACQUIRE_BANK,
        RECEIVE,
        DONE
    } state_t;

    state_t state;


    // ============================================================
    // Registers
    // ============================================================

    logic target_bank_q;

    logic [SIZE_WIDTH-1:0] load_size_q;
    logic [SIZE_WIDTH-1:0] write_count_q;


    // ============================================================
    // Scheduler handshake
    // ============================================================

    assign load_accept =
        (state == IDLE) &&
        load_req;

    assign load_done =
        (state == DONE);


    // ============================================================
    // Buffer manager
    // ============================================================

    assign bank_load_req =
        (state == ACQUIRE_BANK);

    assign bank_load_done =
        (state == DONE);


    // ============================================================
    // Input stream
    //
    // Local SRAM can accept one word every cycle.
    // ============================================================

    assign data_ready =
        (state == RECEIVE);


    // ============================================================
    // Operand buffer write
    // ============================================================

    assign buffer_wen =
        data_valid &&
        data_ready;

    assign buffer_wbank =
        target_bank_q;

    assign buffer_waddr =
        write_count_q[ADDR_WIDTH-1:0];

    assign buffer_wdata =
        data;


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != IDLE);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= IDLE;

            target_bank_q <= 1'b0;

            load_size_q  <= '0;
            write_count_q <= '0;

        end else begin

            case (state)

                // =================================================
                // Wait for scheduler request.
                // =================================================

                IDLE: begin

                    if (load_accept) begin

                        load_size_q <= load_size;

                        state <= ACQUIRE_BANK;

                    end

                end


                // =================================================
                // Ask buffer_manager for an EMPTY bank.
                // =================================================

                ACQUIRE_BANK: begin

                    if (bank_load_grant) begin

                        target_bank_q <= bank_load_bank;

                        write_count_q <= '0;

                        state <= RECEIVE;

                    end

                end


                // =================================================
                // Receive packed words and write them sequentially:
                //
                // word 0 -> SRAM addr 0
                // word 1 -> SRAM addr 1
                // ...
                // =================================================

                RECEIVE: begin

                    if (data_valid && data_ready) begin

                        if (
                            write_count_q ==
                            (load_size_q - 1'b1)
                        ) begin

                            state <= DONE;

                        end else begin

                            write_count_q <=
                                write_count_q + 1'b1;

                        end

                    end

                end


                // =================================================
                // One-cycle completion pulse.
                //
                // Notify:
                // 1. scheduler
                // 2. buffer manager
                // =================================================

                DONE: begin

                    state <= IDLE;

                end


                default: begin

                    state <= IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (WORD_WIDTH < 1) begin
            $fatal(1, "WORD_WIDTH must be >= 1");
        end

        if (DEPTH < 1) begin
            $fatal(1, "DEPTH must be >= 1");
        end

    end

endmodule
