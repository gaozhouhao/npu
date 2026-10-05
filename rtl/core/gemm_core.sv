module gemm_core #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,
    parameter int DATA_WIDTH   = 8,
    parameter int ACC_WIDTH    = 32,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // GEMM control
    //
    // tile_k_size:
    // 当前装入 scratchpad 的 local K tile 大小
    // 0 ~ DEPTH
    // ============================================================

    input logic                    start,
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,

    output logic busy,
    output logic done,


    // ============================================================
    // Scratchpad preload ports
    // ============================================================

    input logic                           a_wen,
    input logic [ADDR_WIDTH-1:0]          a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0]     a_wdata,

    input logic                           b_wen,
    input logic [ADDR_WIDTH-1:0]          b_waddr,
    input logic [COLS*DATA_WIDTH-1:0]     b_wdata,


    // ============================================================
    // GEMM result
    // ============================================================

    output logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS]
);


    // ============================================================
    // Controller <-> Scratchpad
    // ============================================================

    logic clear;

    logic read_en;

    // SRAM真正的地址
    logic [ADDR_WIDTH-1:0] read_addr;

    // SRAM response data valid
    logic feed_valid;


    // ============================================================
    // Scratchpad read side
    // ============================================================

    logic [ROWS*DATA_WIDTH-1:0] a_rdata;
    logic [COLS*DATA_WIDTH-1:0] b_rdata;


    // ============================================================
    // Matrix engine inputs
    // ============================================================

    logic signed [DATA_WIDTH-1:0] a_in [ROWS];
    logic signed [DATA_WIDTH-1:0] b_in [COLS];

    logic a_valid_in [ROWS];
    logic b_valid_in [COLS];


    // ============================================================
    // 1. Matrix controller
    // ============================================================

    matrix_controller #(
        .ROWS         (ROWS),
        .COLS         (COLS),
        .DEPTH        (DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .K_SIZE_WIDTH (K_SIZE_WIDTH)
    ) u_controller (
        .clk         (clk),
        .reset       (reset),

        .start       (start),
        .tile_k_size (tile_k_size),

        .clear       (clear),

        .read_en     (read_en),
        .read_addr   (read_addr),

        .feed_valid  (feed_valid),

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
        .ADDR_WIDTH (ADDR_WIDTH),
        .DEPTH      (DEPTH)
    ) u_scratchpad (
        .clk     (clk),

        // A write
        .a_wen   (a_wen),
        .a_waddr (a_waddr),
        .a_wdata (a_wdata),

        // B write
        .b_wen   (b_wen),
        .b_waddr (b_waddr),
        .b_wdata (b_wdata),

        // Shared read
        .ren     (read_en),
        .raddr   (read_addr),

        .a_rdata (a_rdata),
        .b_rdata (b_rdata)
    );


    // ============================================================
    // 3. Unpack SRAM word -> Matrix Engine lanes
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
    // 4. Matrix engine
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


endmodule

