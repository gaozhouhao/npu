`timescale 1ns/1ps

// Execute compiler-generated FC descriptors and packed tensors. This testbench
// does not recreate alignment rules: it reads the image and independent golden.
module fc_alignment_npu_tb;
    localparam int MEM_WORDS = 1048576;
    localparam int GOLD_WORDS = 16384;
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
    logic [63:0] descriptor_base;
    npu_top dut (.desc_base(descriptor_base), .desc_count(16'd1), .*);
    axi_memory_model #(.WORDS(MEM_WORDS)) ram (.*);
    logic [31:0] golden [0:GOLD_WORDS-1];
    integer image_words, desc_addr, output_base, output_bytes;
    integer cfg, scanned, dump_file, cycles;
    string case_dir;

    always @(posedge clk) begin
        if (reset) cycles <= 0;
        else begin
            cycles <= cycles+1;
            if (m_axi_arvalid && m_axi_arready &&
                m_axi_araddr+(64'(m_axi_arlen)+1)*8 > 64'(image_words)*4)
                $fatal(1, "FC read beyond generated image");
            if (m_axi_awvalid &&
                (m_axi_awaddr < output_base ||
                 m_axi_awaddr+(64'(m_axi_awlen)+1)*4 > output_base+output_bytes))
                $fatal(1, "FC write escapes allocated physical output");
        end
    end

    initial begin
        #1000000000;
        $fatal(1, "FC alignment TIMEOUT");
    end

    initial begin
        if (!$value$plusargs("CASE_DIR=%s", case_dir))
            $fatal(1, "Supply +CASE_DIR=path to generated FC fixture");
        cfg = $fopen({case_dir,"/case.cfg"}, "r");
        if (!cfg) $fatal(1, "Cannot open FC fixture config");
        scanned = $fscanf(cfg, "%d %d %d %d", image_words, desc_addr,
                           output_base, output_bytes);
        $fclose(cfg);
        if (scanned != 4 || image_words <= 0 || image_words > MEM_WORDS ||
            output_bytes <= 0 || output_bytes%4 || output_bytes/4 > GOLD_WORDS)
            $fatal(1, "Invalid FC fixture config");
        descriptor_base = 64'(desc_addr);
        for (int i=0; i<MEM_WORDS; i++) ram.mem[i] = 32'hdeadbeef;
        $readmemh({case_dir,"/ddr.hex"}, ram.mem, 0, image_words-1);
        $readmemh({case_dir,"/expected.hex"}, golden, 0, output_bytes/4-1);
        repeat (4) @(negedge clk);
        reset = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done);
        if (error) $fatal(1, "NPU rejected generated FC descriptor");
        @(negedge clk);
        for (int i=0; i<output_bytes/4; i++)
            if (ram.mem[output_base/4+i] !== golden[i])
                $fatal(1, "FC physical output word %0d: %h != %h", i,
                       ram.mem[output_base/4+i], golden[i]);
        if (ram.mem[output_base/4+output_bytes/4] !== 32'h5a5a5a5a)
            $fatal(1, "FC overwrote trailing guard");
        dump_file = $fopen({case_dir,"/c_dump.bin"}, "wb");
        if (!dump_file) $fatal(1, "Cannot write FC output dump");
        for (int i=0; i<output_bytes; i++)
            $fwrite(dump_file, "%c", ram.mem[(output_base+i)/4][8*((output_base+i)%4) +: 8]);
        $fclose(dump_file);
        $display("FC ALIGNMENT PHYSICAL OUTPUT PASS cycles=%0d words=%0d AR=%0d AW=%0d",
                 cycles, output_bytes/4, ram.read_requests, ram.write_requests);
        $finish;
    end
endmodule
