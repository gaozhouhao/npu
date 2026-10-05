module matrix_controller #(
    parameter int ROWS         = 4,
    parameter int COLS         = 4,

    parameter int DEPTH        = 256,
    parameter int ADDR_WIDTH   = $clog2(DEPTH),
    parameter int K_SIZE_WIDTH = $clog2(DEPTH + 1)
) (
    input  logic clk,
    input  logic reset,

    input  logic start,

    // 当前 local K tile 的大小
    // 合法范围：0 ~ DEPTH
    input  logic [K_SIZE_WIDTH-1:0] tile_k_size,

    output logic clear,

    // SRAM request
    output logic                  read_en,
    output logic [ADDR_WIDTH-1:0] read_addr,

    // SRAM response -> matrix engine
    output logic feed_valid,

    output logic busy,
    output logic done
);

    // ============================================================
    // Drain parameters
    // ============================================================

    localparam int DRAIN_CYCLES = ROWS + COLS - 2;

    localparam int DRAIN_WIDTH =
        (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);

    localparam logic [DRAIN_WIDTH-1:0] DRAIN_LAST =
        DRAIN_WIDTH'(DRAIN_CYCLES - 1);


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        IDLE,
        CLEAR,
        FEED,
        DRAIN,
        DONE
    } state_t;

    state_t state;


    // ============================================================
    // Registers
    // ============================================================

    // 锁存本次 local tile 的 K 大小
    logic [K_SIZE_WIDTH-1:0] tile_k_size_q;

    // 已经发出了多少个 SRAM read request
    //
    // 注意：
    // 需要能够表示 DEPTH，
    // 例如 DEPTH=256 时 issue_count 需要 9 bit
    logic [K_SIZE_WIDTH-1:0] issue_count;

    // SRAM 是 1-cycle synchronous read
    // 所以将 request valid 延迟一拍作为 response valid
    logic rsp_valid_q;

    // 标记“上一拍发出的 request 是最后一个”
    logic rsp_last_q;

    logic [DRAIN_WIDTH-1:0] drain_counter;


    // ============================================================
    // SRAM request generation
    // ============================================================

    assign read_en =
        (state == FEED) &&
        (issue_count < tile_k_size_q);

    // 当前只访问 local scratchpad
    //
    // issue_count:
    //     0 ... tile_k_size_q-1
    //
    // read_addr:
    //     0 ... DEPTH-1
    //
    // 当 tile_k_size = DEPTH 时，
    // 最后一次 request 的 issue_count = DEPTH-1，
    // 所以不会产生地址 DEPTH。
    assign read_addr =
        issue_count[ADDR_WIDTH-1:0];


    // ============================================================
    // 1-cycle SRAM response tracking
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin
            rsp_valid_q <= 1'b0;
            rsp_last_q  <= 1'b0;
        end else begin

            // SRAM data corresponding to this request
            // will be available in the next cycle
            rsp_valid_q <= read_en;

            // 记录当前 request 是否为最后一个 K
            rsp_last_q <=
                read_en &&
                (issue_count == tile_k_size_q - 1'b1);
        end
    end


    assign feed_valid = rsp_valid_q;


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin

            state           <= IDLE;

            tile_k_size_q   <= '0;
            issue_count     <= '0;
            drain_counter   <= '0;

        end else begin

            case (state)

                // ------------------------------------------------
                // IDLE
                // ------------------------------------------------

                IDLE: begin

                    issue_count   <= '0;
                    drain_counter <= '0;

                    if (start) begin

                        // 锁存当前 tile 的 K 大小
                        tile_k_size_q <= tile_k_size;

                        // K=0 不进行任何计算
                        if (tile_k_size == 0)
                            state <= DONE;
                        else
                            state <= CLEAR;

                    end
                end


                // ------------------------------------------------
                // CLEAR
                // ------------------------------------------------

                CLEAR: begin

                    // 清 accumulator
                    // 并确保新任务从 SRAM addr 0 开始
                    issue_count <= '0;

                    state <= FEED;

                end


                // ------------------------------------------------
                // FEED
                // ------------------------------------------------

                FEED: begin

                    // 发出 SRAM read request
                    if (read_en)
                        issue_count <= issue_count + 1'b1;


                    // 最后一个 SRAM response 已经在这一拍
                    // 被送入 matrix_engine
                    //
                    // 此时才真正进入 DRAIN
                    if (rsp_valid_q && rsp_last_q) begin

                        drain_counter <= '0;

                        state <= DRAIN;

                    end
                end


                // ------------------------------------------------
                // DRAIN
                // ------------------------------------------------

                DRAIN: begin

                    if (drain_counter == DRAIN_LAST) begin

                        state <= DONE;

                    end else begin

                        drain_counter <= drain_counter + 1'b1;

                    end
                end


                // ------------------------------------------------
                // DONE
                // ------------------------------------------------

                DONE: begin

                    state <= IDLE;

                end


                // ------------------------------------------------
                // Default
                // ------------------------------------------------

                default: begin

                    state <= IDLE;

                end

            endcase
        end
    end


    // ============================================================
    // Output decode
    // ============================================================

    assign clear = (state == CLEAR);

    assign busy  = (state != IDLE);

    assign done  = (state == DONE);


endmodule

