module gemm_core #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,
    parameter int DATA_WIDTH   = 8,
    parameter int ACC_WIDTH    = 32,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),

    parameter int C_INDEX_WIDTH =
        (ROWS * COLS <= 1) ? 1 : $clog2(ROWS * COLS)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // GEMM control
    // ============================================================

    input logic                    start,
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,

    output logic busy,
    output logic done,

    // ============================================================
    // A scratchpad preload
    // ============================================================

    input logic                           a_wen,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    // ============================================================
    // B scratchpad preload
    // ============================================================

    input logic                           b_wen,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,

    // ============================================================
    // C scratchpad external read
    //
    // 当前主要给 testbench 使用
    // ============================================================

    input logic                           c_ren,
    input logic [ADDR_WIDTH-1:0]          c_raddr,

    output logic [ACC_WIDTH-1:0]          c_rdata,

    // ============================================================
    // Debug result
    // ============================================================

    output logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS]
);


    // ============================================================
    // Controller signals
    // ============================================================

    logic clear;

    logic                  read_en;
    logic [ADDR_WIDTH-1:0] read_addr;

    logic feed_valid;

    logic                     c_wen;
    logic [C_INDEX_WIDTH-1:0] c_index;


    // ============================================================
    // Scratchpad A/B read
    // ============================================================

    logic [ROWS*DATA_WIDTH-1:0] a_rdata;
    logic [COLS*DATA_WIDTH-1:0] b_rdata;


    // ============================================================
    // Matrix engine input
    // ============================================================

    logic signed [DATA_WIDTH-1:0] a_in [ROWS];
    logic signed [DATA_WIDTH-1:0] b_in [COLS];

    logic a_valid_in [ROWS];
    logic b_valid_in [COLS];


    // ============================================================
    // C writeback
    // ============================================================

    logic [ADDR_WIDTH-1:0] c_waddr;
    logic [ACC_WIDTH-1:0]  c_wdata;


    // ============================================================
    // 1. Matrix controller
    // ============================================================

    matrix_controller #(
        .ROWS          (ROWS),
        .COLS          (COLS),

        .DEPTH         (DEPTH),
        .ADDR_WIDTH    (ADDR_WIDTH),
        .K_SIZE_WIDTH  (K_SIZE_WIDTH),

        .C_INDEX_WIDTH (C_INDEX_WIDTH)
    ) u_controller (
        .clk         (clk),
        .reset       (reset),

        .start       (start),
        .tile_k_size (tile_k_size),

        .clear       (clear),

        .read_en     (read_en),
        .read_addr   (read_addr),

        .feed_valid  (feed_valid),

        .c_wen       (c_wen),
        .c_index     (c_index),

        .busy        (busy),
        .done        (done)
    );


    // ============================================================
    // 2. Scratchpad
    // ============================================================

    scratchpad #(
        .ROWS       (ROWS),
        .COLS       (COLS),

        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),

        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_scratchpad (
        .clk     (clk),

        // A
        .a_wen   (a_wen),
        .a_waddr (a_waddr),
        .a_wdata (a_wdata),

        // B
        .b_wen   (b_wen),
        .b_waddr (b_waddr),
        .b_wdata (b_wdata),

        // A/B shared read
        .ren     (read_en),
        .raddr   (read_addr),

        .a_rdata (a_rdata),
        .b_rdata (b_rdata),

        // C write
        .c_wen   (c_wen),
        .c_waddr (c_waddr),
        .c_wdata (c_wdata),

        // C external read
        .c_ren   (c_ren),
        .c_raddr (c_raddr),
        .c_rdata (c_rdata)
    );


    // ============================================================
    // 3. Unpack A SRAM word
    // ============================================================

    genvar i;

    generate

        for (i = 0; i < ROWS; i++) begin : GEN_A_UNPACK

            assign a_in[i] =
                $signed(
                    a_rdata[
                        i*DATA_WIDTH +: DATA_WIDTH
                    ]
                );

            assign a_valid_in[i] = feed_valid;

        end

    endgenerate


    // ============================================================
    // 4. Unpack B SRAM word
    // ============================================================

    generate

        for (i = 0; i < COLS; i++) begin : GEN_B_UNPACK

            assign b_in[i] =
                $signed(
                    b_rdata[
                        i*DATA_WIDTH +: DATA_WIDTH
                    ]
                );

            assign b_valid_in[i] = feed_valid;

        end

    endgenerate


    // ============================================================
    // 5. Matrix engine
    // ============================================================

    matrix_engine #(
        .ROWS (ROWS),
        .COLS (COLS)
    ) u_matrix_engine (
        .clk        (clk),
        .reset      (reset),

        .clear      (clear),

        .a_in       (a_in),
        .a_valid_in (a_valid_in),

        .b_in       (b_in),
        .b_valid_in (b_valid_in),

        .acc_out    (acc_out)
    );


    // ============================================================
    // 6. C writeback address
    //
    // Row-major:
    //
    // 0  1  2  3
    // 4  5  6  7
    // ...
    // ============================================================

    assign c_waddr = ADDR_WIDTH'(c_index);


    // ============================================================
    // 7. Select accumulator for writeback
    // ============================================================

    always_comb begin

        c_wdata = '0;

        for (int r = 0; r < ROWS; r++) begin

            for (int c = 0; c < COLS; c++) begin

                if (c_index == C_INDEX_WIDTH'(r * COLS + c)) begin

                    c_wdata = acc_out[r][c];

                end

            end

        end

    end


endmodule
