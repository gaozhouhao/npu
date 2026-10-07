module strided_read_engine #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 32
) (
    input logic clk,
    input logic reset,

    // ============================================================
    // 2D / strided read command
    //
    // base_addr:
    //   First byte address of row 0.
    //
    // row_count:
    //   Number of rows to read.
    //
    // bytes_per_row:
    //   Number of LOGICAL valid bytes in each row.
    //
    // stride_bytes:
    //   Physical byte distance between two row starts.
    //
    // Example:
    //
    // A tile:
    //
    // base_addr =
    //     A_base
    //     + m_start * A_stride
    //     + k_start
    //
    // row_count     = ROWS
    // bytes_per_row = current_k_size
    // stride_bytes  = A_stride
    // ============================================================

    input  logic                  start,
    input  logic [ADDR_WIDTH-1:0] base_addr,
    input  logic [31:0]           row_count,
    input  logic [31:0]           bytes_per_row,
    input  logic [31:0]           stride_bytes,

    // ============================================================
    // Request interface to axi_read_master
    // ============================================================

    output logic                  rd_req_valid,
    input  logic                  rd_req_ready,

    output logic [ADDR_WIDTH-1:0] rd_req_addr,
    output logic [31:0]           rd_req_beats,

    // ============================================================
    // Data returned by axi_read_master
    // ============================================================

    input  logic                  rd_data_valid,
    output logic                  rd_data_ready,

    input  logic [DATA_WIDTH-1:0] rd_data,
    input  logic                  rd_data_last,

    input  logic                  rd_done,
    input  logic                  rd_error,

    // ============================================================
    // Output stream to operand_loader
    //
    // Ordering:
    //
    // row0 word0
    // row0 word1
    // ...
    // row1 word0
    // row1 word1
    // ...
    //
    // This exactly matches the new lane-bank loader.
    // ============================================================

    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [DATA_WIDTH-1:0] out_data,

    // ============================================================
    // Status
    // ============================================================

    output logic busy,
    output logic done,
    output logic error
);

    // ============================================================
    // Constants
    // ============================================================

    localparam int unsigned DATA_BYTES =
        DATA_WIDTH / 8;

    localparam int unsigned BYTE_SHIFT =
        $clog2(DATA_BYTES);

    localparam logic [ADDR_WIDTH-1:0] ALIGN_MASK =
        ADDR_WIDTH'(DATA_BYTES - 1);

    localparam logic [31:0] ALIGN_MASK_32 =
        32'(DATA_BYTES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_REQ,
        ST_DATA,
        ST_WAIT_DONE,
        ST_DONE
    } state_t;

    state_t state;


    // ============================================================
    // Locked command
    // ============================================================

    logic [31:0] row_count_q;
    logic [31:0] stride_bytes_q;

    logic [31:0] beats_per_row_q;


    // ============================================================
    // Current row tracking
    // ============================================================

    logic [31:0] row_idx_q;

    logic [ADDR_WIDTH-1:0] current_row_addr_q;


    // ============================================================
    // Calculate number of full AXI beats for one logical row
    //
    // ceil(bytes_per_row / DATA_BYTES)
    //
    // Example with 32-bit AXI:
    //
    // 256 bytes -> 64 beats
    // 44 bytes  -> 11 beats
    // 16 bytes  -> 4 beats
    //
    // A non-word-aligned tail is automatically rounded up and the
    // final beat may contain physical padding bytes.
    // ============================================================

    logic [31:0] beats_per_row_calc;

    always_comb begin

        beats_per_row_calc =
            (
                bytes_per_row +
                32'(DATA_BYTES - 1)
            ) >> BYTE_SHIFT;

    end


    // ============================================================
    // AXI-master request
    // ============================================================

    assign rd_req_valid =
        (state == ST_REQ);

    assign rd_req_addr =
        current_row_addr_q;

    assign rd_req_beats =
        beats_per_row_q;


    // ============================================================
    // Data forwarding
    //
    // Backpressure from operand_loader propagates all the way to
    // the AXI R channel through axi_read_master.
    // ============================================================

    assign out_valid =
        (state == ST_DATA) &&
        rd_data_valid;

    assign out_data =
        rd_data;

    assign rd_data_ready =
        (state == ST_DATA) &&
        out_ready;


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != ST_IDLE) &&
        (state != ST_DONE);

    assign done =
        (state == ST_DONE);


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (reset) begin

            state <= ST_IDLE;

            row_count_q <= '0;
            stride_bytes_q <= '0;
            beats_per_row_q <= '0;

            row_idx_q <= '0;
            current_row_addr_q <= '0;

            error <= 1'b0;

        end else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (start) begin

                        row_count_q <=
                            row_count;

                        stride_bytes_q <=
                            stride_bytes;

                        beats_per_row_q <=
                            beats_per_row_calc;

                        row_idx_q <= '0;

                        current_row_addr_q <=
                            base_addr;

                        error <= 1'b0;


                        // -----------------------------------------
                        // Empty transfer
                        // -----------------------------------------

                        if (
                            (row_count == 32'd0) ||
                            (bytes_per_row == 32'd0)
                        ) begin

                            state <= ST_DONE;

                        end else if (
                            (base_addr & ALIGN_MASK) !=
                            {ADDR_WIDTH{1'b0}}
                        ) begin

                            // -------------------------------------
                            // First row must start on an AXI word
                            // boundary.
                            // -------------------------------------

                            error <= 1'b1;
                            state <= ST_DONE;

                        end else if (
                            (stride_bytes & ALIGN_MASK_32) !=
                            32'd0
                        ) begin

                            // -------------------------------------
                            // Physical row stride must also preserve
                            // AXI-word alignment for following rows.
                            // -------------------------------------

                            error <= 1'b1;
                            state <= ST_DONE;

                        end else begin

                            state <= ST_REQ;

                        end

                    end

                end


                // =================================================
                // REQUEST CURRENT ROW
                //
                // axi_read_master may internally split this request
                // into multiple legal AXI bursts because of:
                //
                // - 256-beat limit
                // - 4KB boundary
                // =================================================

                ST_REQ: begin

                    if (
                        rd_req_valid &&
                        rd_req_ready
                    ) begin

                        state <= ST_DATA;

                    end

                end


                // =================================================
                // FORWARD CURRENT ROW DATA
                // =================================================

                ST_DATA: begin

                    if (
                        rd_data_valid &&
                        rd_data_ready &&
                        rd_data_last
                    ) begin

                        // The low-level AXI engine enters its DONE
                        // state after accepting this final beat.
                        //
                        // Wait one stage so its final error status
                        // is visible before advancing.

                        state <= ST_WAIT_DONE;

                    end

                end


                // =================================================
                // WAIT FOR AXI REQUEST COMPLETION
                // =================================================

                ST_WAIT_DONE: begin

                    if (rd_done) begin

                        if (rd_error) begin

                            error <= 1'b1;

                            // Abort the complete strided transfer if
                            // one row encounters an AXI error.

                            state <= ST_DONE;

                        end else if (
                            row_idx_q ==
                            (row_count_q - 32'd1)
                        ) begin

                            // -------------------------------------
                            // Last row completed
                            // -------------------------------------

                            state <= ST_DONE;

                        end else begin

                            // -------------------------------------
                            // Advance to next physical row
                            //
                            // addr(next) =
                            // addr(current) + stride
                            // -------------------------------------

                            row_idx_q <=
                                row_idx_q + 32'd1;

                            current_row_addr_q <=
                                current_row_addr_q +
                                ADDR_WIDTH'(stride_bytes_q);

                            state <= ST_REQ;

                        end

                    end

                end


                // =================================================
                // DONE
                //
                // One-cycle completion pulse.
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


        if (DATA_WIDTH < 8) begin

            $fatal(
                1,
                "DATA_WIDTH must be >= 8"
            );

        end


        if ((DATA_WIDTH % 8) != 0) begin

            $fatal(
                1,
                "DATA_WIDTH must be byte aligned"
            );

        end


        if (
            (
                DATA_BYTES &
                (DATA_BYTES - 1)
            ) != 0
        ) begin

            $fatal(
                1,
                "DATA_BYTES must be a power of two"
            );

        end

    end

endmodule
