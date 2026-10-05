module scratchpad #(
    parameter int DATA_WIDTH = 8,
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int DEPTH      = 256,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input logic clk,

    // A write port
    input logic                           a_wen,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    // B write port
    input logic                           b_wen,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,

    // Compute read port
    input logic                           ren,
    input logic [ADDR_WIDTH-1:0]          raddr,

    // Read data
    output logic [ROWS*DATA_WIDTH-1:0]    a_rdata,
    output logic [COLS*DATA_WIDTH-1:0]    b_rdata
);

    // A scratchpad
    sram_model #(
        .DATA_WIDTH (ROWS * DATA_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_a_sram (
        .clk   (clk),

        .ren   (ren),
        .raddr (raddr),
        .rdata (a_rdata),

        .wen   (a_wen),
        .waddr (a_waddr),
        .wdata (a_wdata)
    );

    // B scratchpad
    sram_model #(
        .DATA_WIDTH (COLS * DATA_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_b_sram (
        .clk   (clk),

        .ren   (ren),
        .raddr (raddr),
        .rdata (b_rdata),

        .wen   (b_wen),
        .waddr (b_waddr),
        .wdata (b_wdata)
    );

endmodule