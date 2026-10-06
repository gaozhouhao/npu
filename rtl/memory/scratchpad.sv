module scratchpad #(
    parameter int ROWS       = 4,
    parameter int COLS       = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,

    parameter int DEPTH      = 256,
    parameter int ADDR_WIDTH = $clog2(DEPTH),

    parameter int A_BUFFER_COUNT = 1,
    parameter int B_BUFFER_COUNT = 1
) (
    input logic clk,

    // ============================================================
    // A Buffer
    // ============================================================

    input logic                           a_wen,
    input logic                           a_wbank,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    input logic                           a_rbank,

    // ============================================================
    // B Buffer
    // ============================================================

    input logic                           b_wen,
    input logic                           b_wbank,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,

    input logic                           b_rbank,

    // ============================================================
    // A/B compute read
    // ============================================================

    input logic                           ren,
    input logic [ADDR_WIDTH-1:0]          raddr,

    output logic [ROWS*DATA_WIDTH-1:0]    a_rdata,
    output logic [COLS*DATA_WIDTH-1:0]    b_rdata,

    // ============================================================
    // C Buffer
    // ============================================================

    input logic                           c_wen,
    input logic [ADDR_WIDTH-1:0]          c_waddr,
    input logic [COLS*ACC_WIDTH-1:0]      c_wdata,

    input logic                           c_ren,
    input logic [ADDR_WIDTH-1:0]          c_raddr,

    output logic [COLS*ACC_WIDTH-1:0]     c_rdata
);


    // ============================================================
    // A Operand Buffer
    // ============================================================

    operand_buffer #(
        .DATA_WIDTH   (ROWS * DATA_WIDTH),
        .DEPTH        (DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .BUFFER_COUNT (A_BUFFER_COUNT)
    ) u_a_buffer (
        .clk   (clk),

        .wen   (a_wen),
        .wbank (a_wbank),
        .waddr (a_waddr),
        .wdata (a_wdata),

        .ren   (ren),
        .rbank (a_rbank),
        .raddr (raddr),
        .rdata (a_rdata)
    );


    // ============================================================
    // B Operand Buffer
    // ============================================================

    operand_buffer #(
        .DATA_WIDTH   (COLS * DATA_WIDTH),
        .DEPTH        (DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .BUFFER_COUNT (B_BUFFER_COUNT)
    ) u_b_buffer (
        .clk   (clk),

        .wen   (b_wen),
        .wbank (b_wbank),
        .waddr (b_waddr),
        .wdata (b_wdata),

        .ren   (ren),
        .rbank (b_rbank),
        .raddr (raddr),
        .rdata (b_rdata)
    );


    // ============================================================
    // C Buffer
    //
    // COLS banks, one INT32 result per bank.
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
