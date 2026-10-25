// Packed operand words with one SRAM lane per PE row/column.
module operand_banks #(
    parameter int unsigned ELEM_WIDTH = 8,
    parameter int unsigned LANE_COUNT = 4,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned K_DEPTH = 256,
    parameter int unsigned BUFFER_COUNT = 2,
    parameter int unsigned K_ADDR_WIDTH = (K_DEPTH <= 1) ? 1 : $clog2(K_DEPTH),
    parameter int unsigned ELEMS_PER_WORD = MEM_WORD_WIDTH / ELEM_WIDTH,
    parameter int unsigned WORD_DEPTH = (K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD,
    parameter int unsigned WORD_ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),
    parameter int unsigned LANE_SEL_WIDTH = (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT),
    parameter int unsigned BANK_SEL_WIDTH = (BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT),
    parameter int unsigned ELEM_SEL_WIDTH = (ELEMS_PER_WORD <= 1) ? 1 : $clog2(ELEMS_PER_WORD)
) (
    input logic clk,
    input logic wen,
    input logic [BANK_SEL_WIDTH-1:0] wbank,
    input logic [LANE_SEL_WIDTH-1:0] wlane,
    input logic [WORD_ADDR_WIDTH-1:0] waddr,
    input logic [MEM_WORD_WIDTH-1:0] wdata,
    input logic ren,
    input logic [BANK_SEL_WIDTH-1:0] rbank,
    input logic [K_ADDR_WIDTH-1:0] r_k_index,
    output logic [LANE_COUNT*ELEM_WIDTH-1:0] rdata
);
    logic [WORD_ADDR_WIDTH-1:0] read_word_addr;
    logic [ELEM_SEL_WIDTH-1:0] read_element;
    logic [ELEM_SEL_WIDTH-1:0] read_element_q;
    logic read_word_enable;
    logic [MEM_WORD_WIDTH-1:0] bank_lane_data [BUFFER_COUNT][LANE_COUNT];

    assign read_word_addr = WORD_ADDR_WIDTH'(r_k_index / ELEMS_PER_WORD);
    assign read_element = ELEM_SEL_WIDTH'(r_k_index % ELEMS_PER_WORD);
    // Sequential K reads reuse each packed word until its last element.
    assign read_word_enable = ren && (read_element == '0);
    always_ff @(posedge clk)
        if (ren) read_element_q <= read_element;

    for (genvar bank = 0; bank < BUFFER_COUNT; bank++) begin : gen_bank
        for (genvar lane = 0; lane < LANE_COUNT; lane++) begin : gen_lane
            operand_sram #(
                .DATA_WIDTH(MEM_WORD_WIDTH), .DEPTH(WORD_DEPTH),
                .ADDR_WIDTH(WORD_ADDR_WIDTH)
            ) u_lane_sram (
                .clk(clk),
                .ren(read_word_enable && (rbank == BANK_SEL_WIDTH'(bank))),
                .raddr(read_word_addr), .rdata(bank_lane_data[bank][lane]),
                .wen(wen && (wbank == BANK_SEL_WIDTH'(bank)) &&
                     (wlane == LANE_SEL_WIDTH'(lane))),
                .waddr(waddr), .wdata(wdata)
            );
        end
    end

    always_comb begin
        for (int lane = 0; lane < LANE_COUNT; lane++)
            rdata[lane*ELEM_WIDTH +: ELEM_WIDTH] =
                bank_lane_data[(BUFFER_COUNT == 1) ? 0 : rbank][lane]
                              [read_element_q*ELEM_WIDTH +: ELEM_WIDTH];
    end
endmodule
