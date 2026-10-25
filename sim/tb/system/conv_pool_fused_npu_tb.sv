`timescale 1ns/1ps

// Compare the existing memory-to-memory Conv/Pool chain with one fused Conv
// descriptor. The AXI model stalls every channel and records actual byte traffic.
module conv_pool_fused_npu_tb #(
    parameter int unsigned OUT_H = 4,
    parameter int unsigned OUT_W = 8,
    parameter int unsigned COUT = 8,
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned POOL_KH = 2,
    parameter int unsigned POOL_KW = 2,
    parameter int unsigned POOL_SH = 2,
    parameter int unsigned POOL_SW = 2,
    parameter int unsigned LINE_WORDS = POOL_KH*OUT_W*(COUT/4),
    parameter bit CAPACITY_FALLBACK = 0,
    parameter int unsigned CONV_CACHE_LINES = 256,
    parameter int unsigned WRITE_RESPONSE_DELAY = 5,
    parameter bit REQUIRE_FULL_BUFFER = 0,
    parameter int unsigned POOL_OUTPUT_FIFO_DEPTH = 16,
    parameter bit EXPECT_POOL_OVERLAP = 0,
    parameter bit EXPECT_POOL_BACKPRESSURE = 0
);
    localparam int POOL_H = (OUT_H-POOL_KH)/POOL_SH+1;
    localparam int POOL_W = (OUT_W-POOL_KW)/POOL_SW+1;
    localparam logic [31:0] POOL_CONFIG =
        (POOL_KH == 2 && POOL_KW == 2 && POOL_SH == 2 && POOL_SW == 2) ? 0 :
        (POOL_SW<<24)|(POOL_SH<<16)|(POOL_KW<<8)|POOL_KH;
    localparam int MEM_WORDS = 32768;
    localparam int INPUT_BASE = 'h1000;
    localparam int WEIGHT_BASE = 'h4000;
    localparam int CONV_BASE = 'h8000;
    localparam int POOL_BASE = 'hc000;
    localparam int PARAM_BASE = 'h10000;
    localparam int DESC_BASE = 'h11000;
    localparam int CIN = 8;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    logic start = 0;
    logic [15:0] desc_count = 0;
    logic busy, done, error;
    logic signed [31:0] acc_out [ROWS][COLS];
    logic [0:0] arid, rid, awid, bid;
    logic [63:0] araddr, awaddr, rdata;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, awburst, rresp, bresp;
    logic arvalid, arready, rlast, rvalid, rready;
    logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic [31:0] mem [0:MEM_WORDS-1];
    logic [7:0] saved_pool [0:POOL_H*POOL_W*COUT-1];

    int kernel_size = 3;
    int pattern_seed = 0;
    bit per_channel = 0;
    bit relu_enable = 0;
    int phase = 0; // 0: unfused, 1: fused, 2: expected rejection
    int conv_bytes = OUT_H * OUT_W * COUT;
    int pool_bytes = POOL_H * POOL_W * COUT;
    int expected_pool_reads = POOL_H * POOL_W * POOL_KH * POOL_KW * COUT;
    int cycle_q;
    int read_beats_q, write_bytes_q, conv_read_bursts_q;
    int conv_write_bytes_q, logical_pool_read_bytes_q;
    int full_buffer_cycles_q;
    int conv_cache_flushes_q;
    int pool_inputs_while_b_pending_q, source_retire_while_b_pending_q;
    int pool_backpressure_cycles_q, final_response_wait_cycles_q;
    int launch_write_start = 0;

    npu_top #(
        .ROWS(ROWS), .COLS(COLS), .K_TILE_SIZE(32),
        .CONV_CACHE_LINES(CONV_CACHE_LINES),
        .POOL_LINE_WORDS(LINE_WORDS),
        .POOL_OUTPUT_FIFO_DEPTH(POOL_OUTPUT_FIFO_DEPTH)
    ) u_dut (
        .clk(clk), .reset(reset), .start(start),
        .desc_base(64'(DESC_BASE)), .desc_count(desc_count),
        .busy(busy), .done(done), .error(error), .acc_out(acc_out),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
        .m_axi_bready(bready)
    );

    logic rd_active_q, rvalid_q;
    logic [63:0] rd_addr_q, rdata_q;
    logic [8:0] rd_left_q;
    logic [0:0] rd_id_q;
    logic rlast_q;
    int read_wait_q;
    logic wr_active_q, b_pending_q, bvalid_q;
    logic [63:0] wr_addr_q;
    logic [8:0] wr_left_q;
    logic [0:0] wr_id_q;
    int b_wait_q;

    assign arready = !rd_active_q && !rvalid_q && (cycle_q % 5 != 1);
    assign rid = rd_id_q;
    assign rvalid = rvalid_q;
    assign rdata = rdata_q;
    assign rlast = rlast_q;
    assign rresp = 0;
    assign awready = !wr_active_q && !b_pending_q && !bvalid_q &&
                     (cycle_q % 5 < 3);
    assign wready = wr_active_q && (cycle_q % 7 >= 3);
    assign bid = wr_id_q;
    assign bresp = 0;
    assign bvalid = bvalid_q;

    always @(posedge clk) begin : memory_model
        if (reset) begin
            cycle_q <= 0;
            rd_active_q <= 0;
            rvalid_q <= 0;
            rd_addr_q <= 0;
            rd_left_q <= 0;
            rd_id_q <= 0;
            rdata_q <= 0;
            rlast_q <= 0;
            read_wait_q <= 0;
            wr_active_q <= 0;
            wr_addr_q <= 0;
            wr_left_q <= 0;
            wr_id_q <= 0;
            b_pending_q <= 0;
            bvalid_q <= 0;
            b_wait_q <= 0;
            read_beats_q <= 0;
            write_bytes_q <= 0;
            conv_read_bursts_q <= 0;
            conv_write_bytes_q <= 0;
            logical_pool_read_bytes_q <= 0;
            full_buffer_cycles_q <= 0;
            conv_cache_flushes_q <= 0;
            pool_inputs_while_b_pending_q <= 0;
            source_retire_while_b_pending_q <= 0;
            pool_backpressure_cycles_q <= 0;
            final_response_wait_cycles_q <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            // Data reaching memory is insufficient for completion: the last
            // response still belongs to this program, including a queued pool
            // result after its source result tile has already been released.
            if ((wr_active_q || b_pending_q || bvalid_q) && (!busy || done))
                $fatal(1, "NPU completed before its AXI write response");
            if (phase == 1) begin
                if (b_pending_q || bvalid_q) begin
                    if (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                        u_dut.u_npu_gemm_engine.pool_in_ready)
                        pool_inputs_while_b_pending_q <= pool_inputs_while_b_pending_q + 1;
                    if (u_dut.u_npu_gemm_engine.c_write_done)
                        source_retire_while_b_pending_q <= source_retire_while_b_pending_q + 1;
                    if (write_bytes_q-launch_write_start == pool_bytes)
                        final_response_wait_cycles_q <= final_response_wait_cycles_q + 1;
                end
                if (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                    !u_dut.u_npu_gemm_engine.pool_in_ready)
                    pool_backpressure_cycles_q <= pool_backpressure_cycles_q + 1;
            end
            if (u_dut.u_npu_gemm_engine.u_read_path.conv_cache_invalidate)
                conv_cache_flushes_q <= conv_cache_flushes_q + 1;
            if (phase == 1 &&
                u_dut.u_npu_gemm_engine.u_result_tile_buffer.bank_state_q[0] >= 2 &&
                u_dut.u_npu_gemm_engine.u_result_tile_buffer.bank_state_q[1] >= 2)
                full_buffer_cycles_q <= full_buffer_cycles_q + 1;
            // Count the pool engine's logical AXI32 request bytes separately:
            // its AXI64 adapter can read the same aligned beat twice.
            if (u_dut.u_pool.u_rd.req_valid && u_dut.u_pool.u_rd.req_ready)
                logical_pool_read_bytes_q <= logical_pool_read_bytes_q +
                    4 * u_dut.u_pool.u_rd.req_beats;

            if (arvalid && arready) begin
                if (arsize !== 3'd3 || arburst !== 2'b01 ||
                    araddr[2:0] !== 0 ||
                    araddr + (64'(arlen)+1)*8 > MEM_WORDS*4 ||
                    araddr[11:0] + (64'(arlen)+1)*8 > 4096)
                    $fatal(1, "Invalid read burst addr=%h len=%0d", araddr, arlen);
                if (araddr >= CONV_BASE && araddr < CONV_BASE + conv_bytes) begin
                    if (phase != 0)
                        $fatal(1, "Fused/rejected command read intermediate Conv output");
                    conv_read_bursts_q <= conv_read_bursts_q + 1;
                end
                rd_active_q <= 1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0,arlen}+1'b1;
                rd_id_q <= arid;
                read_wait_q <= 4 + (cycle_q % 3);
            end
            if (read_wait_q > 0) read_wait_q <= read_wait_q - 1;
            if (rd_active_q && !rvalid_q && read_wait_q == 0) begin
                rvalid_q <= 1;
                rdata_q <= {mem[(rd_addr_q>>2)+1],mem[rd_addr_q>>2]};
                rlast_q <= (rd_left_q == 1);
            end
            if (rvalid && rready) begin
                read_beats_q <= read_beats_q + 1;
                rvalid_q <= 0;
                if (rd_left_q == 1) rd_active_q <= 0;
                else begin
                    rd_addr_q <= rd_addr_q + 8;
                    rd_left_q <= rd_left_q - 1;
                    read_wait_q <= 2;
                end
            end

            if (awvalid && awready) begin
                if (phase == 2)
                    $fatal(1, "Rejected descriptor issued an AXI write");
                if (awsize !== 3'd2 || awburst !== 2'b01 ||
                    awaddr[1:0] !== 0 ||
                    awaddr + (64'(awlen)+1)*4 > MEM_WORDS*4 ||
                    awaddr[11:0] + (64'(awlen)+1)*4 > 4096)
                    $fatal(1, "Invalid write burst addr=%h len=%0d", awaddr, awlen);
                if (!((phase == 0 && awaddr >= CONV_BASE &&
                       awaddr+(64'(awlen)+1)*4 <= CONV_BASE+conv_bytes) ||
                      (awaddr >= POOL_BASE &&
                       awaddr+(64'(awlen)+1)*4 <= POOL_BASE+pool_bytes)))
                    $fatal(1, "Unexpected output range addr=%h phase=%0d", awaddr, phase);
                wr_active_q <= 1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0,awlen}+1'b1;
                wr_id_q <= awid;
            end
            if (wvalid && wready) begin
                if (wlast !== (wr_left_q == 1) || wstrb !== 4'hf)
                    $fatal(1, "Unexpected WLAST/WSTRB");
                mem[wr_addr_q>>2] <= wdata;
                write_bytes_q <= write_bytes_q + 4;
                if (wr_addr_q >= CONV_BASE && wr_addr_q < CONV_BASE+conv_bytes)
                    conv_write_bytes_q <= conv_write_bytes_q + 4;
                if (wr_left_q == 1) begin
                    wr_active_q <= 0;
                    b_pending_q <= 1;
                    b_wait_q <= WRITE_RESPONSE_DELAY;
                end else begin
                    wr_left_q <= wr_left_q - 1;
                    wr_addr_q <= wr_addr_q + 4;
                end
            end
            if (b_wait_q > 0) b_wait_q <= b_wait_q - 1;
            if (b_pending_q && b_wait_q == 0) begin
                b_pending_q <= 0;
                bvalid_q <= 1;
            end
            if (bvalid && bready) bvalid_q <= 0;
        end
    end

    function automatic int signed xval(input int h, w, c);
        return ((h*11+w*5+c*3+pattern_seed*7)%15)-7;
    endfunction
    function automatic int signed kval(input int oc, kh, kw, ci);
        return ((oc*13+kh*5+kw*9+ci*7+pattern_seed)%7)-3;
    endfunction
    function automatic int signed biasval(input int oc);
        return (oc-4)*3;
    endfunction
    function automatic int signed multiplier(input int oc);
        return per_channel ? (1 + oc%3) : 3;
    endfunction
    function automatic int signed quant_shift(input int oc);
        return per_channel ? (3 + oc%2) : 4;
    endfunction
    function automatic int signed conv_golden(input int oh, ow, oc);
        int signed acc, product, value, shift;
        acc = biasval(oc);
        for (int kh=0; kh<kernel_size; kh++)
            for (int kw=0; kw<kernel_size; kw++)
                for (int ci=0; ci<CIN; ci++)
                    acc += xval(oh+kh,ow+kw,ci)*kval(oc,kh,kw,ci);
        product = acc*multiplier(oc);
        shift = quant_shift(oc);
        value = product >= 0 ? (product+(1<<(shift-1))) >>> shift :
                              -((-product+(1<<(shift-1))) >>> shift);
        if (relu_enable && value < 0) value = 0;
        if (value > 127) value = 127;
        if (value < -128) value = -128;
        return value;
    endfunction
    function automatic int signed pool_golden(input int ph, pw, oc);
        int signed best, value;
        best = -128;
        for (int dh=0; dh<POOL_KH; dh++)
            for (int dw=0; dw<POOL_KW; dw++) begin
                value = conv_golden(ph*POOL_SH+dh,pw*POOL_SW+dw,oc);
                if (value > best) best = value;
            end
        return best;
    endfunction
    function automatic logic [7:0] memory_byte(input int address);
        return mem[address>>2][8*(address%4)+:8];
    endfunction
    task automatic put_byte(input int address, input int signed value);
        if (value < -128 || value > 127 || address >= MEM_WORDS*4)
            $fatal(1,"Invalid initialization byte");
        mem[address>>2][8*(address%4)+:8] = 8'(value);
    endtask

    task automatic prepare_data;
        int k, padded_k;
        k = kernel_size*kernel_size*CIN;
        padded_k = (k+7)&~7;
        for (int i=0; i<MEM_WORDS; i++) mem[i] = 'h5a5a5a5a;
        for (int h=0; h<OUT_H+kernel_size-1; h++)
            for (int w=0; w<OUT_W+kernel_size-1; w++)
                for (int c=0; c<CIN; c++)
                    put_byte(INPUT_BASE+((h*(OUT_W+kernel_size-1)+w)*CIN)+c,xval(h,w,c));
        for (int oc=0; oc<COUT; oc++)
            for (int kh=0; kh<kernel_size; kh++)
                for (int kw=0; kw<kernel_size; kw++)
                    for (int ci=0; ci<CIN; ci++)
                        put_byte(WEIGHT_BASE+oc*padded_k+(kh*kernel_size+kw)*CIN+ci,
                                 kval(oc,kh,kw,ci));
        for (int i=0; i<4+COUT*3; i++) mem[PARAM_BASE/4+i] = 0;
        mem[PARAM_BASE/4] = 3;
        mem[PARAM_BASE/4+1] = 4;
        // Each channel stores one bias/multiplier/shift record.
        for (int oc=0; oc<COUT; oc++) begin
            if (per_channel) begin
                mem[PARAM_BASE/4+4+3*oc] = 32'(biasval(oc));
                mem[PARAM_BASE/4+5+3*oc] = 32'(multiplier(oc));
                mem[PARAM_BASE/4+6+3*oc] = 32'(quant_shift(oc));
            end else mem[PARAM_BASE/4+4+oc] = 32'(biasval(oc));
        end
    endtask

    task automatic configure_conv(input bit fused, input int dataflow,
                                  input int height, width);
        int flags;
        for (int i=0; i<32; i++) mem[DESC_BASE/4+i] = 0;
        flags = 3 | (relu_enable ? 4 : 0) | (per_channel ? 8 : 0) |
                (dataflow == 1 ? 32 : 0) | (dataflow == 2 ? 64 : 0) |
                (fused ? 128 : 0);
        mem[DESC_BASE/4] = 32'((flags<<8)|2);
        mem[DESC_BASE/4+1] = 32'(height*width);
        mem[DESC_BASE/4+2] = COUT;
        mem[DESC_BASE/4+3] = 32'(kernel_size*kernel_size*CIN);
        mem[DESC_BASE/4+4] = INPUT_BASE;
        mem[DESC_BASE/4+6] = WEIGHT_BASE;
        mem[DESC_BASE/4+8] = fused ? POOL_BASE : CONV_BASE;
        mem[DESC_BASE/4+10] = ((width+kernel_size-1)<<16)|(height+kernel_size-1);
        mem[DESC_BASE/4+11] = (kernel_size<<24)|(kernel_size<<16)|CIN;
        mem[DESC_BASE/4+12] = 'h00000101;
        mem[DESC_BASE/4+13] = PARAM_BASE;
        mem[DESC_BASE/4+15] = fused ? POOL_CONFIG : 0;
        if (!fused) begin
            mem[DESC_BASE/4+16] = 3;
            mem[DESC_BASE/4+17] = height;
            mem[DESC_BASE/4+18] = width;
            mem[DESC_BASE/4+19] = COUT;
            mem[DESC_BASE/4+20] = CONV_BASE;
            mem[DESC_BASE/4+24] = POOL_BASE;
            mem[DESC_BASE/4+31] = POOL_CONFIG;
        end
        desc_count = fused ? 1 : 2;
    endtask

    task automatic launch(input bit expect_error, output int cycles);
        @(negedge clk);
        launch_write_start = write_bytes_q;
        start = 1;
        @(negedge clk);
        start = 0;
        cycles = 0;
        while (!done && cycles < 500000) begin
            @(negedge clk);
            cycles++;
        end
        if (!done) $fatal(1,"Conv/Pool program timeout phase=%0d",phase);
        if (error !== expect_error)
            $fatal(1,"Unexpected error=%b expected=%b phase=%0d",error,expect_error,phase);
        repeat (3) @(negedge clk);
        if (busy) $fatal(1,"NPU remains busy after program completion");
    endtask

    task automatic run_pair(input int dataflow, input bit use_pc,
                            input bit use_relu, input int kernel, seed);
        int cycles, fused_cycles;
        int write_before, read_before, logical_before, conv_read_before, conv_write_before;
        int baseline_write_bytes, baseline_logical_reads, fused_write_bytes;
        int baseline_read_beats, flushes_before;
        int final_wait_before;
        int expected, address;
        kernel_size = kernel;
        pattern_seed = seed;
        per_channel = use_pc;
        relu_enable = use_relu;
        phase = 0;
        prepare_data();
        configure_conv(0,dataflow,OUT_H,OUT_W);
        write_before = write_bytes_q;
        read_before = read_beats_q;
        logical_before = logical_pool_read_bytes_q;
        launch(0,cycles);
        baseline_write_bytes = write_bytes_q-write_before;
        baseline_read_beats = read_beats_q-read_before;
        baseline_logical_reads = logical_pool_read_bytes_q-logical_before;
        if (baseline_write_bytes != conv_bytes+pool_bytes || baseline_logical_reads != expected_pool_reads)
            $fatal(1,"Baseline traffic mismatch write=%0d read=%0d",baseline_write_bytes,baseline_logical_reads);
        for (int y=0; y<OUT_H; y++)
            for (int x=0; x<OUT_W; x++)
                for (int c=0; c<COUT; c++) begin
                    address = CONV_BASE+(y*OUT_W+x)*COUT+c;
                    expected = conv_golden(y,x,c);
                    if (memory_byte(address) !== 8'(expected))
                        $fatal(1,"Baseline Conv mismatch y=%0d x=%0d c=%0d got=%0d expected=%0d",
                               y,x,c,$signed(memory_byte(address)),expected);
                end
        for (int y=0; y<POOL_H; y++)
            for (int x=0; x<POOL_W; x++)
                for (int c=0; c<COUT; c++) begin
                    address = (y*POOL_W+x)*COUT+c;
                    expected = pool_golden(y,x,c);
                    saved_pool[address] = memory_byte(POOL_BASE+address);
                    if (saved_pool[address] !== 8'(expected))
                        $fatal(1,"Baseline Pool mismatch y=%0d x=%0d c=%0d",y,x,c);
                end

        $display("UNFUSED_BASELINE PASS mode=%0d pc=%0b relu=%0b K=%0d cycles=%0d write_bytes=%0d logical_pool_reads=%0d read_beats=%0d",
                 dataflow,use_pc,use_relu,kernel*kernel*CIN,cycles,
                 baseline_write_bytes,baseline_logical_reads,baseline_read_beats);
        if ($test$plusargs("BASELINE_ONLY")) return;

        // Run again without reset: command state, cache invalidation and line
        // buffer initialization must all work across launches.
        for (int i=0; i<conv_bytes/4; i++) mem[CONV_BASE/4+i] = 'h5a5a5a5a;
        for (int i=0; i<pool_bytes/4; i++) mem[POOL_BASE/4+i] = 'h5a5a5a5a;
        phase = 1;
        configure_conv(1,dataflow,OUT_H,OUT_W);
        write_before = write_bytes_q;
        read_before = read_beats_q;
        logical_before = logical_pool_read_bytes_q;
        conv_read_before = conv_read_bursts_q;
        conv_write_before = conv_write_bytes_q;
        flushes_before = conv_cache_flushes_q;
        final_wait_before = final_response_wait_cycles_q;
        launch(CAPACITY_FALLBACK,fused_cycles);
        if (CAPACITY_FALLBACK) begin
            if (write_bytes_q != write_before)
                $fatal(1,"Insufficient-capacity fused command wrote output");
            $display("CAPACITY_FALLBACK PASS: standalone pair correct, fused command rejected without writes");
            return;
        end
        if (final_response_wait_cycles_q == final_wait_before)
            $fatal(1,"Fused test did not cover waiting for the final B response");
        if (u_dut.u_npu_gemm_engine.pool_channel_tiling_q !==
            ((POOL_KH*OUT_W*(COUT/4)) > LINE_WORDS))
            $fatal(1,"Unexpected pooling channel-tiling mode");
        if (conv_cache_flushes_q-flushes_before != 1)
            $fatal(1,"Conv input cache must be invalidated once per layer");
        fused_write_bytes = write_bytes_q-write_before;
        if (fused_write_bytes != pool_bytes || logical_pool_read_bytes_q != logical_before ||
            conv_read_bursts_q != conv_read_before || conv_write_bytes_q != conv_write_before)
            $fatal(1,"Fused program performed unexpected intermediate memory traffic");
        if (baseline_write_bytes+baseline_logical_reads-fused_write_bytes != conv_bytes+expected_pool_reads)
            $fatal(1,"Unexpected saved intermediate write and standalone window-read bytes");
        for (int i=0; i<pool_bytes; i++)
            if (memory_byte(POOL_BASE+i) !== saved_pool[i])
                $fatal(1,"Fused output mismatch byte=%0d got=%0d expected=%0d",
                       i,$signed(memory_byte(POOL_BASE+i)),$signed(saved_pool[i]));
        for (int i=0; i<conv_bytes/4; i++)
            if (mem[CONV_BASE/4+i] !== 'h5a5a5a5a)
                $fatal(1,"Fused program changed intermediate sentinel");
        $display("FUSED_PAIR PASS mode=%0d pc=%0b relu=%0b K=%0d baseline_cycles=%0d fused_cycles=%0d baseline_write_bytes=%0d pool_logical_read_bytes=%0d fused_write_bytes=%0d saved_logical_bytes=%0d fused_read_beats=%0d",
                 dataflow,use_pc,use_relu,kernel*kernel*CIN,cycles,fused_cycles,
                 baseline_write_bytes,baseline_logical_reads,fused_write_bytes,conv_bytes+expected_pool_reads,
                 read_beats_q-read_before);
    endtask

    task automatic rejected_case(input int kind);
        int cycles, writes_before, too_wide;
        // Even one COLS-channel tile must exceed capacity to be rejected.
        too_wide = LINE_WORDS/(POOL_KH*(COLS/4))+1;
        if (too_wide < POOL_KW) too_wide = POOL_KW;
        while ((OUT_H*too_wide)%ROWS != 0) too_wide++;
        phase = 2;
        configure_conv(1,0,OUT_H,OUT_W);
        case (kind)
            0: mem[DESC_BASE/4][7:0] = 1; // FC fusion with multiple physical M tiles.
            1: mem[DESC_BASE/4][15:8] = 8'h81; // No requantization.
            2: mem[DESC_BASE/4+15] = 'h02000202; // Zero stride_h in a nonzero word.
            3: mem[DESC_BASE/4+15] = 'h0101ffff; // Window exceeds input.
            4: configure_conv(1,0,OUT_H,too_wide); // Valid tile geometry, excessive line capacity.
        endcase
        writes_before = write_bytes_q;
        launch(1,cycles);
        if (write_bytes_q != writes_before)
            $fatal(1,"Rejected command wrote data kind=%0d",kind);
        $display("FUSED_REJECT PASS kind=%0d cycles=%0d",kind,cycles);
    endtask

    initial begin : run
        int cycles;
        if (OUT_H < POOL_KH || OUT_W < POOL_KW ||
            (OUT_H*OUT_W)%ROWS != 0 || COUT%COLS != 0 || COUT%4 != 0 ||
            COLS < 4 || COLS%4 != 0)
            $fatal(1,"Unsupported fused test geometry");
        for (int i=0; i<MEM_WORDS; i++) mem[i] = 0;
        repeat (6) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);
        run_pair(0,0,0,3,0);
        run_pair(1,1,1,3,1);
        run_pair(2,1,0,1,2);
        if (CAPACITY_FALLBACK) begin
            $display("Configurable pooling capacity fallback system PASS");
            $finish;
        end
        if ($test$plusargs("BASELINE_ONLY")) begin
            $display("Conv/Pool baseline reference PASS");
            $finish;
        end
        for (int i=0; i<5; i++) rejected_case(i);
        // A legal launch after all rejected commands must clear sticky status.
        phase = 1;
        prepare_data();
        configure_conv(1,0,OUT_H,OUT_W);
        launch(0,cycles);
        for (int y=0; y<POOL_H; y++)
            for (int x=0; x<POOL_W; x++)
                for (int c=0; c<COUT; c++)
                    if (memory_byte(POOL_BASE+(y*POOL_W+x)*COUT+c) !==
                        8'(pool_golden(y,x,c)))
                        $fatal(1,"Recovery output mismatch");
        if (REQUIRE_FULL_BUFFER && full_buffer_cycles_q == 0)
            $fatal(1,"Test did not exercise two occupied result buffers");
        if (EXPECT_POOL_OVERLAP &&
            (pool_inputs_while_b_pending_q < 2 || source_retire_while_b_pending_q == 0))
            $fatal(1,"Test did not exercise pool input/tile retirement while B is pending");
        if (EXPECT_POOL_BACKPRESSURE && pool_backpressure_cycles_q == 0)
            $fatal(1,"Test did not exercise pool input backpressure");
        $display("POOL_PIPELINE_COVERAGE depth=%0d inputs_while_B_pending=%0d source_retire_while_B_pending=%0d input_stall_cycles=%0d final_B_wait_cycles=%0d",
            POOL_OUTPUT_FIFO_DEPTH, pool_inputs_while_b_pending_q,
            source_retire_while_b_pending_q, pool_backpressure_cycles_q,
            final_response_wait_cycles_q);
        $display("Conv -> MaxPool fusion system PASS: signed INT8, channel tiling, multi-K/A reuse/B stationary, delayed AXI, exact traffic, descriptor rejection and recovery; full_buffer_cycles=%0d",full_buffer_cycles_q);
        $finish;
    end
endmodule
