`timescale 1ns/1ps

// Logical matrix tails must never turn into DDR writes or extra parameter reads.
// The reference computes scalar dot products independently of tile scheduling.
module tail_tiles_npu_tb #(
    parameter int ROWS = 4,
    parameter int COLS = 4,
    parameter int K_TILE_SIZE = 16,
    parameter int POOL_LINE_WORDS = 1024,
    parameter bit FUSED_ONLY = 0
);
    localparam int MEM_WORDS = 98304;
    localparam int A_BASE = 'h1000, B_BASE = 'h8000, PARAM_BASE = 'h18000;
    localparam int C_BASE = 'h20000, C2_BASE = 'h28000, DESC_BASE = 'h40000;
    localparam int OUTPUT_SPAN = 8192;
    logic clk = 0, reset = 1, start = 0, busy, done, error;
    always #5 clk = ~clk;
    logic signed [31:0] acc_out [ROWS][COLS];
    logic arid, rid, awid, bid;
    logic [63:0] araddr, rdata, awaddr;
    logic [7:0] arlen, awlen;
    logic [2:0] arsize, awsize;
    logic [1:0] arburst, rresp, awburst, bresp;
    logic arvalid, arready, rlast, rvalid, rready;
    logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic [31:0] mem [MEM_WORDS];
    int write_hits [OUTPUT_SPAN];
    int pool_hits [2048];
    int cycle_q, case_id = 0, checks = 0;
    int m_q, n_q, k_q, h_q, width_q, a_stride_q, b_stride_q;
    int c_stride_q, output_rows_q, output_row_bytes_q, element_bytes_q;
    int input_base_q, output_base_q, input_end_q, weight_end_q, param_end_q;
    int write_bytes_q, pool_samples_q, seed_q, chain_seed_q;
    bit int8_q, bias_q, relu_q, per_channel_q, conv_q, fused_q, chain_q;
    bit command_active = 0;
    int reuse_mode_q;
    int expected_psum_tasks = 0, observed_psum_tasks = 0;
    int expected_stationary_tasks = 0, observed_stationary_tasks = 0;

    npu_top #(.ROWS(ROWS), .COLS(COLS), .K_TILE_SIZE(K_TILE_SIZE),
              .A_REUSE_BLOCK_SIZE(4), .POOL_LINE_WORDS(POOL_LINE_WORDS)) u_dut (
        .clk(clk), .reset(reset), .start(start), .desc_base(64'(DESC_BASE)),
        .desc_count(16'd1), .busy(busy), .done(done), .error(error), .acc_out(acc_out),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arvalid(arvalid),
        .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata),
        .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready), .m_axi_awid(awid), .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    function automatic int align8(input int value);
        return ((value+7)/8)*8;
    endfunction
    function automatic int signed raw_x(input int seed, row, k);
        return ((seed*3+row*7+k*5)%13)-6;
    endfunction
    function automatic int signed weight_value(input int seed, col, k);
        return ((seed+col*3+k*7)%9)-4;
    endfunction
    function automatic int signed bias_value(input int seed, col);
        return ((seed+col*5)%17)-8;
    endfunction
    function automatic int multiplier(input int col, input bit pc);
        return pc ? 1+col%3 : 3;
    endfunction
    function automatic int shift_value(input int col, input bit pc);
        return pc ? 3+col%3 : 4;
    endfunction
    function automatic int signed requant(input int signed value, input int col,
                                         input bit pc, relu);
        longint signed product, result;
        int shift;
        product = 64'(value)*64'(multiplier(col,pc));
        shift = shift_value(col,pc);
        result = product >= 0 ? (product+(64'd1<<(shift-1)))>>>shift :
                              -((-product+(64'd1<<(shift-1)))>>>shift);
        if (relu && result < 0) result = 0;
        if (result > 127) result = 127;
        if (result < -128) result = -128;
        return int'(result);
    endfunction
    // Chained tests always use an INT8 + per-channel + bias + ReLU producer.
    function automatic int signed previous_value(input int row, col);
        int signed acc;
        acc = bias_value(chain_seed_q,col);
        for (int k=0; k<8; k++)
            acc += raw_x(chain_seed_q,row,k)*weight_value(chain_seed_q,col,k);
        return requant(acc,col,1,1);
    endfunction
    function automatic int signed source_value(input int row, k);
        return chain_q ? previous_value(row,k) : raw_x(seed_q,row,k);
    endfunction
    function automatic int signed golden(input int row, col);
        int signed acc;
        acc = bias_q ? bias_value(seed_q,col) : 0;
        for (int k=0; k<k_q; k++)
            acc += source_value(row,k)*weight_value(seed_q,col,k);
        return int8_q ? requant(acc,col,per_channel_q,relu_q) : acc;
    endfunction
    function automatic int signed pooled_golden(input int row, col);
        int signed best, value;
        int py, px, pooled_w;
        pooled_w = width_q/2;
        py = row/pooled_w;
        px = row%pooled_w;
        best = -128;
        for (int y=0; y<2; y++)
            for (int x=0; x<2; x++) begin
                value = golden((py*2+y)*width_q+px*2+x,col);
                if (value > best) best = value;
            end
        return best;
    endfunction
    function automatic logic [7:0] memory_byte(input int address);
        return mem[address/4][8*(address%4)+:8];
    endfunction
    task automatic put_byte(input int address, input int signed value);
        mem[address/4][8*(address%4)+:8] = 8'(value);
    endtask
    function automatic bit writable_byte(input int address);
        int offset, row, col;
        offset = address-output_base_q;
        if (offset < 0 || offset >= OUTPUT_SPAN || c_stride_q == 0) return 0;
        row = offset/c_stride_q;
        col = offset%c_stride_q;
        return row < output_rows_q && col < output_row_bytes_q;
    endfunction

    logic rd_active_q = 0, rvalid_q = 0, rlast_q = 0, rd_id_q = 0;
    logic [63:0] rd_addr_q = 0, rdata_q = 0;
    logic [8:0] rd_left_q = 0;
    int read_wait_q = 0;
    logic wr_active_q = 0, b_pending_q = 0, bvalid_q = 0, wr_id_q = 0;
    logic [63:0] wr_addr_q = 0;
    logic [8:0] wr_left_q = 0;
    int b_wait_q = 0;
    assign arready = !rd_active_q && !rvalid_q && cycle_q%5 != 1;
    assign rid = rd_id_q, rvalid = rvalid_q, rdata = rdata_q;
    assign rlast = rlast_q, rresp = 0;
    assign awready = !wr_active_q && !b_pending_q && !bvalid_q && cycle_q%7 < 4;
    assign wready = wr_active_q && cycle_q%9 >= 4;
    assign bid = wr_id_q, bvalid = bvalid_q, bresp = 0;

    always @(posedge clk) begin : memory_model
        int address, bytes_this_beat, spatial, channel, pool_index;
        longint unsigned burst_end;
        if (reset) begin
            cycle_q <= 0; rd_active_q <= 0; rvalid_q <= 0;
            rd_addr_q <= 0; rd_left_q <= 0; rd_id_q <= 0;
            rdata_q <= 0; rlast_q <= 0; read_wait_q <= 0;
            wr_active_q <= 0; wr_addr_q <= 0; wr_left_q <= 0; wr_id_q <= 0;
            b_pending_q <= 0; bvalid_q <= 0; b_wait_q <= 0;
        end else begin
            cycle_q <= cycle_q+1;
            if (arvalid && arready) begin
                burst_end = araddr+(64'(arlen)+1)*8;
                if (arsize !== 3'd3 || arburst !== 2'b01 || araddr[2:0] !== 0 ||
                    burst_end > MEM_WORDS*4 ||
                    araddr[11:0]+(64'(arlen)+1)*8 > 4096)
                    $fatal(1,"case %0d invalid AXI read addr=%h len=%0d",case_id,araddr,arlen);
                if (!command_active || !(
                    (araddr >= DESC_BASE && burst_end <= DESC_BASE+64) ||
                    (araddr >= input_base_q && burst_end <= input_end_q) ||
                    (araddr >= B_BASE && burst_end <= weight_end_q) ||
                    ((bias_q || int8_q) && araddr >= PARAM_BASE && burst_end <= param_end_q)))
                    $fatal(1,"case %0d read outside logical tensors addr=%h end=%h Aend=%h Bend=%h Pend=%h",
                           case_id,araddr,burst_end,input_end_q,weight_end_q,param_end_q);
                rd_active_q <= 1; rd_addr_q <= araddr;
                rd_left_q <= {1'b0,arlen}+1'b1; rd_id_q <= arid;
                read_wait_q <= 2+cycle_q%4;
            end
            if (read_wait_q > 0) read_wait_q <= read_wait_q-1;
            if (rd_active_q && !rvalid_q && read_wait_q == 0) begin
                rvalid_q <= 1; rdata_q <= {mem[(rd_addr_q>>2)+1],mem[rd_addr_q>>2]};
                rlast_q <= rd_left_q == 1;
            end
            if (rvalid && rready) begin
                rvalid_q <= 0;
                if (rd_left_q == 1) rd_active_q <= 0;
                else begin
                    rd_addr_q <= rd_addr_q+8; rd_left_q <= rd_left_q-1;
                    read_wait_q <= 1+cycle_q%3;
                end
            end
            if (awvalid && awready) begin
                if (!command_active || awsize !== 3'd2 || awburst !== 2'b01 ||
                    awaddr[1:0] !== 0 || awaddr < output_base_q ||
                    awaddr+(64'(awlen)+1)*4 > output_base_q+OUTPUT_SPAN ||
                    awaddr[11:0]+(64'(awlen)+1)*4 > 4096)
                    $fatal(1,"case %0d invalid AXI write addr=%h len=%0d",case_id,awaddr,awlen);
                wr_active_q <= 1; wr_addr_q <= awaddr;
                wr_left_q <= {1'b0,awlen}+1'b1; wr_id_q <= awid;
            end
            if (wvalid && wready) begin
                if (wlast !== (wr_left_q == 1) || wstrb == 0)
                    $fatal(1,"case %0d invalid WLAST/WSTRB",case_id);
                bytes_this_beat = 0;
                for (int lane=0; lane<4; lane++) begin
                    if (wstrb[lane]) begin
                        address = int'(wr_addr_q)+lane;
                        if (!writable_byte(address))
                            $fatal(1,"case %0d padded row/column written addr=%h",case_id,address);
                        write_hits[address-output_base_q] = write_hits[address-output_base_q]+1;
                        mem[address/4][8*(address%4)+:8] <= wdata[8*lane+:8];
                        bytes_this_beat++;
                    end
                end
                write_bytes_q = write_bytes_q+bytes_this_beat;
                if (wr_left_q == 1) begin
                    wr_active_q <= 0; b_pending_q <= 1; b_wait_q <= 7;
                end else begin
                    wr_left_q <= wr_left_q-1; wr_addr_q <= wr_addr_q+4;
                end
            end
            if (b_wait_q > 0) b_wait_q <= b_wait_q-1;
            if (b_pending_q && b_wait_q == 0) begin b_pending_q <= 0; bvalid_q <= 1; end
            if (bvalid && bready) bvalid_q <= 0;

            if (command_active && fused_q &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_valid &&
                u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_ready) begin
                spatial = int'(u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_spatial_index);
                channel = int'(u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_channel_base);
                if (spatial >= m_q || channel+COLS > n_q || channel%COLS != 0)
                    $fatal(1,"case %0d padding reached fused pool pixel=%0d channel=%0d",case_id,spatial,channel);
                pool_index = spatial*(n_q/COLS)+channel/COLS;
                pool_hits[pool_index] = pool_hits[pool_index]+1;
                for (int lane=0; lane<COLS; lane++)
                    if (u_dut.u_npu_gemm_engine.gen_fused_pool.u_pool.in_data[8*lane+:8] !==
                        8'(golden(spatial,channel+lane)))
                        $fatal(1,"case %0d fused pool source mismatch row=%0d col=%0d",case_id,spatial,channel+lane);
                pool_samples_q = pool_samples_q+1;
            end
        end
    end

    task automatic run_case(
        input int m, n, k,
        input bit output_int8, bias_en, pc_en, relu_en,
        input int reuse_mode,
        input bit conv_en,
        input int input_h, input_w,
        input bit fused_pool,
        input bit chained,
        input int out_base
    );
        int flags, elapsed, expected, actual, address, row, col, value;
        int elem_index, expected_total, start_cycle;
        bit psum_seen, stationary_seen;
        @(negedge clk);
        case_id++;
        m_q=m; n_q=n; k_q=k; h_q=input_h; width_q=input_w;
        int8_q=output_int8; bias_q=bias_en; per_channel_q=pc_en; relu_q=relu_en;
        conv_q=conv_en; fused_q=fused_pool; chain_q=chained; reuse_mode_q=reuse_mode;
        seed_q=case_id; input_base_q=chained ? C_BASE : A_BASE; output_base_q=out_base;
        a_stride_q=align8(k); b_stride_q=align8(k);
        element_bytes_q=output_int8 ? 1 : 4;
        output_rows_q=fused_pool ? (input_h/2)*(input_w/2) : m;
        output_row_bytes_q=n*element_bytes_q;
        c_stride_q=conv_en ? output_row_bytes_q : ((output_row_bytes_q+3)/4)*4+4;
        if (fused_pool) c_stride_q=output_row_bytes_q;
        input_end_q=input_base_q+align8(conv_en ? m*k : m*a_stride_q);
        weight_end_q=B_BASE+n*b_stride_q;
        param_end_q=PARAM_BASE+align8(16+n*(pc_en ? 12 : 4));
        if (m%ROWS==0 && n%COLS==0 && k%K_TILE_SIZE==0)
            $fatal(1,"test case must exercise a tail");
        if (m*c_stride_q >= OUTPUT_SPAN || m*(n/COLS) >= 2048)
            $fatal(1,"test allocation too small");
        for (int i=0; i<OUTPUT_SPAN/4+8; i++)
            mem[(output_base_q-16)/4+i]=32'ha5a5_a5a5;
        for (int i=0; i<OUTPUT_SPAN; i++) write_hits[i]=0;
        for (int i=0; i<2048; i++) pool_hits[i]=0;
        write_bytes_q=0; pool_samples_q=0;
        // Poison bytes after real tensors. Read bounds below prohibit fetching
        // additional matrix lanes while permitting the final aligned AXI beat.
        if (!chained) begin
            for (int i=0; i<align8(m*a_stride_q)+64; i++) put_byte(A_BASE+i,57);
            for (int r=0; r<m; r++)
                for (int kk=0; kk<k; kk++)
                    put_byte(A_BASE+(conv_en ? r*k : r*a_stride_q)+kk,raw_x(seed_q,r,kk));
        end
        for (int i=0; i<n*b_stride_q+COLS*b_stride_q; i++) put_byte(B_BASE+i,43);
        for (int c=0; c<n; c++)
            for (int kk=0; kk<k; kk++)
                put_byte(B_BASE+c*b_stride_q+kk,weight_value(seed_q,c,kk));
        for (int i=0; i<(16+n*12+64)/4; i++) mem[PARAM_BASE/4+i]=32'h5a5a_5a5a;
        mem[PARAM_BASE/4]=32'(multiplier(0,0));
        mem[PARAM_BASE/4+1]=32'(shift_value(0,0));
        mem[PARAM_BASE/4+2]=0;
        mem[PARAM_BASE/4+3]=0;
        for (int c=0; c<n; c++) begin
            if (pc_en) begin
                mem[PARAM_BASE/4+4+c*3]=32'(bias_value(seed_q,c));
                mem[PARAM_BASE/4+5+c*3]=32'(multiplier(c,1));
                mem[PARAM_BASE/4+6+c*3]=32'(shift_value(c,1));
            end else mem[PARAM_BASE/4+4+c]=32'(bias_value(seed_q,c));
        end
        for (int i=0; i<16; i++) mem[DESC_BASE/4+i]=0;
        flags=int'(bias_en)|(int'(output_int8)<<1)|(int'(relu_en)<<2)|
              (int'(pc_en)<<3)|(int'(reuse_mode==1)<<5)|
              (int'(reuse_mode==2)<<6)|(int'(fused_pool)<<7);
        mem[DESC_BASE/4]=(32'(flags)<<8)|(conv_en ? 32'd2 : 32'd1);
        mem[DESC_BASE/4+1]=32'(m);
        mem[DESC_BASE/4+2]=32'(n);
        mem[DESC_BASE/4+3]=32'(k);
        mem[DESC_BASE/4+4]=32'(input_base_q);
        mem[DESC_BASE/4+6]=32'(B_BASE);
        mem[DESC_BASE/4+8]=32'(output_base_q);
        if (conv_en) begin
            mem[DESC_BASE/4+10]={16'(input_w),16'(input_h)};
            mem[DESC_BASE/4+11]={8'd1,8'd1,16'(k)};
            mem[DESC_BASE/4+12]=32'h0000_0101;
        end else begin
            mem[DESC_BASE/4+10]=32'(a_stride_q);
            mem[DESC_BASE/4+11]=32'(b_stride_q);
            mem[DESC_BASE/4+12]=32'(c_stride_q);
        end
        mem[DESC_BASE/4+13]=(bias_en || output_int8) ? 32'(PARAM_BASE) : 0;
        command_active=1;
        start_cycle=cycle_q;
        start=1;
        @(negedge clk);
        start=0;
        elapsed=0; psum_seen=0; stationary_seen=0;
        while (!done && elapsed<500000) begin
            @(negedge clk);
            elapsed++;
            if (u_dut.u_npu_gemm_engine.use_psum_path) psum_seen=1;
            if (u_dut.u_npu_gemm_engine.b_stationary_q) stationary_seen=1;
        end
        if (!done || error)
            $fatal(1,"case %0d failed done=%b error=%b M=%0d N=%0d K=%0d conv=%b fused=%b reuse=%0d",
                   case_id,done,error,m,n,k,conv_en,fused_pool,reuse_mode);
        if (wr_active_q || b_pending_q || bvalid_q)
            $fatal(1,"case %0d completed before AXI write response",case_id);
        expected_total=output_rows_q*output_row_bytes_q;
        if (write_bytes_q != expected_total)
            $fatal(1,"case %0d written bytes=%0d expected=%0d",case_id,write_bytes_q,expected_total);
        for (int offset=0; offset<OUTPUT_SPAN; offset++) begin
            address=output_base_q+offset;
            if (writable_byte(address)) begin
                if (write_hits[offset] != 1)
                    $fatal(1,"case %0d byte missing/duplicated addr=%h hits=%0d",case_id,address,write_hits[offset]);
                row=offset/c_stride_q;
                col=(offset%c_stride_q)/element_bytes_q;
                elem_index=(offset%c_stride_q)%element_bytes_q;
                expected=fused_pool ? pooled_golden(row,col) : golden(row,col);
                value=(expected>>(elem_index*8))&255;
                actual=int'(memory_byte(address));
                if (actual !== value)
                    $fatal(1,"case %0d value mismatch row=%0d col=%0d byte=%0d actual=%h expected=%h M=%0d N=%0d K=%0d conv=%b reuse=%0d",
                           case_id,row,col,elem_index,actual,value,m,n,k,conv_en,reuse_mode);
                checks++;
            end else if (memory_byte(address) !== 8'ha5)
                $fatal(1,"case %0d sentinel corrupted addr=%h",case_id,address);
        end
        for (int offset=-16; offset<0; offset++)
            if (memory_byte(output_base_q+offset) !== 8'ha5)
                $fatal(1,"case %0d prefix sentinel corrupted",case_id);
        if (fused_pool) begin
            if (pool_samples_q != m*(n/COLS))
                $fatal(1,"case %0d pooled real samples=%0d expected=%0d",case_id,pool_samples_q,m*(n/COLS));
            for (int i=0; i<m*(n/COLS); i++)
                if (pool_hits[i] != 1)
                    $fatal(1,"case %0d pool input missing/duplicated sample=%0d",case_id,i);
        end
        if (reuse_mode==1 && k>K_TILE_SIZE && n>COLS && !fused_pool) begin
            expected_psum_tasks++;
            if (!psum_seen) $fatal(1,"case %0d did not exercise PSUM reuse",case_id);
            observed_psum_tasks++;
        end
        if (reuse_mode==2) begin
            expected_stationary_tasks++;
            if (!stationary_seen) $fatal(1,"case %0d did not exercise B stationary",case_id);
            observed_stationary_tasks++;
        end
        command_active=0;
        $display("TAIL CASE PASS id=%0d COLS=%0d M=%0d N=%0d K=%0d INT8=%b conv=%b fused=%b reuse=%0d chained=%b cycles=%0d bytes=%0d",
                 case_id,COLS,m,n,k,output_int8,conv_en,fused_pool,reuse_mode,chained,cycle_q-start_cycle,write_bytes_q);
        // Back-to-back jobs share all DUT state, with no reset between them.
        repeat (3) @(negedge clk);
    endtask

    initial begin : test_main
        for (int i=0; i<MEM_WORDS; i++) mem[i]=0;
        repeat (5) @(negedge clk);
        reset=0;
        repeat (2) @(negedge clk);

        if (FUSED_ONLY) begin
            // Small raw SRAM forces N->M channel tiling while the final M
            // tile is partial. Also exercise multiple K blocks and B reuse.
            run_case(49,2*COLS,2*K_TILE_SIZE+1,1,1,1,1,1,1,7,7,1,0,C_BASE);
            run_case(15,2*COLS,8,1,1,1,0,2,1,3,5,1,0,C_BASE);
            $display("TEST_PASS tail_tiles_npu_tb fused channel tiling COLS=%0d",COLS);
            $finish;
        end

        run_case(1,1,1,1,1,1,0,0,0,0,0,0,0,C_BASE);
        run_case(1,1001,8,1,1,1,0,0,0,0,0,0,0,C_BASE);

        // Every possible nonzero K remainder, with joint M/N tails and
        // alternating INT8/INT32 results through the multi-K PSUM path.
        for (int tail=1; tail<K_TILE_SIZE; tail++)
            run_case(ROWS+1,COLS+1,K_TILE_SIZE+tail,
                     tail%2!=0,1,tail%2!=0,tail%2!=0 && tail%3==0,
                     1,0,0,0,0,0,C_BASE);

        // All row residues, including a one-element shape and INT32 bias.
        for (int tail=1; tail<ROWS; tail++) begin
            run_case(tail,COLS+1,7,0,0,0,0,0,0,0,0,0,0,C_BASE);
            run_case(ROWS+tail,2*COLS+tail,K_TILE_SIZE+1,0,1,0,0,0,0,0,0,0,0,C_BASE);
        end
        // Every column residue for COLS=4 and COLS=8, joint M/N/K tails,
        // global and per-channel scaling, signed INT8, and ReLU.
        for (int tail=1; tail<COLS; tail++) begin
            run_case(ROWS+1,tail,1,1,1,0,0,0,0,0,0,0,0,C_BASE);
            run_case(ROWS+2,COLS+tail,K_TILE_SIZE+7,1,1,1,tail%2==0,1,0,0,0,0,0,C_BASE);
            run_case(ROWS+3,2*COLS+tail,K_TILE_SIZE-1,1,1,1,tail%2!=0,2,0,0,0,0,0,C_BASE);
        end
        // Three K blocks and a full N block exercise final-only epilogue.
        run_case(2*ROWS+3,2*COLS,2*K_TILE_SIZE+1,1,0,0,0,1,0,0,0,0,0,C_BASE);
        run_case(2*ROWS+1,COLS+3,2*K_TILE_SIZE-1,0,1,0,0,1,0,0,0,0,0,C_BASE);

        // Conv output is compact HWC, including unaligned INT8 pixel starts.
        run_case(5,COLS+1,8,1,1,1,0,0,1,1,5,0,0,C_BASE);
        run_case(6,COLS+2,24,0,1,0,0,1,1,2,3,0,0,C_BASE);
        run_case(7,COLS+3,8,1,1,1,1,2,1,1,7,0,0,C_BASE);
        run_case(49,4,8,1,1,1,1,0,1,7,7,0,0,C_BASE);
        run_case(49,COLS+1,24,1,1,1,0,1,1,7,7,0,0,C_BASE);

        // Fused Conv filters only physical padding; unused edge pixels still
        // enter the pool once. N remains a complete external COLS group.
        run_case(9,COLS,8,1,1,1,0,0,1,3,3,1,0,C_BASE);
        run_case(6,COLS,24,1,1,1,1,0,1,2,3,1,0,C_BASE);
        run_case(15,COLS,8,1,1,0,0,2,1,3,5,1,0,C_BASE);
        run_case(49,2*COLS,24,1,1,1,1,0,1,7,7,1,0,C_BASE);

        // A second Conv consumes the first Conv's compact tail channels
        // directly. Cin=5/6/7 needs no alignment/repacking between operators.
        for (int channels=5; channels<=7; channels++) begin
            run_case(9,channels,8,1,1,1,1,0,1,3,3,0,0,C_BASE);
            chain_seed_q=seed_q;
            run_case(9,COLS+1,channels,1,1,1,0,0,1,3,3,0,1,C2_BASE);
        end
        if (expected_psum_tasks == 0 || expected_stationary_tasks == 0 ||
            observed_psum_tasks != expected_psum_tasks ||
            observed_stationary_tasks != expected_stationary_tasks)
            $fatal(1,"Missing scheduling path coverage");
        $display("TAIL TILES PASS COLS=%0d cases=%0d byte_checks=%0d psum=%0d stationary=%0d",
                 COLS,case_id,checks,observed_psum_tasks,observed_stationary_tasks);
        $display("TEST_PASS tail_tiles_npu_tb");
        $finish;
    end
    initial begin
        #1000000000;
        $fatal(1,"tail tiles global timeout case=%0d",case_id);
    end
endmodule
