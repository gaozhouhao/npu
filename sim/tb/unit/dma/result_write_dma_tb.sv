// Check every legal row/column remainder, byte alignment, and page boundaries.
module result_write_dma_tb;
    parameter int COLS = 3;
    parameter int ROWS = 4;
    localparam int AXI_BYTES = 4;
    localparam int MEMORY_BYTES = 16384;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset, tile_valid, tile_accept, int8_mode;
    logic [63:0] tile_addr;
    logic [31:0] tile_stride_bytes, tile_valid_rows, tile_valid_cols;
    logic c_ren, busy, done, error;
    logic [7:0] c_raddr;
    logic [COLS*32-1:0] c_rdata;
    logic [63:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awid, m_axi_awvalid, m_axi_awready;
    logic [31:0] m_axi_wdata;
    logic [3:0] m_axi_wstrb;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic m_axi_bid, m_axi_bvalid, m_axi_bready;
    logic [1:0] m_axi_bresp;
    byte memory [0:MEMORY_BYTES-1];
    byte expected_memory [0:MEMORY_BYTES-1];

    int cycle_count, case_count = 0;
    int case_rows, case_cols, case_addr, case_stride, case_bytes;
    bit case_int8, case_bad_response, case_bad_id, case_invalid;
    int read_count, aw_count, b_count, monitor_row, row_beats_used;
    int write_address, burst_beats_left, response_delay;
    bit outstanding, response_pending;
    bit aw_stalled, w_stalled;
    logic [63:0] held_awaddr;
    logic [7:0] held_awlen;
    logic [31:0] held_wdata;
    logic [3:0] held_wstrb;
    logic held_wlast;

    assign m_axi_awready = cycle_count % 4 != 1;
    assign m_axi_wready = cycle_count % 3 != 0;

    result_write_dma #(.ROWS(ROWS), .COLS(COLS)) dut (
        .clk(clk), .reset(reset), .tile_valid(tile_valid), .tile_accept(tile_accept),
        .tile_addr(tile_addr), .tile_stride_bytes(tile_stride_bytes),
        .tile_valid_rows(tile_valid_rows), .tile_valid_cols(tile_valid_cols),
        .int8_mode(int8_mode), .c_ren(c_ren), .c_raddr(c_raddr), .c_rdata(c_rdata),
        .busy(busy), .done(done), .error(error),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    function automatic byte source_byte(input int row, input int index);
        return 8'(row * 37 + index * 13 + (case_int8 ? 71 : 0) + 5);
    endfunction

    always @(posedge clk) begin : memory_model
        int row_start, total_beats, expected_addr, expected_beats, logical_byte;
        bit expected_strobe;
        if (reset) begin
            cycle_count <= 0;
            m_axi_bvalid <= 0;
            m_axi_bresp <= 0;
            m_axi_bid <= 0;
            c_rdata <= 0;
            aw_stalled = 0;
            w_stalled = 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (aw_stalled && (!m_axi_awvalid || m_axi_awaddr !== held_awaddr ||
                               m_axi_awlen !== held_awlen))
                $fatal(1, "AW changed during backpressure");
            if (w_stalled && (!m_axi_wvalid || m_axi_wdata !== held_wdata ||
                              m_axi_wstrb !== held_wstrb || m_axi_wlast !== held_wlast))
                $fatal(1, "W changed during backpressure");
            aw_stalled = m_axi_awvalid && !m_axi_awready;
            w_stalled = m_axi_wvalid && !m_axi_wready;
            held_awaddr = m_axi_awaddr;
            held_awlen = m_axi_awlen;
            held_wdata = m_axi_wdata;
            held_wstrb = m_axi_wstrb;
            held_wlast = m_axi_wlast;

            if (c_ren) begin
                if (case_invalid || int'(c_raddr) != read_count || read_count >= case_rows)
                    $fatal(1, "Read a padding row or repeated a row: addr=%0d count=%0d", c_raddr, read_count);
                for (int b = 0; b < COLS*4; b++)
                    c_rdata[b*8 +: 8] <= source_byte(int'(c_raddr), b);
                read_count = read_count + 1;
            end
            if (m_axi_awvalid && m_axi_awready) begin
                if (case_invalid || outstanding || monitor_row >= case_rows)
                    $fatal(1, "Unexpected AXI request");
                row_start = case_addr + monitor_row * case_stride;
                total_beats = ((row_start % AXI_BYTES) + case_bytes + AXI_BYTES - 1) / AXI_BYTES;
                expected_addr = (row_start / AXI_BYTES + row_beats_used) * AXI_BYTES;
                expected_beats = total_beats - row_beats_used;
                if (expected_beats > 256) expected_beats = 256;
                if (expected_beats > (4096 - expected_addr % 4096) / AXI_BYTES)
                    expected_beats = (4096 - expected_addr % 4096) / AXI_BYTES;
                if (m_axi_awid != 0 || m_axi_awsize != 2 || m_axi_awburst != 1 ||
                    m_axi_awaddr != 64'(expected_addr) ||
                    int'(m_axi_awlen) + 1 != expected_beats || expected_beats == 0)
                    $fatal(1, "Wrong AXI burst addr=%0h len=%0d expected=%0h/%0d",
                        m_axi_awaddr, m_axi_awlen, expected_addr, expected_beats);
                if ((int'(m_axi_awaddr) % 4096) + (int'(m_axi_awlen)+1)*AXI_BYTES > 4096)
                    $fatal(1, "AXI burst crosses a 4KiB boundary");
                write_address = expected_addr;
                burst_beats_left = expected_beats;
                outstanding = 1;
                aw_count = aw_count + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (!outstanding || response_pending || burst_beats_left == 0)
                    $fatal(1, "Unexpected write data");
                row_start = case_addr + monitor_row * case_stride;
                for (int lane = 0; lane < AXI_BYTES; lane++) begin
                    logical_byte = write_address + lane - row_start;
                    expected_strobe = logical_byte >= 0 && logical_byte < case_bytes;
                    if (m_axi_wstrb[lane] !== expected_strobe)
                        $fatal(1, "Wrong strobe row=%0d addr=%0d lane=%0d", monitor_row, write_address, lane);
                    if (expected_strobe) begin
                        if (m_axi_wdata[lane*8 +: 8] !== source_byte(monitor_row, logical_byte))
                            $fatal(1, "Wrong data row=%0d byte=%0d", monitor_row, logical_byte);
                        memory[write_address+lane] = m_axi_wdata[lane*8 +: 8];
                    end
                end
                if (m_axi_wlast !== (burst_beats_left == 1))
                    $fatal(1, "Wrong WLAST");
                write_address = write_address + AXI_BYTES;
                burst_beats_left = burst_beats_left - 1;
                row_beats_used = row_beats_used + 1;
                if (m_axi_wlast) begin
                    response_pending = 1;
                    response_delay = 3;
                    total_beats = ((row_start % AXI_BYTES) + case_bytes + AXI_BYTES - 1) / AXI_BYTES;
                    if (row_beats_used == total_beats) begin
                        monitor_row = monitor_row + 1;
                        row_beats_used = 0;
                    end
                end
            end
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 0;
                outstanding = 0;
                response_pending = 0;
                b_count = b_count + 1;
            end else if (response_pending && !m_axi_bvalid) begin
                if (response_delay == 0) begin
                    m_axi_bvalid <= 1;
                    m_axi_bresp <= case_bad_response ? 2'b10 : 2'b00;
                    m_axi_bid <= case_bad_id;
                end else begin
                    response_delay = response_delay - 1;
                end
            end
            if (done && (outstanding || response_pending || m_axi_bvalid))
                $fatal(1, "done preceded the final write response");
        end
    end

    task automatic run_case(
        input bit packed_int8, input int valid_rows, input int valid_cols,
        input int address, input int stride, input bit bad_response, input bit bad_id
    );
        while (busy || done) @(negedge clk);
        case_rows = valid_rows;
        case_cols = valid_cols;
        case_int8 = packed_int8;
        case_addr = address;
        case_stride = stride;
        case_bytes = valid_cols * (packed_int8 ? 1 : 4);
        case_bad_response = bad_response;
        case_bad_id = bad_id;
        case_invalid = valid_rows == 0 || valid_rows > ROWS || valid_cols == 0 || valid_cols > COLS;
        read_count = 0; aw_count = 0; b_count = 0;
        monitor_row = 0; row_beats_used = 0;
        outstanding = 0; response_pending = 0; burst_beats_left = 0;
        for (int i = 0; i < MEMORY_BYTES; i++) begin
            memory[i] = 8'ha5;
            expected_memory[i] = 8'ha5;
        end
        if (!case_invalid)
            for (int row = 0; row < valid_rows; row++)
                for (int b = 0; b < case_bytes; b++)
                    expected_memory[address + row*stride + b] = source_byte(row, b);
        tile_addr = 64'(address);
        tile_stride_bytes = 32'(stride);
        tile_valid_rows = 32'(valid_rows);
        tile_valid_cols = 32'(valid_cols);
        int8_mode = packed_int8;
        tile_valid = 1;
        @(negedge clk);
        tile_valid = 0;
        // The accepted dimensions, format, and addresses must be latched.
        tile_addr = '1; tile_stride_bytes = '1;
        tile_valid_rows = 0; tile_valid_cols = 0; int8_mode = !packed_int8;
        wait(done); #1;
        if (error !== (case_invalid || bad_response || bad_id))
            $fatal(1, "Wrong error status rows=%0d cols=%0d mode=%0d", valid_rows, valid_cols, packed_int8);
        if (read_count != (case_invalid ? 0 : valid_rows) ||
            (case_invalid ? aw_count != 0 : (aw_count == 0 || b_count != aw_count)))
            $fatal(1, "Wrong read/burst/response count %0d/%0d/%0d", read_count, aw_count, b_count);
        for (int i = 0; i < MEMORY_BYTES; i++)
            if (memory[i] !== expected_memory[i])
                $fatal(1, "Data or sentinel changed at address=%0d actual=%0h expected=%0h", i, memory[i], expected_memory[i]);
        case_count = case_count + 1;
        @(negedge clk);
    endtask

    initial begin
        reset = 1; tile_valid = 0; int8_mode = 0;
        tile_addr = 0; tile_stride_bytes = 0; tile_valid_rows = 0; tile_valid_cols = 0;
        repeat (3) @(negedge clk);
        reset = 0;
        // No reset between cases: full tiles, row-only, column-only, and combined tails.
        for (int mode = 0; mode < 2; mode++)
            for (int rows = 1; rows <= ROWS; rows++)
                for (int cols = 1; cols <= COLS; cols++)
                    for (int offset = 0; offset < AXI_BYTES; offset++)
                        run_case(1'(mode), rows, cols, 64 + offset, COLS*4 + 5, 0, 0);
        for (int mode = 0; mode < 2; mode++)
            for (int offset = 0; offset < AXI_BYTES; offset++)
                run_case(1'(mode), ROWS, COLS, 4092 + offset, COLS*4 + 5, 0, 0);
        run_case(0, ROWS, COLS, 4095, COLS*4 + 5, 1, 0);
        run_case(1, ROWS, COLS, 65, COLS*4 + 5, 0, 1);
        run_case(0, 0, COLS, 64, 128, 0, 0);
        run_case(1, ROWS, 0, 64, 128, 0, 0);
        run_case(0, ROWS+1, COLS, 64, 128, 0, 0);
        run_case(1, ROWS, COLS+1, 64, 128, 0, 0);
        run_case(1, ROWS, COLS, 67, COLS*4 + 5, 0, 0);
        $display("PASS result_write_dma ROWS=%0d COLS=%0d cases=%0d", ROWS, COLS, case_count);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "Timeout");
    end
endmodule
