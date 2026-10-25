`timescale 1ns/1ps

// Descriptor-to-DDR check of independent MaxPool padding. This intentionally
// runs through the command reader, admission checks and AXI width adapter.
module maxpool_padding_npu_tb;
    localparam int INPUT_BASE = 'h1000;
    localparam int OUTPUT_BASE = 'h3000;
    localparam int DESC_BASE = 'h6000;
    localparam int MEM_WORDS = 8192;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1, start = 0, busy, done, error;
    logic signed [31:0] acc_out [4][4];
    logic m_axi_arid, m_axi_rid, m_axi_awid, m_axi_bid;
    logic [63:0] m_axi_araddr, m_axi_awaddr, m_axi_rdata;
    logic [7:0] m_axi_arlen, m_axi_awlen;
    logic [2:0] m_axi_arsize, m_axi_awsize;
    logic [1:0] m_axi_arburst, m_axi_awburst, m_axi_rresp, m_axi_bresp;
    logic m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic m_axi_bvalid, m_axi_bready;
    logic [31:0] m_axi_wdata;
    logic [3:0] m_axi_wstrb;

    npu_top #(.K_TILE_SIZE(16)) dut (
        .desc_base(64'(DESC_BASE)), .desc_count(16'd1), .*
    );
    axi_memory_model #(.WORDS(MEM_WORDS)) ram (.*);

    integer input_h, input_w, channels, output_h, output_w;
    integer logical_reads, expected_reads;
    bit reject_command;

    // Check the real AXI32 sample addresses before the 64-bit adapter. The
    // adapter may fetch a full aligned beat, but no invalid sample may be issued.
    always @(posedge clk) begin
        if (reset) begin
            logical_reads <= 0;
        end else begin
            if (dut.u_pool.u_rd.req_valid) begin
                if (reject_command ||
                    dut.u_pool.u_rd.req_addr < INPUT_BASE ||
                    dut.u_pool.u_rd.req_addr+4 > INPUT_BASE+input_h*input_w*channels)
                    $fatal(1, "Invalid logical pooling read address");
                if (dut.u_pool.u_rd.req_ready)
                    logical_reads <= logical_reads + 1;
            end
            if (m_axi_awvalid && (reject_command ||
                m_axi_awaddr < OUTPUT_BASE ||
                m_axi_awaddr+4 > OUTPUT_BASE+output_h*output_w*channels))
                $fatal(1, "Invalid pooling output address");
        end
    end

    function automatic integer input_value(input integer y, x, c);
        return -1-((y*23+x*9+c*5)%128);
    endfunction

    task automatic run_case(
        input string name,
        input integer h, w, c, kh, kw, sh, sw, pt, pl, pb, pr,
        input bit expect_error = 0,
        input logic [31:0] reserved_word11 = 0,
        input logic [7:0] opcode = 3
    );
        integer index, expected, actual, iy, ix, d;
        @(negedge clk);
        reset = 1;
        start = 0;
        input_h = h;
        input_w = w;
        channels = c;
        output_h = (h+pt+pb-kh)/sh+1;
        output_w = (w+pl+pr-kw)/sw+1;
        reject_command = expect_error;
        expected_reads = 0;
        for (int i = 0; i < MEM_WORDS; i++) ram.mem[i] = 32'h55555555;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                for (int ch = 0; ch < c; ch++) begin
                    index = INPUT_BASE+(y*w+x)*c+ch;
                    ram.mem[index/4][8*(index%4) +: 8] = 8'(input_value(y,x,ch));
                end
        d = DESC_BASE/4;
        for (int i = 0; i < 16; i++) ram.mem[d+i] = 0;
        ram.mem[d+0] = {24'd0,opcode};
        ram.mem[d+1] = h;
        ram.mem[d+2] = w;
        ram.mem[d+3] = c;
        ram.mem[d+4] = INPUT_BASE;
        ram.mem[d+8] = OUTPUT_BASE;
        ram.mem[d+10] = {8'(pr),8'(pb),8'(pl),8'(pt)};
        ram.mem[d+11] = reserved_word11;
        ram.mem[d+15] = opcode == 4 ? 0 : {8'(sw),8'(sh),8'(kw),8'(kh)};
        repeat (4) @(negedge clk);
        reset = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        wait (done);
        if (error !== expect_error)
            $fatal(1, "%s error=%b expected=%b", name, error, expect_error);
        @(negedge clk);
        if (expect_error) begin
            if (logical_reads != 0 || ram.write_beats != 0)
                $fatal(1, "%s rejected command touched tensors", name);
        end else begin
            for (int oy = 0; oy < output_h; oy++)
                for (int ox = 0; ox < output_w; ox++)
                    for (int ch = 0; ch < c; ch++) begin
                        expected = -128;
                        for (int ky = 0; ky < kh; ky++)
                            for (int kx = 0; kx < kw; kx++) begin
                                iy = oy*sh+ky-pt;
                                ix = ox*sw+kx-pl;
                                if (iy >= 0 && iy < h && ix >= 0 && ix < w) begin
                                    actual = input_value(iy,ix,ch);
                                    if (actual > expected) expected = actual;
                                    if (ch%4 == 0) expected_reads++;
                                end
                            end
                        index = OUTPUT_BASE+(oy*output_w+ox)*c+ch;
                        actual = int'($signed(ram.mem[index/4][8*(index%4) +: 8]));
                        if (actual != expected)
                            $fatal(1, "%s at (%0d,%0d,%0d): %0d != %0d",
                                   name,oy,ox,ch,actual,expected);
                    end
            if (logical_reads != expected_reads ||
                ram.write_beats != output_h*output_w*(c/4))
                $fatal(1, "%s wrong transaction count reads=%0d/%0d writes=%0d/%0d",
                       name,logical_reads,expected_reads,ram.write_beats,
                       output_h*output_w*(c/4));
        end
        if (ram.mem[OUTPUT_BASE/4+output_h*output_w*(c/4)] !== 32'h55555555)
            $fatal(1, "%s wrote beyond output tensor", name);
        $display("MAXPOOL PADDING SYSTEM %s PASS",name);
    endtask

    initial begin
        #10000000;
        $fatal(1,"MaxPool padding system TIMEOUT");
    end

    initial begin
        run_case("ResNet-style bottom/right",8,8,8,3,3,2,2,0,0,1,1);
        run_case("top/left with negative first valid sample",4,5,8,3,3,1,2,1,1,0,0);
        run_case("all sides and small input",1,1,4,3,3,1,1,1,1,1,1);
        run_case("legacy zero padding",4,6,4,2,2,2,2,0,0,0,0);
        run_case("reject padding equal to kernel",4,6,4,3,3,2,2,3,0,0,0,1);
        run_case("reject reserved word11",4,6,4,3,3,2,2,0,0,1,1,1,32'd1);
        run_case("reject global average padding",4,6,4,3,3,2,2,0,0,1,1,1,0,4);
        run_case("recovery after rejection",3,4,4,3,3,1,2,1,1,1,1);
        $display("MAXPOOL PADDING DESCRIPTOR SYSTEM REGRESSION PASS");
        $finish;
    end
endmodule
