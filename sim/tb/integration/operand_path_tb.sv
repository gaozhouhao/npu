`timescale 1ns/1ps

// Real INT8 packing, lane-major loads, and ping-pong load/compute overlap.
module operand_path_tb;
    localparam int LANES = 3;
    localparam int K_DEPTH = 16;
    logic clk = 0;
    logic reset, load_req, load_accept, load_done, loader_busy;
    logic [4:0] load_size;
    logic manager_load_req, manager_load_grant, manager_load_bank, manager_load_done;
    logic data_valid, data_ready;
    logic [31:0] data;
    logic buffer_wen, buffer_wbank;
    logic [1:0] buffer_wlane, buffer_waddr;
    logic [31:0] buffer_wdata;
    logic compute_req, compute_grant, compute_bank, compute_done, release_bank;
    logic buffer_ren, buffer_rbank;
    logic [3:0] buffer_raddr;
    logic [LANES*8-1:0] buffer_rdata;

    operand_loader #(.LANE_COUNT(LANES), .K_DEPTH(K_DEPTH), .BUFFER_COUNT(2)) u_loader (
        .clk(clk), .reset(reset), .load_req(load_req), .load_accept(load_accept),
        .load_size(load_size), .load_done(load_done), .busy(loader_busy),
        .bank_load_req(manager_load_req), .bank_load_grant(manager_load_grant),
        .bank_load_bank(manager_load_bank), .bank_load_done(manager_load_done),
        .data_valid(data_valid), .data_ready(data_ready), .data(data),
        .buffer_wen(buffer_wen), .buffer_wbank(buffer_wbank),
        .buffer_wlane(buffer_wlane), .buffer_waddr(buffer_waddr), .buffer_wdata(buffer_wdata)
    );
    buffer_manager #(.BUFFER_COUNT(2)) u_manager (
        .clk(clk), .reset(reset), .load_req(manager_load_req),
        .load_grant(manager_load_grant), .load_bank(manager_load_bank),
        .load_done(manager_load_done), .compute_req(compute_req),
        .compute_grant(compute_grant), .compute_bank(compute_bank),
        .compute_done(compute_done), .release_bank(release_bank)
    );
    operand_buffer #(.LANE_COUNT(LANES), .K_DEPTH(K_DEPTH), .BUFFER_COUNT(2)) u_buffer (
        .clk(clk), .wen(buffer_wen), .wbank(buffer_wbank), .wlane(buffer_wlane),
        .waddr(buffer_waddr), .wdata(buffer_wdata), .ren(buffer_ren),
        .rbank(buffer_rbank), .r_k_index(buffer_raddr), .rdata(buffer_rdata)
    );
    always #5 clk = ~clk;

    task automatic load_tile(input int seed, k_size, input bit bank);
        logic [31:0] word_data;
        @(negedge clk); load_req = 1; load_size = 5'(k_size);
        #1;
        if (load_accept !== 1'b1) $fatal(1, "Load request rejected");
        @(negedge clk); load_req = 0;
        wait (data_ready === 1'b1);
        for (int lane = 0; lane < LANES; lane++) begin
            for (int word_idx = 0; word_idx < (k_size+3)/4; word_idx++) begin
                // Stall the stream and ensure the loader never writes without valid.
                @(negedge clk); data_valid = 0;
                #1;
                if (buffer_wen !== 1'b0) $fatal(1, "Write during stream stall");
                word_data = 0;
                for (int elem = 0; elem < 4; elem++)
                    if (word_idx*4+elem < k_size)
                        word_data[elem*8 +: 8] = 8'(seed + lane*16 + word_idx*4+elem);
                @(negedge clk); data = word_data; data_valid = 1;
                #1;
                if (buffer_wen !== 1'b1 || buffer_wbank !== bank ||
                    buffer_wlane !== 2'(lane) || buffer_waddr !== 2'(word_idx) ||
                    buffer_wdata !== word_data)
                    $fatal(1, "Load mapping mismatch bank=%0d lane=%0d word=%0d", bank, lane, word_idx);
                @(negedge clk); data_valid = 0;
            end
        end
        if (load_done !== 1'b1 || manager_load_done !== 1'b1)
            $fatal(1, "Missing load completion");
        @(posedge clk); #1;
        if (load_done !== 1'b0) $fatal(1, "Load done must be a pulse");
        $display("LOAD_CHECK bank=%0d K=%0d lanes=%0d", bank, k_size, LANES);
    endtask

    task automatic acquire(input bit bank);
        @(negedge clk); compute_req = 1;
        #1;
        if (compute_grant !== 1'b1 || compute_bank !== bank)
            $fatal(1, "Wrong compute bank expected=%0d", bank);
        @(negedge clk); compute_req = 0;
    endtask

    task automatic check_tile(input int seed, k_size, input bit bank);
        for (int k = 0; k < k_size; k++) begin
            @(negedge clk);
            buffer_ren = 1; buffer_rbank = bank; buffer_raddr = 4'(k);
            @(posedge clk); #1;
            for (int lane = 0; lane < LANES; lane++)
                if (buffer_rdata[lane*8 +: 8] !== 8'(seed+lane*16+k))
                    $fatal(1, "Read mismatch bank=%0d lane=%0d k=%0d", bank, lane, k);
        end
        @(negedge clk); buffer_ren = 0;
        $display("READ_CHECK bank=%0d elements=%0d", bank, LANES*k_size);
    endtask

    task automatic release_compute;
        @(negedge clk); compute_done = 1;
        @(negedge clk); compute_done = 0;
    endtask

    initial begin
        reset = 1; load_req = 0; load_size = 0; data_valid = 0; data = 0;
        compute_req = 0; compute_done = 0; release_bank = 1;
        buffer_ren = 0; buffer_rbank = 0; buffer_raddr = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 0;
        load_tile(1, 7, 0);
        acquire(0);
        load_tile(65, 5, 1); // Load bank 1 while bank 0 remains COMPUTING.
        check_tile(1, 7, 0);
        release_compute();
        acquire(1);
        check_tile(65, 5, 1);
        release_compute();
        $display("TEST_PASS operand_path_tb");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Operand path timeout");
    end
endmodule
