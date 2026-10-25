`timescale 1ns/1ps

// One DDR image, serialized layer descriptors, and independently generated
// layer goldens. Checks run at each layer boundary before aliases are reused.
module graph_model_npu_tb #(
    parameter int unsigned MEM_WORDS = 8388608,
    parameter int unsigned MAX_LAYER_WORDS = 262144
);
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1, start = 0;
    logic busy, done, error;
    logic signed [31:0] acc_out [4][4];
    logic [63:0] desc_base_cfg, logits_base_cfg;
    logic [15:0] desc_count_cfg;
    int unsigned image_words_cfg, logits_count_cfg;
    int unsigned ddr_rd_latency_cfg, ddr_wr_latency_cfg;
    longint unsigned max_cycles_cfg;
    string memfile, checksfile, dumpfile;
    int checks_fd;

    logic [31:0] mem [0:MEM_WORDS-1];
    logic [31:0] expected_mem [0:MAX_LAYER_WORDS-1];
    logic [0:0] arid, rid, awid, bid;
    logic [63:0] araddr, awaddr, rdata;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, awburst, rresp, bresp;
    logic arvalid, arready, rlast, rvalid, rready;
    logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    logic [31:0] wdata;
    logic [3:0] wstrb;

    logic rd_active_q, wr_active_q, b_pending_q, bvalid_q;
    logic [63:0] rd_addr_q, wr_addr_q;
    logic [8:0] rd_left_q, wr_left_q;
    logic [0:0] rd_id_q, wr_id_q;
    int unsigned rd_wait_q, b_wait_q;
    longint unsigned reads_q, writes_q, written_bytes_q;

`ifdef NPU_PERF_ENABLE
    logic [63:0] p_total_cycles, p_executor_cycles, p_pool_cycles;
    logic [63:0] p_ar_transactions, p_r_beats, p_aw_transactions, p_w_beats;
    logic [63:0] p_written_bytes;
    logic [63:0] p_ar_stall_cycles, p_r_wait_cycles, p_aw_stall_cycles;
    logic [63:0] p_w_stall_cycles, p_b_wait_cycles;
    logic p_layer_done;
    logic [31:0] p_layer_index;
    logic [7:0] p_layer_opcode;
    logic [63:0] p_layer_cycles, p_layer_executor, p_layer_pool;
    logic [63:0] p_layer_ar, p_layer_r_beats, p_layer_aw, p_layer_w_beats;
    longint unsigned previous_written_bytes;
    int unsigned checked_layers;
`endif

    npu_top u_dut (
        .clk(clk), .reset(reset), .start(start),
        .desc_base(desc_base_cfg), .desc_count(desc_count_cfg),
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
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
`ifdef NPU_PERF_ENABLE
        , .perf_total_cycles(p_total_cycles),
        .perf_executor_cycles(p_executor_cycles), .perf_pool_cycles(p_pool_cycles),
        .perf_ar_transactions(p_ar_transactions), .perf_r_beats(p_r_beats),
        .perf_aw_transactions(p_aw_transactions), .perf_w_beats(p_w_beats),
        .perf_written_bytes(p_written_bytes), .perf_ar_stall_cycles(p_ar_stall_cycles),
        .perf_r_wait_cycles(p_r_wait_cycles), .perf_aw_stall_cycles(p_aw_stall_cycles),
        .perf_w_stall_cycles(p_w_stall_cycles), .perf_b_wait_cycles(p_b_wait_cycles),
        .perf_layer_done_pulse(p_layer_done), .perf_completed_layer_index(p_layer_index),
        .perf_completed_layer_opcode(p_layer_opcode), .perf_completed_layer_cycles(p_layer_cycles),
        .perf_completed_layer_executor_cycles(p_layer_executor),
        .perf_completed_layer_pool_cycles(p_layer_pool), .perf_completed_layer_ar(p_layer_ar),
        .perf_completed_layer_r_beats(p_layer_r_beats), .perf_completed_layer_aw(p_layer_aw),
        .perf_completed_layer_w_beats(p_layer_w_beats)
`endif
    );

    assign arready = !rd_active_q;
    assign rid = rd_id_q;
    assign rvalid = rd_active_q && rd_wait_q == 0;
    assign rdata = {mem[int'(rd_addr_q >> 2) + 1], mem[int'(rd_addr_q >> 2)]};
    assign rresp = 0;
    assign rlast = rd_left_q == 1;
    assign awready = !wr_active_q && !b_pending_q && !bvalid_q;
    assign wready = wr_active_q;
    assign bid = wr_id_q;
    assign bvalid = bvalid_q;
    assign bresp = 0;

    // Read latency delays the first R beat; write latency delays the B response
    // after WLAST. Zero write latency matches the original ResNet8 DDR model.
    // One read burst and one write/B response may be outstanding independently.
    always @(posedge clk) begin : ddr_model
        if (reset) begin
            rd_active_q <= 0; rd_wait_q <= 0; rd_addr_q <= 0;
            rd_left_q <= 0; rd_id_q <= 0;
            wr_active_q <= 0; b_wait_q <= 0; wr_addr_q <= 0;
            wr_left_q <= 0; wr_id_q <= 0; b_pending_q <= 0; bvalid_q <= 0;
            reads_q <= 0; writes_q <= 0; written_bytes_q <= 0;
        end else begin
            if (arvalid && arready) begin
                if (arsize != 3 || arburst != 1 || araddr[2:0] != 0 ||
                    araddr >= 64'(image_words_cfg)*4 ||
                    (64'(arlen)+1)*8 > 64'(image_words_cfg)*4-araddr ||
                    64'(araddr[11:0])+(64'(arlen)+1)*8 > 4096)
                    $fatal(1, "Bad AXI AR addr=%h len=%0d size=%0d", araddr, arlen, arsize);
                rd_active_q <= 1;
                rd_wait_q <= ddr_rd_latency_cfg;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0, arlen}+9'd1;
                rd_id_q <= arid;
            end else if (rd_active_q && rd_wait_q != 0) begin
                rd_wait_q <= rd_wait_q-1;
            end else if (rvalid && rready) begin
                reads_q <= reads_q+1;
                if (rlast)
                    rd_active_q <= 0;
                else begin
                    rd_addr_q <= rd_addr_q+8;
                    rd_left_q <= rd_left_q-1;
                end
            end
            if (awvalid && awready) begin
                if (awsize != 2 || awburst != 1 || awaddr[1:0] != 0 ||
                    awaddr >= 64'(image_words_cfg)*4 ||
                    (64'(awlen)+1)*4 > 64'(image_words_cfg)*4-awaddr ||
                    64'(awaddr[11:0])+(64'(awlen)+1)*4 > 4096)
                    $fatal(1, "Bad AXI AW addr=%h len=%0d size=%0d", awaddr, awlen, awsize);
                wr_active_q <= 1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0, awlen}+9'd1;
                wr_id_q <= awid;
            end
            if (b_pending_q) begin
                if (b_wait_q > 1)
                    b_wait_q <= b_wait_q-1;
                else begin
                    b_wait_q <= 0;
                    b_pending_q <= 0;
                    bvalid_q <= 1;
                end
            end
            if (wvalid && wready) begin
                if (wlast != (wr_left_q == 1) || wr_addr_q >= 64'(image_words_cfg)*4)
                    $fatal(1, "Invalid AXI W addr=%h last=%b left=%0d", wr_addr_q, wlast, wr_left_q);
                for (int lane=0; lane<4; lane++)
                    if (wstrb[lane])
                        mem[int'(wr_addr_q >> 2)][8*lane+:8] <= wdata[8*lane+:8];
                writes_q <= writes_q+1;
                written_bytes_q <= written_bytes_q+64'($countones(wstrb));
                if (wr_left_q == 1) begin
                    wr_active_q <= 0;
                    if (ddr_wr_latency_cfg == 0)
                        bvalid_q <= 1;
                    else begin
                        b_pending_q <= 1;
                        b_wait_q <= ddr_wr_latency_cfg;
                    end
                end else begin
                    wr_addr_q <= wr_addr_q+4;
                    wr_left_q <= wr_left_q-1;
                end
            end
            if (bvalid && bready)
                bvalid_q <= 0;
        end
    end

`ifdef NPU_PERF_ENABLE
    always @(negedge clk) begin : check_completed_layer
        int scanned, expected_index, expected_opcode, golden_fd;
        int unsigned expected_bytes, expected_words;
        logic [63:0] expected_address;
        logic [7:0] actual_byte, golden_byte;
        string expected_file;
        if (reset) begin
            checked_layers = 0;
            previous_written_bytes = 0;
        end else if (p_layer_done) begin
            if (wr_active_q || b_pending_q || bvalid_q)
                $fatal(1, "Layer %0d completed with outstanding AXI traffic", p_layer_index);
            scanned = $fscanf(checks_fd, "%d %d %h %d %s", expected_index,
                              expected_opcode, expected_address, expected_bytes, expected_file);
            if (scanned != 5 || expected_index != int'(p_layer_index) ||
                expected_index != int'(checked_layers) || expected_opcode != int'(p_layer_opcode))
                $fatal(1, "Layer metadata mismatch index=%0d fields=%0d expected_index=%0d opcode=%0d/%0d",
                       p_layer_index, scanned, expected_index, expected_opcode, p_layer_opcode);
            if (expected_bytes == 0 || 64'(expected_bytes) > 64'(MAX_LAYER_WORDS)*4 ||
                expected_address >= 64'(image_words_cfg)*4 ||
                64'(expected_bytes) > 64'(image_words_cfg)*4-expected_address)
                $fatal(1, "Layer %0d golden range is outside memory/scratch", p_layer_index);
            expected_words = (expected_bytes+3)/4;
            golden_fd = $fopen(expected_file, "r");
            if (golden_fd == 0)
                $fatal(1, "Cannot open golden file %s", expected_file);
            $fclose(golden_fd);
            for (int unsigned word=0; word<expected_words; word++)
                expected_mem[word] = 'x;
            $readmemh(expected_file, expected_mem, 0, expected_words-1);
            for (int unsigned byte_index=0; byte_index<expected_bytes; byte_index++) begin
                actual_byte = mem[int'((expected_address+byte_index) >> 2)]
                                 [8*int'((expected_address+byte_index) & 3)+:8];
                golden_byte = expected_mem[byte_index >> 2][8*(byte_index & 3)+:8];
                if (actual_byte !== golden_byte)
                    $fatal(1, "Layer %0d mismatch byte=%0d addr=%h RTL=%h expected=%h",
                           p_layer_index, byte_index, expected_address+byte_index, actual_byte, golden_byte);
            end
            $display("LAYER_CHECK PASS index=%0d opcode=%0d checked_bytes=%0d",
                     p_layer_index, p_layer_opcode, expected_bytes);
            $display("PERF_LAYER,index=%0d,opcode=%0d,cycles=%0d,executor=%0d,pool=%0d,ar=%0d,read_beats=%0d,aw=%0d,write_beats=%0d,written_bytes=%0d",
                     p_layer_index, p_layer_opcode, p_layer_cycles, p_layer_executor, p_layer_pool,
                     p_layer_ar, p_layer_r_beats, p_layer_aw, p_layer_w_beats,
                     p_written_bytes-previous_written_bytes);
            $fflush();
            previous_written_bytes = p_written_bytes;
            checked_layers = checked_layers+1;
        end
    end
`endif

    initial begin : run_model
        longint unsigned cycles;
        int dump_fd, scanned, extra_index;
        int prediction, value, best;
        int unsigned desc_count_input;
        logic [7:0] raw_logit;
`ifndef NPU_PERF_ENABLE
        $fatal(1, "graph_model_npu_tb requires NPU_PERF_ENABLE");
`endif
        image_words_cfg = 0;
        logits_count_cfg = 1001;
        max_cycles_cfg = 64'd4000000000;
        ddr_rd_latency_cfg = 20;
        ddr_wr_latency_cfg = 0;
        if (!$value$plusargs("DDR_HEX=%s", memfile) ||
            !$value$plusargs("IMAGE_WORDS=%d", image_words_cfg) ||
            !$value$plusargs("DESC_BASE=%h", desc_base_cfg) ||
            !$value$plusargs("DESC_COUNT=%d", desc_count_input) ||
            !$value$plusargs("LOGITS_BASE=%h", logits_base_cfg) ||
            !$value$plusargs("LAYER_CHECKS=%s", checksfile))
            $fatal(1, "Provide DDR_HEX IMAGE_WORDS DESC_BASE DESC_COUNT LOGITS_BASE LAYER_CHECKS");
        void'($value$plusargs("LOGITS_COUNT=%d", logits_count_cfg));
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles_cfg));
        void'($value$plusargs("DDR_RD_LATENCY=%d", ddr_rd_latency_cfg));
        void'($value$plusargs("DDR_WR_LATENCY=%d", ddr_wr_latency_cfg));
        if (image_words_cfg == 0 || image_words_cfg > MEM_WORDS ||
            desc_count_input == 0 || desc_count_input > 65535 ||
            desc_base_cfg[5:0] != 0 || desc_base_cfg >= 64'(image_words_cfg)*4 ||
            64'(desc_count_input)*64 > 64'(image_words_cfg)*4-desc_base_cfg ||
            logits_count_cfg == 0 || logits_base_cfg >= 64'(image_words_cfg)*4 ||
            64'(logits_count_cfg) > 64'(image_words_cfg)*4-logits_base_cfg || max_cycles_cfg == 0)
            $fatal(1, "Invalid model memory, descriptor, logits, or timeout configuration");
        desc_count_cfg = 16'(desc_count_input);
        checks_fd = $fopen(checksfile, "r");
        if (checks_fd == 0)
            $fatal(1, "Cannot open layer metadata %s", checksfile);
        dump_fd = $fopen(memfile, "r");
        if (dump_fd == 0)
            $fatal(1, "Cannot open DDR image %s", memfile);
        $fclose(dump_fd);
        for (int unsigned word=0; word<MEM_WORDS; word++)
            mem[word] = 0;
        $readmemh(memfile, mem, 0, image_words_cfg-1);
        $display("DDR_READ_LATENCY_CYCLES,%0d", ddr_rd_latency_cfg);
        $display("DDR_WRITE_LATENCY_CYCLES,%0d", ddr_wr_latency_cfg);
        $display("MODEL_CONFIG,image_words=%0d,descriptor_count=%0d,logits_count=%0d,max_cycles=%0d",
                 image_words_cfg, desc_count_input, logits_count_cfg, max_cycles_cfg);
        repeat (5) @(negedge clk);
        reset = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        cycles = 0;
        while (!done && cycles < max_cycles_cfg) begin
            @(negedge clk);
            cycles++;
            if (error)
                $fatal(1, "Model inference ERROR after %0d cycles", cycles);
        end
        if (!done)
            $fatal(1, "Model inference TIMEOUT after %0d cycles", cycles);
        // Allow the last registered completed-layer pulse/check to settle.
        repeat (2) @(negedge clk);
        if (busy || error || rd_active_q || wr_active_q || b_pending_q || bvalid_q ||
            arvalid || awvalid || wvalid || rvalid || bvalid)
            $fatal(1, "Model done with busy/error or outstanding AXI traffic");
`ifdef NPU_PERF_ENABLE
        if (checked_layers != desc_count_input)
            $fatal(1, "Checked %0d layers; expected %0d", checked_layers, desc_count_input);
        if (p_r_beats != reads_q || p_w_beats != writes_q || p_written_bytes != written_bytes_q)
            $fatal(1, "Independent AXI read/write/strobe counters differ from NPU monitor");
        $display("PERF_COUNTER_CHECK,PASS");
        $display("PERF_TOTAL,cycles=%0d,executor=%0d,pool=%0d,ar=%0d,read_beats=%0d,aw=%0d,write_beats=%0d,written_bytes=%0d",
                 p_total_cycles, p_executor_cycles, p_pool_cycles, p_ar_transactions,
                 p_r_beats, p_aw_transactions, p_w_beats, p_written_bytes);
        $display("PERF_WAIT,ar_stall=%0d,r_wait=%0d,aw_stall=%0d,w_stall=%0d,b_wait=%0d",
                 p_ar_stall_cycles, p_r_wait_cycles, p_aw_stall_cycles, p_w_stall_cycles, p_b_wait_cycles);
        cycles = p_total_cycles;
`endif
        scanned = $fscanf(checks_fd, "%d", extra_index);
        if (scanned != -1)
            $fatal(1, "Unexpected extra or malformed layer metadata after final layer");
        $fclose(checks_fd);
        prediction = 0;
        best = -129;
        for (int unsigned index=0; index<logits_count_cfg; index++) begin
            raw_logit = mem[int'((logits_base_cfg+index) >> 2)]
                           [8*int'((logits_base_cfg+index) & 3)+:8];
            if ($isunknown(raw_logit))
                $fatal(1, "Unknown logit at index %0d", index);
            value = raw_logit[7] ? int'(raw_logit)-256 : int'(raw_logit);
            if (value > best) begin
                best = value;
                prediction = index;
            end
        end
        $display("MODEL_NPU FINISHED: cycles=%0d read_beats=%0d write_beats=%0d written_bytes=%0d logits_count=%0d top1=%0d descriptors=%0d layers=%0d",
                 cycles, reads_q, writes_q, written_bytes_q, logits_count_cfg, prediction,
                 desc_count_input, desc_count_input);
        $fflush();
        if ($value$plusargs("DDR_DUMP=%s", dumpfile)) begin
            dump_fd = $fopen(dumpfile, "w");
            if (dump_fd == 0)
                $fatal(1, "Cannot open DDR dump %s", dumpfile);
            for (int unsigned word=0; word<image_words_cfg; word++)
                $fdisplay(dump_fd, "%08x", mem[word]);
            $fclose(dump_fd);
            $display("DDR SNAPSHOT FINISHED: words=%0d file=%s", image_words_cfg, dumpfile);
        end
        $finish;
    end
endmodule
