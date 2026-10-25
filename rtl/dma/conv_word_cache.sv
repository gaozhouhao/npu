// Conv-only, direct-mapped read-through cache.
// Each line holds one AXI beat. CACHE_LINES is a power of two, at least 2.
// The upper interface uses complete requests and an ordered beat stream.
// Consecutive cache misses are gathered into legal low-level AXI requests.
module conv_word_cache #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned CACHE_LINES = 256,
    parameter bit ENABLE = 1'b1
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
    localparam int unsigned INDEX_BITS = $clog2(CACHE_LINES);
    localparam int unsigned BEAT_SHIFT = $clog2(DATA_WIDTH / 8);
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

    logic [DATA_WIDTH-1:0] line_data [0:CACHE_LINES-1];
    logic [TAG_BITS-1:0] line_tag [0:CACHE_LINES-1];
    logic [CACHE_LINES-1:0] line_valid_q;

    logic [ADDR_WIDTH-1:0] request_base_q;
    logic [31:0] request_beats_q;
    logic [31:0] request_index_q;
    logic [31:0] scan_index_q;
    logic [31:0] miss_beats_q;
    logic [31:0] miss_remaining_q;
    logic error_q;

    logic [ADDR_WIDTH-1:0] current_addr;
    logic [ADDR_WIDTH-1:BEAT_SHIFT] scan_addr;
    logic [INDEX_BITS-1:0] current_line_index;
    logic [INDEX_BITS-1:0] scan_line_index;
    logic current_hit;
    logic scan_hit;

    assign current_addr = request_base_q + (ADDR_WIDTH'(request_index_q) << BEAT_SHIFT);
    assign scan_addr = request_base_q[ADDR_WIDTH-1:BEAT_SHIFT] +
        (ADDR_WIDTH-BEAT_SHIFT)'(scan_index_q);
    assign current_line_index = current_addr[BEAT_SHIFT +: INDEX_BITS];
    assign scan_line_index = scan_addr[BEAT_SHIFT +: INDEX_BITS];
    assign current_hit = line_valid_q[current_line_index] &&
        (line_tag[current_line_index] == current_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS]);
    assign scan_hit = line_valid_q[scan_line_index] &&
        (line_tag[scan_line_index] == scan_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS]);

    localparam bit bypass_cache = !ENABLE;

    assign s_req_ready = bypass_cache ? m_req_ready : (state_q == ST_IDLE);
    assign s_done = bypass_cache ? m_done : (state_q == ST_DONE);
    assign s_error = bypass_cache ? m_error : error_q;

    assign s_data_valid = bypass_cache ?
        m_data_valid :
        (((state_q == ST_STREAM) && current_hit) ||
         ((state_q == ST_MISS_DATA) && m_data_valid));
    assign s_data = bypass_cache ? m_data :
        ((state_q == ST_MISS_DATA) ?
         m_data : line_data[current_line_index]);
    assign s_data_last = bypass_cache ?
        m_data_last :
        (s_data_valid && (request_index_q == request_beats_q - 32'd1));

    assign m_req_valid = bypass_cache ?
        s_req_valid : (state_q == ST_MISS_REQ);
    assign m_req_addr = bypass_cache ?
        s_req_addr : current_addr;
    assign m_req_beats = bypass_cache ?
        s_req_beats : miss_beats_q;
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
            request_base_q <= '0;
            request_beats_q <= '0;
            request_index_q <= '0;
            scan_index_q <= '0;
            miss_beats_q <= '0;
            miss_remaining_q <= '0;
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
                        request_base_q <= s_req_addr;
                        request_beats_q <= s_req_beats;
                        request_index_q <= '0;
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
                            request_index_q <= request_index_q + 32'd1;
                            if (request_index_q == request_beats_q - 32'd1)
                                state_q <= ST_DONE;
                        end
                    end else begin
                        // Begin a run of misses; scan until the first hit
                        // or the request end, then issue ONE AXI request.
                        scan_index_q <= request_index_q;
                        miss_beats_q <= '0;
                        state_q <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    if ((scan_index_q == request_beats_q) || scan_hit) begin
                        state_q <= ST_MISS_REQ;
                    end else begin
                        scan_index_q <= scan_index_q + 32'd1;
                        miss_beats_q <= miss_beats_q + 32'd1;
                    end
                end

                ST_MISS_REQ: begin
                    if (m_req_valid && m_req_ready) begin
                        miss_remaining_q <= miss_beats_q;
                        state_q <= ST_MISS_DATA;
`ifdef NPU_PERF_ENABLE
                        perf_miss_bursts_q <= perf_miss_bursts_q + 64'd1;
`endif
                    end
                end

                ST_MISS_DATA: begin
                    if (m_data_valid && m_data_ready) begin
                        line_data[current_line_index] <= m_data;
                        line_tag[current_line_index] <=
                            current_addr[ADDR_WIDTH-1:BEAT_SHIFT+INDEX_BITS];
                        line_valid_q[current_line_index] <= 1'b1;
                        request_index_q <= request_index_q + 32'd1;
                        miss_remaining_q <= miss_remaining_q - 32'd1;
                        if (m_data_last != (miss_remaining_q == 32'd1))
                            error_q <= 1'b1;
                        if (miss_remaining_q == 32'd1)
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
                        state_q <= (request_index_q == request_beats_q) ?
                            ST_DONE : ST_STREAM;
                    end
                end

                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
