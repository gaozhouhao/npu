module gemm_core #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,
    parameter int DATA_WIDTH   = 8,
    parameter int ACC_WIDTH    = 32,

    parameter int A_BUFFER_COUNT = 1,
    parameter int B_BUFFER_COUNT = 1,

    // Logical K capacity
    parameter int DEPTH        = 256,

    // Logical K address width
    parameter int ADDR_WIDTH   =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH),

    parameter int K_SIZE_WIDTH =
        $clog2(DEPTH + 1),

    // ============================================================
    // Physical operand SRAM organization
    //
    // Current configuration:
    //
    // DATA_WIDTH     = 8
    // MEM_WORD_WIDTH = 32
    //
    // Each SRAM word therefore stores 4 consecutive K elements.
    // ============================================================

    parameter int MEM_WORD_WIDTH = 32,

    parameter int ELEMS_PER_WORD =
        MEM_WORD_WIDTH / DATA_WIDTH,

    parameter int WORD_DEPTH =
        (DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    // ============================================================
    // Lane index widths
    // ============================================================

    parameter int A_LANE_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS),

    parameter int B_LANE_WIDTH =
        (COLS <= 1) ?
        1 :
        $clog2(COLS),

    parameter int ROW_INDEX_WIDTH =
        (ROWS <= 1) ?
        1 :
        $clog2(ROWS)

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
    //
    // New physical organization:
    //
    // a_wlane selects one PE-row lane SRAM.
    //
    // Example:
    //
    // a_wlane = 0
    // a_waddr = 0
    // a_wdata = {A[0][3], A[0][2], A[0][1], A[0][0]}
    //
    // a_wlane = 0
    // a_waddr = 1
    // a_wdata = {A[0][7], A[0][6], A[0][5], A[0][4]}
    //
    // Then:
    //
    // a_wlane = 1
    // ...
    // ============================================================

    input logic                        a_wen,
    input logic [A_LANE_WIDTH-1:0]     a_wlane,
    input logic [WORD_ADDR_WIDTH-1:0]  a_waddr,
    input logic [MEM_WORD_WIDTH-1:0]   a_wdata,

    input logic a_wbank,
    input logic a_rbank,

    // ============================================================
    // B Scratchpad preload
    //
    // B is stored externally as B^T.
    //
    // Therefore each B lane is also contiguous along K.
    //
    // Example:
    //
    // b_wlane = 0
    // b_wdata =
    // {
    //     B[3][n0],
    //     B[2][n0],
    //     B[1][n0],
    //     B[0][n0]
    // }
    // ============================================================

    input logic                        b_wen,
    input logic [B_LANE_WIDTH-1:0]     b_wlane,
    input logic [WORD_ADDR_WIDTH-1:0]  b_waddr,
    input logic [MEM_WORD_WIDTH-1:0]   b_wdata,

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


    // ============================================================
    // Matrix controller signals
    // ============================================================

    logic clear;

    logic                  read_en;
    logic [ADDR_WIDTH-1:0] read_addr;
    logic                  feed_valid;

    logic                       c_wen;
    logic [ROW_INDEX_WIDTH-1:0] c_row;


    // ============================================================
    // Scratchpad compute-side data
    //
    // The physical SRAM organization is hidden inside scratchpad /
    // operand_buffer.
    //
    // Compute side still sees:
    //
    // A:
    // {A[ROWS-1][k], ..., A[1][k], A[0][k]}
    //
    // B:
    // {B[k][COLS-1], ..., B[k][1], B[k][0]}
    // ============================================================

    logic [ROWS*DATA_WIDTH-1:0] a_rdata;
    logic [COLS*DATA_WIDTH-1:0] b_rdata;


    // ============================================================
    // Matrix-engine input lanes
    // ============================================================

    logic signed [DATA_WIDTH-1:0] a_in [ROWS];
    logic signed [DATA_WIDTH-1:0] b_in [COLS];

    logic a_valid_in [ROWS];
    logic b_valid_in [COLS];


    // ============================================================
    // C Buffer write path
    // ============================================================

    logic [ADDR_WIDTH-1:0]     c_waddr;
    logic [COLS*ACC_WIDTH-1:0] c_wdata;


    // ============================================================
    // Matrix controller
    //
    // read_addr remains the LOGICAL K index:
    //
    // 0, 1, 2, 3, ...
    //
    // It does not know about the new SRAM word organization.
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
    //
    // A/B physical organization:
    //
    // A:
    // ROWS lane SRAMs
    //
    // B:
    // COLS lane SRAMs
    //
    // Each lane SRAM word is MEM_WORD_WIDTH bits.
    //
    // The scratchpad converts logical read_addr (K index) into:
    //
    // word_addr = K / ELEMS_PER_WORD
    // elem_sel  = K % ELEMS_PER_WORD
    //
    // and reconstructs the original PE input vectors.
    // ============================================================

    scratchpad #(
        .ROWS           (ROWS),
        .COLS           (COLS),

        .A_BUFFER_COUNT (A_BUFFER_COUNT),
        .B_BUFFER_COUNT (B_BUFFER_COUNT),

        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),

        .DEPTH          (DEPTH),
        .ADDR_WIDTH     (ADDR_WIDTH),

        .MEM_WORD_WIDTH (MEM_WORD_WIDTH)
    ) u_scratchpad (
        .clk     (clk),

        // --------------------------------------------------------
        // A preload
        // --------------------------------------------------------

        .a_wen   (a_wen),
        .a_wbank (a_wbank),
        .a_wlane (a_wlane),
        .a_waddr (a_waddr),
        .a_wdata (a_wdata),

        .a_rbank (a_rbank),

        // --------------------------------------------------------
        // B preload
        // --------------------------------------------------------

        .b_wen   (b_wen),
        .b_wbank (b_wbank),
        .b_wlane (b_wlane),
        .b_waddr (b_waddr),
        .b_wdata (b_wdata),

        .b_rbank (b_rbank),

        // --------------------------------------------------------
        // Logical K read
        // --------------------------------------------------------

        .ren     (read_en),
        .raddr   (read_addr),

        .a_rdata (a_rdata),
        .b_rdata (b_rdata),

        // --------------------------------------------------------
        // C Buffer
        // --------------------------------------------------------

        .c_wen   (c_wen),
        .c_waddr (c_waddr),
        .c_wdata (c_wdata),

        .c_ren   (c_ren),
        .c_raddr (c_raddr),
        .c_rdata (c_rdata)
    );


    // ============================================================
    // A unpack
    //
    // scratchpad gives:
    //
    // a_rdata =
    // {
    //     A[ROWS-1][k],
    //     ...
    //     A[1][k],
    //     A[0][k]
    // }
    //
    // This interface is intentionally unchanged from the previous
    // GEMM datapath.
    // ============================================================

    genvar i;

    generate

        for (
            i = 0;
            i < ROWS;
            i = i + 1
        ) begin : GEN_A_UNPACK

            assign a_in[i] =
                $signed(
                    a_rdata[
                        i * DATA_WIDTH
                        +:
                        DATA_WIDTH
                    ]
                );

            assign a_valid_in[i] =
                feed_valid;

        end

    endgenerate


    // ============================================================
    // B unpack
    //
    // scratchpad gives:
    //
    // b_rdata =
    // {
    //     B[k][COLS-1],
    //     ...
    //     B[k][1],
    //     B[k][0]
    // }
    // ============================================================

    generate

        for (
            i = 0;
            i < COLS;
            i = i + 1
        ) begin : GEN_B_UNPACK

            assign b_in[i] =
                $signed(
                    b_rdata[
                        i * DATA_WIDTH
                        +:
                        DATA_WIDTH
                    ]
                );

            assign b_valid_in[i] =
                feed_valid;

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
    //
    // Example:
    //
    // C tile base = 8
    //
    // row0 -> C[8]
    // row1 -> C[9]
    // row2 -> C[10]
    // row3 -> C[11]
    // ============================================================

    assign c_waddr =
        c_base_addr +
        ADDR_WIDTH'(c_row);


    // ============================================================
    // Pack one result row
    //
    // One C Buffer address contains COLS INT32 values.
    // ============================================================

    integer r_idx;
    integer c_idx;

    always_comb begin

        c_wdata = '0;

        for (
            r_idx = 0;
            r_idx < ROWS;
            r_idx = r_idx + 1
        ) begin

            if (
                c_row ==
                ROW_INDEX_WIDTH'(r_idx)
            ) begin

                for (
                    c_idx = 0;
                    c_idx < COLS;
                    c_idx = c_idx + 1
                ) begin

                    c_wdata[
                        c_idx * ACC_WIDTH
                        +:
                        ACC_WIDTH
                    ] =
                        acc_out[
                            r_idx
                        ][
                            c_idx
                        ];

                end

            end

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ROWS < 1) begin

            $fatal(
                1,
                "ROWS must be >= 1"
            );

        end


        if (COLS < 1) begin

            $fatal(
                1,
                "COLS must be >= 1"
            );

        end


        if (DATA_WIDTH < 1) begin

            $fatal(
                1,
                "DATA_WIDTH must be >= 1"
            );

        end


        if (ACC_WIDTH < 1) begin

            $fatal(
                1,
                "ACC_WIDTH must be >= 1"
            );

        end


        if (DEPTH < 1) begin

            $fatal(
                1,
                "DEPTH must be >= 1"
            );

        end


        if (
            (A_BUFFER_COUNT != 1) &&
            (A_BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "A_BUFFER_COUNT must be 1 or 2"
            );

        end


        if (
            (B_BUFFER_COUNT != 1) &&
            (B_BUFFER_COUNT != 2)
        ) begin

            $fatal(
                1,
                "B_BUFFER_COUNT must be 1 or 2"
            );

        end


        if (
            (MEM_WORD_WIDTH % DATA_WIDTH) != 0
        ) begin

            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by DATA_WIDTH"
            );

        end


        if (
            (
                ELEMS_PER_WORD &
                (ELEMS_PER_WORD - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "ELEMS_PER_WORD must be a power of two"
            );

        end

    end

endmodule
