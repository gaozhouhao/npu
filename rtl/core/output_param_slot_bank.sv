
module output_param_slot_bank #(
    parameter int unsigned SLOTS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned TAG_WIDTH = 16,
    parameter int unsigned SLOT_WIDTH =
        (SLOTS <= 1) ? 1 : $clog2(SLOTS)
) (
    input logic clk,
    input logic reset,
    input logic clear,

    // Parameter fill from DMA/parameter loader
    input  logic fill_valid,
    output logic fill_ready,
    input  logic [SLOT_WIDTH-1:0] fill_slot,
    input  logic [TAG_WIDTH-1:0] fill_n_tile,
    input  logic signed [31:0] fill_bias [0:COLS-1],
    input  logic [31:0] fill_multiplier [0:COLS-1],
    input  logic [5:0] fill_shift [0:COLS-1],

    // Parameter lookup for final writeback
    input  logic read_valid,
    input  logic [SLOT_WIDTH-1:0] read_slot,
    input  logic [TAG_WIDTH-1:0] read_n_tile,
    output logic read_hit,
    output logic signed [31:0] read_bias [0:COLS-1],
    output logic [31:0] read_multiplier [0:COLS-1],
    output logic [5:0] read_shift [0:COLS-1],

    // Retire only after C writeback completion
    input  logic retire_valid,
    input  logic [SLOT_WIDTH-1:0] retire_slot,
    input  logic [TAG_WIDTH-1:0] retire_n_tile,
    output logic retire_hit
);

    logic slot_valid_q [0:SLOTS-1];
    logic [TAG_WIDTH-1:0] slot_tag_q [0:SLOTS-1];

    logic signed [31:0] bias_q
        [0:SLOTS-1][0:COLS-1];

    logic [31:0] multiplier_q
        [0:SLOTS-1][0:COLS-1];

    logic [5:0] shift_q
        [0:SLOTS-1][0:COLS-1];

    // ------------------------------------------------------------
    // Fill and retirement checks
    // ------------------------------------------------------------

    always_comb begin
        fill_ready = 1'b0;
        retire_hit = 1'b0;

        if (!reset && !clear) begin
            if (int'($unsigned(retire_slot)) < SLOTS) begin
                retire_hit =
                    retire_valid &&
                    slot_valid_q[retire_slot] &&
                    (slot_tag_q[retire_slot] == retire_n_tile);
            end

            if (int'($unsigned(retire_slot)) < SLOTS) begin
                fill_ready =
                    !(retire_valid && (retire_slot == fill_slot)) &&
                    (
                        !slot_valid_q[fill_slot] ||
                        (slot_tag_q[fill_slot] == fill_n_tile)
                    );
            end
        end
    end

    // ------------------------------------------------------------
    // Combinational parameter read
    // ------------------------------------------------------------

    always_comb begin
        read_hit = 1'b0;

        for (int lane = 0; lane < COLS; lane++) begin
            read_bias[lane] = '0;
            read_multiplier[lane] = '0;
            read_shift[lane] = '0;
        end

        if (!reset && !clear &&
            (int'($unsigned(read_slot)) < SLOTS)) begin

            if (read_valid &&
                slot_valid_q[read_slot] &&
                (slot_tag_q[read_slot] == read_n_tile)) begin

                read_hit = 1'b1;

                for (int lane = 0; lane < COLS; lane++) begin
                    read_bias[lane] =
                        bias_q[read_slot][lane];

                    read_multiplier[lane] =
                        multiplier_q[read_slot][lane];

                    read_shift[lane] =
                        shift_q[read_slot][lane];
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Slot state and parameter storage
    // ------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            for (int s = 0; s < SLOTS; s++) begin
                slot_valid_q[s] <= 1'b0;
                slot_tag_q[s] <= '0;
            end
        end else begin
            if (retire_hit) begin
                slot_valid_q[retire_slot] <= 1'b0;
            end

            if (fill_valid && fill_ready) begin
                slot_valid_q[fill_slot] <= 1'b1;
                slot_tag_q[fill_slot] <= fill_n_tile;

                for (int lane = 0; lane < COLS; lane++) begin
                    bias_q[fill_slot][lane] <=
                        fill_bias[lane];

                    multiplier_q[fill_slot][lane] <=
                        fill_multiplier[lane];

                    shift_q[fill_slot][lane] <=
                        fill_shift[lane];
                end
            end
        end
    end

    initial begin
        if (SLOTS < 1 || COLS < 1 || TAG_WIDTH < 1)
            $fatal(1, "Invalid parameter bank configuration");

        if (SLOTS > (2 ** SLOT_WIDTH))
            $fatal(1, "SLOT_WIDTH cannot address SLOTS");
    end

endmodule
