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
    //
    // One word contains ROWS INT8 values:
    //
    // {
    //     A[ROWS-1][k],
    //     ...
    //     A[1][k],
    //     A[0][k]
    // }
    // ============================================================

    input logic                           a_wen,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    // ============================================================
    // B SRAM write
    //
    // One word contains COLS INT8 values:
    //
    // {
    //     B[k][COLS-1],
    //     ...
    //     B[k][1],
    //     B[k][0]
    // }
    // ============================================================

    input logic                           b_wen,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,

    // ============================================================
    // A/B shared read
    // ============================================================

    input logic                           ren,
    input logic [ADDR_WIDTH-1:0]          raddr,

    output logic [ROWS*DATA_WIDTH-1:0]    a_rdata,
    output logic [COLS*DATA_WIDTH-1:0]    b_rdata,

    // ============================================================
    // C Buffer
    //
    // Implemented as COLS independent SRAM banks.
    //
    // For COLS = 4:
    //
    // bank 0 -> output column 0
    // bank 1 -> output column 1
    // bank 2 -> output column 2
    // bank 3 -> output column 3
    //
    // All banks share the same address.
    //
    // Therefore one write stores one complete output row.
    // ============================================================

    input logic                           c_wen,
    input logic [ADDR_WIDTH-1:0]          c_waddr,
    input logic [COLS*ACC_WIDTH-1:0]      c_wdata,

    input logic                           c_ren,
    input logic [ADDR_WIDTH-1:0]          c_raddr,

    output logic [COLS*ACC_WIDTH-1:0]     c_rdata
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
    // C SRAM banks
    //
    // Each bank is:
    //
    // DEPTH × ACC_WIDTH
    //
    // Example for 4 columns:
    //
    // Bank0[address] = C[row][0]
    // Bank1[address] = C[row][1]
    // Bank2[address] = C[row][2]
    // Bank3[address] = C[row][3]
    // ============================================================

    genvar bank;

    generate

        for (bank = 0; bank < COLS; bank++) begin : GEN_C_BANK

            sram_model #(
                .DATA_WIDTH (ACC_WIDTH),
                .ADDR_WIDTH (ADDR_WIDTH),
                .DEPTH      (DEPTH)
            ) u_c_sram (
                .clk   (clk),

                .ren   (c_ren),
                .raddr (c_raddr),
                .rdata (
                    c_rdata[
                        bank*ACC_WIDTH +: ACC_WIDTH
                    ]
                ),

                .wen   (c_wen),
                .waddr (c_waddr),
                .wdata (
                    c_wdata[
                        bank*ACC_WIDTH +: ACC_WIDTH
                    ]
                )
            );

        end

    endgenerate


endmodule
