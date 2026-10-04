module matrix_controller #(
    parameter int ROWS    = 4,
    parameter int COLS    = 4,
    parameter int K_WIDTH = 16
) (
    input  logic               clk,
    input  logic               reset,

    input  logic               start,
    input  logic [K_WIDTH-1:0] k_size,

    output logic               clear,
    output logic               feed_valid,
    output logic [K_WIDTH-1:0] k_index,

    output logic               busy,
    output logic               done
);

    localparam int DRAIN_CYCLES = ROWS + COLS - 2;

    localparam int DRAIN_WIDTH =
        (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);

    localparam logic [DRAIN_WIDTH-1:0] DRAIN_LAST =
        DRAIN_WIDTH'(DRAIN_CYCLES - 1);


    typedef enum logic [2:0] {
        IDLE,
        CLEAR,
        FEED,
        DRAIN,
        DONE
    } state_t;

    state_t state;

    logic [K_WIDTH-1:0] k_counter;
    logic [DRAIN_WIDTH-1:0] drain_counter;


    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            k_counter <= {K_WIDTH{1'b0}};
            drain_counter <= {DRAIN_WIDTH{1'b0}};
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        k_counter <= 0;
                        drain_counter <= 0;
                        state <= CLEAR;
                    end
                end

                CLEAR: begin
                    state <= FEED;
                end

                FEED: begin
                    if (k_counter == k_size - 1) begin
                        state <= DRAIN;
                    end else begin
                        k_counter <= k_counter + 1;
                    end
                end

                DRAIN: begin
                    if (drain_counter == DRAIN_LAST) begin
                        state <= DONE;
                    end else begin
                        drain_counter <= drain_counter + 1;
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

    assign clear      = (state == CLEAR);
    assign feed_valid = (state == FEED);
    assign k_index    = k_counter;
    assign busy       = (state != IDLE);
    assign done       = (state == DONE);

endmodule

