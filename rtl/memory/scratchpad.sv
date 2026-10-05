module scratchpad #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,

    parameter int DEPTH      = 256,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input logic clk,

    // ============================================================
    // A SRAM write
    // ============================================================

    input logic                           a_wen,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    // ============================================================
    // B SRAM write
    // ============================================================

    input logic                           b_wen,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,

    // ============================================================
    // A/B SRAM shared read
    // ============================================================

    input logic                           ren,
    input logic [ADDR_WIDTH-1:0]          raddr,

    output logic [ROWS*DATA_WIDTH-1:0]    a_rdata,
    output logic [COLS*DATA_WIDTH-1:0]    b_rdata,

    // ============================================================
    // C SRAM
    // ============================================================

    input logic                           c_wen,
    input logic [ADDR_WIDTH-1:0]          c_waddr,
    input logic [ACC_WIDTH-1:0]           c_wdata,

    input logic                           c_ren,
    input logic [ADDR_WIDTH-1:0]          c_raddr,

    output logic [ACC_WIDTH-1:0]          c_rdata
);


    // ============================================================
    // A SRAM
    // ============================================================

    sram_model #(
        .DATA_WIDTH (ROWS * DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_a_sram (
        .clk   (clk),

        .ren   (ren),
        .raddr (raddr),
        .rdata (a_rdata),

        .wen   (a_wen),
        .waddr (a_waddr),
        .wdata (a_wdata)
    );


    // ============================================================
    // B SRAM
    // ============================================================

    sram_model #(
        .DATA_WIDTH (COLS * DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_b_sram (
        .clk   (clk),

        .ren   (ren),
        .raddr (raddr),
        .rdata (b_rdata),

        .wen   (b_wen),
        .waddr (b_waddr),
        .wdata (b_wdata)
    );


    // ============================================================
    // C SRAM
    //
    // One word = one INT32 result / partial sum
    // ============================================================

    sram_model #(
        .DATA_WIDTH (ACC_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_c_sram (
        .clk   (clk),

        .ren   (c_ren),
        .raddr (c_raddr),
        .rdata (c_rdata),

        .wen   (c_wen),
        .waddr (c_waddr),
        .wdata (c_wdata)
    );


endmodule
