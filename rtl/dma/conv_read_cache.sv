// Conv-only, direct-mapped read-through cache.
// Cache granularity: one 64-bit AXI beat. 256 entries = 2048 data bytes.
// The upper interface uses complete requests and an ordered beat stream.
// Consecutive cache misses are gathered into legal low-level AXI requests.
module conv_read_cache #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 64
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  invalidate,

    input  logic                  s_req_valid,
    output logic                  s_req_ready,
    input  logic [ADDR_WIDTH-1:0] s_req_addr,
    input  logic [31:0]           s_req_beats,
    output logic                  s_data_valid,
    input  logic                  s_data_ready,
    output logic [DATA_WIDTH-1:0] s_data,
    output logic                  s_data_last,
    output logic                  s_done,
    output logic                  s_error,

    output logic                  m_req_valid,
    input  logic                  m_req_ready,
    output logic [ADDR_WIDTH-1:0] m_req_addr,
    output logic [31:0]           m_req_beats,
    input  logic                  m_data_valid,
    output logic                  m_data_ready,
    input  logic [DATA_WIDTH-1:0] m_data,
    input  logic                  m_data_last,
    input  logic                  m_done,
    input  logic                  m_error
);
    localparam int unsigned LINES = 256;
    localparam int unsigned INDEX_BITS = 8;
    localparam int unsigned BEAT_SHIFT = 3;
    localparam int unsigned TAG_BITS = ADDR_WIDTH - INDEX_BITS - BEAT_SHIFT;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_STREAM,
        ST_SCAN,
        ST_MISS_REQ,
        ST_MISS_DATA,
        ST_MISS_DONE,
        ST_DONE
    } state_t;
    state_t state_q;

    logic [DATA_WIDTH-1:0] line_data [0:LINES-1];
    logic [TAG_BITS-1:0] line_tag [0:LINES-1];
    logic [LINES-1:0] line_valid_q;

    logic [ADDR_WIDTH-1:0] base_q;
    logic [31:0] length_q;
    logic [31:0] index_q;
    logic [31:0] scan_q;
    logic [31:0] miss_length_q;
    logic [31:0] miss_left_q;
    logic error_q;

    logic [ADDR_WIDTH-1:0] current_addr;
    logic [ADDR_WIDTH-1:BEAT_SHIFT] scan_addr;
    logic [INDEX_BITS-1:0] current_set;
    logic [INDEX_BITS-1:0] scan_set;
    logic current_hit;
    logic scan_hit;

    assign current_addr = base_q + (ADDR_WIDTH'(index_q) << BEAT_SHIFT);
    assign scan_addr = base_q[ADDR_WIDTH-1:BEAT_SHIFT] +
        (ADDR_WIDTH-BEAT_SHIFT)'(scan_q);
    assign current_set = current_addr[BEAT_SHIFT +: INDEX_BITS];
    assign scan_set = scan_addr[BEAT_SHIFT +: INDEX_BITS];
    assign current_hit = line_valid_q[current_set] &&
        (line_tag[current_set] == current_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS]);
    assign scan_hit = line_valid_q[scan_set] &&
        (line_tag[scan_set] == scan_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS]);

`ifdef NPU_PERF_ENABLE
    logic bypass_cache;
    initial bypass_cache = $test$plusargs("CONV_CACHE_DISABLE");
`else
    localparam bit bypass_cache = 1'b0;
`endif

    assign s_req_ready =
        bypass_cache ? m_req_ready : (state_q == ST_IDLE);
    assign s_done =
        bypass_cache ? m_done : (state_q == ST_DONE);
    assign s_error =
        bypass_cache ? m_error : error_q;

    assign s_data_valid = bypass_cache ?
        m_data_valid :
        (((state_q == ST_STREAM) && current_hit) ||
         ((state_q == ST_MISS_DATA) && m_data_valid));
    assign s_data = bypass_cache ? m_data :
        ((state_q == ST_MISS_DATA) ?
         m_data : line_data[current_set]);
    assign s_data_last = bypass_cache ?
        m_data_last :
        (s_data_valid && (index_q == length_q - 32'd1));

    assign m_req_valid = bypass_cache ?
        s_req_valid : (state_q == ST_MISS_REQ);
    assign m_req_addr = bypass_cache ?
        s_req_addr : current_addr;
    assign m_req_beats = bypass_cache ?
        s_req_beats : miss_length_q;
    assign m_data_ready = bypass_cache ?
        s_data_ready :
        ((state_q == ST_MISS_DATA) && s_data_ready);

`ifdef NPU_PERF_ENABLE
    logic [63:0] perf_requests_q;
    logic [63:0] perf_hits_q;
    logic [63:0] perf_misses_q;
    logic [63:0] perf_miss_bursts_q;
    final begin
        $display("CONV_CACHE_TOTAL,requests=%0d,hits=%0d,misses=%0d,miss_bursts=%0d",
                 perf_requests_q, perf_hits_q, perf_misses_q,
                 perf_miss_bursts_q);
    end
`endif

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= ST_IDLE;
            base_q <= '0;
            length_q <= '0;
            index_q <= '0;
            scan_q <= '0;
            miss_length_q <= '0;
            miss_left_q <= '0;
            error_q <= 1'b0;
            line_valid_q <= '0;
`ifdef NPU_PERF_ENABLE
            perf_requests_q <= '0;
            perf_hits_q <= '0;
            perf_misses_q <= '0;
            perf_miss_bursts_q <= '0;
`endif
        end else begin
            // Flush only at the first accepted Conv A tile of a layer.
            // A/B DMA scheduling must keep a layer's inputs immutable.
            if (invalidate)
                line_valid_q <= '0;

            case (state_q)
                ST_IDLE: begin
                    if (!bypass_cache && s_req_valid && s_req_ready) begin
                        base_q <= s_req_addr;
                        length_q <= s_req_beats;
                        index_q <= '0;
                        error_q <= 1'b0;
                        state_q <= (s_req_beats == 32'd0) ?
                            ST_DONE : ST_STREAM;
`ifdef NPU_PERF_ENABLE
                        perf_requests_q <= perf_requests_q + 64'd1;
`endif
                    end
                end

                ST_STREAM: begin
                    if (current_hit) begin
                        if (s_data_ready) begin
`ifdef NPU_PERF_ENABLE
                            perf_hits_q <= perf_hits_q + 64'd1;
`endif
                            index_q <= index_q + 32'd1;
                            if (index_q == length_q - 32'd1)
                                state_q <= ST_DONE;
                        end
                    end else begin
                        // Begin a run of misses; scan until the first hit
                        // or the request end, then issue ONE AXI request.
                        scan_q <= index_q;
                        miss_length_q <= '0;
                        state_q <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    if ((scan_q == length_q) || scan_hit) begin
                        state_q <= ST_MISS_REQ;
                    end else begin
                        scan_q <= scan_q + 32'd1;
                        miss_length_q <= miss_length_q + 32'd1;
                    end
                end

                ST_MISS_REQ: begin
                    if (m_req_valid && m_req_ready) begin
                        miss_left_q <= miss_length_q;
                        state_q <= ST_MISS_DATA;
`ifdef NPU_PERF_ENABLE
                        perf_miss_bursts_q <= perf_miss_bursts_q + 64'd1;
`endif
                    end
                end

                ST_MISS_DATA: begin
                    if (m_data_valid && m_data_ready) begin
                        line_data[current_set] <= m_data;
                        line_tag[current_set] <=
                            current_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS];
                        line_valid_q[current_set] <= 1'b1;
                        index_q <= index_q + 32'd1;
                        miss_left_q <= miss_left_q - 32'd1;
                        if (m_data_last != (miss_left_q == 32'd1))
                            error_q <= 1'b1;
                        if (miss_left_q == 32'd1)
                            state_q <= ST_MISS_DONE;
`ifdef NPU_PERF_ENABLE
                        perf_misses_q <= perf_misses_q + 64'd1;
`endif
                    end
                end

                ST_MISS_DONE: begin
                    if (m_done) begin
                        if (m_error)
                            error_q <= 1'b1;
                        state_q <= (index_q == length_q) ?
                            ST_DONE : ST_STREAM;
                    end
                end

                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if ((ADDR_WIDTH != 64) || (DATA_WIDTH != 64))
            $fatal(1, "conv_read_cache requires 64-bit address and data");
    end
endmodule
