module gemm_core #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,
    parameter int DATA_WIDTH   = 8,
    parameter int ACC_WIDTH    = 32,

    parameter int A_BUFFER_COUNT = 1,
    parameter int B_BUFFER_COUNT = 1,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),

    parameter int ROW_INDEX_WIDTH =
        (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Local GEMM control
    // ============================================================

    input logic                    start,
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,

    input logic clear_acc,
    input logic writeback_en,

    output logic busy,
    output logic done,

    // Base address of current output tile in C Buffer
    input logic [ADDR_WIDTH-1:0] c_base_addr,

    // ============================================================
    // A Scratchpad preload
    // ============================================================

    input logic                       a_wen,
    input logic [ADDR_WIDTH-1:0]      a_waddr,
    input logic [ROWS*DATA_WIDTH-1:0] a_wdata,

    input logic a_wbank,
    input logic a_rbank,


    // ============================================================
    // B Scratchpad preload
    // ============================================================

    input logic                       b_wen,
    input logic [ADDR_WIDTH-1:0]      b_waddr,
    input logic [COLS*DATA_WIDTH-1:0] b_wdata,

    input logic b_wbank,
    input logic b_rbank,

    // ============================================================
    // C Buffer read
    // ============================================================

    input logic                       c_ren,
    input logic [ADDR_WIDTH-1:0]      c_raddr,
    output logic [COLS*ACC_WIDTH-1:0] c_rdata,

    // ============================================================
    // Debug
    // ============================================================

    output logic signed [ACC_WIDTH-1:0]
        acc_out [ROWS][COLS]
);

    logic clear;

    logic                  read_en;
    logic [ADDR_WIDTH-1:0] read_addr;
    logic                  feed_valid;

    logic                       c_wen;
    logic [ROW_INDEX_WIDTH-1:0] c_row;

    logic [ROWS*DATA_WIDTH-1:0] a_rdata;
    logic [COLS*DATA_WIDTH-1:0] b_rdata;

    logic signed [DATA_WIDTH-1:0] a_in [ROWS];
    logic signed [DATA_WIDTH-1:0] b_in [COLS];

    logic a_valid_in [ROWS];
    logic b_valid_in [COLS];

    logic [ADDR_WIDTH-1:0]     c_waddr;
    logic [COLS*ACC_WIDTH-1:0] c_wdata;


    // ============================================================
    // Matrix controller
    // ============================================================

    matrix_controller #(
        .ROWS            (ROWS),
        .COLS            (COLS),
        .DEPTH           (DEPTH),
        .ADDR_WIDTH      (ADDR_WIDTH),
        .K_SIZE_WIDTH    (K_SIZE_WIDTH),
        .ROW_INDEX_WIDTH (ROW_INDEX_WIDTH)
    ) u_controller (
        .clk          (clk),
        .reset        (reset),

        .start        (start),
        .tile_k_size  (tile_k_size),

        .clear_acc    (clear_acc),
        .writeback_en (writeback_en),

        .clear        (clear),

        .read_en      (read_en),
        .read_addr    (read_addr),
        .feed_valid   (feed_valid),

        .c_wen        (c_wen),
        .c_row        (c_row),

        .busy         (busy),
        .done         (done)
    );


    // ============================================================
    // Scratchpad
    // ============================================================

    scratchpad #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_scratchpad (
        .clk     (clk),

        .a_wen   (a_wen),
        .a_waddr (a_waddr),
        .a_wdata (a_wdata),
        .a_wbank (a_wbank),
        .a_rbank (a_rbank),



        .b_wen   (b_wen),
        .b_waddr (b_waddr),
        .b_wdata (b_wdata),
        .b_wbank (b_wbank),
        .b_rbank (b_rbank),

        .ren     (read_en),
        .raddr   (read_addr),

        .a_rdata (a_rdata),
        .b_rdata (b_rdata),

        .c_wen   (c_wen),
        .c_waddr (c_waddr),
        .c_wdata (c_wdata),

        .c_ren   (c_ren),
        .c_raddr (c_raddr),
        .c_rdata (c_rdata)
    );


    // ============================================================
    // A unpack
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
    // B unpack
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
    // Matrix engine
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
    // C Buffer address
    //
    // Each output tile occupies ROWS addresses.
    // ============================================================

    assign c_waddr =
        c_base_addr + ADDR_WIDTH'(c_row);


    // ============================================================
    // Pack one result row
    // ============================================================

    always_comb begin

        c_wdata = '0;

        for (int r = 0; r < ROWS; r++) begin

            if (c_row == ROW_INDEX_WIDTH'(r)) begin

                for (int c = 0; c < COLS; c++) begin

                    c_wdata[
                        c*ACC_WIDTH +: ACC_WIDTH
                    ] = acc_out[r][c];

                end

            end

        end

    end

endmodule
