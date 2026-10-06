module operand_loader_tb;

    localparam int unsigned WORD_WIDTH = 32;
    localparam int unsigned DEPTH      = 256;
    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
    localparam int unsigned SIZE_WIDTH = $clog2(DEPTH + 1);

    typedef logic [SIZE_WIDTH-1:0] size_t;

    logic clk;
    logic reset;

    logic load_req;
    logic load_accept;
    size_t load_size;
    logic load_done;

    logic bank_load_req;
    logic bank_load_grant;
    logic bank_load_bank;
    logic bank_load_done;

    logic                  data_valid;
    logic [WORD_WIDTH-1:0] data;
    logic                  data_ready;

    logic                  buffer_wen;
    logic                  buffer_wbank;
    logic [ADDR_WIDTH-1:0] buffer_waddr;
    logic [WORD_WIDTH-1:0] buffer_wdata;

    logic busy;


    operand_loader #(
        .WORD_WIDTH (WORD_WIDTH),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .SIZE_WIDTH (SIZE_WIDTH)
    ) dut (
        .clk             (clk),
        .reset           (reset),

        .load_req        (load_req),
        .load_accept     (load_accept),
        .load_size       (load_size),
        .load_done       (load_done),

        .bank_load_req   (bank_load_req),
        .bank_load_grant (bank_load_grant),
        .bank_load_bank  (bank_load_bank),
        .bank_load_done  (bank_load_done),

        .data_valid      (data_valid),
        .data            (data),
        .data_ready      (data_ready),

        .buffer_wen      (buffer_wen),
        .buffer_wbank    (buffer_wbank),
        .buffer_waddr    (buffer_waddr),
        .buffer_wdata    (buffer_wdata),

        .busy            (busy)
    );


    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    task automatic reset_dut;
        begin
            load_req        = 1'b0;
            load_size       = '0;

            bank_load_grant = 1'b0;
            bank_load_bank  = 1'b0;

            data_valid      = 1'b0;
            data            = '0;

            reset = 1'b1;

            repeat (3) begin
                @(posedge clk);
            end

            @(negedge clk);
            reset = 1'b0;

            @(posedge clk);
            #1;

            if (busy !== 1'b0) begin
                $fatal(1, "busy must be 0 after reset");
            end
        end
    endtask


    task automatic start_load(
        input size_t size,
        input logic  bank
    );
        begin

            // ----------------------------------------------------
            // Scheduler issues one load request.
            // ----------------------------------------------------

            @(negedge clk);

            load_size = size;
            load_req  = 1'b1;

            #1;

            if (load_accept !== 1'b1) begin
                $fatal(1, "load request was not accepted");
            end

            @(negedge clk);
            load_req = 1'b0;


            // ----------------------------------------------------
            // Loader should request an EMPTY bank.
            // ----------------------------------------------------

            wait (bank_load_req === 1'b1);

            @(negedge clk);

            bank_load_bank  = bank;
            bank_load_grant = 1'b1;

            @(negedge clk);

            bank_load_grant = 1'b0;

            wait (data_ready === 1'b1);

        end
    endtask


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
                $fatal(1, "buffer_wen missing");
            end

            if (buffer_waddr !== expected_addr) begin
                $fatal(
                    1,
                    "wrong write address: got %0d expected %0d",
                    buffer_waddr,
                    expected_addr
                );
            end

            if (buffer_wbank !== expected_bank) begin
                $fatal(
                    1,
                    "wrong bank: got %0d expected %0d",
                    buffer_wbank,
                    expected_bank
                );
            end

            if (buffer_wdata !== word) begin
                $fatal(1, "wrong write data");
            end

            @(negedge clk);
            data_valid = 1'b0;

        end
    endtask


    initial begin

        reset = 1'b1;

        load_req        = 1'b0;
        load_size       = '0;

        bank_load_grant = 1'b0;
        bank_load_bank  = 1'b0;

        data_valid      = 1'b0;
        data            = '0;


        // ========================================================
        // TEST 1
        //
        // Load 4 words into bank 0.
        // ========================================================

        $display("TEST 1: load 4 words into bank 0");

        reset_dut();

        start_load(
            size_t'(4),
            1'b0
        );

        send_word(32'h11111111, 8'd0, 1'b0);
        send_word(32'h22222222, 8'd1, 1'b0);


        // --------------------------------------------------------
        // Deliberate data stall.
        //
        // Address must remain at 2 while data_valid = 0.
        // --------------------------------------------------------

        repeat (3) begin

            @(negedge clk);
            data_valid = 1'b0;

            #1;

            if (buffer_wen !== 1'b0) begin
                $fatal(1, "buffer_wen asserted during data stall");
            end

            if (buffer_waddr !== 8'd2) begin
                $fatal(
                    1,
                    "write address changed during stall"
                );
            end

        end


        send_word(32'h33333333, 8'd2, 1'b0);
        send_word(32'h44444444, 8'd3, 1'b0);


        // --------------------------------------------------------
        // Completion
        // --------------------------------------------------------

        wait (load_done === 1'b1);

        #1;

        if (bank_load_done !== 1'b1) begin
            $fatal(1, "bank_load_done missing");
        end

        @(posedge clk);
        #1;

        if (load_done !== 1'b0) begin
            $fatal(1, "load_done must be one cycle");
        end


        // ========================================================
        // TEST 2
        //
        // Verify bank 1 selection.
        // ========================================================

        $display("TEST 2: load into bank 1");

        start_load(
            size_t'(2),
            1'b1
        );

        send_word(32'hAAAA0001, 8'd0, 1'b1);
        send_word(32'hAAAA0002, 8'd1, 1'b1);

        wait (load_done === 1'b1);

        #1;

        if (bank_load_done !== 1'b1) begin
            $fatal(1, "bank_load_done missing for bank 1");
        end


        // ========================================================
        // PASS
        // ========================================================

        $display("All operand_loader tests passed.");

        $finish;

    end

endmodule
