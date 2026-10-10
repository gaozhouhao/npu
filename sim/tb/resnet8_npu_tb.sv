module resnet8_npu_tb;
    localparam int unsigned MEM_WORDS = 262144;
    logic clk;
    logic reset;
    logic start;
    logic busy, done, error;
    logic signed [31:0] acc_out [4][4];
    logic [0:0] arid,rid,awid,bid;
    logic [63:0] araddr,awaddr;
    logic [7:0] arlen,awlen;
    logic [2:0] arsize,awsize;
    logic [1:0] arburst,awburst,rresp,bresp;
    logic arvalid,arready,rlast,rvalid,rready;
    logic awvalid,awready,wlast,wvalid,wready,bvalid,bready;
    logic [31:0] rdata,wdata;
    logic [3:0] wstrb;

    logic [31:0] init_mem [0:MEM_WORDS-1];
    logic [31:0] mem [0:MEM_WORDS-1];
    logic rd_active_q,wr_active_q,bvalid_q;
    logic [63:0] rd_addr_q,wr_addr_q;
    logic [8:0] rd_left_q,wr_left_q;
    logic [0:0] rd_id_q,wr_id_q;
    logic [63:0] desc_base_cfg,logits_base_cfg;
    logic [15:0] desc_count_cfg;
    logic [31:0] reads_q,writes_q;
    string memfile;

    initial clk = 1'b0;
    always #5 clk = ~clk;
    npu_top u_dut (
        .clk(clk), .reset(reset), .start(start),
        .desc_base(desc_base_cfg), .desc_count(desc_count_cfg),
        .busy(busy), .done(done), .error(error), .acc_out(acc_out),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

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
            reads_q <= '0;
        end else begin
            if (arvalid && arready) begin
                if (arsize != 3'd2 || arburst != 2'b01 ||
                    araddr[1:0] != 2'b00 ||
                    araddr >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI AR addr=%h size=%d",araddr,arsize);
                rd_active_q <= 1'b1;
                rd_addr_q <= araddr;
                rd_left_q <= {1'b0,arlen} + 9'd1;
                rd_id_q <= arid;
            end else if (rvalid && rready) begin
                reads_q <= reads_q + 32'd1;
                if (rlast)
                    rd_active_q <= 1'b0;
                else begin
                    rd_addr_q <= rd_addr_q + 64'd4;
                    rd_left_q <= rd_left_q - 9'd1;
                end
            end
        end
    end

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
            writes_q <= '0;
            for (int i=0;i<MEM_WORDS;i++)
                mem[i] <= init_mem[i];
        end else begin
            if (awvalid && awready) begin
                if (awsize != 3'd2 || awburst != 2'b01 ||
                    awaddr[1:0] != 2'b00 ||
                    awaddr >= 64'(MEM_WORDS * 4))
                    $fatal(1, "Bad AXI AW addr=%h size=%d",awaddr,awsize);
                wr_active_q <= 1'b1;
                wr_addr_q <= awaddr;
                wr_left_q <= {1'b0,awlen} + 9'd1;
                wr_id_q <= awid;
            end
            if (wvalid && wready) begin
                if (wlast != (wr_left_q == 9'd1) ||
                    wr_addr_q >= 64'(MEM_WORDS * 4))
                    $fatal(1,"Invalid AXI W");
                for (int i=0;i<4;i++)
                    if (wstrb[i])
                        mem[int'(wr_addr_q >> 2)][8*i +: 8] <= wdata[8*i +: 8];
                writes_q <= writes_q + 32'd1;
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

    initial begin : run
        int unsigned cycles;
        int signed q, best, prediction;
        int unsigned addr, shift_amt;
        reset=1'b1;
        start=1'b0;
        desc_base_cfg='0;
        logits_base_cfg='0;
        desc_count_cfg='0;
        if (!$value$plusargs("DDR_HEX=%s",memfile))
            $fatal(1,"Provide +DDR_HEX=<ddr.hex>");
        if (!$value$plusargs("DESC_BASE=%h",desc_base_cfg))
            $fatal(1,"Provide +DESC_BASE=<hex>");
        if (!$value$plusargs("DESC_COUNT=%d",desc_count_cfg))
            $fatal(1,"Provide +DESC_COUNT=<int>");
        if (!$value$plusargs("LOGITS_BASE=%h",logits_base_cfg))
            $fatal(1,"Provide +LOGITS_BASE=<hex>");
        if (logits_base_cfg > 64'(MEM_WORDS * 4 - 10))
            $fatal(1, "Logits address outside memory: %h", logits_base_cfg);
        for (int i=0;i<MEM_WORDS;i++)
            init_mem[i]='0;
        $readmemh(memfile,init_mem);
        repeat (5) @(negedge clk);
        reset=1'b0;
        repeat (2) @(negedge clk);
        start=1'b1;
        @(negedge clk);
        start=1'b0;
        cycles=0;
        while (!done && cycles < 5000000) begin
            @(negedge clk);
            cycles++;
        end
        if (!done)
            $fatal(1,"ResNet inference TIMEOUT: cycles=%0d",cycles);
        if (error)
            $fatal(1,"ResNet inference ERROR after %0d cycles",cycles);
        best=-129;
        prediction=-1;
        for (int n=0;n<10;n++) begin
            addr=int'(logits_base_cfg)+n;
            shift_amt=8*(addr%4);
            if (shift_amt > 32'd24 ||
                (shift_amt % 32'd8) != 32'd0)
                $fatal(1, "Invalid INT8 bit offset: %0d", shift_amt);

            q = int'($signed(mem[addr/4][shift_amt +: 8]));
            $display("logit[%0d]=%0d",n,q);
            if (q>best) begin
                best=q;
                prediction=n;
            end
        end
        $display("RESNET8 NPU FINISHED: top1=%0d cycles=%0d reads=%0d writes=%0d busy=%0b acc00=%0d",prediction,cycles,reads_q,writes_q,busy,acc_out[0][0]);
        $finish;
    end
endmodule
