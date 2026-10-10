`timescale 1ns/1ps

// Per-channel requant + C-PSUM slot stress test.
// 8x32x32 GEMM, K_TILE_SIZE=16: 2 M tiles x 8 N tiles x 2 K tiles.
// 16 final output tiles must reuse 4 C/parameter slots.
module param_slot_stress_npu_tb;

    localparam int unsigned MEM_WORDS = 8192;
    localparam int unsigned M = 8;
    localparam int unsigned N = 32;
    localparam int unsigned K = 32;
    localparam int unsigned COLS = 4;
    localparam int unsigned NTILES = N / COLS;
    localparam int unsigned MTILES = M / 4;
    localparam int unsigned FINAL_TILES = MTILES * NTILES;
    localparam int unsigned K_TILES = 2;

    localparam int unsigned A_BASE = 'h1000;
    localparam int unsigned B_BASE = 'h2000;
    localparam int unsigned C_BASE = 'h3000;
    localparam int unsigned PARAM_BASE = 'h4000;
    localparam int unsigned DESC_BASE = 'h5000;

    logic clk;
    logic reset;
    logic start;
    logic busy;
    logic done;
    logic error;
    logic signed [31:0] acc_out [4][4];

    logic [0:0] arid;
    logic [0:0] rid;
    logic [0:0] awid;
    logic [0:0] bid;
    logic [63:0] araddr;
    logic [63:0] awaddr;
    logic [7:0] arlen;
    logic [7:0] awlen;
    logic [2:0] arsize;
    logic [2:0] awsize;
    logic [1:0] arburst;
    logic [1:0] awburst;
    logic [1:0] rresp;
    logic [1:0] bresp;
    logic arvalid;
    logic arready;
    logic rlast;
    logic rvalid;
    logic rready;
    logic awvalid;
    logic awready;
    logic wlast;
    logic wvalid;
    logic wready;
    logic bvalid;
    logic bready;
    logic [31:0] rdata;
    logic [31:0] wdata;
    logic [3:0] wstrb;

    logic [31:0] init_mem [0:MEM_WORDS-1];
    logic [31:0] mem [0:MEM_WORDS-1];

    logic rd_active_q;
    logic wr_active_q;
    logic bvalid_q;
    logic [63:0] rd_addr_q;
    logic [63:0] wr_addr_q;
    logic [8:0] rd_left_q;
    logic [8:0] wr_left_q;
    logic [0:0] rd_id_q;
    logic [0:0] wr_id_q;

    int unsigned read_beats_q;
    int unsigned write_beats_q;
    int unsigned param_requests_q;
    int unsigned param_beats_q;
    int unsigned fill_count_q;
    int unsigned retire_count_q;
    int unsigned final_accepts_q;
    int unsigned matrix_starts_q;
    int unsigned matrix_finals_q;
    int unsigned psum_writes_q;
    int unsigned retire_per_slot_q [0:3];

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Force multiple K tiles. Otherwise the default K_TILE_SIZE=256
    // would make K=32 a single-tile test.
    npu_top #(
        .K_TILE_SIZE(16)
    ) u_dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .desc_base(64'(DESC_BASE)),
        .desc_count(16'd1),
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
        .m_axi_bready(bready)
    );

    // ------------------------------------------------------------
    // DDR AXI read model, 32-bit incrementing bursts.
    // ------------------------------------------------------------

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
            read_beats_q <= 0;
            param_requests_q <= 0;
            param_beats_q <= 0;
        end else begin
            if (arvalid && arready) begin
                if (arsize != 3'd2 || arburst != 2'b01 ||
                    araddr[1:0] != 2'b00 ||
                    araddr + (64'(arlen) + 64'd1) * 64'd4 >
                        64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI read request addr=%h len=%0d",
                           araddr, arlen);

                rd_active_q <= 1'b1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0, arlen} + 9'd1;
                rd_id_q <= arid;

                if (araddr >= 64'(PARAM_BASE + 16) &&
                    araddr < (64'(PARAM_BASE) + 64'd16 + 64'(N) * 64'd12)) begin
                    if (arlen != 8'd11)
                        $fatal(1, "Unexpected parameter burst length %0d", arlen);
                    param_requests_q <= param_requests_q + 1;
                end
            end else if (rvalid && rready) begin
                read_beats_q <= read_beats_q + 1;
                if (rd_addr_q >= 64'(PARAM_BASE + 16) &&
                    rd_addr_q < (64'(PARAM_BASE) + 64'd16 + 64'(N) * 64'd12))
                    param_beats_q <= param_beats_q + 1;

                if (rlast) begin
                    rd_active_q <= 1'b0;
                end else begin
                    rd_addr_q <= rd_addr_q + 64'd4;
                    rd_left_q <= rd_left_q - 9'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // DDR AXI write model, byte strobes preserved.
    // ------------------------------------------------------------

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
            write_beats_q <= 0;
            for (int idx = 0; idx < MEM_WORDS; idx++)
                mem[idx] <= init_mem[idx];
        end else begin
            if (awvalid && awready) begin
                if (awsize != 3'd2 || awburst != 2'b01 ||
                    awaddr[1:0] != 2'b00 ||
                    awaddr + (64'(awlen) + 64'd1) * 64'd4 >
                        64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI write request addr=%h len=%0d",
                           awaddr, awlen);

                wr_active_q <= 1'b1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0, awlen} + 9'd1;
                wr_id_q <= awid;
            end

            if (wvalid && wready) begin
                if (wlast != (wr_left_q == 9'd1) ||
                    wr_addr_q >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Invalid AXI write data");

                for (int lane = 0; lane < 4; lane++) begin
                    if (wstrb[lane])
                        mem[int'(wr_addr_q >> 2)][8*lane +: 8] <=
                            wdata[8*lane +: 8];
                end

                write_beats_q <= write_beats_q + 1;
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

    // ------------------------------------------------------------
    // Deterministic signed test vectors and software golden.
    // ------------------------------------------------------------

    function automatic int signed aval(input int m, input int k);
        return ((m * 7 + k * 3) % 11) - 5;
    endfunction

    function automatic int signed bval(input int n, input int k);
        return ((n * 5 + k * 2 + 3) % 13) - 6;
    endfunction

    function automatic int signed biasval(input int n);
        return n * 3 - 48;
    endfunction

    function automatic int unsigned multiplier_val(input int n);
        return 2 + (n % 7);
    endfunction

    function automatic int unsigned shift_val(input int n);
        return 2 + (n % 4);
    endfunction

    function automatic int signed golden(input int m, input int n);
        int signed acc;
        int signed product;
        int signed mag;
        int signed q;
        int unsigned shift_amount;

        acc = biasval(n);
        for (int k = 0; k < int'(K); k++)
            acc += aval(m, k) * bval(n, k);

        product = acc * int'(multiplier_val(n));
        shift_amount = shift_val(n);
        mag = (product < 0) ? -product : product;
        q = (mag + (1 << (shift_amount - 1))) >> shift_amount;
        if (product < 0)
            q = -q;
        if (q > 127)
            q = 127;
        if (q < -128)
            q = -128;
        return q;
    endfunction

    task automatic put_byte(
        input int unsigned addr,
        input int signed value
    );
        if (value < -128 || value > 127 || addr >= MEM_WORDS * 4)
            $fatal(1, "Bad test-vector byte addr=%0d val=%0d",
                   addr, value);
        init_mem[addr >> 2][8*addr[1:0] +: 8] = 8'(value);
    endtask

    // ------------------------------------------------------------
    // Coverage of scheduling and parameter/C slot lifecycle.
    // ------------------------------------------------------------

    always @(posedge clk) begin : monitor
        int unsigned oc;
        logic [1:0] slot_idx;

        if (reset) begin
            fill_count_q <= 0;
            retire_count_q <= 0;
            final_accepts_q <= 0;
            matrix_starts_q <= 0;
            matrix_finals_q <= 0;
            psum_writes_q <= 0;
            for (int s = 0; s < 4; s++)
                retire_per_slot_q[s] <= 0;
        end else begin
            if (u_dut.u_gemm_executor.scheduler_matrix_start) begin
                matrix_starts_q <= matrix_starts_q + 1;
                if (u_dut.u_gemm_executor.scheduler_writeback_en)
                    matrix_finals_q <= matrix_finals_q + 1;
            end

            if (u_dut.u_gemm_executor.psum_wr_en)
                psum_writes_q <= psum_writes_q + 1;

            if (u_dut.u_gemm_executor.bias_load_done) begin
                if (!u_dut.u_gemm_executor.param_bank_fill_ready)
                    $fatal(1, "Parameter fill attempted on an occupied slot");
                fill_count_q <= fill_count_q + 1;
            end

            if (u_dut.u_gemm_executor.c_write_tile_accept) begin
                if (!u_dut.u_gemm_executor.param_bank_read_hit)
                    $fatal(1, "No matching parameters at output writeback");

                final_accepts_q <= final_accepts_q + 1;
                for (int lane = 0; lane < int'(COLS); lane++) begin
                    oc = int'($unsigned(
                        u_dut.u_gemm_executor.compute_n_tile_idx
                    )) * int'(COLS) + lane;

                    if (u_dut.u_gemm_executor.bank_bias[lane] !==
                        32'(biasval(int'(oc))) ||
                        u_dut.u_gemm_executor.bank_multiplier[lane] !==
                        32'(multiplier_val(int'(oc))) ||
                        u_dut.u_gemm_executor.bank_shift[lane] !==
                        6'(shift_val(int'(oc))))
                        $fatal(1, "Slot data mismatch N=%0d lane=%0d",
                               oc / int'(COLS), lane);
                end
            end

            if (u_dut.u_gemm_executor.c_write_done) begin
                if (!u_dut.u_gemm_executor.param_bank_retire_hit)
                    $fatal(1, "Parameter slot retired with wrong N tag");

                retire_count_q <= retire_count_q + 1;
                slot_idx = u_dut.u_gemm_executor.psum_target_slot;
                retire_per_slot_q[slot_idx] <=
                    retire_per_slot_q[slot_idx] + 1;
            end
        end
    end

    // ------------------------------------------------------------
    // Descriptor and DDR initialization.
    // ------------------------------------------------------------

    initial begin : run
        int unsigned cycles;
        int signed exp;
        logic [7:0] actual;

        reset = 1'b1;
        start = 1'b0;

        for (int i = 0; i < MEM_WORDS; i++)
            init_mem[i] = 32'd0;

        // A: M rows, K signed INT8 elements per row.
        for (int m = 0; m < int'(M); m++)
            for (int k = 0; k < int'(K); k++)
                put_byte(A_BASE + m * int'(K) + k, aval(m, k));

        // B is B-transposed: N rows, K elements per output channel.
        for (int n = 0; n < int'(N); n++)
            for (int k = 0; k < int'(K); k++)
                put_byte(B_BASE + n * int'(K) + k, bval(n, k));

        // Initialize output region with a sentinel to detect no writes.
        for (int idx = 0; idx < int'(M * N / 4); idx++)
            init_mem[C_BASE / 4 + idx] = 32'hA5A5_A5A5;

        // [16-byte header] followed by per-channel triples.
        for (int n = 0; n < int'(N); n++) begin
            init_mem[PARAM_BASE / 4 + 4 + 3*n] = 32'(biasval(n));
            init_mem[PARAM_BASE / 4 + 5 + 3*n] =
                32'(multiplier_val(n));
            init_mem[PARAM_BASE / 4 + 6 + 3*n] = 32'(shift_val(n));
        end

        // GEMM opcode=1; flags bit0 Bias, bit1 Requant,
        // bit3 Per-channel; bit2 ReLU disabled to test signed INT8.
        init_mem[DESC_BASE / 4 + 0] = 32'h0000_0b01;
        init_mem[DESC_BASE / 4 + 1] = 32'(M);
        init_mem[DESC_BASE / 4 + 2] = 32'(N);
        init_mem[DESC_BASE / 4 + 3] = 32'(K);
        init_mem[DESC_BASE / 4 + 4] = 32'(A_BASE);
        init_mem[DESC_BASE / 4 + 6] = 32'(B_BASE);
        init_mem[DESC_BASE / 4 + 8] = 32'(C_BASE);
        init_mem[DESC_BASE / 4 + 10] = 32'(K);
        init_mem[DESC_BASE / 4 + 11] = 32'(K);
        init_mem[DESC_BASE / 4 + 12] = 32'(N);
        init_mem[DESC_BASE / 4 + 13] = 32'(PARAM_BASE);

        repeat (6) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (!done && cycles < 250000) begin
            @(negedge clk);
            cycles++;
        end
        if (!done)
            $fatal(1, "Multi-K/Multi-N test timeout");
        if (error)
            $fatal(1, "NPU signalled an execution error");

        // All 256 output bytes must match signed software golden.
        for (int m = 0; m < int'(M); m++) begin
            for (int n = 0; n < int'(N); n++) begin
                actual = mem[
                    C_BASE / 4 + (m * int'(N) + n) / 4
                ][8*(n % 4) +: 8];
                exp = golden(m, n);
                if (actual !== 8'(exp))
                    $fatal(1,
                        "C[%0d,%0d] mismatch actual=%0d expected=%0d",
                        m, n, $signed(actual), exp);
            end
        end

        if (write_beats_q != 64 ||
            matrix_starts_q != FINAL_TILES * K_TILES ||
            matrix_finals_q != FINAL_TILES ||
            final_accepts_q != FINAL_TILES ||
            retire_count_q != FINAL_TILES ||
            fill_count_q != FINAL_TILES ||
            param_requests_q != FINAL_TILES ||
            param_beats_q != FINAL_TILES * 3 * COLS)
            $fatal(1,
                "Coverage mismatch: W=%0d matrix=%0d finals=%0d accepts=%0d fills=%0d retires=%0d param_req=%0d param_beats=%0d",
                write_beats_q, matrix_starts_q, matrix_finals_q,
                final_accepts_q, fill_count_q, retire_count_q,
                param_requests_q, param_beats_q);

        for (int s = 0; s < 4; s++)
            if (retire_per_slot_q[s] != FINAL_TILES / 4)
                $fatal(1, "Slot %0d reuse coverage=%0d expected=%0d",
                       s, retire_per_slot_q[s], FINAL_TILES / 4);

`ifdef NPU_PSUM_EXPERIMENT
        if (psum_writes_q == 0)
            $fatal(1, "Expected C SRAM PSUM writes");
`else
        if (psum_writes_q != 0)
            $fatal(1, "Unexpected C SRAM PSUM writes");
`endif

        $display(
            "PARAM SLOT STRESS PASS: cycles=%0d reads=%0d writes=%0d fills=%0d retires=%0d psum_rows=%0d acc00=%0d busy=%0b",
            cycles, read_beats_q, write_beats_q,
            fill_count_q, retire_count_q, psum_writes_q,
            acc_out[0][0], busy
        );
        $finish;
    end

endmodule
