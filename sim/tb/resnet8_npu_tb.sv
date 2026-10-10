
module resnet8_npu_tb;
    localparam int unsigned MEM_WORDS = 262144;

    logic clk;
    logic reset;
    logic start;
    logic busy, done, error;
    logic signed [31:0] acc_out [4][4];

    logic [0:0] arid,rid,awid,bid;
    logic [63:0] araddr,awaddr;
    logic [7:0] arlen,awlen;
    logic [2:0] arsize,awsize;
    logic [1:0] arburst,awburst,rresp,bresp;
    logic arvalid,arready,rlast,rvalid,rready;
    logic awvalid,awready,wlast,wvalid,wready,bvalid,bready;
    logic [31:0] rdata,wdata;
    logic [3:0] wstrb;

    logic [31:0] init_mem [0:MEM_WORDS-1];
    logic [31:0] mem [0:MEM_WORDS-1];

    logic rd_active_q,wr_active_q,bvalid_q;
    logic [63:0] rd_addr_q,wr_addr_q;
    logic [8:0] rd_left_q,wr_left_q;
    logic [0:0] rd_id_q,wr_id_q;

    logic [63:0] desc_base_cfg,logits_base_cfg;
    logic [15:0] desc_count_cfg;
    logic [31:0] reads_q,writes_q;

    string memfile;
    string dumpfile;

    initial clk = 1'b0;
    always #5 clk = ~clk;


`ifdef NPU_PERF_ENABLE
    logic [63:0] p_total_cycles;
    logic [63:0] p_executor_cycles;
    logic [63:0] p_pool_cycles;
    logic [63:0] p_ar_transactions;
    logic [63:0] p_r_beats;
    logic [63:0] p_aw_transactions;
    logic [63:0] p_w_beats;
    logic [63:0] p_written_bytes;
    logic [63:0] p_ar_stall_cycles;
    logic [63:0] p_r_wait_cycles;
    logic [63:0] p_aw_stall_cycles;
    logic [63:0] p_w_stall_cycles;
    logic [63:0] p_b_wait_cycles;
    logic  p_layer_done_pulse;
    logic [31:0] p_completed_layer_index;
    logic [7:0] p_completed_layer_opcode;
    logic [63:0] p_completed_layer_cycles;
    logic [63:0] p_completed_layer_executor_cycles;
    logic [63:0] p_completed_layer_pool_cycles;
    logic [63:0] p_completed_layer_ar;
    logic [63:0] p_completed_layer_r_beats;
    logic [63:0] p_completed_layer_aw;
    logic [63:0] p_completed_layer_w_beats;
`endif

    npu_top u_dut (
        .clk(clk), .reset(reset), .start(start),
        .desc_base(desc_base_cfg), .desc_count(desc_count_cfg),
        .busy(busy), .done(done), .error(error),
        .acc_out(acc_out),
        .m_axi_arid(arid), .m_axi_araddr(araddr),
        .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata),
        .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
`ifdef NPU_PERF_ENABLE
        ,
        .perf_total_cycles(p_total_cycles),
        .perf_executor_cycles(p_executor_cycles),
        .perf_pool_cycles(p_pool_cycles),
        .perf_ar_transactions(p_ar_transactions),
        .perf_r_beats(p_r_beats),
        .perf_aw_transactions(p_aw_transactions),
        .perf_w_beats(p_w_beats),
        .perf_written_bytes(p_written_bytes),
        .perf_ar_stall_cycles(p_ar_stall_cycles),
        .perf_r_wait_cycles(p_r_wait_cycles),
        .perf_aw_stall_cycles(p_aw_stall_cycles),
        .perf_w_stall_cycles(p_w_stall_cycles),
        .perf_b_wait_cycles(p_b_wait_cycles),
        .perf_layer_done_pulse(p_layer_done_pulse),
        .perf_completed_layer_index(p_completed_layer_index),
        .perf_completed_layer_opcode(p_completed_layer_opcode),
        .perf_completed_layer_cycles(p_completed_layer_cycles),
        .perf_completed_layer_executor_cycles(p_completed_layer_executor_cycles),
        .perf_completed_layer_pool_cycles(p_completed_layer_pool_cycles),
        .perf_completed_layer_ar(p_completed_layer_ar),
        .perf_completed_layer_r_beats(p_completed_layer_r_beats),
        .perf_completed_layer_aw(p_completed_layer_aw),
        .perf_completed_layer_w_beats(p_completed_layer_w_beats)
`endif
    );

    assign arready = !rd_active_q;
    assign rid = rd_id_q;
    assign rvalid = rd_active_q;
    assign rdata = mem[int'(rd_addr_q >> 2)];
    assign rresp = 2'b00;
    assign rlast = rd_left_q == 9'd1;

    always_ff @(posedge clk) begin
        if (reset) begin
            rd_active_q <= 1'b0;
            rd_addr_q <= '0;
            rd_left_q <= '0;
            rd_id_q <= '0;
            reads_q <= '0;
        end else begin
            if (arvalid && arready) begin
                if (arsize != 3'd2 || arburst != 2'b01 ||
                    araddr[1:0] != 2'b00 ||
                    araddr >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI AR addr=%h size=%d",
                           araddr, arsize);

                rd_active_q <= 1'b1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0,arlen} + 9'd1;
                rd_id_q <= arid;
            end else if (rvalid && rready) begin
                reads_q <= reads_q + 32'd1;

                if (rlast)
                    rd_active_q <= 1'b0;
                else begin
                    rd_addr_q <= rd_addr_q + 64'd4;
                    rd_left_q <= rd_left_q - 9'd1;
                end
            end
        end
    end

    assign awready = !wr_active_q && !bvalid_q;
    assign wready = wr_active_q;
    assign bid = wr_id_q;
    assign bresp = 2'b00;
    assign bvalid = bvalid_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_active_q <= 1'b0;
            wr_addr_q <= '0;
            wr_left_q <= '0;
            wr_id_q <= '0;
            bvalid_q <= 1'b0;
            writes_q <= '0;

            for (int i=0; i<MEM_WORDS; i++)
                mem[i] <= init_mem[i];

        end else begin
            if (awvalid && awready) begin
                if (awsize != 3'd2 || awburst != 2'b01 ||
                    awaddr[1:0] != 2'b00 ||
                    awaddr >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI AW addr=%h size=%d",
                           awaddr, awsize);

                wr_active_q <= 1'b1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0,awlen} + 9'd1;
                wr_id_q <= awid;
            end

            if (wvalid && wready) begin
                if (wlast != (wr_left_q == 9'd1) ||
                    wr_addr_q >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Invalid AXI W");

                for (int i=0; i<4; i++)
                    if (wstrb[i])
                        mem[int'(wr_addr_q >> 2)][8*i +: 8]
                            <= wdata[8*i +: 8];

                writes_q <= writes_q + 32'd1;

                if (wr_left_q == 9'd1) begin
                    wr_active_q <= 1'b0;
                    bvalid_q <= 1'b1;
                end else begin
                    wr_addr_q <= wr_addr_q + 64'd4;
                    wr_left_q <= wr_left_q - 9'd1;
                end
            end

            if (bvalid && bready)
                bvalid_q <= 1'b0;
        end
    end


`ifdef NPU_PERF_ENABLE

    // Completed-layer values are registered by npu_perf_monitor.
    // Observe at falling edge, after nonblocking assignments.
    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin
            $display(
                "PERF_LAYER,index=%0d,opcode=%0d,cycles=%0d,executor=%0d,pool=%0d,ar=%0d,read_beats=%0d,aw=%0d,write_beats=%0d",
                p_completed_layer_index,
                p_completed_layer_opcode,
                p_completed_layer_cycles,
                p_completed_layer_executor_cycles,
                p_completed_layer_pool_cycles,
                p_completed_layer_ar,
                p_completed_layer_r_beats,
                p_completed_layer_aw,
                p_completed_layer_w_beats
            );
        end
    end

`endif


`ifdef NPU_PERF_ENABLE

    // RESNET8_COMPUTE_PERF_PROBE
    //
    // Non-intrusive observation of the actual 4x4 PE array.
    // Counts MAC operations when both PE operands are valid
    // and the accumulator is not being cleared.
    //
    // Executed MACs are not necessarily useful model MACs:
    // padded and boundary computations may be included.

    logic [15:0] perf_pe_fire;
    logic [4:0] perf_mac_fires_now;

    logic perf_compute_running;
    logic perf_compute_layer_active;

    logic [63:0] perf_mac_total;
    logic [63:0] perf_mac_layer;
    logic [63:0] perf_mac_layer_sum;

    logic [63:0] perf_active_cycles_total;
    logic [63:0] perf_active_cycles_layer;

    logic [63:0] perf_tile_starts_total;
    logic [63:0] perf_tile_dones_total;
    logic [63:0] perf_tile_starts_layer;
    logic [63:0] perf_tile_dones_layer;

    logic [63:0] perf_mac_capacity_total;

    // Observe the same valid operands as the actual PEs.
    for (genvar r = 0; r < 4; r++) begin : gen_perf_row
        for (genvar c = 0; c < 4; c++) begin : gen_perf_col

            assign perf_pe_fire[r*4+c] =
                !reset &&
                !u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.clear &&
                u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.a_valid_wire[r][c] &&
                u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.b_valid_wire[r][c];

        end
    end

    always_comb begin
        perf_mac_fires_now = '0;

        for (int j = 0; j < 16; j++) begin
            perf_mac_fires_now =
                perf_mac_fires_now + 5'(perf_pe_fire[j]);
        end
    end

    // Sample events on the clock edge where MACs execute.
    always @(posedge clk) begin
        if (reset) begin
            perf_compute_running <= 1'b0;
            perf_compute_layer_active <= 1'b0;

            perf_mac_total <= '0;
            perf_mac_layer <= '0;
            perf_mac_layer_sum <= '0;

            perf_active_cycles_total <= '0;
            perf_active_cycles_layer <= '0;

            perf_tile_starts_total <= '0;
            perf_tile_dones_total <= '0;
            perf_tile_starts_layer <= '0;
            perf_tile_dones_layer <= '0;

            perf_mac_capacity_total <= '0;

        end else if (start && !busy) begin
            perf_compute_running <= 1'b1;
            perf_compute_layer_active <= 1'b0;

            perf_mac_total <= '0;
            perf_mac_layer <= '0;
            perf_mac_layer_sum <= '0;

            perf_active_cycles_total <= '0;
            perf_active_cycles_layer <= '0;

            perf_tile_starts_total <= '0;
            perf_tile_dones_total <= '0;
            perf_tile_starts_layer <= '0;
            perf_tile_dones_layer <= '0;

            perf_mac_capacity_total <= '0;

        end else begin

            if (perf_compute_running) begin
                perf_mac_total <=
                    perf_mac_total + 64'(perf_mac_fires_now);

                perf_mac_capacity_total <=
                    perf_mac_capacity_total + 64'd16;

                if (perf_mac_fires_now != 5'd0)
                    perf_active_cycles_total <=
                        perf_active_cycles_total + 64'd1;

                if (u_dut.u_gemm_executor.scheduler_matrix_start)
                    perf_tile_starts_total <=
                        perf_tile_starts_total + 64'd1;

                if (u_dut.u_gemm_executor.core_done)
                    perf_tile_dones_total <=
                        perf_tile_dones_total + 64'd1;
            end

            if (u_dut.perf_layer_start) begin
                perf_compute_layer_active <= 1'b1;

                perf_mac_layer <= '0;
                perf_active_cycles_layer <= '0;
                perf_tile_starts_layer <= '0;
                perf_tile_dones_layer <= '0;

            end else if (perf_compute_layer_active) begin

                perf_mac_layer <=
                    perf_mac_layer + 64'(perf_mac_fires_now);

                if (perf_mac_fires_now != 5'd0)
                    perf_active_cycles_layer <=
                        perf_active_cycles_layer + 64'd1;

                if (u_dut.u_gemm_executor.scheduler_matrix_start)
                    perf_tile_starts_layer <=
                        perf_tile_starts_layer + 64'd1;

                if (u_dut.u_gemm_executor.core_done)
                    perf_tile_dones_layer <=
                        perf_tile_dones_layer + 64'd1;

            end

            if (u_dut.perf_layer_done &&
                perf_compute_layer_active) begin

                perf_compute_layer_active <= 1'b0;

                perf_mac_layer_sum <=
                    perf_mac_layer_sum +
                    perf_mac_layer +
                    64'(perf_mac_fires_now);
            end

            if (done)
                perf_compute_running <= 1'b0;

        end
    end

    // Existing layer performance monitor publishes this
    // pulse after the clock edge. Observe it at negedge.
    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin

            $display(
                "PERF_COMPUTE_LAYER,index=%0d,mac=%0d,active_cycles=%0d,tile_starts=%0d,tile_dones=%0d",
                p_completed_layer_index,
                perf_mac_layer,
                perf_active_cycles_layer,
                perf_tile_starts_layer,
                perf_tile_dones_layer
            );

        end
    end

`endif


`ifdef NPU_PERF_ENABLE

    // RESNET8_MEMORY_PERF_PROBE
    //
    // Observe resource-level activity.
    // These counters do not depend on external clock frequency.

    logic mem_running_q;
    logic mem_layer_active_q;

    logic [63:0] mem_core_cycles;
    logic [63:0] mem_dma_cycles;
    logic [63:0] mem_overlap_cycles;
    logic [63:0] mem_axi_overlap_beats;

    logic [63:0] mem_a_compute_wait;
    logic [63:0] mem_b_compute_wait;
    logic [63:0] mem_a_load_wait;
    logic [63:0] mem_b_load_wait;

    logic [63:0] mem_layer_core;
    logic [63:0] mem_layer_dma;
    logic [63:0] mem_layer_overlap;
    logic [63:0] mem_layer_axi_overlap;
    logic [63:0] mem_layer_a_compute_wait;
    logic [63:0] mem_layer_b_compute_wait;
    logic [63:0] mem_layer_a_load_wait;
    logic [63:0] mem_layer_b_load_wait;

    logic [63:0] mem_layer_core_sum;
    logic [63:0] mem_layer_dma_sum;
    logic [63:0] mem_layer_overlap_sum;

    wire mem_core_event =
        u_dut.u_gemm_executor.core_busy;

    wire mem_dma_event =
        u_dut.u_gemm_executor.read_path_busy;

    wire mem_overlap_event =
        mem_core_event && mem_dma_event;

    wire mem_axi_overlap_event =
        mem_core_event && rvalid && rready;

    wire mem_a_compute_wait_event =
        u_dut.u_gemm_executor.scheduler_a_compute_req &&
        !u_dut.u_gemm_executor.scheduler_a_compute_grant;

    wire mem_b_compute_wait_event =
        u_dut.u_gemm_executor.scheduler_b_compute_req &&
        !u_dut.u_gemm_executor.scheduler_b_compute_grant;

    wire mem_a_load_wait_event =
        u_dut.u_gemm_executor.a_bank_load_req &&
        !u_dut.u_gemm_executor.a_bank_load_grant;

    wire mem_b_load_wait_event =
        u_dut.u_gemm_executor.b_bank_load_req &&
        !u_dut.u_gemm_executor.b_bank_load_grant;

    always @(posedge clk) begin
        if (reset) begin
            mem_running_q <= 1'b0;
            mem_layer_active_q <= 1'b0;

            mem_core_cycles <= '0;
            mem_dma_cycles <= '0;
            mem_overlap_cycles <= '0;
            mem_axi_overlap_beats <= '0;

            mem_a_compute_wait <= '0;
            mem_b_compute_wait <= '0;
            mem_a_load_wait <= '0;
            mem_b_load_wait <= '0;

            mem_layer_core <= '0;
            mem_layer_dma <= '0;
            mem_layer_overlap <= '0;
            mem_layer_axi_overlap <= '0;
            mem_layer_a_compute_wait <= '0;
            mem_layer_b_compute_wait <= '0;
            mem_layer_a_load_wait <= '0;
            mem_layer_b_load_wait <= '0;

            mem_layer_core_sum <= '0;
            mem_layer_dma_sum <= '0;
            mem_layer_overlap_sum <= '0;

        end else if (start && !busy) begin
            mem_running_q <= 1'b1;
            mem_layer_active_q <= 1'b0;

            mem_core_cycles <= '0;
            mem_dma_cycles <= '0;
            mem_overlap_cycles <= '0;
            mem_axi_overlap_beats <= '0;

            mem_a_compute_wait <= '0;
            mem_b_compute_wait <= '0;
            mem_a_load_wait <= '0;
            mem_b_load_wait <= '0;

            mem_layer_core <= '0;
            mem_layer_dma <= '0;
            mem_layer_overlap <= '0;
            mem_layer_axi_overlap <= '0;
            mem_layer_a_compute_wait <= '0;
            mem_layer_b_compute_wait <= '0;
            mem_layer_a_load_wait <= '0;
            mem_layer_b_load_wait <= '0;

            mem_layer_core_sum <= '0;
            mem_layer_dma_sum <= '0;
            mem_layer_overlap_sum <= '0;

        end else begin

            if (mem_running_q) begin
                mem_core_cycles <=
                    mem_core_cycles + 64'(mem_core_event);

                mem_dma_cycles <=
                    mem_dma_cycles + 64'(mem_dma_event);

                mem_overlap_cycles <=
                    mem_overlap_cycles + 64'(mem_overlap_event);

                mem_axi_overlap_beats <=
                    mem_axi_overlap_beats +
                    64'(mem_axi_overlap_event);

                mem_a_compute_wait <=
                    mem_a_compute_wait +
                    64'(mem_a_compute_wait_event);

                mem_b_compute_wait <=
                    mem_b_compute_wait +
                    64'(mem_b_compute_wait_event);

                mem_a_load_wait <=
                    mem_a_load_wait +
                    64'(mem_a_load_wait_event);

                mem_b_load_wait <=
                    mem_b_load_wait +
                    64'(mem_b_load_wait_event);
            end

            if (u_dut.perf_layer_start) begin
                mem_layer_active_q <= 1'b1;

                mem_layer_core <= '0;
                mem_layer_dma <= '0;
                mem_layer_overlap <= '0;
                mem_layer_axi_overlap <= '0;

                mem_layer_a_compute_wait <= '0;
                mem_layer_b_compute_wait <= '0;
                mem_layer_a_load_wait <= '0;
                mem_layer_b_load_wait <= '0;

            end else if (mem_layer_active_q) begin

                mem_layer_core <=
                    mem_layer_core + 64'(mem_core_event);

                mem_layer_dma <=
                    mem_layer_dma + 64'(mem_dma_event);

                mem_layer_overlap <=
                    mem_layer_overlap + 64'(mem_overlap_event);

                mem_layer_axi_overlap <=
                    mem_layer_axi_overlap +
                    64'(mem_axi_overlap_event);

                mem_layer_a_compute_wait <=
                    mem_layer_a_compute_wait +
                    64'(mem_a_compute_wait_event);

                mem_layer_b_compute_wait <=
                    mem_layer_b_compute_wait +
                    64'(mem_b_compute_wait_event);

                mem_layer_a_load_wait <=
                    mem_layer_a_load_wait +
                    64'(mem_a_load_wait_event);

                mem_layer_b_load_wait <=
                    mem_layer_b_load_wait +
                    64'(mem_b_load_wait_event);
            end

            if (
                u_dut.perf_layer_done &&
                mem_layer_active_q
            ) begin
                mem_layer_active_q <= 1'b0;

                mem_layer_core_sum <=
                    mem_layer_core_sum + mem_layer_core +
                    64'(mem_core_event);

                mem_layer_dma_sum <=
                    mem_layer_dma_sum + mem_layer_dma +
                    64'(mem_dma_event);

                mem_layer_overlap_sum <=
                    mem_layer_overlap_sum + mem_layer_overlap +
                    64'(mem_overlap_event);
            end

            if (done)
                mem_running_q <= 1'b0;
        end
    end

    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin
            $display(
                "PERF_MEMORY_LAYER,index=%0d,core=%0d,dma=%0d,overlap=%0d,axi_overlap=%0d,a_compute_wait=%0d,b_compute_wait=%0d,a_load_wait=%0d,b_load_wait=%0d",
                p_completed_layer_index,
                mem_layer_core,
                mem_layer_dma,
                mem_layer_overlap,
                mem_layer_axi_overlap,
                mem_layer_a_compute_wait,
                mem_layer_b_compute_wait,
                mem_layer_a_load_wait,
                mem_layer_b_load_wait
            );
        end
    end

`endif

    initial begin : run
        int unsigned cycles;
        int signed q, best, prediction;
        int unsigned addr, shift_amt;
        int unsigned dump_words;
        int dump_fd;

        reset = 1'b1;
        start = 1'b0;
        desc_base_cfg = '0;
        logits_base_cfg = '0;
        desc_count_cfg = '0;
        dump_words = 0;

        if (!$value$plusargs("DDR_HEX=%s", memfile))
            $fatal(1, "Provide +DDR_HEX=<ddr.hex>");

        if (!$value$plusargs("DESC_BASE=%h", desc_base_cfg))
            $fatal(1, "Provide +DESC_BASE=<hex>");

        if (!$value$plusargs("DESC_COUNT=%d", desc_count_cfg))
            $fatal(1, "Provide +DESC_COUNT=<int>");

        if (!$value$plusargs("LOGITS_BASE=%h", logits_base_cfg))
            $fatal(1, "Provide +LOGITS_BASE=<hex>");

        if (logits_base_cfg > 64'(MEM_WORDS * 4 - 10))
            $fatal(1, "Logits address outside memory: %h",
                   logits_base_cfg);

        for (int i=0; i<MEM_WORDS; i++)
            init_mem[i] = '0;

        $readmemh(memfile, init_mem);

        repeat (5) @(negedge clk);
        reset = 1'b0;

        repeat (2) @(negedge clk);
        start = 1'b1;

        @(negedge clk);
        start = 1'b0;

        cycles = 0;

        while (!done && cycles < 5000000) begin
            @(negedge clk);
            cycles++;
        end

        if (!done)
            $fatal(1, "ResNet inference TIMEOUT: cycles=%0d",
                   cycles);

        if (error)
            $fatal(1, "ResNet inference ERROR after %0d cycles",
                   cycles);


`ifdef NPU_PERF_ENABLE

        $display(
            "PERF_TOTAL,cycles=%0d,executor=%0d,pool=%0d,ar=%0d,read_beats=%0d,aw=%0d,write_beats=%0d,written_bytes=%0d",
            p_total_cycles,
            p_executor_cycles,
            p_pool_cycles,
            p_ar_transactions,
            p_r_beats,
            p_aw_transactions,
            p_w_beats,
            p_written_bytes
        );

        $display(
            "PERF_WAIT,ar_stall=%0d,r_wait=%0d,aw_stall=%0d,w_stall=%0d,b_wait=%0d",
            p_ar_stall_cycles,
            p_r_wait_cycles,
            p_aw_stall_cycles,
            p_w_stall_cycles,
            p_b_wait_cycles
        );

        if (p_r_beats != 64'(reads_q))
            $fatal(
                1,
                "Read counter mismatch: monitor=%0d TB=%0d",
                p_r_beats, reads_q
            );

        if (p_w_beats != 64'(writes_q))
            $fatal(
                1,
                "Write counter mismatch: monitor=%0d TB=%0d",
                p_w_beats, writes_q
            );

        $display("PERF_COUNTER_CHECK,PASS");

`endif


`ifdef NPU_PERF_ENABLE
        $display(
            "PERF_COMPUTE_TOTAL,mac=%0d,active_cycles=%0d,tile_starts=%0d,tile_dones=%0d,capacity=%0d,layer_mac_sum=%0d",
            perf_mac_total,
            perf_active_cycles_total,
            perf_tile_starts_total,
            perf_tile_dones_total,
            perf_mac_capacity_total,
            perf_mac_layer_sum
        );

        if (perf_mac_total != perf_mac_layer_sum)
            $fatal(
                1,
                "Compute MAC layer sum mismatch: total=%0d layers=%0d",
                perf_mac_total, perf_mac_layer_sum
            );

        if (perf_tile_starts_total != perf_tile_dones_total)
            $fatal(
                1,
                "Matrix tile start/done mismatch: %0d/%0d",
                perf_tile_starts_total,
                perf_tile_dones_total
            );

        if (perf_mac_total > perf_mac_capacity_total)
            $fatal(
                1,
                "PE MAC count exceeds array capacity"
            );

        $display("PERF_COMPUTE_CHECK,PASS");
`endif


`ifdef NPU_PERF_ENABLE

        $display(
            "PERF_MEMORY_TOTAL,core=%0d,dma=%0d,overlap=%0d,axi_overlap=%0d,a_compute_wait=%0d,b_compute_wait=%0d,a_load_wait=%0d,b_load_wait=%0d",
            mem_core_cycles,
            mem_dma_cycles,
            mem_overlap_cycles,
            mem_axi_overlap_beats,
            mem_a_compute_wait,
            mem_b_compute_wait,
            mem_a_load_wait,
            mem_b_load_wait
        );

        if (mem_overlap_cycles > mem_core_cycles ||
            mem_overlap_cycles > mem_dma_cycles)
            $fatal(1, "Invalid DMA/compute overlap count");

        if (mem_axi_overlap_beats > p_r_beats)
            $fatal(1, "Invalid AXI overlap beats");

        if (mem_layer_core_sum != mem_core_cycles ||
            mem_layer_dma_sum != mem_dma_cycles ||
            mem_layer_overlap_sum != mem_overlap_cycles)
            $fatal(
                1,
                "Memory layer/global counter mismatch"
            );

        $display("PERF_MEMORY_CHECK,PASS");

`endif

        best = -129;
        prediction = -1;

        for (int n=0; n<10; n++) begin
            addr = int'(logits_base_cfg) + unsigned'(n);
            shift_amt = 8 * (addr % 4);

            if (shift_amt > 32'd24 ||
                (shift_amt % 32'd8) != 32'd0)
                $fatal(1, "Invalid INT8 bit offset: %0d",
                       shift_amt);

            q = int'($signed(mem[addr/4][shift_amt +: 8]));

            $display("logit[%0d]=%0d", n, q);

            if (q > best) begin
                best = q;
                prediction = n;
            end
        end

        $display(
            "RESNET8 NPU FINISHED: top1=%0d cycles=%0d reads=%0d writes=%0d busy=%0b acc00=%0d",
            prediction, cycles, reads_q, writes_q,
            busy, acc_out[0][0]
        );

        // Optional final DDR snapshot for layer verification.
        if ($value$plusargs("DDR_DUMP=%s", dumpfile)) begin
            if (!$value$plusargs("DUMP_WORDS=%d", dump_words))
                $fatal(1, "Provide +DUMP_WORDS=<count>");

            if (dump_words == 0 || dump_words > MEM_WORDS)
                $fatal(1, "Invalid DUMP_WORDS=%0d",
                       dump_words);

            dump_fd = $fopen(dumpfile, "w");

            if (dump_fd == 0)
                $fatal(1, "Cannot open DDR dump: %s",
                       dumpfile);

            for (int unsigned i=0; i<dump_words; i++)
                $fdisplay(dump_fd, "%08x", mem[i]);

            $fclose(dump_fd);

            $display(
                "DDR SNAPSHOT FINISHED: words=%0d file=%s",
                dump_words, dumpfile
            );
        end

        $finish;
    end
endmodule
