// Acquire one operand bank and stream lane-major packed words into its SRAMs.
module operand_packer #(
    parameter int unsigned ELEM_WIDTH = 8,
    parameter int unsigned LANE_COUNT = 4,
    parameter int unsigned MEM_WORD_WIDTH = 32,
    parameter int unsigned K_DEPTH = 256,
    parameter int unsigned BUFFER_COUNT = 2,
    parameter int unsigned K_SIZE_WIDTH = $clog2(K_DEPTH + 1),
    parameter int unsigned ELEMS_PER_WORD = MEM_WORD_WIDTH / ELEM_WIDTH,
    parameter int unsigned WORD_DEPTH = (K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD,
    parameter int unsigned WORD_ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),
    parameter int unsigned LANE_WIDTH = (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT),
    parameter int unsigned BANK_WIDTH = (BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)
) (
    input logic clk,
    input logic reset,
    input logic load_req,
    output logic load_accept,
    input logic [K_SIZE_WIDTH-1:0] load_size,
    output logic load_done,
    output logic busy,
    output logic bank_load_req,
    input logic bank_load_grant,
    input logic [BANK_WIDTH-1:0] bank_load_bank,
    output logic bank_load_done,
    input logic data_valid,
    output logic data_ready,
    input logic [MEM_WORD_WIDTH-1:0] data,
    output logic buffer_wen,
    output logic [BANK_WIDTH-1:0] buffer_wbank,
    output logic [LANE_WIDTH-1:0] buffer_wlane,
    output logic [WORD_ADDR_WIDTH-1:0] buffer_waddr,
    output logic [MEM_WORD_WIDTH-1:0] buffer_wdata
);
    typedef enum logic [1:0] {IDLE, ACQUIRE_BANK, RECEIVE, DONE} state_t;
    state_t state_q;
    logic [BANK_WIDTH-1:0] destination_bank_q;
    logic [LANE_WIDTH-1:0] lane_index_q;
    logic [WORD_ADDR_WIDTH-1:0] word_index_q;
    logic [WORD_ADDR_WIDTH-1:0] last_word_q;
    logic [31:0] words_per_lane;

    assign words_per_lane = (32'(load_size) + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD;
    assign load_accept = (state_q == IDLE) && load_req;
    assign bank_load_req = (state_q == ACQUIRE_BANK);
    assign data_ready = (state_q == RECEIVE);
    assign buffer_wen = data_valid && data_ready;
    assign buffer_wbank = destination_bank_q;
    assign buffer_wlane = lane_index_q;
    assign buffer_waddr = word_index_q;
    assign buffer_wdata = data;
    assign load_done = (state_q == DONE);
    assign bank_load_done = load_done;
    assign busy = (state_q != IDLE) && (state_q != DONE);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            destination_bank_q <= '0;
            lane_index_q <= '0;
            word_index_q <= '0;
            last_word_q <= '0;
        end else begin
            case (state_q)
                IDLE: begin
                    if (load_req) begin
                        lane_index_q <= '0;
                        word_index_q <= '0;
                        last_word_q <= (load_size == 0) ? '0 : WORD_ADDR_WIDTH'(words_per_lane - 1);
                        state_q <= ACQUIRE_BANK;
                    end
                end
                ACQUIRE_BANK: begin
                    if (bank_load_grant) begin
                        destination_bank_q <= bank_load_bank;
                        lane_index_q <= '0;
                        word_index_q <= '0;
                        state_q <= (load_size == 0) ? DONE : RECEIVE;
                    end
                end
                RECEIVE: begin
                    if (data_valid && data_ready) begin
                        if (word_index_q == last_word_q) begin
                            word_index_q <= '0;
                            if (lane_index_q == LANE_WIDTH'(LANE_COUNT - 1))
                                state_q <= DONE;
                            else
                                lane_index_q <= lane_index_q + 1'b1;
                        end else
                            word_index_q <= word_index_q + 1'b1;
                    end
                end
                DONE: state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
