module gemm_address_generator #(
    parameter int unsigned ADDR_WIDTH       = 64,
    parameter int unsigned TILE_COUNT_WIDTH = 16,

    parameter int unsigned ROWS             = 4,
    parameter int unsigned COLS             = 4,

    parameter int unsigned DATA_WIDTH       = 8,
    parameter int unsigned ACC_WIDTH        = 32,

    parameter int unsigned K_TILE           = 256
) (
    input logic [ADDR_WIDTH-1:0]
        a_base,

    input logic [ADDR_WIDTH-1:0]
        b_base,

    input logic [ADDR_WIDTH-1:0]
        c_base,


    input logic [31:0]
        a_stride_bytes,

    input logic [31:0]
        b_stride_bytes,

    input logic [31:0]
        c_stride_bytes,


    input logic [TILE_COUNT_WIDTH-1:0]
        load_m_tile_idx,

    input logic [TILE_COUNT_WIDTH-1:0]
        load_n_tile_idx,

    input logic [TILE_COUNT_WIDTH-1:0]
        load_k_tile_idx,


    input logic [TILE_COUNT_WIDTH-1:0]
        compute_m_tile_idx,

    input logic [TILE_COUNT_WIDTH-1:0]
        compute_n_tile_idx,


    // 0: INT32 output
    // 1: INT8 output
    input logic
        c_int8_mode,


    output logic [ADDR_WIDTH-1:0]
        a_tile_addr,

    output logic [ADDR_WIDTH-1:0]
        b_tile_addr,

    output logic [ADDR_WIDTH-1:0]
        c_tile_addr
);


    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned ACC_BYTES =
        ACC_WIDTH / 8;


    logic [ADDR_WIDTH-1:0]
        c_element_bytes;


    always_comb begin

        if (c_int8_mode) begin

            c_element_bytes =
                ADDR_WIDTH'(1);

        end else begin

            c_element_bytes =
                ADDR_WIDTH'(ACC_BYTES);

        end


        // --------------------------------------------------------
        // A layout:
        //
        // A[M][K], row-major
        //
        // tile:
        // rows = load_m_tile_idx * ROWS
        // K    = load_k_tile_idx * K_TILE
        // --------------------------------------------------------

        a_tile_addr =
            a_base +
            (
                ADDR_WIDTH'(load_m_tile_idx) *
                ADDR_WIDTH'(ROWS) *
                ADDR_WIDTH'(a_stride_bytes)
            ) +
            (
                ADDR_WIDTH'(load_k_tile_idx) *
                ADDR_WIDTH'(K_TILE) *
                ADDR_WIDTH'(DATA_BYTES)
            );


        // --------------------------------------------------------
        // B is stored externally as B^T[N][K].
        // --------------------------------------------------------

        b_tile_addr =
            b_base +
            (
                ADDR_WIDTH'(load_n_tile_idx) *
                ADDR_WIDTH'(COLS) *
                ADDR_WIDTH'(b_stride_bytes)
            ) +
            (
                ADDR_WIDTH'(load_k_tile_idx) *
                ADDR_WIDTH'(K_TILE) *
                ADDR_WIDTH'(DATA_BYTES)
            );


        // --------------------------------------------------------
        // C[M][N]
        //
        // INT32 mode:
        //     4 bytes / element
        //
        // INT8 requant mode:
        //     1 byte / element
        // --------------------------------------------------------

        c_tile_addr =
            c_base +
            (
                ADDR_WIDTH'(compute_m_tile_idx) *
                ADDR_WIDTH'(ROWS) *
                ADDR_WIDTH'(c_stride_bytes)
            ) +
            (
                ADDR_WIDTH'(compute_n_tile_idx) *
                ADDR_WIDTH'(COLS) *
                c_element_bytes
            );

    end


    initial begin

        if (ADDR_WIDTH < 12) begin

            $fatal(
                1,
                "ADDR_WIDTH must be >= 12"
            );

        end


        if ((DATA_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "DATA_WIDTH must be byte aligned"
            );

        end


        if ((ACC_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "ACC_WIDTH must be byte aligned"
            );

        end


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


        if (K_TILE < 1) begin

            $fatal(
                1,
                "K_TILE must be >= 1"
            );

        end

    end

endmodule
