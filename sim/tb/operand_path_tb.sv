module operand_path_tb;

    localparam int unsigned WORD_WIDTH   = 32;
    localparam int unsigned DEPTH        = 256;
    localparam int unsigned ADDR_WIDTH   = $clog2(DEPTH);
    localparam int unsigned SIZE_WIDTH   = $clog2(DEPTH + 1);
    localparam int unsigned BUFFER_COUNT = 2;

    typedef logic [SIZE_WIDTH-1:0] size_t;

    logic clk;
    logic reset;

    // ============================================================
    // Scheduler -> Loader
    // ============================================================

    logic  load_req;
    logic  load_accept;
    size_t load_size;
    logic  load_done;

    // ============================================================
    // Loader -> Buffer Manager
    // ============================================================

    logic manager_load_req;
    logic manager_load_grant;
    logic manager_load_bank;
    logic manager_load_done;

    // ============================================================
    // Input data stream
    // ============================================================

    logic                  data_valid;
    logic [WORD_WIDTH-1:0] data;
    logic                  data_ready;

    // ============================================================
    // Loader -> Operand Buffer
    // ============================================================

    logic                  buffer_wen;
    logic                  buffer_wbank;
    logic [ADDR_WIDTH-1:0] buffer_waddr;
    logic [WORD_WIDTH-1:0] buffer_wdata;

    // ============================================================
    // Buffer Manager compute side
    // ============================================================

    logic compute_req;
    logic compute_grant;
    logic compute_bank;
    logic compute_done;
    logic release_bank;

    // ============================================================
    // Operand Buffer read side
    // ============================================================

    logic                  buffer_ren;
    logic                  buffer_rbank;
    logic [ADDR_WIDTH-1:0] buffer_raddr;
    logic [WORD_WIDTH-1:0] buffer_rdata;

    logic loader_busy;


    // ============================================================
    // Loader
    // ============================================================

    operand_loader #(
        .WORD_WIDTH (WORD_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .SIZE_WIDTH (SIZE_WIDTH)
    ) u_loader (
        .clk             (clk),
        .reset           (reset),

        .load_req        (load_req),
        .load_accept     (load_accept),
        .load_size       (load_size),
        .load_done       (load_done),

        .bank_load_req   (manager_load_req),
        .bank_load_grant (manager_load_grant),
        .bank_load_bank  (manager_load_bank),
        .bank_load_done  (manager_load_done),

        .data_valid      (data_valid),
        .data            (data),
        .data_ready      (data_ready),

        .buffer_wen      (buffer_wen),
        .buffer_wbank    (buffer_wbank),
        .buffer_waddr    (buffer_waddr),
        .buffer_wdata    (buffer_wdata),

        .busy            (loader_busy)
    );


    // ============================================================
    // Buffer Manager
    // ============================================================

    buffer_manager #(
        .BUFFER_COUNT (BUFFER_COUNT)
    ) u_buffer_manager (
        .clk           (clk),
        .reset         (reset),

        .load_req      (manager_load_req),
        .load_grant    (manager_load_grant),
        .load_bank     (manager_load_bank),
        .load_done     (manager_load_done),

        .compute_req   (compute_req),
        .compute_grant (compute_grant),
        .compute_bank  (compute_bank),

        .compute_done  (compute_done),
        .release_bank  (release_bank)
    );


    // ============================================================
    // Physical Operand Buffer
    // ============================================================

    operand_buffer #(
        .DATA_WIDTH   (WORD_WIDTH),
        .DEPTH        (DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .BUFFER_COUNT (BUFFER_COUNT)
    ) u_operand_buffer (
        .clk   (clk),

        .wen   (buffer_wen),
        .wbank (buffer_wbank),
        .waddr (buffer_waddr),
        .wdata (buffer_wdata),

        .ren   (buffer_ren),
        .rbank (buffer_rbank),
        .raddr (buffer_raddr),
        .rdata (buffer_rdata)
    );


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    // ============================================================
    // Reset
    // ============================================================

    task automatic reset_dut;
        begin

            load_req     = 1'b0;
            load_size    = '0;

            data_valid   = 1'b0;
            data         = '0;

            compute_req  = 1'b0;
            compute_done = 1'b0;
            release_bank = 1'b1;

            buffer_ren   = 1'b0;
            buffer_rbank = 1'b0;
            buffer_raddr = '0;

            reset = 1'b1;

            repeat (3) begin
                @(posedge clk);
            end

            @(negedge clk);
            reset = 1'b0;

            @(posedge clk);
            #1;

            if (loader_busy !== 1'b0) begin
                $fatal(1, "loader must be idle after reset");
            end

        end
    endtask


    // ============================================================
    // Start one loader transaction
    // ============================================================

    task automatic begin_load(
        input size_t size
    );
        begin

            @(negedge clk);

            load_size = size;
            load_req  = 1'b1;

            #1;

            if (load_accept !== 1'b1) begin
                $fatal(1, "loader did not accept load request");
            end

            @(negedge clk);
            load_req = 1'b0;

            wait (data_ready === 1'b1);

        end
    endtask


    // ============================================================
    // Send one SRAM word
    // ============================================================

    task automatic send_word(
        input logic [WORD_WIDTH-1:0] word,
        input logic [ADDR_WIDTH-1:0] expected_addr,
        input logic                  expected_bank
    );
        begin

            @(negedge clk);

            data       = word;
            data_valid = 1'b1;

            #1;

            if (buffer_wen !== 1'b1) begin
                $fatal(1, "buffer write enable missing");
            end

            if (buffer_wbank !== expected_bank) begin
                $fatal(
                    1,
                    "wrong write bank: got %0d expected %0d",
                    buffer_wbank,
                    expected_bank
                );
            end

            if (buffer_waddr !== expected_addr) begin
                $fatal(
                    1,
                    "wrong write address: got %0d expected %0d",
                    buffer_waddr,
                    expected_addr
                );
            end

            if (buffer_wdata !== word) begin
                $fatal(1, "wrong write data");
            end

            @(negedge clk);
            data_valid = 1'b0;

        end
    endtask


    // ============================================================
    // Finish load
    // ============================================================

    task automatic finish_load;
        begin

            wait (load_done === 1'b1);

            #1;

            if (manager_load_done !== 1'b1) begin
                $fatal(1, "buffer manager load_done missing");
            end

            @(posedge clk);
            #1;

        end
    endtask


    // ============================================================
    // Acquire one READY bank for compute
    // ============================================================

    task automatic acquire_compute(
        input logic expected_bank
    );
        begin

            @(negedge clk);

            compute_req = 1'b1;

            #1;

            if (compute_grant !== 1'b1) begin
                $fatal(1, "compute bank was not granted");
            end

            if (compute_bank !== expected_bank) begin
                $fatal(
                    1,
                    "wrong compute bank: got %0d expected %0d",
                    compute_bank,
                    expected_bank
                );
            end

            @(negedge clk);
            compute_req = 1'b0;

        end
    endtask


    // ============================================================
    // Read and verify one SRAM location
    // ============================================================

    task automatic check_word(
        input logic                  bank,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [WORD_WIDTH-1:0] expected
    );
        begin

            @(negedge clk);

            buffer_rbank = bank;
            buffer_raddr = addr;
            buffer_ren   = 1'b1;

            @(posedge clk);
            #1;

            if (buffer_rdata !== expected) begin
                $fatal(
                    1,
                    "read mismatch bank=%0d addr=%0d got=%h expected=%h",
                    bank,
                    addr,
                    buffer_rdata,
                    expected
                );
            end

            @(negedge clk);
            buffer_ren = 1'b0;

        end
    endtask


    // ============================================================
    // Release compute bank
    // ============================================================

    task automatic finish_compute;
        begin

            @(negedge clk);

            release_bank = 1'b1;
            compute_done = 1'b1;

            @(negedge clk);

            compute_done = 1'b0;

        end
    endtask


    // ============================================================
    // Test
    // ============================================================

    initial begin

        reset = 1'b1;

        load_req     = 1'b0;
        load_size    = '0;

        data_valid   = 1'b0;
        data         = '0;

        compute_req  = 1'b0;
        compute_done = 1'b0;
        release_bank = 1'b1;

        buffer_ren   = 1'b0;
        buffer_rbank = 1'b0;
        buffer_raddr = '0;


        // ========================================================
        // TEST 1
        //
        // First tile must enter bank 0.
        // ========================================================

        $display("TEST 1: load first tile into bank 0");

        reset_dut();

        begin_load(size_t'(4));

        send_word(32'h11110000, 8'd0, 1'b0);
        send_word(32'h11110001, 8'd1, 1'b0);
        send_word(32'h11110002, 8'd2, 1'b0);
        send_word(32'h11110003, 8'd3, 1'b0);

        finish_load();


        // ========================================================
        // TEST 2
        //
        // Bank 0 becomes COMPUTING.
        // ========================================================

        $display("TEST 2: acquire bank 0 for compute");

        acquire_compute(1'b0);

        check_word(1'b0, 8'd0, 32'h11110000);
        check_word(1'b0, 8'd1, 32'h11110001);
        check_word(1'b0, 8'd2, 32'h11110002);
        check_word(1'b0, 8'd3, 32'h11110003);


        // ========================================================
        // TEST 3
        //
        // While bank 0 is COMPUTING, load another tile.
        //
        // Buffer manager must allocate bank 1.
        // ========================================================

        $display("TEST 3: load bank 1 while bank 0 is computing");

        begin_load(size_t'(2));

        send_word(32'h22220000, 8'd0, 1'b1);
        send_word(32'h22220001, 8'd1, 1'b1);

        finish_load();


        // ========================================================
        // Finish computation on bank 0.
        // ========================================================

        finish_compute();


        // ========================================================
        // TEST 4
        //
        // Bank 1 is READY and should now be selected.
        // ========================================================

        $display("TEST 4: acquire bank 1 for compute");

        acquire_compute(1'b1);

        check_word(1'b1, 8'd0, 32'h22220000);
        check_word(1'b1, 8'd1, 32'h22220001);

        finish_compute();


        // ========================================================
        // PASS
        // ========================================================

        $display("All operand path integration tests passed.");

        $finish;

    end

endmodule
