
module psum_tile_engine #(
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned PSUM_SLOTS = 4,

    parameter int unsigned SLOT_WIDTH =
        (PSUM_SLOTS <= 1) ? 1 : $clog2(PSUM_SLOTS),

    parameter int unsigned ROW_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS),

    parameter int unsigned DATA_WIDTH =
        COLS * ACC_WIDTH,

    parameter int unsigned TILE_WIDTH =
        ROWS * DATA_WIDTH
) (
    input logic clk,
    input logic reset,

    input logic start,
    input logic first_k,
    input logic [SLOT_WIDTH-1:0] slot,
    input logic [TILE_WIDTH-1:0] pe_tile,

    output logic busy,
    output logic done,

    output logic sram_rd_en,
    output logic [SLOT_WIDTH-1:0] sram_rd_slot,
    output logic [ROW_WIDTH-1:0] sram_rd_row,
    input logic sram_rd_valid,
    input logic [DATA_WIDTH-1:0] sram_rd_data,

    output logic sram_wr_en,
    output logic [SLOT_WIDTH-1:0] sram_wr_slot,
    output logic [ROW_WIDTH-1:0] sram_wr_row,
    output logic [DATA_WIDTH-1:0] sram_wr_data,

    // Borrow the existing four INT32 Bias adders.
    output logic alu_use_psum,
    output logic [DATA_WIDTH-1:0] alu_a,
    output logic [DATA_WIDTH-1:0] alu_b,
    input logic [DATA_WIDTH-1:0] alu_sum
);

    typedef enum logic [2:0] {
        IDLE,
        ISSUE_READ,
        WAIT_READ,
        WRITE_ROW,
        FINISHED
    } state_t;

    state_t state_q;

    logic [ROW_WIDTH-1:0] row_q;
    logic [SLOT_WIDTH-1:0] slot_q;
    logic first_q;

    logic [TILE_WIDTH-1:0] tile_q;
    logic [DATA_WIDTH-1:0] pe_row_data;

    assign pe_row_data =
        tile_q[
            32'(row_q) * DATA_WIDTH +: DATA_WIDTH
        ];

    assign busy =
        (state_q != IDLE) &&
        (state_q != FINISHED);

    assign done = (state_q == FINISHED);

    // SRAM read interface.

    assign sram_rd_en =
        (state_q == ISSUE_READ);

    assign sram_rd_slot = slot_q;
    assign sram_rd_row = row_q;

    // SRAM write interface.

    assign sram_wr_en =
        (state_q == WRITE_ROW);

    assign sram_wr_slot = slot_q;
    assign sram_wr_row = row_q;

    // Shared four-lane INT32 ALU.
    //
    // first_k = 1:
    //     SRAM = PE result
    //
    // first_k = 0:
    //     SRAM = old SRAM + PE result

    assign alu_use_psum =
        (state_q == WRITE_ROW) && !first_q;

    assign alu_a = pe_row_data;
    assign alu_b = sram_rd_data;

    assign sram_wr_data =
        first_q ? pe_row_data : alu_sum;

    // Row-wise partial-sum update FSM.

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            row_q <= '0;
            slot_q <= '0;
            first_q <= 1'b0;
            tile_q <= '0;
        end else begin

            case (state_q)

                IDLE: begin
                    if (start) begin
                        row_q <= '0;
                        slot_q <= slot;
                        first_q <= first_k;
                        tile_q <= pe_tile;

                        state_q <= first_k
                            ? WRITE_ROW
                            : ISSUE_READ;
                    end
                end

                ISSUE_READ: begin
                    state_q <= WAIT_READ;
                end

                WAIT_READ: begin
                    if (sram_rd_valid)
                        state_q <= WRITE_ROW;
                end

                WRITE_ROW: begin
                    if (
                        row_q == ROW_WIDTH'(ROWS - 1)
                    ) begin
                        state_q <= FINISHED;
                    end else begin
                        row_q <=
                            row_q + ROW_WIDTH'(1);

                        state_q <= first_q
                            ? WRITE_ROW
                            : ISSUE_READ;
                    end
                end

                FINISHED: begin
                    state_q <= IDLE;
                end

                default: begin
                    state_q <= IDLE;
                end

            endcase
        end
    end

    initial begin
        if (
            (ROWS < 1) ||
            (COLS < 1) ||
            (ACC_WIDTH != 32) ||
            (PSUM_SLOTS < 1)
        )
            $fatal(
                1,
                "Invalid psum_tile_engine parameters"
            );
    end

endmodule
