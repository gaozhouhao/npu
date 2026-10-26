// Verification only: every input is observed; no DUT signal is driven.
// The snapshot builder prefixes BURST_PREFETCH_EXPECT_BANKS=1 or 2.
`ifndef BURST_PREFETCH_EXPECT_BANKS
`define BURST_PREFETCH_EXPECT_BANKS 0
`endif

module burst_prefetch_guard #(
    parameter int unsigned ROWS = 4,
    parameter int unsigned COLS = 4,
    parameter int unsigned K_TILE_SIZE = 256,
    parameter int unsigned TILE_COUNT_WIDTH = 16,
    parameter int unsigned EXPECTED_BANKS = 0,
    parameter int unsigned A_BUFFER_COUNT = 2,
    parameter int unsigned B_BUFFER_COUNT = 2
) (
    input logic clk, reset, cmd_valid, cmd_ready, done,
    input logic [31:0] cmd_m, cmd_n, cmd_k,
    input logic cmd_conv_mode,
    input logic a_load_req, a_load_accept, a_load_done,
    input logic b_load_req, b_load_accept, b_load_done,
    input logic [TILE_COUNT_WIDTH-1:0] load_m, load_n, load_k,
    input logic matrix_start, core_done, core_busy,
    input logic operand_rvalid, operand_rready,
    input logic a_wen, b_wen,
    input logic conv_req_valid, conv_req_ready,
    input logic [31:0] conv_req_beats,
    input logic conv_data_valid, conv_data_ready
);
    longint unsigned command_q, m_q, n_q, k_q;
    longint unsigned n_tiles_q, k_tiles_q, expected_tiles_q;
    longint unsigned a_loads_q, b_loads_q, a_finished_q, b_finished_q;
    longint unsigned launched_q, completed_q;
    longint unsigned load_cycles_q, core_cycles_q, overlap_cycles_q;
    longint unsigned a_start_overlap_q, b_start_overlap_q;
    longint unsigned read_overlap_q, sram_overlap_q;
    longint unsigned conv_requests_q, conv_words_q, conv_max_q;
    longint unsigned conv_multibeat_q, conv_received_q;
    logic active_q, conv_q, a_pending_q, b_pending_q, core_pending_q;
    wire a_accept = a_load_req && a_load_accept;
    wire b_accept = b_load_req && b_load_accept;
    // A load occupies the interval from its accepted request through done,
    // inclusive. core_busy includes the core's C-SRAM write phase. The
    // transfer and SRAM-write overlap counters give narrower observations.
    wire loading = a_pending_q || b_pending_q || a_accept || b_accept;
    wire [63:0] load_ordinal =
        (64'(load_m) * n_tiles_q + 64'(load_n)) * k_tiles_q + 64'(load_k);

    initial begin
        if (!((EXPECTED_BANKS == 1) || (EXPECTED_BANKS == 2)) ||
            (A_BUFFER_COUNT != EXPECTED_BANKS) || (B_BUFFER_COUNT != EXPECTED_BANKS))
            $fatal(1, "BURST_PREFETCH_CHECK: unexpected executor bank counts");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            command_q <= 0; m_q <= 0; n_q <= 0; k_q <= 0;
            n_tiles_q <= 0; k_tiles_q <= 0; expected_tiles_q <= 0;
            a_loads_q <= 0; b_loads_q <= 0;
            a_finished_q <= 0; b_finished_q <= 0;
            launched_q <= 0; completed_q <= 0;
            load_cycles_q <= 0; core_cycles_q <= 0; overlap_cycles_q <= 0;
            a_start_overlap_q <= 0; b_start_overlap_q <= 0;
            read_overlap_q <= 0; sram_overlap_q <= 0;
            conv_requests_q <= 0; conv_words_q <= 0; conv_max_q <= 0;
            conv_multibeat_q <= 0; conv_received_q <= 0;
            active_q <= 0; conv_q <= 0;
            a_pending_q <= 0; b_pending_q <= 0; core_pending_q <= 0;
        end else if (cmd_valid && cmd_ready) begin
            if (active_q)
                $fatal(1, "BURST_PREFETCH_CHECK: command accepted before previous completion");
            m_q <= 64'(cmd_m); n_q <= 64'(cmd_n); k_q <= 64'(cmd_k);
            n_tiles_q <= (64'(cmd_n) + COLS - 1) / COLS;
            k_tiles_q <= (64'(cmd_k) + K_TILE_SIZE - 1) / K_TILE_SIZE;
            expected_tiles_q <= ((64'(cmd_m) + ROWS - 1) / ROWS) *
                ((64'(cmd_n) + COLS - 1) / COLS) *
                ((64'(cmd_k) + K_TILE_SIZE - 1) / K_TILE_SIZE);
            a_loads_q <= 0; b_loads_q <= 0;
            a_finished_q <= 0; b_finished_q <= 0;
            launched_q <= 0; completed_q <= 0;
            load_cycles_q <= 0; core_cycles_q <= 0; overlap_cycles_q <= 0;
            a_start_overlap_q <= 0; b_start_overlap_q <= 0;
            read_overlap_q <= 0; sram_overlap_q <= 0;
            conv_requests_q <= 0; conv_words_q <= 0; conv_max_q <= 0;
            conv_multibeat_q <= 0; conv_received_q <= 0;
            active_q <= 1; conv_q <= cmd_conv_mode;
            a_pending_q <= 0; b_pending_q <= 0; core_pending_q <= 0;
        end else if (active_q) begin
            if (loading) load_cycles_q <= load_cycles_q + 1;
            if (core_busy) core_cycles_q <= core_cycles_q + 1;
            if (loading && core_busy) overlap_cycles_q <= overlap_cycles_q + 1;
            if (a_accept && core_busy) a_start_overlap_q <= a_start_overlap_q + 1;
            if (b_accept && core_busy) b_start_overlap_q <= b_start_overlap_q + 1;
            if (operand_rvalid && operand_rready && core_busy)
                read_overlap_q <= read_overlap_q + 1;
            if ((a_wen || b_wen) && core_busy) sram_overlap_q <= sram_overlap_q + 1;
            if ((EXPECTED_BANKS == 1) && core_busy &&
                (loading || (operand_rvalid && operand_rready) || a_wen || b_wen))
                $fatal(1, "BURST_PREFETCH_CHECK: single-bank load/compute overlap");
            if (a_accept) begin
                if (a_pending_q || (a_loads_q >= expected_tiles_q) ||
                    (load_ordinal != a_loads_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: A must reload every M/N/K tile in order");
                a_loads_q <= a_loads_q + 1;
                a_pending_q <= 1;
            end
            if (b_accept) begin
                if (b_pending_q || (b_loads_q >= expected_tiles_q) ||
                    (load_ordinal != b_loads_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: B must reload every M/N/K tile in order");
                b_loads_q <= b_loads_q + 1;
                b_pending_q <= 1;
            end
            if (a_load_done) begin
                if (!a_pending_q || (a_finished_q >= a_loads_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: A completion without an accepted load");
                a_finished_q <= a_finished_q + 1;
                a_pending_q <= 0;
            end
            if (b_load_done) begin
                if (!b_pending_q || (b_finished_q >= b_loads_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: B completion without an accepted load");
                b_finished_q <= b_finished_q + 1;
                b_pending_q <= 0;
            end
            if (matrix_start) begin
                // The double-bank design may have already completed the
                // next tile's loads. Equality here would reject prefetch.
                if (core_pending_q || (launched_q >= expected_tiles_q) ||
                    (a_finished_q < launched_q + 1) || (b_finished_q < launched_q + 1))
                    $fatal(1, "BURST_PREFETCH_CHECK: compute requires fresh completed A/B loads");
                launched_q <= launched_q + 1;
                core_pending_q <= 1;
            end
            if (core_done) begin
                if (!core_pending_q || (completed_q >= launched_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: core completion without a launch");
                completed_q <= completed_q + 1;
                core_pending_q <= 0;
            end
            // Observe the Conv A reader itself, not parameter/weight DMA.
            // Count only accepted requests, even when valid is held waiting.
            if (conv_req_valid && conv_req_ready) begin
                if (!conv_q || !a_pending_q || (conv_req_beats == 0))
                    $fatal(1, "BURST_PREFETCH_CHECK: invalid Conv request handshake");
                conv_requests_q <= conv_requests_q + 1;
                conv_words_q <= conv_words_q + 64'(conv_req_beats);
                if (64'(conv_req_beats) > conv_max_q) conv_max_q <= 64'(conv_req_beats);
                if (conv_req_beats > 1) conv_multibeat_q <= conv_multibeat_q + 1;
            end
            if (conv_data_valid && conv_data_ready) conv_received_q <= conv_received_q + 1;
            if (done) begin
                if (a_pending_q || b_pending_q || core_pending_q ||
                    (a_loads_q != expected_tiles_q) || (b_loads_q != expected_tiles_q) ||
                    (a_finished_q != expected_tiles_q) || (b_finished_q != expected_tiles_q) ||
                    (launched_q != expected_tiles_q) || (completed_q != expected_tiles_q))
                    $fatal(1, "BURST_PREFETCH_CHECK: incomplete fresh load/compute counts");
                if (conv_words_q != conv_received_q)
                    $fatal(1, "BURST_PREFETCH_CHECK: Conv requested/received word mismatch");
                $display("BURST_PREFETCH_CHECK,PASS,command=%0d,conv=%0d,m=%0d,n=%0d,k=%0d,tiles=%0d,a_loads=%0d,b_loads=%0d,a_finished=%0d,b_finished=%0d,launched=%0d,completed=%0d,load_cycles=%0d,core_busy_cycles=%0d,overlap_cycles=%0d,a_start_overlap=%0d,b_start_overlap=%0d,read_overlap=%0d,sram_overlap=%0d,conv_requests=%0d,conv_words=%0d,conv_max_beats=%0d,conv_multibeat_requests=%0d,conv_received=%0d", command_q, conv_q, m_q, n_q, k_q, expected_tiles_q, a_loads_q, b_loads_q, a_finished_q, b_finished_q, launched_q, completed_q, load_cycles_q, core_cycles_q, overlap_cycles_q, a_start_overlap_q, b_start_overlap_q, read_overlap_q, sram_overlap_q, conv_requests_q, conv_words_q, conv_max_q, conv_multibeat_q, conv_received_q);
                command_q <= command_q + 1;
                active_q <= 0;
            end
        end
    end
endmodule

module burst_prefetch_bank_guard #(
    parameter int unsigned EXPECTED_BANKS = 0,
    parameter int unsigned A_BUFFER_COUNT = 2,
    parameter int unsigned B_BUFFER_COUNT = 2
) ();
    initial begin
        if (!((EXPECTED_BANKS == 1) || (EXPECTED_BANKS == 2)) ||
            (A_BUFFER_COUNT != EXPECTED_BANKS) || (B_BUFFER_COUNT != EXPECTED_BANKS))
            $fatal(1, "BURST_PREFETCH_BANK_CHECK: unexpected physical bank counts");
        $display("BURST_PREFETCH_BANK_CHECK,PASS,a_banks=%0d,b_banks=%0d", A_BUFFER_COUNT, B_BUFFER_COUNT);
    end
endmodule

bind gemm_executor burst_prefetch_guard #(
    .ROWS(ROWS), .COLS(COLS), .K_TILE_SIZE(K_TILE_SIZE), .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH),
    .EXPECTED_BANKS(`BURST_PREFETCH_EXPECT_BANKS),
    .A_BUFFER_COUNT(A_BUFFER_COUNT), .B_BUFFER_COUNT(B_BUFFER_COUNT)
) u_burst_prefetch_guard (
    .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .done(done),
    .cmd_m(cmd_m), .cmd_n(cmd_n), .cmd_k(cmd_k), .cmd_conv_mode(cmd_conv_mode),
    .a_load_req(scheduler_a_load_req), .a_load_accept(scheduler_a_load_accept),
    .a_load_done(scheduler_a_load_done),
    .b_load_req(scheduler_b_load_req), .b_load_accept(scheduler_b_load_accept),
    .b_load_done(scheduler_b_load_done),
    .load_m(load_m_tile_idx), .load_n(load_n_tile_idx), .load_k(load_k_tile_idx),
    .matrix_start(scheduler_matrix_start), .core_done(core_done), .core_busy(core_busy),
    .operand_rvalid(operand_axi_rvalid), .operand_rready(operand_axi_rready),
    .a_wen(a_wen), .b_wen(b_wen),
    .conv_req_valid(u_read_path.conv_a_rd_req_valid),
    .conv_req_ready(u_read_path.conv_a_rd_req_ready),
    .conv_req_beats(u_read_path.conv_a_rd_req_beats),
    .conv_data_valid(u_read_path.conv_a_rd_data_valid),
    .conv_data_ready(u_read_path.conv_a_rd_data_ready)
);
bind npu_top burst_prefetch_bank_guard #(
    .EXPECTED_BANKS(`BURST_PREFETCH_EXPECT_BANKS),
    .A_BUFFER_COUNT(A_BUFFER_COUNT), .B_BUFFER_COUNT(B_BUFFER_COUNT)
) u_burst_prefetch_bank_guard ();
