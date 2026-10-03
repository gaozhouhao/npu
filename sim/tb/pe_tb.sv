module pe_tb;

    // 1. 给 DUT 的输入
    logic clk;
    logic reset;

    logic signed [7:0] a_in;
    logic signed [7:0] b_in;
    logic a_valid_in;
    logic b_valid_in;
    logic clear;

    // 2. DUT 返回的输出
    logic signed [7:0]  a_out;
    logic signed [7:0]  b_out;
    logic               a_valid_out;
    logic               b_valid_out;
    logic signed [31:0] acc_out;

    // 3. 实例化 PE
    pe dut (
        .clk       (clk),
        .reset     (reset),

        .a_in      (a_in),
        .b_in      (b_in),
        .a_valid_in  (a_valid_in),
        .b_valid_in  (b_valid_in),

        .clear     (clear),

        .a_out     (a_out),
        .b_out     (b_out),
        .a_valid_out (a_valid_out),
        .b_valid_out (b_valid_out),

        .acc_out   (acc_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        // 初始输入
        reset    = 1'b1;
        clear    = 1'b0;
        a_valid_in = 1'b0;
        b_valid_in = 1'b0;
        a_in     = 8'sd0;
        b_in     = 8'sd0;

        // 等待一个上升沿，让 DUT 执行 reset
        @(posedge clk);

        // 稍微等一下，再检查寄存器更新后的结果
        #1;

        if (acc_out !== 32'sd0) begin
            $display("RESET TEST FAIL: acc_out = %0d", acc_out);
            $finish;
        end

        if (a_valid_out !== 1'b0) begin
            $display("RESET TEST FAIL: a_valid_out = %b", a_valid_out);
            $finish;
        end

        if (b_valid_out !== 1'b0) begin
            $display("RESET TEST FAIL: b_valid_out = %b", b_valid_out);
            $finish;
        end

        if (a_out !== 8'sd0) begin
            $display("RESET TEST FAIL: a_out = %0d", a_out);
            $finish;
        end

        if (b_out !== 8'sd0) begin
            $display("RESET TEST FAIL: b_out = %0d", b_out);
            $finish;
        end

        $display("RESET TEST PASS");

        // 解除 reset
        @(negedge clk);
        reset = 1'b0;

        // Single MAC Test: 3 * (-4) = -12
        @(negedge clk);
        a_in     = 8'sd3;
        b_in     = -8'sd4;
        a_valid_in = 1'b1;
        b_valid_in = 1'b1;

        @(posedge clk);
        #1;

        if (acc_out !== -32'sd12) begin
            $display("MAC TEST FAIL: acc_out = %0d, expected = -12", acc_out);
            $finish;
        end

        $display("MAC TEST PASS");


        #20;
        $finish;
    end



endmodule

