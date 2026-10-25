// One local GEMM tile: operand SRAMs -> matrix controller/array -> result SRAM.
module gemm_tile_compute #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32,
    parameter int A_BUFFER_COUNT = 1,
    parameter int B_BUFFER_COUNT = 1,
    parameter int DEPTH = 256,
    parameter int ADDR_WIDTH = ((DEPTH > ROWS ? DEPTH : ROWS) <= 1) ? 1 :
        $clog2(DEPTH > ROWS ? DEPTH : ROWS),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1),
    parameter int MEM_WORD_WIDTH = 32,
    parameter int ELEMS_PER_WORD = MEM_WORD_WIDTH / DATA_WIDTH,
    parameter int WORD_DEPTH = (DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD,
    parameter int WORD_ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),
    parameter int A_LANE_WIDTH = (ROWS <= 1) ? 1 : $clog2(ROWS),
    parameter int B_LANE_WIDTH = (COLS <= 1) ? 1 : $clog2(COLS),
    parameter int ROW_INDEX_WIDTH = (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
    input logic clk,
    input logic reset,
    input logic start,
    input logic [K_SIZE_WIDTH-1:0] tile_k_size,
    input logic clear_acc,
    input logic writeback_en,
    output logic busy,
    output logic done,
    input logic [ADDR_WIDTH-1:0] c_base_addr,

    // DMA writes one packed K word to one row/column lane at a time.
    input logic a_wen,
    input logic [A_LANE_WIDTH-1:0] a_wlane,
    input logic [WORD_ADDR_WIDTH-1:0] a_waddr,
    input logic [MEM_WORD_WIDTH-1:0] a_wdata,
    input logic a_wbank,
    input logic a_rbank,
    input logic b_wen,
    input logic [B_LANE_WIDTH-1:0] b_wlane,
    input logic [WORD_ADDR_WIDTH-1:0] b_waddr,
    input logic [MEM_WORD_WIDTH-1:0] b_wdata,
    input logic b_wbank,
    input logic b_rbank,

    // One result SRAM address contains COLS signed accumulators.
    input logic c_ren,
    input logic [ADDR_WIDTH-1:0] c_raddr,
    output logic [COLS*ACC_WIDTH-1:0] c_rdata,
    output logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS]
);
    logic matrix_clear;
    logic operand_read_enable;
    logic [ADDR_WIDTH-1:0] operand_k_index;
    logic operand_valid;
    logic [ROWS*DATA_WIDTH-1:0] operand_a_data;
    logic [COLS*DATA_WIDTH-1:0] operand_b_data;
    logic signed [DATA_WIDTH-1:0] matrix_a_data [ROWS];
    logic signed [DATA_WIDTH-1:0] matrix_b_data [COLS];
    logic matrix_a_valid [ROWS];
    logic matrix_b_valid [COLS];
    logic result_write_enable;
    logic [ROW_INDEX_WIDTH-1:0] result_row;
    logic [ADDR_WIDTH-1:0] result_write_addr;
    logic [COLS*ACC_WIDTH-1:0] result_write_data;

    gemm_cycle_controller #(
        .ROWS(ROWS), .COLS(COLS), .DEPTH(DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH), .K_SIZE_WIDTH(K_SIZE_WIDTH),
        .ROW_INDEX_WIDTH(ROW_INDEX_WIDTH)
    ) u_controller (
        .clk(clk), .reset(reset), .start(start), .tile_k_size(tile_k_size),
        .clear_acc(clear_acc), .writeback_en(writeback_en),
        .clear(matrix_clear), .read_en(operand_read_enable),
        .read_addr(operand_k_index), .feed_valid(operand_valid),
        .c_wen(result_write_enable), .c_row(result_row),
        .busy(busy), .done(done)
    );

    // A has one SRAM lane per PE row; B is stored transposed, one per column.
    operand_banks #(
        .ELEM_WIDTH(DATA_WIDTH), .LANE_COUNT(ROWS),
        .MEM_WORD_WIDTH(MEM_WORD_WIDTH), .K_DEPTH(DEPTH),
        .BUFFER_COUNT(A_BUFFER_COUNT), .K_ADDR_WIDTH(ADDR_WIDTH)
    ) u_a_buffer (
        .clk(clk), .wen(a_wen), .wbank(a_wbank), .wlane(a_wlane),
        .waddr(a_waddr), .wdata(a_wdata), .ren(operand_read_enable),
        .rbank(a_rbank), .r_k_index(operand_k_index), .rdata(operand_a_data)
    );

    operand_banks #(
        .ELEM_WIDTH(DATA_WIDTH), .LANE_COUNT(COLS),
        .MEM_WORD_WIDTH(MEM_WORD_WIDTH), .K_DEPTH(DEPTH),
        .BUFFER_COUNT(B_BUFFER_COUNT), .K_ADDR_WIDTH(ADDR_WIDTH)
    ) u_b_buffer (
        .clk(clk), .wen(b_wen), .wbank(b_wbank), .wlane(b_wlane),
        .waddr(b_waddr), .wdata(b_wdata), .ren(operand_read_enable),
        .rbank(b_rbank), .r_k_index(operand_k_index), .rdata(operand_b_data)
    );

    for (genvar row = 0; row < ROWS; row++) begin : gen_a_lane
        assign matrix_a_data[row] = $signed(operand_a_data[row*DATA_WIDTH +: DATA_WIDTH]);
        assign matrix_a_valid[row] = operand_valid;
    end
    for (genvar col = 0; col < COLS; col++) begin : gen_b_lane
        assign matrix_b_data[col] = $signed(operand_b_data[col*DATA_WIDTH +: DATA_WIDTH]);
        assign matrix_b_valid[col] = operand_valid;
    end

    gemm_array #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_gemm_array (
        .clk(clk), .reset(reset), .clear(matrix_clear),
        .a_in(matrix_a_data), .a_valid_in(matrix_a_valid),
        .b_in(matrix_b_data), .b_valid_in(matrix_b_valid), .acc_out(acc_out)
    );

    assign result_write_addr = c_base_addr + ADDR_WIDTH'(result_row);
    always_comb begin
        for (int col = 0; col < COLS; col++)
            result_write_data[col*ACC_WIDTH +: ACC_WIDTH] = acc_out[result_row][col];
    end

    sync_sram #(
        .DATA_WIDTH(COLS*ACC_WIDTH), .DEPTH(DEPTH > ROWS ? DEPTH : ROWS),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_result_sram (
        .clk(clk), .ren(c_ren), .raddr(c_raddr), .rdata(c_rdata),
        .wen(result_write_enable), .waddr(result_write_addr), .wdata(result_write_data)
    );
endmodule
