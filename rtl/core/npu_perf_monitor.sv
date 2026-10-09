
 // Synthesizable, observational NPU performance monitor.
 // No control signal is fed back into the NPU datapath.
 module npu_perf_monitor #(
     parameter int unsigned DATA_WIDTH = 32
 ) (
     input  logic clk,
     input  logic reset,
     input  logic run_start,
     input  logic run_done,
     input  logic layer_start,
     input  logic layer_done,
     input  logic [7:0] layer_opcode,
     input  logic executor_busy,
     input  logic pool_busy,
     input  logic arvalid,
     input  logic arready,
     input  logic rvalid,
     input  logic rready,
     input  logic rlast,
     input  logic awvalid,
     input  logic awready,
     input  logic wvalid,
     input  logic wready,
     input  logic [(DATA_WIDTH/8)-1:0] wstrb,
     input  logic wlast,
     input  logic bvalid,
     input  logic bready,

     output logic [63:0] total_cycles,
     output logic [63:0] executor_cycles,
     output logic [63:0] pool_cycles,
     output logic [63:0] ar_transactions,
     output logic [63:0] r_beats,
     output logic [63:0] aw_transactions,
     output logic [63:0] w_beats,
     output logic [63:0] written_bytes,
     output logic [63:0] ar_stall_cycles,
     output logic [63:0] r_wait_cycles,
     output logic [63:0] aw_stall_cycles,
     output logic [63:0] w_stall_cycles,
     output logic [63:0] b_wait_cycles,

     output logic layer_done_pulse,
     output logic [31:0] completed_layer_index,
     output logic [7:0] completed_layer_opcode,
     output logic [63:0] completed_layer_cycles,
     output logic [63:0] completed_layer_executor_cycles,
     output logic [63:0] completed_layer_pool_cycles,
     output logic [63:0] completed_layer_ar,
     output logic [63:0] completed_layer_r_beats,
     output logic [63:0] completed_layer_aw,
     output logic [63:0] completed_layer_w_beats
 );

     logic running_q;
     logic layer_active_q;
     logic read_outstanding_q;
     logic b_pending_q;
     logic [31:0] layer_index_q;
     logic [7:0] active_opcode_q;

     logic [63:0] layer_cycles_q;
     logic [63:0] layer_executor_cycles_q;
     logic [63:0] layer_pool_cycles_q;
     logic [63:0] layer_ar_q;
     logic [63:0] layer_r_q;
     logic [63:0] layer_aw_q;
     logic [63:0] layer_w_q;

     logic ar_fire;
     logic r_fire;
     logic aw_fire;
     logic w_fire;
     logic b_fire;

     assign ar_fire = arvalid && arready;
     assign r_fire  = rvalid && rready;
     assign aw_fire = awvalid && awready;
     assign w_fire  = wvalid && wready;
     assign b_fire  = bvalid && bready;

     always_ff @(posedge clk) begin
         if (reset) begin
             running_q <= 1'b0;
             layer_active_q <= 1'b0;
             read_outstanding_q <= 1'b0;
             b_pending_q <= 1'b0;
             layer_index_q <= '0;
             active_opcode_q <= '0;

             total_cycles <= '0;
             executor_cycles <= '0;
             pool_cycles <= '0;
             ar_transactions <= '0;
             r_beats <= '0;
             aw_transactions <= '0;
             w_beats <= '0;
             written_bytes <= '0;
             ar_stall_cycles <= '0;
             r_wait_cycles <= '0;
             aw_stall_cycles <= '0;
             w_stall_cycles <= '0;
             b_wait_cycles <= '0;

             layer_cycles_q <= '0;
             layer_executor_cycles_q <= '0;
             layer_pool_cycles_q <= '0;
             layer_ar_q <= '0;
             layer_r_q <= '0;
             layer_aw_q <= '0;
             layer_w_q <= '0;

             layer_done_pulse <= 1'b0;
             completed_layer_index <= '0;
             completed_layer_opcode <= '0;
             completed_layer_cycles <= '0;
             completed_layer_executor_cycles <= '0;
             completed_layer_pool_cycles <= '0;
             completed_layer_ar <= '0;
             completed_layer_r_beats <= '0;
             completed_layer_aw <= '0;
             completed_layer_w_beats <= '0;
         end else begin
             layer_done_pulse <= 1'b0;

             // An accepted fresh run resets every statistic without
             // requiring an extra system reset.
             if (run_start) begin
                 running_q <= 1'b1;
                 layer_active_q <= 1'b0;
                 read_outstanding_q <= 1'b0;
                 b_pending_q <= 1'b0;
                 layer_index_q <= '0;
                 active_opcode_q <= '0;
                 total_cycles <= '0;
                 executor_cycles <= '0;
                 pool_cycles <= '0;
                 ar_transactions <= '0;
                 r_beats <= '0;
                 aw_transactions <= '0;
                 w_beats <= '0;
                 written_bytes <= '0;
                 ar_stall_cycles <= '0;
                 r_wait_cycles <= '0;
                 aw_stall_cycles <= '0;
                 w_stall_cycles <= '0;
                 b_wait_cycles <= '0;
                 layer_cycles_q <= '0;
                 layer_executor_cycles_q <= '0;
                 layer_pool_cycles_q <= '0;
                 layer_ar_q <= '0;
                 layer_r_q <= '0;
                 layer_aw_q <= '0;
                 layer_w_q <= '0;
                 completed_layer_index <= '0;
                 completed_layer_opcode <= '0;
                 completed_layer_cycles <= '0;
                 completed_layer_executor_cycles <= '0;
                 completed_layer_pool_cycles <= '0;
                 completed_layer_ar <= '0;
                 completed_layer_r_beats <= '0;
                 completed_layer_aw <= '0;
                 completed_layer_w_beats <= '0;
             end else begin
                 if (running_q) begin
                     total_cycles <= total_cycles + 64'd1;
                     if (executor_busy)
                         executor_cycles <= executor_cycles + 64'd1;
                     if (pool_busy)
                         pool_cycles <= pool_cycles + 64'd1;
                     if (ar_fire)
                         ar_transactions <= ar_transactions + 64'd1;
                     if (r_fire)
                         r_beats <= r_beats + 64'd1;
                     if (aw_fire)
                         aw_transactions <= aw_transactions + 64'd1;
                     if (w_fire) begin
                         w_beats <= w_beats + 64'd1;
                         written_bytes <= written_bytes + 64'($countones(wstrb));
                     end
                     if (arvalid && !arready)
                         ar_stall_cycles <= ar_stall_cycles + 64'd1;
                     if (read_outstanding_q && rready && !rvalid)
                         r_wait_cycles <= r_wait_cycles + 64'd1;
                     if (awvalid && !awready)
                         aw_stall_cycles <= aw_stall_cycles + 64'd1;
                     if (wvalid && !wready)
                         w_stall_cycles <= w_stall_cycles + 64'd1;
                     if (b_pending_q && !bvalid)
                         b_wait_cycles <= b_wait_cycles + 64'd1;
                 end

                 // The test system permits one outstanding external read.
                 if (ar_fire)
                     read_outstanding_q <= 1'b1;
                 if (r_fire && rlast)
                     read_outstanding_q <= 1'b0;
                 if (w_fire && wlast)
                     b_pending_q <= 1'b1;
                 if (b_fire)
                     b_pending_q <= 1'b0;

                 if (layer_start) begin
                     layer_active_q <= 1'b1;
                     active_opcode_q <= layer_opcode;
                     layer_cycles_q <= '0;
                     layer_executor_cycles_q <= '0;
                     layer_pool_cycles_q <= '0;
                     layer_ar_q <= '0;
                     layer_r_q <= '0;
                     layer_aw_q <= '0;
                     layer_w_q <= '0;
                 end else if (layer_active_q) begin
                     layer_cycles_q <= layer_cycles_q + 64'd1;
                     if (executor_busy)
                         layer_executor_cycles_q <= layer_executor_cycles_q + 64'd1;
                     if (pool_busy)
                         layer_pool_cycles_q <= layer_pool_cycles_q + 64'd1;
                     if (ar_fire)
                         layer_ar_q <= layer_ar_q + 64'd1;
                     if (r_fire)
                         layer_r_q <= layer_r_q + 64'd1;
                     if (aw_fire)
                         layer_aw_q <= layer_aw_q + 64'd1;
                     if (w_fire)
                         layer_w_q <= layer_w_q + 64'd1;
                 end

                 if (layer_done && layer_active_q) begin
                     layer_active_q <= 1'b0;
                     layer_done_pulse <= 1'b1;
                     completed_layer_index <= layer_index_q;
                     completed_layer_opcode <= active_opcode_q;
                     completed_layer_cycles <= layer_cycles_q + 64'd1;
                     completed_layer_executor_cycles <= layer_executor_cycles_q + 64'(executor_busy);
                     completed_layer_pool_cycles <= layer_pool_cycles_q + 64'(pool_busy);
                     completed_layer_ar <= layer_ar_q + 64'(ar_fire);
                     completed_layer_r_beats <= layer_r_q + 64'(r_fire);
                     completed_layer_aw <= layer_aw_q + 64'(aw_fire);
                     completed_layer_w_beats <= layer_w_q + 64'(w_fire);
                     layer_index_q <= layer_index_q + 32'd1;
                 end

                 if (run_done)
                     running_q <= 1'b0;
             end
         end
     end

     initial begin
         if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0)
             $fatal(1, "npu_perf_monitor DATA_WIDTH must be byte-aligned");
     end
 endmodule
