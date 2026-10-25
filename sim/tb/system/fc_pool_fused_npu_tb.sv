`timescale 1ns/1ps

// Compare a physical, ROWS-padded FC followed by a standalone HWC pool with
// one fused FC descriptor. Only physical GEMM row zero is a logical image.
module fc_pool_fused_npu_tb #(
    parameter int RESHAPE_H = 2,
    parameter int RESHAPE_W = 2,
    parameter int RESHAPE_C = 4,
    parameter int K = 72,
    parameter int K_TILE_SIZE = 32,
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int POOL_KH = 2,
    parameter int POOL_KW = 2,
    parameter int POOL_SH = 2,
    parameter int POOL_SW = 2,
    parameter int LINE_WORDS = POOL_KH*RESHAPE_W*(RESHAPE_C/4),
    parameter bit REPEAT_INPUT_ROW = 1,
    parameter int WRITE_RESPONSE_DELAY = 5,
    parameter bit EXPECT_POOL_BACKPRESSURE = 0
);
    localparam int H = RESHAPE_H, W = RESHAPE_W, C = RESHAPE_C;
    localparam int N = H*W*C;
    localparam int PADDED_K = ((K+7)/8)*8;
    localparam int A_STRIDE = REPEAT_INPUT_ROW ? 0 : PADDED_K;
    localparam int PH = (H-POOL_KH)/POOL_SH+1;
    localparam int PW = (W-POOL_KW)/POOL_SW+1;
    localparam int FC_BYTES = ROWS*N, POOL_BYTES = PH*PW*C;
    localparam int POOL_READ_BYTES = PH*PW*POOL_KH*POOL_KW*C;
    localparam int POOL_SAMPLES = H*W*(C/COLS);
    localparam int COVERED_H = POOL_SH >= POOL_KH ? PH*POOL_KH :
        (PH-1)*POOL_SH+POOL_KH;
    localparam int COVERED_W = POOL_SW >= POOL_KW ? PW*POOL_KW :
        (PW-1)*POOL_SW+POOL_KW;
    localparam int UNUSED_POOL_SAMPLES =
        (H*W-COVERED_H*COVERED_W)*(C/COLS);
    localparam int FULL_WORDS = POOL_KH*W*(C/4);
    localparam logic [31:0] POOL_CONFIG =
        (POOL_KH==2 && POOL_KW==2 && POOL_SH==2 && POOL_SW==2) ? 0 :
        (POOL_SW<<24)|(POOL_SH<<16)|(POOL_KW<<8)|POOL_KH;
    localparam int MEM_WORDS = 131072;
    localparam int INPUT_BASE='h1000, WEIGHT_BASE='h8000, FC_BASE='h30000;
    localparam int POOL_BASE='h50000, PARAM_BASE='h60000, DESC_BASE='h70000;

    logic clk=0, reset=1, start=0;
    always #5 clk=~clk;
    logic [15:0] desc_count=0;
    logic busy, done, error;
    logic signed [31:0] acc_out [ROWS][COLS];
    logic [0:0] arid,rid,awid,bid;
    logic [63:0] araddr,rdata,awaddr;
    logic [7:0] arlen,awlen;
    logic [2:0] arsize,awsize;
    logic [1:0] arburst,rresp,awburst,bresp;
    logic arvalid,arready,rlast,rvalid,rready;
    logic awvalid,awready,wlast,wvalid,wready,bvalid,bready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic [31:0] mem [0:MEM_WORDS-1];
    logic [7:0] saved_pool [0:POOL_BYTES-1];
    int seed=0, phase=0; // 0: baseline, 1: fused FC, 2: rejected, 3: fused Conv
    bit per_channel=0, relu_enable=0;
    int cycle_q,read_beats_q,write_bytes_q,fc_read_bursts_q,fc_write_bytes_q;
    int logical_pool_read_bytes_q,pool_input_samples_q;
    int pool_stall_cycles_q,unused_pool_samples_q;
    logic pool_stalled_q;
    logic [COLS*8-1:0] stalled_pool_data_q;
    logic [31:0] stalled_pool_spatial_q,stalled_pool_channel_q;

    npu_top #(.ROWS(ROWS),.COLS(COLS),.K_TILE_SIZE(K_TILE_SIZE),
        .POOL_LINE_WORDS(LINE_WORDS)) u_dut (
        .clk(clk),.reset(reset),.start(start),.desc_base(64'(DESC_BASE)),
        .desc_count(desc_count),.busy(busy),.done(done),.error(error),.acc_out(acc_out),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),
        .m_axi_arsize(arsize),.m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(rid),.m_axi_rdata(rdata),.m_axi_rresp(rresp),
        .m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),
        .m_axi_awsize(awsize),.m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(bid),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready)
    );

    logic rd_active_q=0,rvalid_q=0,rlast_q=0;
    logic [63:0] rd_addr_q=0,rdata_q=0;
    logic [8:0] rd_left_q=0;
    logic [0:0] rd_id_q=0;
    int read_wait_q=0;
    logic wr_active_q=0,b_pending_q=0,bvalid_q=0;
    logic [63:0] wr_addr_q=0;
    logic [8:0] wr_left_q=0;
    logic [0:0] wr_id_q=0;
    int b_wait_q=0;
    assign arready=!rd_active_q && !rvalid_q && cycle_q%5!=1;
    assign rid=rd_id_q, rvalid=rvalid_q, rdata=rdata_q, rlast=rlast_q, rresp=0;
    assign awready=!wr_active_q && !b_pending_q && !bvalid_q && cycle_q%5<3;
    assign wready=wr_active_q && cycle_q%7>=3;
    assign bid=wr_id_q, bvalid=bvalid_q, bresp=0;

    always @(posedge clk) begin : memory_model
        int sample_index;
        if (reset) begin
            cycle_q<=0; rd_active_q<=0; rvalid_q<=0; rd_addr_q<=0; rd_left_q<=0;
            rd_id_q<=0; rdata_q<=0; rlast_q<=0; read_wait_q<=0;
            wr_active_q<=0; wr_addr_q<=0; wr_left_q<=0; wr_id_q<=0;
            b_pending_q<=0; bvalid_q<=0; b_wait_q<=0;
            read_beats_q<=0; write_bytes_q<=0; fc_read_bursts_q<=0;
            fc_write_bytes_q<=0; logical_pool_read_bytes_q<=0; pool_input_samples_q<=0;
            pool_stall_cycles_q<=0; unused_pool_samples_q<=0; pool_stalled_q<=0;
            stalled_pool_data_q<=0; stalled_pool_spatial_q<=0; stalled_pool_channel_q<=0;
        end else begin
            cycle_q<=cycle_q+1;
            if (phase==2 && (u_dut.u_npu_gemm_engine.scheduler_start ||
                            u_dut.u_npu_gemm_engine.operand64_arvalid))
                $fatal(1,"Invalid FC metadata reached scheduling or operand DMA");
            if (u_dut.u_pool.u_rd.req_valid && u_dut.u_pool.u_rd.req_ready)
                logical_pool_read_bytes_q<=logical_pool_read_bytes_q+4*u_dut.u_pool.u_rd.req_beats;
            if (pool_stalled_q &&
                (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid !== 1'b1 ||
                 u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_data !== stalled_pool_data_q ||
                 u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_spatial_index !== stalled_pool_spatial_q ||
                 u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_channel_base !== stalled_pool_channel_q))
                $fatal(1,"FC pool input data or coordinates changed under backpressure");
            pool_stalled_q <= phase==1 &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                !u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready;
            if (phase==1 && u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                !u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready) begin
                stalled_pool_data_q<=u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_data;
                stalled_pool_spatial_q<=u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_spatial_index;
                stalled_pool_channel_q<=u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_channel_base;
                pool_stall_cycles_q<=pool_stall_cycles_q+1;
            end
            // The same interface is checked independently of DDR output.
            if (phase==1 && u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready) begin
                sample_index=pool_input_samples_q%POOL_SAMPLES;
                if (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_spatial_index !==
                        32'(sample_index/(C/COLS)) ||
                    u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_channel_base !==
                        32'((sample_index%(C/COLS))*COLS))
                    $fatal(1,"FC reshape coordinates incorrect sample=%0d",sample_index);
                for (int lane=0;lane<COLS;lane++)
                    if (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_data[8*lane+:8] !==
                            8'(fc_golden(0,sample_index*COLS+lane)))
                        $fatal(1,"FC pool input mismatch sample=%0d lane=%0d",sample_index,lane);
                if (!pixel_in_pool_window(sample_index/(C/COLS)))
                    unused_pool_samples_q<=unused_pool_samples_q+1;
                pool_input_samples_q<=pool_input_samples_q+1;
            end
            if (arvalid && arready) begin
                if (arsize!==3'd3 || arburst!==2'b01 || araddr[2:0]!==0 ||
                    araddr+(64'(arlen)+1)*8>MEM_WORDS*4 ||
                    araddr[11:0]+(64'(arlen)+1)*8>4096)
                    $fatal(1,"Invalid read burst addr=%h len=%0d",araddr,arlen);
                if (araddr>=FC_BASE && araddr<FC_BASE+FC_BYTES) begin
                    if (phase!=0) $fatal(1,"Fused FC read intermediate output");
                    fc_read_bursts_q<=fc_read_bursts_q+1;
                end
                rd_active_q<=1; rd_addr_q<=araddr; rd_left_q<={1'b0,arlen}+1'b1;
                rd_id_q<=arid; read_wait_q<=4+cycle_q%3;
            end
            if (read_wait_q>0) read_wait_q<=read_wait_q-1;
            if (rd_active_q && !rvalid_q && read_wait_q==0) begin
                rvalid_q<=1; rdata_q<={mem[(rd_addr_q>>2)+1],mem[rd_addr_q>>2]};
                rlast_q<=rd_left_q==1;
            end
            if (rvalid && rready) begin
                read_beats_q<=read_beats_q+1; rvalid_q<=0;
                if (rd_left_q==1) rd_active_q<=0;
                else begin rd_addr_q<=rd_addr_q+8; rd_left_q<=rd_left_q-1; read_wait_q<=2; end
            end
            if (awvalid && awready) begin
                if (phase==2) $fatal(1,"Rejected FC descriptor issued a write");
                if (awsize!==3'd2 || awburst!==2'b01 || awaddr[1:0]!==0 ||
                    awaddr+(64'(awlen)+1)*4>MEM_WORDS*4 ||
                    awaddr[11:0]+(64'(awlen)+1)*4>4096)
                    $fatal(1,"Invalid write burst addr=%h len=%0d",awaddr,awlen);
                if (!((phase==0 && awaddr>=FC_BASE &&
                       awaddr+(64'(awlen)+1)*4<=FC_BASE+FC_BYTES) ||
                      (awaddr>=POOL_BASE && awaddr+(64'(awlen)+1)*4<=POOL_BASE+POOL_BYTES)))
                    $fatal(1,"Unexpected output range addr=%h phase=%0d",awaddr,phase);
                wr_active_q<=1; wr_addr_q<=awaddr; wr_left_q<={1'b0,awlen}+1'b1; wr_id_q<=awid;
            end
            if (wvalid && wready) begin
                if (wlast!==(wr_left_q==1) || wstrb!==4'hf) $fatal(1,"Invalid WLAST/WSTRB");
                mem[wr_addr_q>>2]<=wdata; write_bytes_q<=write_bytes_q+4;
                if (wr_addr_q>=FC_BASE && wr_addr_q<FC_BASE+FC_BYTES)
                    fc_write_bytes_q<=fc_write_bytes_q+4;
                if (wr_left_q==1) begin
                    wr_active_q<=0; b_pending_q<=1; b_wait_q<=WRITE_RESPONSE_DELAY;
                end else begin wr_left_q<=wr_left_q-1; wr_addr_q<=wr_addr_q+4; end
            end
            if (b_wait_q>0) b_wait_q<=b_wait_q-1;
            if (b_pending_q && b_wait_q==0) begin b_pending_q<=0; bvalid_q<=1; end
            if (bvalid && bready) bvalid_q<=0;
        end
    end

    initial begin : inject_pool_backpressure
        if (EXPECT_POOL_BACKPRESSURE) forever begin
            @(negedge clk);
            if (!reset && phase==1 &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready) begin
                // FC drains the pool after each physical tile, so its next
                // real row naturally arrives with the pool idle. Hold the
                // pool's own ready signal low to stall both sides together.
                force u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready = 1'b0;
                repeat (5) @(negedge clk);
                release u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready;
                // Let the held sample handshake before another injection.
                @(negedge clk);
            end
        end
    end

    function automatic int signed xval(input int row,k);
        return row!=0 && !REPEAT_INPUT_ROW ? 0 : ((k*11+seed*7)%15)-7;
    endfunction
    function automatic int signed weightval(input int oc,k);
        return ((oc*13+k*5+seed)%7)-3;
    endfunction
    function automatic int signed biasval(input int oc);
        return ((oc%17)-8)*3;
    endfunction
    function automatic int signed mult(input int oc);
        return per_channel ? 1+oc%3 : 3;
    endfunction
    function automatic int signed qshift(input int oc);
        return per_channel ? 3+oc%2 : 4;
    endfunction
    function automatic int signed fc_golden(input int row,oc);
        int signed acc,product,value,s;
        acc=biasval(oc);
        for (int k=0;k<K;k++) acc+=xval(row,k)*weightval(oc,k);
        product=acc*mult(oc); s=qshift(oc);
        value=product>=0 ? (product+(1<<(s-1)))>>>s : -((-product+(1<<(s-1)))>>>s);
        if (relu_enable && value<0) value=0;
        if (value>127) value=127;
        if (value< -128) value=-128;
        return value;
    endfunction
    function automatic int signed pool_golden(input int y,x,c);
        int signed best,value;
        best=-128;
        for (int dy=0;dy<POOL_KH;dy++)
            for (int dx=0;dx<POOL_KW;dx++) begin
                value=fc_golden(0,((y*POOL_SH+dy)*W+x*POOL_SW+dx)*C+c);
                if (value>best) best=value;
            end
        return best;
    endfunction
    function automatic bit pixel_in_pool_window(input int pixel);
        bit covered_y,covered_x;
        int y,x;
        y=pixel/W; x=pixel%W; covered_y=0; covered_x=0;
        for (int row=0;row<PH;row++)
            if (y>=row*POOL_SH && y<row*POOL_SH+POOL_KH) covered_y=1;
        for (int col=0;col<PW;col++)
            if (x>=col*POOL_SW && x<col*POOL_SW+POOL_KW) covered_x=1;
        return covered_y && covered_x;
    endfunction
    function automatic logic [7:0] memory_byte(input int address);
        return mem[address>>2][8*(address%4)+:8];
    endfunction
    task automatic put_byte(input int address,input int signed value);
        if (value< -128 || value>127 || address>=MEM_WORDS*4) $fatal(1,"Bad init byte");
        mem[address>>2][8*(address%4)+:8]=8'(value);
    endtask
    task automatic prepare_data;
        for (int i=0;i<MEM_WORDS;i++) mem[i]='h5a5a5a5a;
        for (int row=0;row<(REPEAT_INPUT_ROW ? 1 : ROWS);row++)
            for (int k=0;k<PADDED_K;k++)
                put_byte(INPUT_BASE+row*PADDED_K+k,k<K ? xval(row,k) : 0);
        for (int oc=0;oc<N;oc++)
            for (int k=0;k<PADDED_K;k++)
                put_byte(WEIGHT_BASE+oc*PADDED_K+k,k<K ? weightval(oc,k) : 0);
    endtask
    task automatic configure_fc(input bit fused,input int mode);
        int flags,records;
        for (int i=0;i<32;i++) mem[DESC_BASE/4+i]=0;
        flags=3|(per_channel ? 8 : 0)|(relu_enable ? 4 : 0)|
            (mode==1 ? 32 : 0)|(mode==2 && K<=K_TILE_SIZE ? 64 : 0)|(fused ? 128 : 0);
        mem[DESC_BASE/4]=(flags<<8)|1;
        mem[DESC_BASE/4+1]=ROWS; mem[DESC_BASE/4+2]=N; mem[DESC_BASE/4+3]=K;
        mem[DESC_BASE/4+4]=INPUT_BASE; mem[DESC_BASE/4+6]=WEIGHT_BASE;
        mem[DESC_BASE/4+8]=fused ? POOL_BASE : FC_BASE;
        mem[DESC_BASE/4+10]=A_STRIDE; mem[DESC_BASE/4+11]=PADDED_K;
        mem[DESC_BASE/4+12]=N; mem[DESC_BASE/4+13]=PARAM_BASE;
        mem[DESC_BASE/4+15]=fused ? POOL_CONFIG : 0;
        if (!fused) begin
            mem[DESC_BASE/4+16]=3; mem[DESC_BASE/4+17]=H; mem[DESC_BASE/4+18]=W;
            mem[DESC_BASE/4+19]=C; mem[DESC_BASE/4+20]=FC_BASE;
            mem[DESC_BASE/4+24]=POOL_BASE; mem[DESC_BASE/4+31]=POOL_CONFIG;
        end
        desc_count=fused ? 1 : 2;
        // Ordinary GEMM keeps its 16-byte header; the fused header is 32B.
        records=fused ? 8 : 4;
        for (int i=0;i<8+N*3;i++) mem[PARAM_BASE/4+i]=0;
        mem[PARAM_BASE/4]=3; mem[PARAM_BASE/4+1]=4;
        if (fused) begin
            mem[PARAM_BASE/4+4]=H; mem[PARAM_BASE/4+5]=W;
            mem[PARAM_BASE/4+6]=C; mem[PARAM_BASE/4+7]=1;
        end
        for (int oc=0;oc<N;oc++)
            if (per_channel) begin
                mem[PARAM_BASE/4+records+3*oc]=32'(biasval(oc));
                mem[PARAM_BASE/4+records+3*oc+1]=32'(mult(oc));
                mem[PARAM_BASE/4+records+3*oc+2]=32'(qshift(oc));
            end else mem[PARAM_BASE/4+records+oc]=32'(biasval(oc));
    endtask
    task automatic launch(input bit expect_error,output int cycles);
        @(negedge clk); start=1;
        @(negedge clk); start=0; cycles=0;
        while (!done && cycles<500000) begin @(negedge clk); cycles++; end
        if (!done || error!==expect_error) begin
            $display("FC_ERROR_DIAG engine=%b read=%b param_loader=%b param_axi=%b fused_pool=%b coordinate=%b global_ready=%b shape_valid=%b state=%0d fc_mode=%b HWC=%0dx%0dx%0d batch=%0d",
                u_dut.u_npu_gemm_engine.error,u_dut.u_npu_gemm_engine.read_path_error,
                u_dut.u_npu_gemm_engine.param_loader_error,u_dut.u_npu_gemm_engine.param_axi_error,
                u_dut.u_npu_gemm_engine.fused_pool_error,u_dut.u_npu_gemm_engine.pool_coordinate_error,
                u_dut.u_npu_gemm_engine.global_param_ready_q,u_dut.u_npu_gemm_engine.fc_pool_geometry_valid,
                u_dut.u_npu_gemm_engine.exec_state,u_dut.u_npu_gemm_engine.fc_pool_q,
                u_dut.u_npu_gemm_engine.fc_pool_h,u_dut.u_npu_gemm_engine.fc_pool_w,
                u_dut.u_npu_gemm_engine.fc_pool_c,u_dut.u_npu_gemm_engine.fc_pool_batch);
            $fatal(1,"FC/Pool launch error phase=%0d done=%b error=%b expected=%b",phase,done,error,expect_error);
        end
        repeat (3) @(negedge clk);
        if (busy || rd_active_q || rvalid_q || wr_active_q || b_pending_q || bvalid_q)
            $fatal(1,"Program finished with outstanding work");
    endtask
    task automatic run_pair(input int mode);
        int bc,fc,wb,rb,fr,fw,ps,bwrites,breads,stalls,unused;
        seed=mode; per_channel=mode!=0; relu_enable=mode==1; phase=0;
        prepare_data(); configure_fc(0,mode);
        wb=write_bytes_q; rb=logical_pool_read_bytes_q; launch(0,bc);
        bwrites=write_bytes_q-wb; breads=logical_pool_read_bytes_q-rb;
        if (bwrites!=FC_BYTES+POOL_BYTES || breads!=POOL_READ_BYTES)
            $fatal(1,"Baseline traffic mismatch write=%0d read=%0d",bwrites,breads);
        for (int row=0;row<ROWS;row++)
            for (int oc=0;oc<N;oc++)
                if (memory_byte(FC_BASE+row*N+oc)!==8'(fc_golden(row,oc)))
                    $fatal(1,"Baseline FC mismatch row=%0d col=%0d got=%0d expected=%0d",row,oc,$signed(memory_byte(FC_BASE+row*N+oc)),fc_golden(row,oc));
        for (int y=0;y<PH;y++) for (int x=0;x<PW;x++) for (int c=0;c<C;c++) begin
            saved_pool[(y*PW+x)*C+c]=memory_byte(POOL_BASE+(y*PW+x)*C+c);
            if (saved_pool[(y*PW+x)*C+c]!==8'(pool_golden(y,x,c)))
                $fatal(1,"Baseline Pool mismatch y=%0d x=%0d c=%0d",y,x,c);
        end
        $display("FC_UNFUSED PASS mode=%0d K=%0d HWC=%0dx%0dx%0d strideA=%0d cycles=%0d write_bytes=%0d pool_reads=%0d",mode,K,H,W,C,A_STRIDE,bc,bwrites,breads);
        if ($test$plusargs("BASELINE_ONLY")) return;
        for (int i=0;i<FC_BYTES/4;i++) mem[FC_BASE/4+i]='h5a5a5a5a;
        for (int i=0;i<POOL_BYTES/4;i++) mem[POOL_BASE/4+i]='h5a5a5a5a;
        phase=1; configure_fc(1,mode);
        wb=write_bytes_q; rb=logical_pool_read_bytes_q; fr=fc_read_bursts_q;
        fw=fc_write_bytes_q; ps=pool_input_samples_q;
        stalls=pool_stall_cycles_q; unused=unused_pool_samples_q; launch(0,fc);
        if (write_bytes_q-wb!=POOL_BYTES || logical_pool_read_bytes_q!=rb ||
            fc_read_bursts_q!=fr || fc_write_bytes_q!=fw)
            $fatal(1,"Fused FC performed intermediate DDR traffic");
        if (pool_input_samples_q-ps!=POOL_SAMPLES)
            $fatal(1,"Padding rows entered pool or samples lost got=%0d expected=%0d",pool_input_samples_q-ps,POOL_SAMPLES);
        if (unused_pool_samples_q-unused!=UNUSED_POOL_SAMPLES)
            $fatal(1,"Window-free real pixels were lost got=%0d expected=%0d",
                unused_pool_samples_q-unused,UNUSED_POOL_SAMPLES);
        if (EXPECT_POOL_BACKPRESSURE && pool_stall_cycles_q==stalls)
            $fatal(1,"FC backpressure coverage was not exercised");
        for (int i=0;i<POOL_BYTES;i++)
            if (memory_byte(POOL_BASE+i)!==saved_pool[i]) $fatal(1,"Fused output mismatch byte=%0d",i);
        for (int i=0;i<FC_BYTES/4;i++)
            if (mem[FC_BASE/4+i]!=='h5a5a5a5a) $fatal(1,"Intermediate sentinel changed");
        $display("FC_FUSED PASS mode=%0d baseline_cycles=%0d fused_cycles=%0d fused_write_bytes=%0d avoided_intermediate_bytes=%0d real_fc_write_bytes=%0d padded_fc_write_bytes=%0d pool_logical_read_bytes=%0d pool_samples=%0d unused_samples=%0d stall_cycles=%0d",
            mode,bc,fc,write_bytes_q-wb,FC_BYTES+POOL_READ_BYTES,N,(ROWS-1)*N,
            POOL_READ_BYTES,pool_input_samples_q-ps,unused_pool_samples_q-unused,
            pool_stall_cycles_q-stalls);
    endtask
    task automatic rejected_case(input int kind);
        int cycles,wb,bad_h,bad_w,bad_c,bad_n,bad_k,square_words;
        phase=2; configure_fc(1,0);
        case (kind)
            0: mem[PARAM_BASE/4+5]=W+1;
            1: mem[PARAM_BASE/4+7]=2;
            2: begin
                bad_h=((POOL_KH+COLS-1)/COLS)*COLS;
                bad_w=((POOL_KW+COLS-1)/COLS)*COLS;
                bad_c=COLS>4 ? COLS+4 : COLS+2; bad_n=bad_h*bad_w*bad_c;
                mem[PARAM_BASE/4+4]=bad_h; mem[PARAM_BASE/4+5]=bad_w;
                mem[PARAM_BASE/4+6]=bad_c; mem[DESC_BASE/4+2]=bad_n; mem[DESC_BASE/4+12]=bad_n;
            end
            3: begin
                // One channel block fits, but FC requires all channel state.
                bad_c=(LINE_WORDS/(POOL_KH*POOL_KW*(COLS/4))+1)*COLS;
                bad_n=POOL_KH*POOL_KW*bad_c;
                mem[PARAM_BASE/4+4]=POOL_KH; mem[PARAM_BASE/4+5]=POOL_KW;
                mem[PARAM_BASE/4+6]=bad_c; mem[DESC_BASE/4+2]=bad_n; mem[DESC_BASE/4+12]=bad_n;
            end
            4: mem[PARAM_BASE/4+4]=0;
            5: mem[PARAM_BASE/4+5]=0;
            6: mem[PARAM_BASE/4+6]=0;
            7: mem[PARAM_BASE/4+7]=0;
            8: mem[DESC_BASE/4+15]='h02000202;
            9: mem[DESC_BASE/4+15]='h0101ffff;
            10: mem[DESC_BASE/4][15:8]=8'h81;
            11: begin
                // 65536 N tiles overflow the default 16-bit tile counter.
                // Keep the pooling state within SRAM so capacity rejection
                // cannot conceal a missing counter-range check.
                square_words=POOL_KH*256*(COLS/4);
                bad_c=COLS;
                if (square_words<=LINE_WORDS) begin
                    bad_h=256; bad_w=256;
                end else begin
                    bad_h=(65536+POOL_KW-1)/POOL_KW;
                    bad_w=POOL_KW;
                end
                bad_n=bad_h*bad_w*bad_c;
                if (POOL_KH*bad_w*(bad_c/4)>LINE_WORDS ||
                    bad_n/COLS<65536)
                    $fatal(1,"Overflow rejection case did not isolate counter range");
                mem[PARAM_BASE/4+4]=bad_h; mem[PARAM_BASE/4+5]=bad_w;
                mem[PARAM_BASE/4+6]=bad_c; mem[DESC_BASE/4+2]=bad_n;
                mem[DESC_BASE/4+12]=bad_n;
                $display("FC_TILE_OVERFLOW_CASE HWC=%0dx%0dx%0d N=%0d n_tiles=%0d",
                    bad_h,bad_w,bad_c,bad_n,bad_n/COLS);
            end
            12: begin
                // configure_fc(...,0) leaves B stationary disabled. Supply
                // a consistent weight-row stride to isolate K count range.
                bad_k=K_TILE_SIZE*65536;
                mem[DESC_BASE/4+3]=bad_k;
                mem[DESC_BASE/4+10]=0;
                mem[DESC_BASE/4+11]=bad_k;
                $display("FC_K_TILE_OVERFLOW_CASE K=%0d k_tiles=%0d",
                    bad_k,bad_k/K_TILE_SIZE);
            end
        endcase
        wb=write_bytes_q; launch(1,cycles);
        if (write_bytes_q!=wb) $fatal(1,"Rejected FC fusion wrote data kind=%0d",kind);
        $display("FC_FUSED_REJECT PASS kind=%0d cycles=%0d",kind,cycles);
    endtask

    function automatic int signed conv_after_fc_golden(input int channel);
        int signed best,acc,product,value;
        best=-128;
        for (int p=0;p<4;p++) begin
            acc=channel-2;
            for (int k=0;k<8;k++)
                acc+=(((p*5+k*3)%13)-6)*(((channel*7+k*2)%7)-3);
            product=acc*3;
            value=product>=0 ? (product+8)>>>4 : -((-product+8)>>>4);
            if (value>127) value=127;
            if (value< -128) value=-128;
            if (value>best) best=value;
        end
        return best;
    endfunction

    task automatic conv_after_fc;
        int cycles,wb;
        // The tiny Conv uses a different shape and the ordinary 16B header.
        // Start it without reset after FC to catch a stale FC-config mux.
        if (4%ROWS!=0) return;
        phase=3;
        for (int p=0;p<4;p++) for (int k=0;k<8;k++)
            put_byte(INPUT_BASE+p*8+k,((p*5+k*3)%13)-6);
        for (int c=0;c<COLS;c++) for (int k=0;k<8;k++)
            put_byte(WEIGHT_BASE+c*8+k,((c*7+k*2)%7)-3);
        for (int i=0;i<8+COLS;i++) mem[PARAM_BASE/4+i]=0;
        mem[PARAM_BASE/4]=3; mem[PARAM_BASE/4+1]=4;
        for (int c=0;c<COLS;c++) mem[PARAM_BASE/4+4+c]=32'(c-2);
        for (int i=0;i<32;i++) mem[DESC_BASE/4+i]=0;
        mem[DESC_BASE/4]='h00008302;
        mem[DESC_BASE/4+1]=4; mem[DESC_BASE/4+2]=COLS; mem[DESC_BASE/4+3]=8;
        mem[DESC_BASE/4+4]=INPUT_BASE; mem[DESC_BASE/4+6]=WEIGHT_BASE;
        mem[DESC_BASE/4+8]=POOL_BASE; mem[DESC_BASE/4+10]='h00020002;
        mem[DESC_BASE/4+11]='h01010008; mem[DESC_BASE/4+12]='h00000101;
        mem[DESC_BASE/4+13]=PARAM_BASE; desc_count=1;
        for (int i=0;i<COLS/4;i++) mem[POOL_BASE/4+i]='h5a5a5a5a;
        wb=write_bytes_q; launch(0,cycles);
        if (write_bytes_q-wb!=COLS) $fatal(1,"Conv after FC wrote wrong byte count");
        for (int c=0;c<COLS;c++)
            if (memory_byte(POOL_BASE+c)!==8'(conv_after_fc_golden(c)))
                $fatal(1,"Conv after FC mismatch channel=%0d got=%0d expected=%0d",
                    c,$signed(memory_byte(POOL_BASE+c)),conv_after_fc_golden(c));
        $display("CONV_AFTER_FC PASS cycles=%0d output_bytes=%0d",cycles,COLS);
    endtask

    task automatic fc_after_conv;
        int cycles,wb,rb,fr,fw,ps;
        phase=1; per_channel=0; relu_enable=0; seed=4;
        prepare_data(); configure_fc(1,0);
        wb=write_bytes_q; rb=logical_pool_read_bytes_q;
        fr=fc_read_bursts_q; fw=fc_write_bytes_q; ps=pool_input_samples_q;
        launch(0,cycles);
        if (write_bytes_q-wb!=POOL_BYTES || logical_pool_read_bytes_q!=rb ||
            fc_read_bursts_q!=fr || fc_write_bytes_q!=fw ||
            pool_input_samples_q-ps!=POOL_SAMPLES)
            $fatal(1,"FC after Conv traffic or sample count incorrect");
        for (int y=0;y<PH;y++) for (int x=0;x<PW;x++) for (int c=0;c<C;c++)
            if (memory_byte(POOL_BASE+(y*PW+x)*C+c)!==8'(pool_golden(y,x,c)))
                $fatal(1,"FC after Conv mismatch y=%0d x=%0d c=%0d",y,x,c);
        $display("FC_AFTER_CONV PASS cycles=%0d output_bytes=%0d pool_samples=%0d",
            cycles,write_bytes_q-wb,pool_input_samples_q-ps);
    endtask

    initial begin : run
        int cycles,ps;
        if (H<POOL_KH || W<POOL_KW || C<COLS || C%COLS!=0 || COLS<4 || COLS%4!=0 ||
            K<=0 || ROWS<=0 || FULL_WORDS>LINE_WORDS ||
            INPUT_BASE+ROWS*PADDED_K>WEIGHT_BASE || WEIGHT_BASE+N*PADDED_K>FC_BASE ||
            FC_BASE+FC_BYTES>POOL_BASE || POOL_BASE+POOL_BYTES>PARAM_BASE ||
            PARAM_BASE+32+N*12>DESC_BASE) $fatal(1,"Unsupported FC pool test geometry");
        for (int i=0;i<MEM_WORDS;i++) mem[i]=0;
        repeat (6) @(negedge clk); reset=0;
        repeat (2) @(negedge clk);
        for (int mode=0;mode<3;mode++) run_pair(mode);
        if ($test$plusargs("BASELINE_ONLY")) begin $display("FC/Pool baseline reference PASS"); $finish; end
        for (int i=0;i<13;i++) rejected_case(i);
        // Recover in per-channel mode as well as clearing the top status.
        phase=1; per_channel=1; relu_enable=0; seed=3;
        prepare_data(); configure_fc(1,0); ps=pool_input_samples_q; launch(0,cycles);
        if (pool_input_samples_q-ps!=POOL_SAMPLES) $fatal(1,"Recovery sample count wrong");
        for (int y=0;y<PH;y++) for (int x=0;x<PW;x++) for (int c=0;c<C;c++)
            if (memory_byte(POOL_BASE+(y*PW+x)*C+c)!==8'(pool_golden(y,x,c)))
                $fatal(1,"FC fusion recovery mismatch");
        conv_after_fc();
        fc_after_conv();
        $display("FC -> Reshape -> MaxPool fusion system PASS HWC=%0dx%0dx%0d K=%0d tileK=%0d array=%0dx%0d line_words=%0d repeated_rows=%0b",H,W,C,K,K_TILE_SIZE,ROWS,COLS,LINE_WORDS,REPEAT_INPUT_ROW);
        $finish;
    end
    initial begin #100000000; $fatal(1,"FC pool testbench timeout"); end
endmodule
