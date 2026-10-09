
module psum_tile_sram #(
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned ACC_WIDTH = 32,
    parameter int unsigned PSUM_SLOTS = 4,

    parameter int unsigned SLOT_WIDTH =
        (PSUM_SLOTS <= 1) ? 1 : $clog2(PSUM_SLOTS),

    parameter int unsigned ROW_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS),

    parameter int unsigned DATA_WIDTH =
        COLS * ACC_WIDTH
) (
    input logic clk,
    input logic reset,

    input logic rd_en,
    input logic [SLOT_WIDTH-1:0] rd_slot,
    input logic [ROW_WIDTH-1:0] rd_row,

    output logic rd_valid,
    output logic [DATA_WIDTH-1:0] rd_data,

    input logic wr_en,
    input logic [SLOT_WIDTH-1:0] wr_slot,
    input logic [ROW_WIDTH-1:0] wr_row,
    input logic [DATA_WIDTH-1:0] wr_data
);

    localparam int unsigned TOTAL_ROWS =
        PSUM_SLOTS * ROWS;

    // One address contains one full C row:
    // COLS signed INT32 values.
    logic [DATA_WIDTH-1:0] mem [0:TOTAL_ROWS-1];

    logic [31:0] rd_addr;
    logic [31:0] wr_addr;

    assign rd_addr =
        (32'(rd_slot) * 32'(ROWS)) + 32'(rd_row);

    assign wr_addr =
        (32'(wr_slot) * 32'(ROWS)) + 32'(wr_row);

    // Synchronous read, one-cycle latency.
    // No memory reset: first K overwrites every valid row.

    always_ff @(posedge clk) begin
        if (reset) begin
            rd_valid <= 1'b0;
            rd_data <= '0;
        end else begin
            rd_valid <= rd_en;

            if (rd_en)
                rd_data <= mem[rd_addr];

            if (wr_en)
                mem[wr_addr] <= wr_data;
        end
    end

    // Same-address simultaneous R/W is disallowed.
    // The controller must serialize this access.

    assert property (
        @(posedge clk)
        disable iff (reset)
        !(
            rd_en && wr_en &&
            (rd_addr == wr_addr)
        )
    );

    initial begin
        if (
            (ROWS < 1) ||
            (COLS < 1) ||
            (ACC_WIDTH != 32) ||
            (PSUM_SLOTS < 1)
        )
            $fatal(
                1,
                "Invalid psum_tile_sram parameters"
            );
    end

endmodule
