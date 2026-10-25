`timescale 1ns/1ps

// Parameter overrides exercise rectangular arrays and independent A/B banks.
module gemm_tile_compute_tb #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int A_BUFFER_COUNT = 1,
    parameter int B_BUFFER_COUNT = 1,
    parameter int DEPTH = 256,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32,
    parameter int MEM_WORD_WIDTH = 32
);
    localparam int RESULT_DEPTH = (DEPTH > ROWS) ? DEPTH : ROWS;
    localparam int ADDR_WIDTH = (RESULT_DEPTH <= 1) ? 1 : $clog2(RESULT_DEPTH);
    localparam int K_SIZE_WIDTH = $clog2(DEPTH + 1);
    localparam int ELEMS_PER_WORD = MEM_WORD_WIDTH / DATA_WIDTH;
    localparam int WORD_DEPTH = (DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD;
    localparam int OPERAND_MAX = (1 << (DATA_WIDTH - 1)) - 1;
    localparam int OPERAND_MIN = -(1 << (DATA_WIDTH - 1));
    localparam int WORD_ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH);
    localparam int A_LANE_WIDTH = (ROWS <= 1) ? 1 : $clog2(ROWS);
    localparam int B_LANE_WIDTH = (COLS <= 1) ? 1 : $clog2(COLS);

    logic clk = 0;
    logic reset, start, clear_acc, writeback_en, busy, done;
    logic [K_SIZE_WIDTH-1:0] tile_k_size;
    logic [ADDR_WIDTH-1:0] c_base_addr, c_raddr;
    logic a_wen, b_wen, a_wbank, a_rbank, b_wbank, b_rbank, c_ren;
    logic [A_LANE_WIDTH-1:0] a_wlane;
    logic [B_LANE_WIDTH-1:0] b_wlane;
    logic [WORD_ADDR_WIDTH-1:0] a_waddr, b_waddr;
    logic [MEM_WORD_WIDTH-1:0] a_wdata, b_wdata;
    logic [COLS*ACC_WIDTH-1:0] c_rdata;
    logic signed [ACC_WIDTH-1:0] acc_out [ROWS][COLS];
    longint signed golden [ROWS][COLS];
    integer checks = 0;

    gemm_tile_compute #(
        .ROWS(ROWS), .COLS(COLS), .DEPTH(DEPTH),
        .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .MEM_WORD_WIDTH(MEM_WORD_WIDTH),
        .A_BUFFER_COUNT(A_BUFFER_COUNT), .B_BUFFER_COUNT(B_BUFFER_COUNT)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic integer operand_a(input integer mode, row, k);
        if (mode < 2) operand_a = row * 6 + k + 1 + mode * 3;
        else if (k % 4 == 0) operand_a = OPERAND_MIN;
        else if (k % 4 == 1) operand_a = OPERAND_MAX;
        else operand_a = row - k % 7;
        operand_a = $signed(DATA_WIDTH'(operand_a));
    endfunction

    function automatic integer operand_b(input integer mode, col, k);
        if (mode < 2) operand_b = k * 4 + col + 1 + mode * 12;
        else if (k % 4 == 0) operand_b = OPERAND_MAX;
        else if (k % 4 == 1) operand_b = OPERAND_MIN;
        else operand_b = col + k % 5;
        operand_b = $signed(DATA_WIDTH'(operand_b));
    endfunction

    task automatic preload(input integer mode, k_size);
        logic [MEM_WORD_WIDTH-1:0] word_data;
        for (int row = 0; row < ROWS; row++) begin
            for (int word_idx = 0; word_idx < (k_size + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD; word_idx++) begin
                word_data = '0;
                for (int elem = 0; elem < ELEMS_PER_WORD; elem++)
                    if (word_idx * ELEMS_PER_WORD + elem < k_size)
                        word_data[elem*DATA_WIDTH +: DATA_WIDTH] = DATA_WIDTH'(operand_a(mode, row, word_idx*ELEMS_PER_WORD+elem));
                @(negedge clk);
                a_wen = 1;
                a_wlane = A_LANE_WIDTH'(row);
                a_waddr = WORD_ADDR_WIDTH'(word_idx);
                a_wdata = word_data;
                @(negedge clk);
                a_wen = 0;
            end
        end
        for (int col = 0; col < COLS; col++) begin
            for (int word_idx = 0; word_idx < (k_size + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD; word_idx++) begin
                word_data = '0;
                for (int elem = 0; elem < ELEMS_PER_WORD; elem++)
                    if (word_idx * ELEMS_PER_WORD + elem < k_size)
                        word_data[elem*DATA_WIDTH +: DATA_WIDTH] = DATA_WIDTH'(operand_b(mode, col, word_idx*ELEMS_PER_WORD+elem));
                @(negedge clk);
                b_wen = 1;
                b_wlane = B_LANE_WIDTH'(col);
                b_waddr = WORD_ADDR_WIDTH'(word_idx);
                b_wdata = word_data;
                @(negedge clk);
                b_wen = 0;
            end
        end
    endtask

    task automatic run_tile(input integer mode, k_size, input bit do_clear, do_writeback);
        preload(mode, k_size);
        for (int row = 0; row < ROWS; row++)
            for (int col = 0; col < COLS; col++) begin
                if (do_clear) golden[row][col] = 0;
                for (int k = 0; k < k_size; k++)
                    golden[row][col] += operand_a(mode, row, k) * operand_b(mode, col, k);
            end
        @(negedge clk);
        tile_k_size = K_SIZE_WIDTH'(k_size);
        clear_acc = do_clear;
        writeback_en = do_writeback;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (done === 1'b1);
        if (busy !== 1'b1) $fatal(1, "busy must remain high during DONE");
        @(posedge clk);
        #1;
        if (busy !== 1'b0 || done !== 1'b0) $fatal(1, "DUT did not return to IDLE");
        for (int row = 0; row < ROWS; row++)
            for (int col = 0; col < COLS; col++) begin
                if (acc_out[row][col] !== golden[row][col])
                    $fatal(1, "ACC[%0d,%0d]=%0d expected=%0d K=%0d", row, col,
                           acc_out[row][col], golden[row][col], k_size);
                checks++;
            end
        $display("ACC_CHECK K=%0d clear=%0b writeback=%0b elements=%0d", k_size,
                 do_clear, do_writeback, ROWS*COLS);
    endtask

    task automatic check_c;
        for (int row = 0; row < ROWS; row++) begin
            @(negedge clk);
            c_ren = 1;
            c_raddr = c_base_addr + ADDR_WIDTH'(row);
            @(posedge clk);
            #1;
            for (int col = 0; col < COLS; col++) begin
                if ($signed(c_rdata[col*ACC_WIDTH +: ACC_WIDTH]) !== golden[row][col])
                    $fatal(1, "C[%0d,%0d]=%0d expected=%0d", row, col,
                           $signed(c_rdata[col*ACC_WIDTH +: ACC_WIDTH]), golden[row][col]);
                checks++;
                $display("C[%0d,%0d]=%0d", row, col, golden[row][col]);
            end
            @(negedge clk);
            c_ren = 0;
        end
    endtask

    initial begin
        reset = 1; start = 0; clear_acc = 0; writeback_en = 0; tile_k_size = 0;
        a_wen = 0; b_wen = 0; a_wlane = 0; b_wlane = 0;
        a_waddr = 0; b_waddr = 0; a_wdata = 0; b_wdata = 0;
        a_wbank = 0; a_rbank = 0; b_wbank = 0; b_rbank = 0;
        c_ren = 0; c_raddr = 0; c_base_addr = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Preserve the original two K=3 accumulation cases and expected matrix.
        run_tile(0, (DEPTH < 3) ? DEPTH : 3, 1, 0);
        $display("K tile 0 partial sums preserved: PASS");
        run_tile(1, (DEPTH < 3) ? DEPTH : 3, 0, 1);
        check_c();
        $display("K-TILING TEST PASSED");

        // Signed extremes, word boundary, full depth, and nonzero C base.
        c_base_addr = (RESULT_DEPTH >= 16 + ROWS) ? ADDR_WIDTH'(16) : '0;
        a_wbank = (A_BUFFER_COUNT == 2); a_rbank = a_wbank;
        b_wbank = (B_BUFFER_COUNT == 2); b_rbank = b_wbank;
        run_tile(2, 1, 1, 1); check_c();
        if (DEPTH >= ELEMS_PER_WORD) begin run_tile(2, ELEMS_PER_WORD, 1, 1); check_c(); end
        if (DEPTH > ELEMS_PER_WORD) begin run_tile(2, ELEMS_PER_WORD + 1, 1, 1); check_c(); end
        run_tile(2, DEPTH, 1, 1); check_c();
        $display("TEST_PASS gemm_tile_compute_tb checks=%0d rows=%0d cols=%0d A=%0d B=%0d depth=%0d data=%0d acc=%0d word=%0d",
                 checks, ROWS, COLS, A_BUFFER_COUNT, B_BUFFER_COUNT, DEPTH, DATA_WIDTH, ACC_WIDTH, MEM_WORD_WIDTH);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "GEMM core timeout");
    end
    initial begin
        $dumpfile("gemm_tile_compute_tb.vcd");
        $dumpvars(0, gemm_tile_compute_tb);
    end
endmodule
