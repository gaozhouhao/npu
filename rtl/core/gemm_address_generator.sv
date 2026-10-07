module gemm_address_generator #(
    parameter int unsigned ADDR_WIDTH = 64,

    parameter int unsigned ROWS       = 4,
    parameter int unsigned COLS       = 4,

    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 32,

    parameter int unsigned TILE_COUNT_WIDTH = 16,

    parameter int unsigned K_TILE     = 256
) (
    // ============================================================
    // Matrix base addresses
    //
    // B_base points to B^T, not original B.
    // ============================================================

    input logic [ADDR_WIDTH-1:0] a_base,
    input logic [ADDR_WIDTH-1:0] b_base,
    input logic [ADDR_WIDTH-1:0] c_base,

    // ============================================================
    // Physical row strides in bytes
    // ============================================================

    input logic [31:0] a_stride_bytes,
    input logic [31:0] b_stride_bytes,
    input logic [31:0] c_stride_bytes,

    // ============================================================
    // Current tile indices
    // ============================================================

    input logic [TILE_COUNT_WIDTH-1:0] m_tile_idx,
    input logic [TILE_COUNT_WIDTH-1:0] n_tile_idx,
    input logic [TILE_COUNT_WIDTH-1:0] k_tile_idx,

    // ============================================================
    // Generated addresses
    // ============================================================

    output logic [ADDR_WIDTH-1:0] a_tile_addr,
    output logic [ADDR_WIDTH-1:0] b_tile_addr,
    output logic [ADDR_WIDTH-1:0] c_tile_addr
);

    // ============================================================
    // Element sizes
    // ============================================================

    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned ACC_BYTES =
        ACC_WIDTH / 8;


    // ============================================================
    // Tile starts in logical matrix coordinates
    //
    // m_start = m_tile_idx * ROWS
    // n_start = n_tile_idx * COLS
    // k_start = k_tile_idx * K_TILE
    // ============================================================

    logic [63:0] m_start;
    logic [63:0] n_start;
    logic [63:0] k_start;


    // ============================================================
    // Byte offsets
    // ============================================================

    logic [63:0] a_row_offset;
    logic [63:0] a_k_offset;

    logic [63:0] b_row_offset;
    logic [63:0] b_k_offset;

    logic [63:0] c_row_offset;
    logic [63:0] c_col_offset;


    // ============================================================
    // Logical tile coordinate generation
    // ============================================================

    always_comb begin

        m_start =
            64'(m_tile_idx) *
            64'(ROWS);

        n_start =
            64'(n_tile_idx) *
            64'(COLS);

        k_start =
            64'(k_tile_idx) *
            64'(K_TILE);

    end


    // ============================================================
    // A address
    //
    // A is M x K row-major.
    //
    // A_tile =
    //
    // A_base
    // + m_start * A_stride
    // + k_start * DATA_BYTES
    // ============================================================

    always_comb begin

        a_row_offset =
            m_start *
            64'(a_stride_bytes);

        a_k_offset =
            k_start *
            64'(DATA_BYTES);

        a_tile_addr =
            a_base +
            ADDR_WIDTH'(
                a_row_offset +
                a_k_offset
            );

    end


    // ============================================================
    // B address
    //
    // External memory stores B^T as N x K row-major.
    //
    // B_tile =
    //
    // B_base
    // + n_start * B_stride
    // + k_start * DATA_BYTES
    // ============================================================

    always_comb begin

        b_row_offset =
            n_start *
            64'(b_stride_bytes);

        b_k_offset =
            k_start *
            64'(DATA_BYTES);

        b_tile_addr =
            b_base +
            ADDR_WIDTH'(
                b_row_offset +
                b_k_offset
            );

    end


    // ============================================================
    // C address
    //
    // C is M x N row-major, INT32 by default.
    //
    // C_tile =
    //
    // C_base
    // + m_start * C_stride
    // + n_start * ACC_BYTES
    // ============================================================

    always_comb begin

        c_row_offset =
            m_start *
            64'(c_stride_bytes);

        c_col_offset =
            n_start *
            64'(ACC_BYTES);

        c_tile_addr =
            c_base +
            ADDR_WIDTH'(
                c_row_offset +
                c_col_offset
            );

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ADDR_WIDTH > 64) begin

            $fatal(
                1,
                "ADDR_WIDTH > 64 is not supported"
            );

        end


        if (ADDR_WIDTH < 12) begin

            $fatal(
                1,
                "ADDR_WIDTH must be >= 12"
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

    end

endmodule
