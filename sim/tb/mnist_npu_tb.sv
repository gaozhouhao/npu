module mnist_npu_tb;

    localparam int unsigned MEM_WORDS = 8192;
    localparam int unsigned DDR_IMAGE_BYTES = 26304;
    localparam int unsigned MAX_GOLD_BYTES = 6272;
    localparam int unsigned DESC_BASE = 25984;
    localparam int unsigned FC_OUTPUT_BASE = 25744;
    localparam int unsigned MAX_CYCLES = 10_000_000;

    logic clk;
    logic reset;
    logic start;
    logic busy;
    logic done;
    logic error;

    logic signed [31:0] acc_out [4][4];

    // ============================================================
    // AXI Bus
    // ============================================================

    logic [0:0] arid, rid, awid, bid;
    logic [63:0] araddr, awaddr;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, awburst, rresp, bresp;

    logic arvalid, arready;
    logic rvalid, rready, rlast;
    logic awvalid, awready;
    logic wvalid, wready, wlast;
    logic bvalid, bready;

    logic [31:0] rdata, wdata;
    logic [3:0] wstrb;

    // ============================================================
    // DDR Memory Model
    // ============================================================

    logic [31:0] init_mem [0:MEM_WORDS-1];
    logic [31:0] mem [0:MEM_WORDS-1];

    logic [7:0] ddr_bytes [0:DDR_IMAGE_BYTES-1];
    logic [7:0] golden_bytes [0:MAX_GOLD_BYTES-1];

    logic rd_active_q;
    logic wr_active_q;
    logic bvalid_q;

    logic [63:0] rd_addr_q;
    logic [63:0] wr_addr_q;

    logic [8:0] rd_left_q;
    logic [8:0] wr_left_q;

    logic [0:0] rd_id_q;
    logic [0:0] wr_id_q;

    logic [31:0] read_beats_q;
    logic [31:0] write_beats_q;
    logic [31:0] read_transactions_q;
    logic [31:0] write_transactions_q;

    string data_root;

    // ============================================================
    // Performance Monitor V1
    // ============================================================

    logic [63:0] perf_total_cycles;
    logic [63:0] perf_executor_cycles;
    logic [63:0] perf_pool_cycles;

    logic [63:0] perf_ar_transactions;
    logic [63:0] perf_r_beats;
    logic [63:0] perf_aw_transactions;
    logic [63:0] perf_w_beats;
    logic [63:0] perf_written_bytes;

    logic [63:0] perf_ar_stall_cycles;
    logic [63:0] perf_r_wait_cycles;
    logic [63:0] perf_aw_stall_cycles;
    logic [63:0] perf_w_stall_cycles;
    logic [63:0] perf_b_wait_cycles;

    logic perf_layer_done_pulse;
    logic [31:0] perf_completed_layer_index;
    logic [7:0] perf_completed_layer_opcode;
    logic [63:0] perf_completed_layer_cycles;
    logic [63:0] perf_completed_layer_executor_cycles;
    logic [63:0] perf_completed_layer_pool_cycles;
    logic [63:0] perf_completed_layer_ar;
    logic [63:0] perf_completed_layer_r_beats;
    logic [63:0] perf_completed_layer_aw;
    logic [63:0] perf_completed_layer_w_beats;

    // ============================================================
    // Performance Monitor V2
    // ============================================================

    logic [15:0] pe_fire;
    logic [4:0] pe_mac_fires;

    logic [63:0] perf2_matrix_cycles;
    logic [63:0] perf2_matrix_tiles;
    logic [63:0] perf2_pe_mac_events;
    logic [63:0] perf2_pe_active_cycles;
    logic [63:0] perf2_bank_wait_cycles;
    logic [63:0] perf2_dma_overlap_cycles;
    logic [63:0] perf2_dma_only_cycles;

    logic perf2_layer_done_pulse;

    logic [63:0] perf2_layer_matrix_cycles;
    logic [63:0] perf2_layer_matrix_tiles;
    logic [63:0] perf2_layer_pe_mac_events;
    logic [63:0] perf2_layer_pe_active_cycles;
    logic [63:0] perf2_layer_bank_wait_cycles;
    logic [63:0] perf2_layer_dma_overlap_cycles;
    logic [63:0] perf2_layer_dma_only_cycles;

    // ============================================================
    // Clock
    // ============================================================

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ============================================================
    // DUT
    // ============================================================

    npu_top u_dut (
        .clk(clk),
        .reset(reset),
        .start(start),

        .desc_base(64'(DESC_BASE)),
        .desc_count(16'd5),

        .busy(busy),
        .done(done),
        .error(error),
        .acc_out(acc_out),

        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),

        .m_axi_rid(rid),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),

        .m_axi_awid(awid),
        .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),

        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),

        .m_axi_bid(bid),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),

        .perf_total_cycles(perf_total_cycles),
        .perf_executor_cycles(perf_executor_cycles),
        .perf_pool_cycles(perf_pool_cycles),

        .perf_ar_transactions(perf_ar_transactions),
        .perf_r_beats(perf_r_beats),
        .perf_aw_transactions(perf_aw_transactions),
        .perf_w_beats(perf_w_beats),
        .perf_written_bytes(perf_written_bytes),

        .perf_ar_stall_cycles(perf_ar_stall_cycles),
        .perf_r_wait_cycles(perf_r_wait_cycles),
        .perf_aw_stall_cycles(perf_aw_stall_cycles),
        .perf_w_stall_cycles(perf_w_stall_cycles),
        .perf_b_wait_cycles(perf_b_wait_cycles),

        .perf_layer_done_pulse(perf_layer_done_pulse),
        .perf_completed_layer_index(perf_completed_layer_index),
        .perf_completed_layer_opcode(perf_completed_layer_opcode),
        .perf_completed_layer_cycles(perf_completed_layer_cycles),

        .perf_completed_layer_executor_cycles(
            perf_completed_layer_executor_cycles
        ),
        .perf_completed_layer_pool_cycles(
            perf_completed_layer_pool_cycles
        ),

        .perf_completed_layer_ar(perf_completed_layer_ar),
        .perf_completed_layer_r_beats(perf_completed_layer_r_beats),
        .perf_completed_layer_aw(perf_completed_layer_aw),
        .perf_completed_layer_w_beats(perf_completed_layer_w_beats)
    );

    // ============================================================
    // Actual PE MAC Events
    //
    // pe.sv:
    //   if (a_valid_in && b_valid_in) accumulator += product
    //
    // Count the same condition at the input of each PE.
    // Exclude reset/clear cycles.
    // ============================================================

    genvar gr, gc;

    generate
        for (gr = 0; gr < 4; gr++) begin : gen_pe_row
            for (gc = 0; gc < 4; gc++) begin : gen_pe_col

                assign pe_fire[gr*4 + gc] =
                    u_dut.u_gemm_executor
                         .u_gemm_core
                         .u_matrix_engine
                         .u_array
                         .a_valid_wire[gr][gc] &&

                    u_dut.u_gemm_executor
                         .u_gemm_core
                         .u_matrix_engine
                         .u_array
                         .b_valid_wire[gr][gc] &&

                    !u_dut.u_gemm_executor
                          .u_gemm_core.clear;

            end
        end
    endgenerate

    assign pe_mac_fires = 5'($countones(pe_fire));

    // ============================================================
    // Compute Performance Monitor V2
    //
    // Hierarchical connections are verification-only.
    // The monitor does not drive any DUT signals.
    // ============================================================

    npu_perf_v2_monitor #(
        .PE_COUNT(16)
    ) u_perf_v2 (
        .clk(clk),
        .reset(reset),

        .run_start(start && !busy),
        .run_done(done),

        .layer_start(
            u_dut.frontend_cmd_valid &&
            u_dut.frontend_cmd_ready
        ),

        .layer_done(u_dut.frontend_exec_done),

        .matrix_start(
            u_dut.u_gemm_executor.scheduler_matrix_start
        ),

        .matrix_done(
            u_dut.u_gemm_executor.core_done
        ),

        .pe_mac_fires(pe_mac_fires),

        .executor_busy(u_dut.executor_busy),

        .read_path_busy(
            u_dut.u_gemm_executor.read_path_busy
        ),

        .a_compute_req(
            u_dut.u_gemm_executor.scheduler_a_compute_req
        ),

        .a_compute_grant(
            u_dut.u_gemm_executor.scheduler_a_compute_grant
        ),

        .b_compute_req(
            u_dut.u_gemm_executor.scheduler_b_compute_req
        ),

        .b_compute_grant(
            u_dut.u_gemm_executor.scheduler_b_compute_grant
        ),

        .matrix_cycles(perf2_matrix_cycles),
        .matrix_tiles(perf2_matrix_tiles),
        .pe_mac_events(perf2_pe_mac_events),
        .pe_active_cycles(perf2_pe_active_cycles),
        .bank_wait_cycles(perf2_bank_wait_cycles),
        .dma_compute_overlap_cycles(perf2_dma_overlap_cycles),
        .dma_only_cycles(perf2_dma_only_cycles),

        .layer_done_pulse(perf2_layer_done_pulse),

        .completed_matrix_cycles(
            perf2_layer_matrix_cycles
        ),

        .completed_matrix_tiles(
            perf2_layer_matrix_tiles
        ),

        .completed_pe_mac_events(
            perf2_layer_pe_mac_events
        ),

        .completed_pe_active_cycles(
            perf2_layer_pe_active_cycles
        ),

        .completed_bank_wait_cycles(
            perf2_layer_bank_wait_cycles
        ),

        .completed_dma_overlap_cycles(
            perf2_layer_dma_overlap_cycles
        ),

        .completed_dma_only_cycles(
            perf2_layer_dma_only_cycles
        )
    );

    // ============================================================
    // Layer Reports
    // ============================================================

    always @(negedge clk) begin
        if (!reset) begin

            if (perf_layer_done_pulse) begin
                $display(
                    "PERF layer=%0d opcode=0x%02h cycles=%0d executor=%0d pool=%0d AR=%0d R=%0d AW=%0d W=%0d",
                    perf_completed_layer_index,
                    perf_completed_layer_opcode,
                    perf_completed_layer_cycles,
                    perf_completed_layer_executor_cycles,
                    perf_completed_layer_pool_cycles,
                    perf_completed_layer_ar,
                    perf_completed_layer_r_beats,
                    perf_completed_layer_aw,
                    perf_completed_layer_w_beats
                );
            end

            if (perf2_layer_done_pulse) begin
                $display(
                    "PERF2 matrix_cycles=%0d tiles=%0d PE_MACs=%0d PE_active_cycles=%0d",
                    perf2_layer_matrix_cycles,
                    perf2_layer_matrix_tiles,
                    perf2_layer_pe_mac_events,
                    perf2_layer_pe_active_cycles
                );

                $display(
                    "PERF2 bank_wait=%0d DMA_compute_overlap=%0d DMA_only=%0d",
                    perf2_layer_bank_wait_cycles,
                    perf2_layer_dma_overlap_cycles,
                    perf2_layer_dma_only_cycles
                );
            end
        end
    end

    // ============================================================
    // AXI Read Memory Model
    // ============================================================

    assign arready = !rd_active_q;

    assign rid = rd_id_q;
    assign rvalid = rd_active_q;
    assign rresp = 2'b00;
    assign rlast = (rd_left_q == 9'd1);

    assign rdata = mem[int'(rd_addr_q >> 2)];

    always_ff @(posedge clk) begin
        if (reset) begin
            rd_active_q <= 1'b0;
            rd_addr_q <= '0;
            rd_left_q <= '0;
            rd_id_q <= '0;

            read_beats_q <= '0;
            read_transactions_q <= '0;

        end else begin

            if (arvalid && arready) begin

                if (
                    arsize != 3'd2 ||
                    arburst != 2'b01 ||
                    araddr[1:0] != 2'b00 ||
                    (araddr >> 2) + 64'({1'b0, arlen})
                        >= 64'(MEM_WORDS)
                ) begin
                    $fatal(
                        1,
                        "AXI AR invalid addr=0x%h len=%0d",
                        araddr,
                        arlen
                    );
                end

                rd_active_q <= 1'b1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0, arlen} + 9'd1;
                rd_id_q <= arid;

                read_transactions_q <=
                    read_transactions_q + 32'd1;

            end else if (rvalid && rready) begin

                read_beats_q <= read_beats_q + 32'd1;

                if (rlast) begin
                    rd_active_q <= 1'b0;
                end else begin
                    rd_addr_q <= rd_addr_q + 64'd4;
                    rd_left_q <= rd_left_q - 9'd1;
                end
            end
        end
    end

    // ============================================================
    // AXI Write Memory Model
    // ============================================================

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

            write_beats_q <= '0;
            write_transactions_q <= '0;

            for (int i = 0; i < MEM_WORDS; i++)
                mem[i] <= init_mem[i];

        end else begin

            if (awvalid && awready) begin

                if (
                    awsize != 3'd2 ||
                    awburst != 2'b01 ||
                    awaddr[1:0] != 2'b00 ||
                    (awaddr >> 2) + 64'({1'b0, awlen})
                        >= 64'(MEM_WORDS)
                ) begin
                    $fatal(
                        1,
                        "AXI AW invalid addr=0x%h len=%0d",
                        awaddr,
                        awlen
                    );
                end

                wr_active_q <= 1'b1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0, awlen} + 9'd1;
                wr_id_q <= awid;

                write_transactions_q <=
                    write_transactions_q + 32'd1;
            end

            if (wvalid && wready) begin

                if (
                    wlast != (wr_left_q == 9'd1) ||
                    wr_addr_q >= 64'(MEM_WORDS * 4)
                ) begin
                    $fatal(
                        1,
                        "AXI W invalid addr=0x%h",
                        wr_addr_q
                    );
                end

                for (int lane = 0; lane < 4; lane++) begin
                    if (wstrb[lane]) begin
                        mem[int'(wr_addr_q >> 2)]
                           [8*lane +: 8] <=
                           wdata[8*lane +: 8];
                    end
                end

                write_beats_q <= write_beats_q + 32'd1;

                if (wlast) begin
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

    // ============================================================
    // Load DDR Image
    // ============================================================

    task automatic load_ddr(input int image_index);

        string image_path;
        int fd;
        int read_bytes;

        image_path = $sformatf(
            "%s/ddr/image_%04d.bin",
            data_root,
            image_index
        );

        fd = $fopen(image_path, "rb");

        if (fd == 0)
            $fatal(
                1,
                "Cannot open DDR image: %s",
                image_path
            );

        read_bytes = $fread(ddr_bytes, fd);
        $fclose(fd);

        if (read_bytes != int'(DDR_IMAGE_BYTES))
            $fatal(
                1,
                "DDR image length mismatch: %s",
                image_path
            );

        for (int i = 0; i < MEM_WORDS; i++)
            init_mem[i] = '0;

        for (int i = 0; i < int'(DDR_IMAGE_BYTES); i++)
            init_mem[i >> 2][8*(i & 3) +: 8] =
                ddr_bytes[i];

        if (
            init_mem[DESC_BASE/4] != 32'h0000_0702 ||
            init_mem[DESC_BASE/4+16] != 32'h0000_0003 ||
            init_mem[DESC_BASE/4+32] != 32'h0000_0702 ||
            init_mem[DESC_BASE/4+48] != 32'h0000_0003 ||
            init_mem[DESC_BASE/4+64] != 32'h0000_0101
        ) begin
            $fatal(
                1,
                "Unexpected SmallCNN descriptor sequence"
            );
        end

        $display(
            "Loaded %s (%0d bytes), desc_base=0x%h",
            image_path,
            read_bytes,
            64'(DESC_BASE)
        );
    endtask

    // ============================================================
    // Golden Comparison
    // ============================================================

    task automatic check_layer(
        input int image_index,
        input string layer_name,
        input int unsigned base_addr,
        input int unsigned byte_count
    );

        string golden_path;
        int fd;
        int read_bytes;
        logic [7:0] actual;

        golden_path = $sformatf(
            "%s/golden/image_%04d/%s.bin",
            data_root,
            image_index,
            layer_name
        );

        fd = $fopen(golden_path, "rb");

        if (fd == 0)
            $fatal(
                1,
                "Cannot open golden: %s",
                golden_path
            );

        read_bytes = $fread(
            golden_bytes,
            fd,
            0,
            byte_count
        );

        $fclose(fd);

        if (read_bytes != int'(byte_count))
            $fatal(
                1,
                "Golden length mismatch: %s",
                golden_path
            );

        for (int i = 0; i < int'(byte_count); i++) begin

            actual =
                mem[(base_addr + 32'(i)) >> 2]
                   [8*((base_addr + 32'(i)) & 32'd3) +: 8];

            if (actual !== golden_bytes[i]) begin
                $fatal(
                    1,
                    "Image %0d %s MISMATCH addr=0x%h offset=%0d actual=0x%02h expected=0x%02h",
                    image_index,
                    layer_name,
                    base_addr + 32'(i),
                    i,
                    actual,
                    golden_bytes[i]
                );
            end
        end

        $display(
            "  %s PASS (%0d bytes)",
            layer_name,
            byte_count
        );
    endtask

    // ============================================================
    // Execute One MNIST Image
    // ============================================================

    task automatic run_image(input int image_index);

        int cycles;
        int expected_label;
        int predicted_label;

        logic signed [31:0] best_logit;
        logic signed [31:0] current_logit;

        @(negedge clk);

        reset = 1'b1;
        start = 1'b0;

        load_ddr(image_index);

        repeat (4) @(negedge clk);
        reset = 1'b0;

        repeat (2) @(negedge clk);

        start = 1'b1;

        @(negedge clk);
        start = 1'b0;

        cycles = 0;

        while (!done && cycles < int'(MAX_CYCLES)) begin
            @(negedge clk);
            cycles++;
        end

        if (!done) begin
            $fatal(
                1,
                "MNIST image %0d TIMEOUT cycles=%0d AR=%0d R=%0d AW=%0d W=%0d",
                image_index,
                cycles,
                read_transactions_q,
                read_beats_q,
                write_transactions_q,
                write_beats_q
            );
        end

        if (error)
            $fatal(
                1,
                "MNIST image %0d NPU reported error",
                image_index
            );

        if (busy)
            $fatal(
                1,
                "MNIST image %0d NPU busy at done",
                image_index
            );

        // ========================================================
        // V1 Independent AXI Counter Cross-Check
        // ========================================================

        if (
            perf_ar_transactions != 64'(read_transactions_q) ||
            perf_r_beats != 64'(read_beats_q) ||
            perf_aw_transactions != 64'(write_transactions_q) ||
            perf_w_beats != 64'(write_beats_q)
        ) begin
            $fatal(
                1,
                "Performance monitor AXI counters disagree with TB: AR=%0d/%0d R=%0d/%0d AW=%0d/%0d W=%0d/%0d",
                perf_ar_transactions,
                read_transactions_q,
                perf_r_beats,
                read_beats_q,
                perf_aw_transactions,
                write_transactions_q,
                perf_w_beats,
                write_beats_q
            );
        end

        $display(
            "PERF run=%0d executor=%0d pool=%0d AR=%0d R=%0d AW=%0d W=%0d written_bytes=%0d",
            perf_total_cycles,
            perf_executor_cycles,
            perf_pool_cycles,
            perf_ar_transactions,
            perf_r_beats,
            perf_aw_transactions,
            perf_w_beats,
            perf_written_bytes
        );

        $display(
            "PERF stalls AR=%0d R_gap=%0d AW=%0d W=%0d B_response=%0d",
            perf_ar_stall_cycles,
            perf_r_wait_cycles,
            perf_aw_stall_cycles,
            perf_w_stall_cycles,
            perf_b_wait_cycles
        );

        // ========================================================
        // V2 Whole-Run Counters
        // ========================================================

        $display(
            "PERF2 RUN matrix_cycles=%0d tiles=%0d PE_MACs=%0d PE_active_cycles=%0d",
            perf2_matrix_cycles,
            perf2_matrix_tiles,
            perf2_pe_mac_events,
            perf2_pe_active_cycles
        );

        $display(
            "PERF2 RUN bank_wait=%0d DMA_compute_overlap=%0d DMA_only=%0d",
            perf2_bank_wait_cycles,
            perf2_dma_overlap_cycles,
            perf2_dma_only_cycles
        );

        // ========================================================
        // Golden Model Validation
        // ========================================================

        check_layer(image_index, "conv1", 11632, 6272);
        check_layer(image_index, "pool1", 17904, 1568);
        check_layer(image_index, "conv2", 19472, 3136);
        check_layer(image_index, "pool2", 22608, 784);
        check_layer(image_index, "fc", FC_OUTPUT_BASE, 192);

        // ========================================================
        // Classification
        // ========================================================

        best_logit = $signed(mem[FC_OUTPUT_BASE/4]);
        predicted_label = 0;

        for (int cls = 1; cls < 10; cls++) begin

            current_logit =
                $signed(mem[FC_OUTPUT_BASE/4 + cls]);

            if (current_logit > best_logit) begin
                best_logit = current_logit;
                predicted_label = cls;
            end
        end

        case (image_index)
            0: expected_label = 7;
            1: expected_label = 2;
            2: expected_label = 1;
            3: expected_label = 0;
            default: expected_label = -1;
        endcase

        if (predicted_label != expected_label)
            $fatal(
                1,
                "Classification mismatch: predicted=%0d expected=%0d",
                predicted_label,
                expected_label
            );

        $display(
            "MNIST image_%04d PASS pred=%0d cycles=%0d AR=%0d R_beats=%0d AW=%0d W_beats=%0d acc00=%0d",
            image_index,
            predicted_label,
            cycles,
            read_transactions_q,
            read_beats_q,
            write_transactions_q,
            write_beats_q,
            acc_out[0][0]
        );
    endtask

    // ============================================================
    // Test Sequence
    // ============================================================

    initial begin : test_sequence

        int only_image;

        reset = 1'b1;
        start = 1'b0;

        if (!$value$plusargs("NPU_DATA_ROOT=%s", data_root))
            data_root = "artifacts/npu";

        if ($value$plusargs("IMAGE=%d", only_image)) begin

            if (only_image < 0 || only_image > 3)
                $fatal(
                    1,
                    "+IMAGE must be 0, 1, 2 or 3"
                );

            run_image(only_image);

        end else begin

            for (int i = 0; i < 4; i++)
                run_image(i);

        end

        $display("All selected MNIST RTL inference tests PASS");
        $finish;
    end

endmodule
