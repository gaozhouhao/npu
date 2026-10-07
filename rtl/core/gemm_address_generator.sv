module gemm_address_generator #(
    parameter int unsigned ADDR_WIDTH       = 64,
    parameter int unsigned TILE_COUNT_WIDTH = 16,

    parameter int unsigned ROWS       = 4,
    parameter int unsigned COLS       = 4,

    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 32,

    parameter int unsigned K_TILE     = 256
) (
    input logic [ADDR_WIDTH-1:0] a_base,
    input logic [ADDR_WIDTH-1:0] b_base,
    input logic [ADDR_WIDTH-1:0] c_base,

    input logic [31:0] a_stride_bytes,
    input logic [31:0] b_stride_bytes,
    input logic [31:0] c_stride_bytes,

    // ============================================================
    // Tile currently being loaded
    // ============================================================

    input logic [TILE_COUNT_WIDTH-1:0] load_m_tile_idx,
    input logic [TILE_COUNT_WIDTH-1:0] load_n_tile_idx,
    input logic [TILE_COUNT_WIDTH-1:0] load_k_tile_idx,

    // ============================================================
    // Tile currently being computed
    // ============================================================

    input logic [TILE_COUNT_WIDTH-1:0] compute_m_tile_idx,
    input logic [TILE_COUNT_WIDTH-1:0] compute_n_tile_idx,

    // ============================================================
    // Generated external-memory addresses
    // ============================================================

    output logic [ADDR_WIDTH-1:0] a_tile_addr,
    output logic [ADDR_WIDTH-1:0] b_tile_addr,
    output logic [ADDR_WIDTH-1:0] c_tile_addr
);


    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned ACC_BYTES =
        ACC_WIDTH / 8;


    logic [63:0] load_m_start;
    logic [63:0] load_n_start;
    logic [63:0] load_k_start;

    logic [63:0] compute_m_start;
    logic [63:0] compute_n_start;


    logic [63:0] a_addr_calc;
    logic [63:0] b_addr_calc;
    logic [63:0] c_addr_calc;


    always_comb begin

        load_m_start =
            64'(load_m_tile_idx) *
            64'(ROWS);

        load_n_start =
            64'(load_n_tile_idx) *
            64'(COLS);

        load_k_start =
            64'(load_k_tile_idx) *
            64'(K_TILE);


        compute_m_start =
            64'(compute_m_tile_idx) *
            64'(ROWS);

        compute_n_start =
            64'(compute_n_tile_idx) *
            64'(COLS);


        // --------------------------------------------------------
        // A is M x K row-major
        // --------------------------------------------------------

        a_addr_calc =
            64'(a_base) +
            (
                load_m_start *
                64'(a_stride_bytes)
            ) +
            (
                load_k_start *
                64'(DATA_BYTES)
            );


        // --------------------------------------------------------
        // External B is stored as B^T:
        //
        // N x K row-major
        // --------------------------------------------------------

        b_addr_calc =
            64'(b_base) +
            (
                load_n_start *
                64'(b_stride_bytes)
            ) +
            (
                load_k_start *
                64'(DATA_BYTES)
            );


        // --------------------------------------------------------
        // C is M x N INT32 row-major
        // --------------------------------------------------------

        c_addr_calc =
            64'(c_base) +
            (
                compute_m_start *
                64'(c_stride_bytes)
            ) +
            (
                compute_n_start *
                64'(ACC_BYTES)
            );


        a_tile_addr =
            ADDR_WIDTH'(a_addr_calc);

        b_tile_addr =
            ADDR_WIDTH'(b_addr_calc);

        c_tile_addr =
            ADDR_WIDTH'(c_addr_calc);

    end


    initial begin

        if (
            (DATA_WIDTH % 8) !=
            0
        ) begin

            $fatal(
                1,
                "DATA_WIDTH must be byte aligned"
            );

        end


        if (
            (ACC_WIDTH % 8) !=
            0
        ) begin

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
