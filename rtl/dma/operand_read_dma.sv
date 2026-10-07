module operand_read_dma #(
    parameter int unsigned ADDR_WIDTH     = 64,
    parameter int unsigned ELEM_WIDTH     = 8,
    parameter int unsigned LANE_COUNT     = 4,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned K_DEPTH        = 256,
    parameter int unsigned BUFFER_COUNT   = 2,

    parameter int unsigned K_SIZE_WIDTH =
        $clog2(K_DEPTH + 1),

    parameter int unsigned ELEMS_PER_WORD =
        MEM_WORD_WIDTH / ELEM_WIDTH,

    parameter int unsigned WORD_DEPTH =
        (K_DEPTH + ELEMS_PER_WORD - 1) /
        ELEMS_PER_WORD,

    parameter int unsigned WORD_ADDR_WIDTH =
        (WORD_DEPTH <= 1) ?
        1 :
        $clog2(WORD_DEPTH),

    parameter int unsigned LANE_WIDTH =
        (LANE_COUNT <= 1) ?
        1 :
        $clog2(LANE_COUNT),

    parameter int unsigned BANK_WIDTH =
        (BUFFER_COUNT <= 1) ?
        1 :
        $clog2(BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // Tile load command
    //
    // base_addr:
    //   Address of the first element of lane/row 0 of this tile.
    //
    // stride_bytes:
    //   Physical byte distance between two matrix rows.
    //
    // load_size:
    //   Number of logical K elements in this tile.
    //
    // Example:
    //
    // A:
    // base =
    //   A_base +
    //   m_start * A_stride +
    //   k_start
    //
    // B^T:
    // base =
    //   B_base +
    //   n_start * B_stride +
    //   k_start
    // ============================================================

    input  logic                    load_req,
    output logic                    load_accept,

    input  logic [ADDR_WIDTH-1:0]   base_addr,
    input  logic [31:0]             stride_bytes,
    input  logic [K_SIZE_WIDTH-1:0] load_size,

    output logic load_done,
    output logic busy,
    output logic error,

    // ============================================================
    // Buffer manager
    // ============================================================

    output logic                  bank_load_req,
    input  logic                  bank_load_grant,
    input  logic [BANK_WIDTH-1:0] bank_load_bank,

    output logic bank_load_done,

    // ============================================================
    // Read request interface to shared axi_read_master
    // ============================================================

    output logic                  rd_req_valid,
    input  logic                  rd_req_ready,

    output logic [ADDR_WIDTH-1:0] rd_req_addr,
    output logic [31:0]           rd_req_beats,

    // ============================================================
    // Data returned from shared axi_read_master
    // ============================================================

    input  logic                      rd_data_valid,
    output logic                      rd_data_ready,
    input  logic [MEM_WORD_WIDTH-1:0] rd_data,
    input  logic                      rd_data_last,

    input  logic rd_done,
    input  logic rd_error,

    // ============================================================
    // Scratchpad write interface
    // ============================================================

    output logic                       buffer_wen,
    output logic [BANK_WIDTH-1:0]      buffer_wbank,
    output logic [LANE_WIDTH-1:0]      buffer_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] buffer_waddr,
    output logic [MEM_WORD_WIDTH-1:0]  buffer_wdata
);

    // ============================================================
    // Constants
    // ============================================================

    localparam int unsigned ELEM_BYTES =
        ELEM_WIDTH / 8;

    localparam int unsigned MEM_WORD_BYTES =
        MEM_WORD_WIDTH / 8;

    localparam logic [ADDR_WIDTH-1:0] ALIGN_MASK =
        ADDR_WIDTH'(MEM_WORD_BYTES - 1);

    localparam logic [31:0] ALIGN_MASK_32 =
        32'(MEM_WORD_BYTES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_LOADER,
        ST_TRANSFER,
        ST_ZERO_WAIT,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Locked command
    // ============================================================

    logic [ADDR_WIDTH-1:0] base_addr_q;
    logic [31:0]           stride_bytes_q;
    logic [31:0]           row_bytes_q;

    logic zero_size_q;


    // ============================================================
    // Completion tracking
    //
    // reader_done and loader_done do not have to occur in exactly
    // the same cycle, so remember each independently.
    // ============================================================

    logic reader_done_seen_q;
    logic loader_done_seen_q;


    // ============================================================
    // Internal loader interface
    // ============================================================

    logic                    loader_req;
    logic                    loader_accept;
    logic                    loader_done;
    logic                    loader_busy;

    logic                    loader_data_valid;
    logic                    loader_data_ready;
    logic [MEM_WORD_WIDTH-1:0] loader_data;


    // ============================================================
    // Internal strided reader interface
    // ============================================================

    logic reader_start;

    logic                  reader_out_valid;
    logic                  reader_out_ready;
    logic [MEM_WORD_WIDTH-1:0] reader_out_data;

    logic reader_busy;
    logic reader_done;
    logic reader_error;


    // ============================================================
    // Command validation
    //
    // Current baseline requires:
    //
    // - tile base aligned to memory word width
    // - row stride aligned to memory word width
    // - load_size <= K_DEPTH
    //
    // Physical row padding is handled by software/compiler through
    // stride_bytes.
    // ============================================================

    logic command_invalid;

    always_comb begin

        command_invalid = 1'b0;

        if (
            (base_addr & ALIGN_MASK) !=
            {ADDR_WIDTH{1'b0}}
        ) begin
            command_invalid = 1'b1;
        end

        if (
            (stride_bytes & ALIGN_MASK_32) !=
            32'd0
        ) begin
            command_invalid = 1'b1;
        end

        if (
            load_size >
            K_SIZE_WIDTH'(K_DEPTH)
        ) begin
            command_invalid = 1'b1;
        end

    end


    // ============================================================
    // Number of logical bytes in one row
    //
    // For current INT8 design:
    //
    // row_bytes = load_size
    //
    // Example:
    //
    // load_size = 256 -> 256 bytes
    // load_size = 44  -> 44 bytes
    //
    // strided_read_engine rounds this to complete AXI words.
    // ============================================================

    logic [31:0] row_bytes_calc;

    always_comb begin

        row_bytes_calc =
            32'(load_size) *
            32'(ELEM_BYTES);

    end


    // ============================================================
    // Loader request
    //
    // Do not allocate a buffer bank for an invalid command.
    // ============================================================

    assign loader_req =
        (state == ST_IDLE) &&
        load_req &&
        !command_invalid;


    // ============================================================
    // External command acceptance
    //
    // Invalid commands are still consumed, then return error.
    // ============================================================

    assign load_accept =
        (state == ST_IDLE) &&
        load_req &&
        (
            command_invalid ||
            loader_accept
        );


    // ============================================================
    // Start strided reader only after operand_loader has acquired
    // a destination buffer bank and entered RECEIVE state.
    //
    // loader_data_ready stays high in RECEIVE.
    // Because state changes immediately to ST_TRANSFER, this pulse
    // occurs for exactly one cycle.
    // ============================================================

    assign reader_start =
        (state == ST_WAIT_LOADER) &&
        loader_data_ready &&
        !zero_size_q;


    // ============================================================
    // Connect reader stream directly into operand_loader
    // ============================================================

    assign loader_data_valid =
        reader_out_valid;

    assign loader_data =
        reader_out_data;

    assign reader_out_ready =
        loader_data_ready;


    // ============================================================
    // Top-level status
    // ============================================================

    assign busy =
        (
            (state != ST_IDLE) &&
            (state != ST_DONE)
        ) ||
        loader_busy ||
        reader_busy;

    assign load_done =
        (state == ST_DONE);


    // ============================================================
    // Operand loader
    // ============================================================

    operand_loader #(
        .ELEM_WIDTH     (ELEM_WIDTH),
        .LANE_COUNT     (LANE_COUNT),
        .MEM_WORD_WIDTH (MEM_WORD_WIDTH),
        .K_DEPTH        (K_DEPTH),
        .BUFFER_COUNT   (BUFFER_COUNT)
    ) u_operand_loader (
        .clk             (clk),
        .reset           (reset),

        .load_req        (loader_req),
        .load_accept     (loader_accept),
        .load_size       (load_size),

        .load_done       (loader_done),
        .busy            (loader_busy),

        .bank_load_req   (bank_load_req),
        .bank_load_grant (bank_load_grant),
        .bank_load_bank  (bank_load_bank),
        .bank_load_done  (bank_load_done),

        .data_valid      (loader_data_valid),
        .data_ready      (loader_data_ready),
        .data            (loader_data),

        .buffer_wen      (buffer_wen),
        .buffer_wbank    (buffer_wbank),
        .buffer_wlane    (buffer_wlane),
        .buffer_waddr    (buffer_waddr),
        .buffer_wdata    (buffer_wdata)
    );


    // ============================================================
    // Strided read engine
    //
    // row_count is fixed to LANE_COUNT.
    //
    // A:
    // row_count = ROWS
    //
    // B^T:
    // row_count = COLS
    // ============================================================

    strided_read_engine #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (MEM_WORD_WIDTH)
    ) u_strided_reader (
        .clk           (clk),
        .reset         (reset),

        .start         (reader_start),

        .base_addr     (base_addr_q),
        .row_count     (32'(LANE_COUNT)),
        .bytes_per_row (row_bytes_q),
        .stride_bytes  (stride_bytes_q),

        .rd_req_valid  (rd_req_valid),
        .rd_req_ready  (rd_req_ready),

        .rd_req_addr   (rd_req_addr),
        .rd_req_beats  (rd_req_beats),

        .rd_data_valid (rd_data_valid),
        .rd_data_ready (rd_data_ready),
        .rd_data       (rd_data),
        .rd_data_last  (rd_data_last),

        .rd_done       (rd_done),
        .rd_error      (rd_error),

        .out_valid     (reader_out_valid),
        .out_ready     (reader_out_ready),
        .out_data      (reader_out_data),

        .busy          (reader_busy),
        .done          (reader_done),
        .error         (reader_error)
    );


    // ============================================================
    // Main controller
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= ST_IDLE;

            base_addr_q    <= '0;
            stride_bytes_q <= '0;
            row_bytes_q    <= '0;

            zero_size_q <= 1'b0;

            reader_done_seen_q <= 1'b0;
            loader_done_seen_q <= 1'b0;

            error <= 1'b0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (load_req) begin

                        if (command_invalid) begin

                            error <= 1'b1;

                            state <= ST_DONE;

                        end else if (loader_accept) begin

                            base_addr_q <=
                                base_addr;

                            stride_bytes_q <=
                                stride_bytes;

                            row_bytes_q <=
                                row_bytes_calc;

                            zero_size_q <=
                                (load_size == '0);

                            reader_done_seen_q <=
                                1'b0;

                            loader_done_seen_q <=
                                1'b0;

                            error <=
                                1'b0;


                            if (load_size == '0) begin

                                state <= ST_ZERO_WAIT;

                            end else begin

                                state <= ST_WAIT_LOADER;

                            end

                        end

                    end

                end


                // =================================================
                // WAIT UNTIL BUFFER BANK IS READY
                //
                // operand_loader:
                //
                // IDLE
                //   ->
                // ACQUIRE_BANK
                //   ->
                // RECEIVE
                //
                // loader_data_ready becomes 1 in RECEIVE.
                // =================================================

                ST_WAIT_LOADER: begin

                    if (loader_data_ready) begin

                        state <= ST_TRANSFER;

                    end

                end


                // =================================================
                // ACTIVE TRANSFER
                //
                // Reader:
                //
                // system memory -> stream
                //
                // Loader:
                //
                // stream -> lane SRAM
                // =================================================

                ST_TRANSFER: begin

                    if (reader_done) begin

                        reader_done_seen_q <=
                            1'b1;

                        if (reader_error) begin
                            error <= 1'b1;
                        end

                    end


                    if (loader_done) begin

                        loader_done_seen_q <=
                            1'b1;

                    end


                    if (
                        (
                            reader_done_seen_q ||
                            reader_done
                        ) &&
                        (
                            loader_done_seen_q ||
                            loader_done
                        )
                    ) begin

                        state <= ST_DONE;

                    end

                end


                // =================================================
                // ZERO-SIZE LOAD
                //
                // No memory request is generated.
                //
                // Wait until operand_loader completes its bank
                // transaction.
                // =================================================

                ST_ZERO_WAIT: begin

                    if (loader_done) begin

                        state <= ST_DONE;

                    end

                end


                // =================================================
                // DONE
                // =================================================

                ST_DONE: begin

                    state <= ST_IDLE;

                end


                // =================================================
                // Recovery
                // =================================================

                default: begin

                    state <= ST_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // Parameter checks
    // ============================================================

    initial begin

        if (ADDR_WIDTH < 12) begin
            $fatal(
                1,
                "ADDR_WIDTH must be >= 12"
            );
        end

        if (ELEM_WIDTH < 8) begin
            $fatal(
                1,
                "ELEM_WIDTH must be >= 8"
            );
        end

        if ((ELEM_WIDTH % 8) != 0) begin
            $fatal(
                1,
                "ELEM_WIDTH must be byte aligned"
            );
        end

        if (LANE_COUNT < 1) begin
            $fatal(
                1,
                "LANE_COUNT must be >= 1"
            );
        end

        if ((MEM_WORD_WIDTH % 8) != 0) begin
            $fatal(
                1,
                "MEM_WORD_WIDTH must be byte aligned"
            );
        end

        if (
            (MEM_WORD_WIDTH % ELEM_WIDTH) != 0
        ) begin
            $fatal(
                1,
                "MEM_WORD_WIDTH must be divisible by ELEM_WIDTH"
            );
        end

        if (
            (
                MEM_WORD_BYTES &
                (MEM_WORD_BYTES - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "MEM_WORD_BYTES must be a power of two"
            );
        end

        if (K_DEPTH < 1) begin
            $fatal(
                1,
                "K_DEPTH must be >= 1"
            );
        end

        if (
            (BUFFER_COUNT != 1) &&
            (BUFFER_COUNT != 2)
        ) begin
            $fatal(
                1,
                "BUFFER_COUNT must be 1 or 2"
            );
        end

    end

endmodule
