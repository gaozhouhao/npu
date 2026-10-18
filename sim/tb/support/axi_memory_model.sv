`timescale 1ns/1ps

// Verification-only AXI64/32 read and AXI32 write memory. Backing words are little endian.
module axi_memory_model #(
    parameter int WORDS = 8192,
    parameter int READ_DATA_WIDTH = 64
) (
    input logic clk, reset,
    input logic m_axi_arid,
    input logic [63:0] m_axi_araddr,
    input logic [7:0] m_axi_arlen,
    input logic [2:0] m_axi_arsize,
    input logic [1:0] m_axi_arburst,
    input logic m_axi_arvalid,
    output logic m_axi_arready,
    output logic m_axi_rid,
    output logic [READ_DATA_WIDTH-1:0] m_axi_rdata,
    output logic [1:0] m_axi_rresp,
    output logic m_axi_rlast, m_axi_rvalid,
    input logic m_axi_rready,
    input logic m_axi_awid,
    input logic [63:0] m_axi_awaddr,
    input logic [7:0] m_axi_awlen,
    input logic [2:0] m_axi_awsize,
    input logic [1:0] m_axi_awburst,
    input logic m_axi_awvalid,
    output logic m_axi_awready,
    input logic [31:0] m_axi_wdata,
    input logic [3:0] m_axi_wstrb,
    input logic m_axi_wlast, m_axi_wvalid,
    output logic m_axi_wready,
    output logic m_axi_bid,
    output logic [1:0] m_axi_bresp,
    output logic m_axi_bvalid,
    input logic m_axi_bready
);
    logic [31:0] mem [WORDS];
    logic rd_active, wr_active;
    logic [63:0] rd_addr, wr_addr;
    logic [8:0] rd_left, wr_left;
    logic rd_id, wr_id;
    integer read_requests, write_requests, write_beats;
    localparam int READ_BYTES = READ_DATA_WIDTH / 8;
    // +WRITE_GAP=N inserts N waiting cycles before each accepted write beat.
    integer write_gap = 0;
    integer write_wait;
    initial void'($value$plusargs("WRITE_GAP=%d", write_gap));
    assign m_axi_arready = !rd_active && !m_axi_rvalid;
    assign m_axi_awready = !wr_active && !m_axi_bvalid;
    assign m_axi_wready = wr_active && !m_axi_bvalid && (write_wait == 0);

    // A test process initializes mem before releasing reset; this is not always_ff.
    always @(posedge clk) begin
        if (reset) begin
            rd_active <= 0; wr_active <= 0;
            rd_addr <= 0; wr_addr <= 0; rd_left <= 0; wr_left <= 0;
            rd_id <= 0; wr_id <= 0;
            m_axi_rid <= 0; m_axi_rdata <= 0; m_axi_rresp <= 0;
            m_axi_rlast <= 0; m_axi_rvalid <= 0;
            m_axi_bid <= 0; m_axi_bresp <= 0; m_axi_bvalid <= 0;
            read_requests <= 0; write_requests <= 0; write_beats <= 0;
            write_wait <= 0;
        end else begin
            if (write_wait > 0) write_wait <= write_wait - 1;
            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_arsize !== 3'($clog2(READ_BYTES)) || m_axi_arburst !== 2'b01 ||
                    (m_axi_araddr % READ_BYTES) != 0)
                    $fatal(1, "Invalid AXI read request");
                if (m_axi_araddr + (64'(m_axi_arlen)+1)*READ_BYTES > 64'(WORDS*4))
                    $fatal(1, "Read burst exceeds backing memory");
                rd_active <= 1; rd_addr <= m_axi_araddr;
                rd_left <= {1'b0,m_axi_arlen}+1'b1; rd_id <= m_axi_arid;
                read_requests <= read_requests+1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 0;
                rd_left <= rd_left-1'b1;
                rd_addr <= rd_addr+READ_BYTES;
                if (rd_left == 1) rd_active <= 0;
            end
            if (rd_active && !m_axi_rvalid) begin
                m_axi_rid <= rd_id;
                if (READ_DATA_WIDTH == 64)
                    m_axi_rdata <= {mem[(rd_addr>>2)+1],mem[rd_addr>>2]};
                else
                    m_axi_rdata <= mem[rd_addr>>2];
                m_axi_rresp <= 0; m_axi_rlast <= (rd_left == 1); m_axi_rvalid <= 1;
            end
            if (m_axi_bvalid && m_axi_bready) m_axi_bvalid <= 0;
            if (m_axi_awvalid && m_axi_awready) begin
                if (m_axi_awsize !== 3'd2 || m_axi_awburst !== 2'b01 || m_axi_awaddr[1:0] !== 2'd0)
                    $fatal(1, "Invalid AXI32 write request");
                if (m_axi_awaddr + (64'(m_axi_awlen)+1)*4 > 64'(WORDS*4))
                    $fatal(1, "Write burst exceeds backing memory");
                wr_active <= 1; wr_addr <= m_axi_awaddr;
                wr_left <= {1'b0,m_axi_awlen}+1'b1; wr_id <= m_axi_awid;
                write_wait <= write_gap;
                write_requests <= write_requests+1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (m_axi_wlast !== (wr_left == 1)) $fatal(1, "WLAST mismatch");
                for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                    if (m_axi_wstrb[byte_idx]) mem[wr_addr>>2][byte_idx*8 +: 8] <= m_axi_wdata[byte_idx*8 +: 8];
                wr_addr <= wr_addr+4; wr_left <= wr_left-1'b1; write_beats <= write_beats+1;
                write_wait <= write_gap;
                if (wr_left == 1) begin
                    wr_active <= 0; m_axi_bid <= wr_id; m_axi_bresp <= 0; m_axi_bvalid <= 1;
                end
            end
        end
    end
endmodule
