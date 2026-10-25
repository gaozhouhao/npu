// Track operand-bank ownership. A retained bank becomes READY for reuse.
module operand_bank_controller #(
    parameter int BUFFER_COUNT = 1
) (
    input logic clk,
    input logic reset,
    input logic load_req,
    output logic load_grant,
    output logic load_bank,
    input logic load_done,
    input logic compute_req,
    output logic compute_grant,
    output logic compute_bank,
    input logic compute_done,
    input logic release_bank
);
    typedef enum logic [1:0] {EMPTY, LOADING, READY, COMPUTING} bank_state_t;
    bank_state_t bank_state_q [BUFFER_COUNT];
    logic load_active_q;
    logic load_bank_q;
    logic compute_active_q;
    logic compute_bank_q;
    logic empty_found;
    logic empty_bank;
    logic ready_found;
    logic ready_bank;

    always_comb begin
        empty_found = 1'b0;
        empty_bank = 1'b0;
        ready_found = 1'b0;
        ready_bank = 1'b0;
        for (int bank = 0; bank < BUFFER_COUNT; bank++) begin
            if (!empty_found && (bank_state_q[bank] == EMPTY)) begin
                empty_found = 1'b1;
                empty_bank = 1'(bank);
            end
            if (!ready_found && (bank_state_q[bank] == READY)) begin
                ready_found = 1'b1;
                ready_bank = 1'(bank);
            end
        end
    end
    assign load_grant = load_req && !load_active_q && empty_found;
    assign compute_grant = compute_req && !compute_active_q && ready_found;
    assign load_bank = load_active_q ? load_bank_q : empty_bank;
    assign compute_bank = compute_active_q ? compute_bank_q : ready_bank;

    always_ff @(posedge clk) begin
        if (reset) begin
            load_active_q <= 1'b0;
            load_bank_q <= 1'b0;
            compute_active_q <= 1'b0;
            compute_bank_q <= 1'b0;
            for (int bank = 0; bank < BUFFER_COUNT; bank++) bank_state_q[bank] <= EMPTY;
        end else begin
            if (load_grant) begin
                load_active_q <= 1'b1;
                load_bank_q <= empty_bank;
                bank_state_q[empty_bank] <= LOADING;
            end
            if (load_active_q && load_done) begin
                bank_state_q[load_bank_q] <= READY;
                load_active_q <= 1'b0;
            end
            if (compute_grant) begin
                compute_active_q <= 1'b1;
                compute_bank_q <= ready_bank;
                bank_state_q[ready_bank] <= COMPUTING;
            end
            if (compute_active_q && compute_done) begin
                bank_state_q[compute_bank_q] <= release_bank ? EMPTY : READY;
                compute_active_q <= 1'b0;
            end
        end
    end
endmodule
