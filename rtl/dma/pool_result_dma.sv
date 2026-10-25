// Queue complete pooled words independently of the AXI write response latency.
// The active write owns a private copy, so its queue slot can be reused early.
module pool_result_dma #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned ID_WIDTH = 1,
    parameter int unsigned FIFO_DEPTH = 16
) (
    input logic clk,
    input logic reset,
    input logic clear,
    input logic in_valid,
    output logic in_ready,
    input logic [ADDR_WIDTH-1:0] in_addr,
    input logic [31:0] in_data,
    output logic busy,
    output logic error,
    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    input logic [ID_WIDTH-1:0] m_axi_bid,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready
);
    localparam int unsigned SAFE_DEPTH = FIFO_DEPTH == 0 ? 1 : FIFO_DEPTH;
    localparam int unsigned PTR_WIDTH = SAFE_DEPTH <= 1 ? 1 : $clog2(SAFE_DEPTH);
    localparam int unsigned COUNT_WIDTH = $clog2(SAFE_DEPTH + 1);

    typedef enum logic [1:0] {ST_IDLE, ST_WR_REQ, ST_WR_DATA, ST_WR_DONE} state_t;
    state_t state_q;
    logic [ADDR_WIDTH-1:0] addr_mem [SAFE_DEPTH];
    logic [31:0] data_mem [SAFE_DEPTH];
    logic [PTR_WIDTH-1:0] read_ptr_q, write_ptr_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic [ADDR_WIDTH-1:0] active_addr_q;
    logic [31:0] active_data_q;
    logic push, pop, accept_clear;
    logic write_req_ready, write_data_ready, write_busy, write_done, write_error;

    // Explicit wrap supports depth one and non-power-of-two capacities.
    function automatic logic [PTR_WIDTH-1:0] next_ptr(
        input logic [PTR_WIDTH-1:0] ptr
    );
        next_ptr = ptr == PTR_WIDTH'(SAFE_DEPTH - 1) ? '0 : ptr + 1'b1;
    endfunction

    assign busy = count_q != 0 || state_q != ST_IDLE || write_busy || write_done;
    assign accept_clear = clear && !busy;
    assign pop = !reset && !clear && state_q == ST_IDLE && count_q != 0;
    // A simultaneous pop releases capacity even when the queue starts full.
    assign in_ready = !reset && !clear &&
        (count_q < COUNT_WIDTH'(SAFE_DEPTH) || pop);
    assign push = in_valid && in_ready;

    // clear starts a new idle task; it must never cancel a pending AXI write.
    axi_write_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(32), .ID_WIDTH(ID_WIDTH)
    ) u_writer (
        .clk(clk), .reset(reset || accept_clear),
        .req_valid(state_q == ST_WR_REQ), .req_ready(write_req_ready),
        .req_addr(active_addr_q), .req_beats(32'd1),
        .data_valid(state_q == ST_WR_DATA), .data_ready(write_data_ready),
        .data(active_data_q), .busy(write_busy),
        .done(write_done), .error(write_error),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    always_ff @(posedge clk) begin
        if (reset || accept_clear) begin
            state_q <= ST_IDLE;
            read_ptr_q <= '0;
            write_ptr_q <= '0;
            count_q <= '0;
            active_addr_q <= '0;
            active_data_q <= '0;
            error <= 1'b0;
        end else begin
            if (push) begin
                addr_mem[write_ptr_q] <= in_addr;
                data_mem[write_ptr_q] <= in_data;
                write_ptr_q <= next_ptr(write_ptr_q);
            end
            if (pop) begin
                // Read the old head before a same-slot push overwrites it.
                active_addr_q <= addr_mem[read_ptr_q];
                active_data_q <= data_mem[read_ptr_q];
                read_ptr_q <= next_ptr(read_ptr_q);
            end
            case ({push, pop})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: ;
            endcase

            case (state_q)
                ST_IDLE: if (pop) state_q <= ST_WR_REQ;
                ST_WR_REQ: if (write_req_ready) state_q <= ST_WR_DATA;
                ST_WR_DATA: begin
                    // A rejected request (for example an unaligned address)
                    // completes without requesting a data beat.
                    if (write_done) begin
                        if (write_error) error <= 1'b1;
                        state_q <= ST_IDLE;
                    end else if (write_data_ready) state_q <= ST_WR_DONE;
                end
                ST_WR_DONE: if (write_done) begin
                    if (write_error) error <= 1'b1;
                    state_q <= ST_IDLE;
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    // synthesis translate_off
`ifndef SYNTHESIS
    initial begin
        assert (FIFO_DEPTH > 0)
            else $fatal(1, "Pool result FIFO depth must be positive");
    end
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!clear || !busy)
                else $fatal(1, "Pool result DMA cannot clear a pending write");
            assert (count_q <= COUNT_WIDTH'(SAFE_DEPTH))
                else $fatal(1, "Pool result FIFO occupancy exceeds capacity");
        end
    end
`endif
    // synthesis translate_on
endmodule
