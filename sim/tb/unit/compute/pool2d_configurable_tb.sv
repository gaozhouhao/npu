`timescale 1ns/1ps

module pool2d_configurable_tb #(
    parameter bit RUN_RESNET = 1'b0
);
    logic clk = 1'b0;
    logic reset;
    always #5 clk = ~clk;

    logic cmd_valid, cmd_ready, cmd_global_avg;
    logic [63:0] cmd_input_base, cmd_output_base;
    logic [31:0] cmd_input_h, cmd_input_w, cmd_channels, cmd_pool_config;
    logic [31:0] cmd_pool_padding;
    logic busy, done, error;
    logic [0:0] arid, rid, awid, bid;
    logic [63:0] araddr, awaddr;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, awburst;
    logic arvalid, arready, rvalid, rready, rlast;
    logic awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic [31:0] rdata, wdata;
    logic [3:0] wstrb;
    logic [1:0] rresp, bresp;

    npu_pool_engine dut (
        .clk(clk), .reset(reset),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_global_avg(cmd_global_avg), .cmd_pool_config(cmd_pool_config),
        .cmd_pool_padding(cmd_pool_padding),
        .cmd_input_base(cmd_input_base), .cmd_output_base(cmd_output_base),
        .cmd_input_h(cmd_input_h), .cmd_input_w(cmd_input_w),
        .cmd_channels(cmd_channels),
        .busy(busy), .done(done), .error(error),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    localparam integer INPUT_BASE = 256;
    localparam integer OUTPUT_BASE = RUN_RESNET ? 1048576 : 32768;
    localparam integer OUTPUT_WORDS = OUTPUT_BASE / 4;
    localparam integer MEM_WORDS = 2 * OUTPUT_WORDS;
    logic [31:0] mem [0:MEM_WORDS-1];
    logic [63:0] active_input_bytes, active_output_bytes;
    logic read_pending, write_pending, response_pending;
    integer read_word, write_word, read_delay, response_delay;
    integer cycle_count, read_count, write_count;
    integer read_stalls, write_stalls;
    logic ar_stalled, aw_stalled, w_stalled;
    logic [63:0] held_araddr, held_awaddr;
    logic [31:0] held_wdata;

    // Delayed responses and address/data backpressure exercise the complete
    // offline path. A pending response remains valid until it is accepted.
    assign arready = !read_pending && ((cycle_count % 4) == 0);
    assign rid = '0;
    assign rresp = 2'b00;
    assign rlast = 1'b1;
    assign rvalid = read_pending && (read_delay == 0);
    assign rdata = mem[read_word];
    assign awready = !write_pending && !response_pending &&
                     ((cycle_count % 5) == 0);
    assign wready = write_pending && ((cycle_count % 7) == 0);
    assign bid = '0;
    assign bresp = 2'b00;
    assign bvalid = response_pending && (response_delay == 0);

    always @(posedge clk) begin
        if (reset) begin
            cycle_count <= 0;
            read_count <= 0;
            write_count <= 0;
            read_stalls <= 0;
            write_stalls <= 0;
            read_pending <= 1'b0;
            write_pending <= 1'b0;
            response_pending <= 1'b0;
            read_word <= 0;
            write_word <= 0;
            read_delay <= 0;
            response_delay <= 0;
            ar_stalled <= 1'b0;
            aw_stalled <= 1'b0;
            w_stalled <= 1'b0;
            held_araddr <= '0;
            held_awaddr <= '0;
            held_wdata <= '0;
        end else begin
            cycle_count <= cycle_count + 1;
            // Even an unaccepted request must remain inside the real tensor;
            // an out-of-bounds pooling sample must never issue an AXI read.
            if (arvalid && (araddr < cmd_input_base ||
                araddr-cmd_input_base+64'd4 > active_input_bytes))
                $fatal(1, "Pool issued a read outside the input tensor: %h", araddr);
            if (ar_stalled && (!arvalid || araddr !== held_araddr))
                $fatal(1, "Read address changed under backpressure");
            if (aw_stalled && (!awvalid || awaddr !== held_awaddr))
                $fatal(1, "Write address changed under backpressure");
            if (w_stalled && (!wvalid || wdata !== held_wdata))
                $fatal(1, "Write data changed under backpressure");
            ar_stalled <= arvalid && !arready;
            aw_stalled <= awvalid && !awready;
            w_stalled <= wvalid && !wready;
            held_araddr <= araddr;
            held_awaddr <= awaddr;
            held_wdata <= wdata;
            if (arvalid && !arready) read_stalls <= read_stalls + 1;
            if ((awvalid && !awready) || (wvalid && !wready))
                write_stalls <= write_stalls + 1;

            if (read_pending && read_delay != 0)
                read_delay <= read_delay - 1;
            if (response_pending && response_delay != 0)
                response_delay <= response_delay - 1;

            if (arvalid && arready) begin
                if (arid != '0 || arlen != 0 || arsize != 2 ||
                    (arburst != 0 && arburst != 1) ||
                    araddr < cmd_input_base ||
                    araddr-cmd_input_base+64'd4 > active_input_bytes ||
                    araddr[1:0] != 0)
                    $fatal(1, "Invalid pool read request: %h", araddr);
                read_word <= INPUT_BASE/4 +
                    int'((araddr-cmd_input_base) >> 2);
                read_pending <= 1'b1;
                read_delay <= 2 + (read_count % 4);
                read_count <= read_count + 1;
            end
            if (rvalid && rready) read_pending <= 1'b0;

            if (awvalid && awready) begin
                if (awid != '0 || awlen != 0 || awsize != 2 ||
                    (awburst != 0 && awburst != 1) ||
                    awaddr < cmd_output_base ||
                    awaddr-cmd_output_base+64'd4 > active_output_bytes ||
                    awaddr[1:0] != 0)
                    $fatal(1, "Invalid pool write request: %h", awaddr);
                write_word <= OUTPUT_BASE/4 +
                    int'((awaddr-cmd_output_base) >> 2);
                write_pending <= 1'b1;
            end
            if (wvalid && wready) begin
                if (!wlast || wstrb != 4'hf)
                    $fatal(1, "Invalid pool write data");
                mem[write_word] <= wdata;
                write_count <= write_count + 1;
                write_pending <= 1'b0;
                response_pending <= 1'b1;
                response_delay <= 2 + (write_count % 3);
            end
            if (bvalid && bready) response_pending <= 1'b0;
        end
    end

    function automatic logic [31:0] config_word(
        input integer kh, kw, sh, sw
    );
        return {8'(sw), 8'(sh), 8'(kw), 8'(kh)};
    endfunction

    function automatic logic [31:0] padding_word(
        input integer pt, pl, pb, pr
    );
        return {8'(pr), 8'(pb), 8'(pl), 8'(pt)};
    endfunction

    function automatic integer input_value(
        input integer y, x, c,
        input logic negative_only
    );
        if (negative_only)
            return -1 - ((y*23 + x*9 + c*5) % 128);
        return ((y*71 + x*29 + c*43) % 256) - 128;
    endfunction

    task automatic issue_command(
        input logic global_avg,
        input integer h, w, channels,
        input logic [31:0] config,
        input logic expect_error,
        input logic [63:0] input_base = INPUT_BASE,
        input logic [63:0] output_base = OUTPUT_BASE,
        input logic [31:0] padding = 32'd0
    );
        wait (cmd_ready);
        @(negedge clk);
        cmd_global_avg = global_avg;
        cmd_input_h = h;
        cmd_input_w = w;
        cmd_channels = channels;
        cmd_pool_config = config;
        cmd_pool_padding = padding;
        cmd_input_base = input_base;
        cmd_output_base = output_base;
        cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;
        // The accepted configuration must be latched, not read live.
        cmd_pool_config = 32'hffffffff;
        cmd_pool_padding = 32'hffffffff;
        wait (done);
        if (error !== expect_error)
            $fatal(1, "Pool error=%b expected=%b config=%h",
                   error, expect_error, config);
        @(negedge clk);
    endtask

    task automatic check_case(
        input string name,
        input integer h, w, channels, kh, kw, sh, sw,
        input logic legacy = 1'b0,
        input logic negative_only = 1'b0,
        input logic [63:0] input_base = INPUT_BASE,
        input logic [63:0] output_base = OUTPUT_BASE,
        input integer pt = 0, pl = 0, pb = 0, pr = 0
    );
        integer oh_count, ow_count, expected, actual, value;
        integer old_reads, old_writes, byte_index, iy, ix, expected_reads;
        logic [31:0] config;
        oh_count = (h+pt+pb-kh)/sh + 1;
        ow_count = (w+pl+pr-kw)/sw + 1;
        active_input_bytes = 64'(h)*64'(w)*64'(channels);
        active_output_bytes = 64'(oh_count)*64'(ow_count)*64'(channels);
        config = legacy ? 32'd0 : config_word(kh, kw, sh, sw);
        if (active_input_bytes > OUTPUT_BASE-INPUT_BASE ||
            active_output_bytes+4 > OUTPUT_WORDS*4)
            $fatal(1, "Test memory is too small for %s", name);
        for (int i = 0; i <= oh_count*ow_count*(channels/4); i++)
            mem[OUTPUT_BASE/4 + i] = 32'h55555555;
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                for (int c = 0; c < channels; c++) begin
                    byte_index = INPUT_BASE + (y*w+x)*channels+c;
                    mem[byte_index/4][(byte_index%4)*8 +: 8] =
                        8'(input_value(y, x, c, negative_only));
                end
            end
        end
        old_reads = read_count;
        old_writes = write_count;
        issue_command(1'b0, h, w, channels, config, 1'b0,
                      input_base, output_base, padding_word(pt, pl, pb, pr));
        expected_reads = 0;
        for (int oy = 0; oy < oh_count; oy++) begin
            for (int ox = 0; ox < ow_count; ox++) begin
                for (int c = 0; c < channels; c++) begin
                    expected = -128;
                    for (int ky = 0; ky < kh; ky++) begin
                        for (int kx = 0; kx < kw; kx++) begin
                            iy = oy*sh+ky-pt;
                            ix = ox*sw+kx-pl;
                            if (iy >= 0 && iy < h && ix >= 0 && ix < w) begin
                                value = input_value(iy, ix, c, negative_only);
                                if (value > expected) expected = value;
                                if (c % 4 == 0) expected_reads++;
                            end
                        end
                    end
                    byte_index = OUTPUT_BASE + (oy*ow_count+ox)*channels+c;
                    actual = int'($signed(mem[byte_index/4]
                                            [(byte_index%4)*8 +: 8]));
                    if (actual != expected)
                        $fatal(1, "%s mismatch at (%0d,%0d,%0d): %0d != %0d",
                               name, oy, ox, c, actual, expected);
                end
            end
        end
        if (read_count-old_reads != expected_reads ||
            write_count-old_writes != oh_count*ow_count*(channels/4))
            $fatal(1, "%s transaction count reads=%0d expected=%0d writes=%0d expected=%0d",
                   name, read_count-old_reads, expected_reads, write_count-old_writes,
                   oh_count*ow_count*(channels/4));
        if (mem[OUTPUT_BASE/4 + oh_count*ow_count*(channels/4)] !== 32'h55555555)
            $fatal(1, "%s wrote beyond output shape", name);
        $display("CONFIGURABLE MAXPOOL %s PASS (%0dx%0d -> %0dx%0d)",
                 name, h, w, oh_count, ow_count);
    endtask

    task automatic reject_case(
        input string name,
        input integer h, w, channels,
        input logic [31:0] config,
        input logic global_avg = 1'b0,
        input logic [63:0] input_base = INPUT_BASE,
        input logic [63:0] output_base = OUTPUT_BASE,
        input logic [31:0] padding = 32'd0
    );
        integer old_reads, old_writes;
        old_reads = read_count;
        old_writes = write_count;
        issue_command(global_avg, h, w, channels, config, 1'b1,
                      input_base, output_base, padding);
        if (old_reads != read_count || old_writes != write_count)
            $fatal(1, "%s touched memory before rejection", name);
        $display("CONFIGURABLE MAXPOOL reject %s PASS", name);
    endtask

    initial begin
        #500000000;
        $fatal(1, "Configurable MaxPool TIMEOUT");
    end

    initial begin
        reset = 1'b1;
        cmd_valid = 1'b0;
        cmd_global_avg = 1'b0;
        cmd_input_base = '0;
        cmd_output_base = '0;
        cmd_input_h = '0;
        cmd_input_w = '0;
        cmd_channels = '0;
        cmd_pool_config = '0;
        cmd_pool_padding = '0;
        active_input_bytes = '0;
        active_output_bytes = '0;
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;
        repeat (4) @(negedge clk);
        reset = 1'b0;

        check_case("legacy odd shape", 5, 7, 8, 2, 2, 2, 2, 1'b1);
        check_case("overlap stride1 negative", 4, 5, 8, 2, 2, 1, 1, 1'b0, 1'b1);
        check_case("kernel3 stride2", 7, 9, 4, 3, 3, 2, 2);
        check_case("gaps stride3", 8, 11, 8, 2, 2, 3, 3);
        check_case("rectangular mixed strides", 6, 9, 8, 2, 3, 1, 2);
        check_case("stride5", 13, 14, 4, 3, 2, 5, 5);
        check_case("kernel1", 5, 7, 8, 1, 1, 2, 3, 1'b0, 1'b1);
        check_case("stride255", 4, 5, 4, 2, 3, 255, 255);
        check_case("kernel255", 255, 1, 4, 255, 1, 1, 1);
        check_case("ResNet-style right/bottom padding negative", 8, 8, 8,
                    3, 3, 2, 2, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 0, 0, 1, 1);
        check_case("top/left first sample invalid negative", 4, 5, 8,
                    3, 3, 1, 2, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 1, 1, 0, 0);
        check_case("four sides negative", 3, 4, 8,
                    3, 3, 1, 1, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 1, 1, 1, 1);
        check_case("input smaller than padded kernel", 1, 1, 4,
                    3, 3, 1, 1, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 1, 1, 1, 1);
        check_case("unequal padding kernel and strides", 4, 6, 8,
                    3, 4, 2, 3, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 2, 1, 0, 3);
        check_case("extreme padding bytes", 1, 1, 4,
                    255, 255, 255, 255, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE,
                    254, 254, 0, 0);
        if (RUN_RESNET)
            check_case("ResNet50 real first pool", 112, 112, 64,
                        3, 3, 2, 2, 1'b0, 1'b1, INPUT_BASE, OUTPUT_BASE, 0, 0, 1, 1);
        check_case("input at highest valid address", 1, 2, 4, 1, 1, 1, 1,
                    1'b0, 1'b0, 64'hffff_ffff_ffff_fff8);
        check_case("output at highest valid address", 1, 2, 4, 1, 1, 1, 1,
                    1'b0, 1'b0, INPUT_BASE, 64'hffff_ffff_ffff_fff8);
        check_case("addresses above 32 bits", 1, 2, 4, 1, 1, 1, 1,
                    1'b0, 1'b0, 64'h1_0000_0000, 64'h2_0000_0000);

        reject_case("zero KH", 4, 5, 4, config_word(0, 2, 2, 2));
        reject_case("zero KW", 4, 5, 4, config_word(2, 0, 2, 2));
        reject_case("zero SH", 4, 5, 4, config_word(2, 2, 0, 2));
        reject_case("zero SW", 4, 5, 4, config_word(2, 2, 2, 0));
        reject_case("KH larger than input", 4, 5, 4, config_word(5, 2, 2, 2));
        reject_case("KW larger than input", 4, 5, 4, config_word(2, 6, 2, 2));
        reject_case("legacy too small", 1, 5, 4, 32'd0);
        reject_case("zero height", 0, 5, 4, 32'd0);
        reject_case("unaligned channels", 4, 5, 6, 32'd0);
        reject_case("unaligned input", 4, 5, 4, 32'd0, 1'b0, INPUT_BASE+1);
        reject_case("unaligned output", 4, 5, 4, 32'd0, 1'b0,
                    INPUT_BASE, OUTPUT_BASE+1);
        reject_case("global average config", 4, 5, 4,
                    config_word(2, 2, 2, 2), 1'b1);
        reject_case("top padding reaches kernel", 4, 5, 4,
                    config_word(3, 3, 2, 2), 1'b0, INPUT_BASE, OUTPUT_BASE,
                    padding_word(3, 0, 0, 0));
        reject_case("left padding reaches kernel", 4, 5, 4,
                    config_word(3, 3, 2, 2), 1'b0, INPUT_BASE, OUTPUT_BASE,
                    padding_word(0, 3, 0, 0));
        reject_case("bottom padding reaches kernel", 4, 5, 4,
                    config_word(3, 3, 2, 2), 1'b0, INPUT_BASE, OUTPUT_BASE,
                    padding_word(0, 0, 3, 0));
        reject_case("right padding reaches kernel", 4, 5, 4,
                    config_word(3, 3, 2, 2), 1'b0, INPUT_BASE, OUTPUT_BASE,
                    padding_word(0, 0, 0, 3));
        reject_case("global average padding", 4, 5, 4, 32'd0, 1'b1,
                    INPUT_BASE, OUTPUT_BASE, padding_word(0, 0, 1, 1));
        reject_case("padded output dimension overflow", 32'hffff_ffff, 1, 4,
                    config_word(3, 1, 1, 1), 1'b0, INPUT_BASE, OUTPUT_BASE,
                    padding_word(2, 0, 2, 0));
        reject_case("input end address overflow", 1, 2, 4,
                    config_word(1, 1, 1, 1), 1'b0,
                    64'hffff_ffff_ffff_fffc);
        reject_case("output end address overflow", 1, 2, 4,
                    config_word(1, 1, 1, 1), 1'b0,
                    INPUT_BASE, 64'hffff_ffff_ffff_fffc);
        reject_case("96-bit tensor span overflow", 32'hffff_ffff,
                    32'hffff_ffff, 32'hffff_fffc, config_word(1, 1, 1, 1));
        reject_case("global average input end overflow", 1, 2, 4,
                    32'd0, 1'b1, 64'hffff_ffff_ffff_fffc);
        reject_case("global average output end overflow", 1, 1, 8,
                    32'd0, 1'b1, INPUT_BASE, 64'hffff_ffff_ffff_fffc);
        check_case("recovery after rejection", 5, 6, 4, 3, 2, 2, 1);

        if (read_stalls == 0 || write_stalls == 0)
            $fatal(1, "Backpressure was not exercised");
        $display("POOL2D CONFIGURABLE REGRESSION PASS read_stalls=%0d write_stalls=%0d",
                 read_stalls, write_stalls);
        $finish;
    end
endmodule
