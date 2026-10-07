module scratchpad #(
    parameter int unsigned ROWS           = 4,
    parameter int unsigned COLS           = 4,

    parameter int unsigned A_BUFFER_COUNT = 1,
    parameter int unsigned B_BUFFER_COUNT = 1,

    parameter int unsigned DATA_WIDTH     = 8,
    parameter int unsigned ACC_WIDTH      = 32,

    // Logical K depth
    parameter int unsigned DEPTH          = 256,

    parameter int unsigned ADDR_WIDTH =
        (DEPTH <= 1) ?
        1 :
        $clog2(DEPTH),

    // Physical SRAM word width
    parameter int unsigned MEM_WORD_WIDTH = 32,

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / DATA_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    parameter int unsigned A_LANE_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS),

    parameter int unsigned B_LANE_WIDTH =
        (COLS <= 1) ?
        1 :
        $clog2(COLS)
) (
    input logic clk,

    // ============================================================
    // A operand buffer
    // ============================================================

    input logic                        a_wen,
    input logic                        a_wbank,
    input logic [A_LANE_WIDTH-1:0]     a_wlane,
    input logic [WORD_ADDR_WIDTH-1:0]  a_waddr,
    input logic [MEM_WORD_WIDTH-1:0]   a_wdata,

    input logic                        a_rbank,

    // ============================================================
    // B operand buffer
    // ============================================================

    input logic                        b_wen,
    input logic                        b_wbank,
    input logic [B_LANE_WIDTH-1:0]     b_wlane,
    input logic [WORD_ADDR_WIDTH-1:0]  b_waddr,
    input logic [MEM_WORD_WIDTH-1:0]   b_wdata,

    input logic                        b_rbank,

    // ============================================================
    // Logical K read interface
    // ============================================================

    input logic                        ren,
    input logic [ADDR_WIDTH-1:0]       raddr,

    output logic [ROWS*DATA_WIDTH-1:0] a_rdata,
    output logic [COLS*DATA_WIDTH-1:0] b_rdata,

    // ============================================================
    // C buffer
    // ============================================================

    input logic                         c_wen,
    input logic [ADDR_WIDTH-1:0]        c_waddr,
    input logic [COLS*ACC_WIDTH-1:0]    c_wdata,

    input logic                         c_ren,
    input logic [ADDR_WIDTH-1:0]        c_raddr,
    output logic [COLS*ACC_WIDTH-1:0]   c_rdata
);


    // ============================================================
    // A Operand Buffer
    // ============================================================

    operand_buffer #(
        .ELEM_WIDTH     (DATA_WIDTH),
        .LANE_COUNT     (COLS),
        .MEM_WORD_WIDTH (32),
        .K_DEPTH        (DEPTH),
        .BUFFER_COUNT   (B_BUFFER_COUNT)
    ) u_a_buffer (
        .clk       (clk),

        .wen       (a_wen),
        .wbank     (a_wbank),
        .wlane     (a_wlane),
        .waddr     (a_waddr),
        .wdata     (a_wdata),

        .ren       (ren),
        .rbank     (a_rbank),
        .r_k_index (raddr),

        .rdata     (a_rdata)
    );


    // ============================================================
    // B Operand Buffer
    // ============================================================

    operand_buffer #(
        .ELEM_WIDTH     (DATA_WIDTH),
        .LANE_COUNT     (ROWS),
        .MEM_WORD_WIDTH (32),
        .K_DEPTH        (DEPTH),
        .BUFFER_COUNT   (A_BUFFER_COUNT)
    ) u_b_buffer (
        .clk       (clk),

        .wen       (b_wen),
        .wbank     (b_wbank),
        .wlane     (b_wlane),
        .waddr     (b_waddr),
        .wdata     (b_wdata),

        .ren       (ren),
        .rbank     (b_rbank),
        .r_k_index (raddr),

        .rdata     (b_rdata)
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
