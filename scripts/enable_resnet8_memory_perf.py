
#!/usr/bin/env python3
"""Add memory/compute overlap profiling to the ResNet-8 TB.

Testbench-only instrumentation. No synthesizable RTL changes.
"""

from pathlib import Path

path = Path("sim/tb/resnet8_npu_tb.sv")
src = path.read_text()

marker = "// RESNET8_MEMORY_PERF_PROBE"

if marker in src:
    raise SystemExit("Memory probe already installed.")

if "// RESNET8_COMPUTE_PERF_PROBE" not in src:
    raise SystemExit("Install compute performance probe first.")

run_anchor = "    initial begin : run"
report_anchor = "        best = -129;"

if src.count(run_anchor) != 1:
    raise SystemExit("Cannot locate run block.")

if src.count(report_anchor) != 1:
    raise SystemExit("Cannot locate report location.")

probe = r'''
`ifdef NPU_PERF_ENABLE

    // RESNET8_MEMORY_PERF_PROBE
    //
    // Observe resource-level activity.
    // These counters do not depend on external clock frequency.

    logic mem_running_q;
    logic mem_layer_active_q;

    logic [63:0] mem_core_cycles;
    logic [63:0] mem_dma_cycles;
    logic [63:0] mem_overlap_cycles;
    logic [63:0] mem_axi_overlap_beats;

    logic [63:0] mem_a_compute_wait;
    logic [63:0] mem_b_compute_wait;
    logic [63:0] mem_a_load_wait;
    logic [63:0] mem_b_load_wait;

    logic [63:0] mem_layer_core;
    logic [63:0] mem_layer_dma;
    logic [63:0] mem_layer_overlap;
    logic [63:0] mem_layer_axi_overlap;
    logic [63:0] mem_layer_a_compute_wait;
    logic [63:0] mem_layer_b_compute_wait;
    logic [63:0] mem_layer_a_load_wait;
    logic [63:0] mem_layer_b_load_wait;

    logic [63:0] mem_layer_core_sum;
    logic [63:0] mem_layer_dma_sum;
    logic [63:0] mem_layer_overlap_sum;

    wire mem_core_event =
        u_dut.u_gemm_executor.core_busy;

    wire mem_dma_event =
        u_dut.u_gemm_executor.read_path_busy;

    wire mem_overlap_event =
        mem_core_event && mem_dma_event;

    wire mem_axi_overlap_event =
        mem_core_event && rvalid && rready;

    wire mem_a_compute_wait_event =
        u_dut.u_gemm_executor.scheduler_a_compute_req &&
        !u_dut.u_gemm_executor.scheduler_a_compute_grant;

    wire mem_b_compute_wait_event =
        u_dut.u_gemm_executor.scheduler_b_compute_req &&
        !u_dut.u_gemm_executor.scheduler_b_compute_grant;

    wire mem_a_load_wait_event =
        u_dut.u_gemm_executor.a_bank_load_req &&
        !u_dut.u_gemm_executor.a_bank_load_grant;

    wire mem_b_load_wait_event =
        u_dut.u_gemm_executor.b_bank_load_req &&
        !u_dut.u_gemm_executor.b_bank_load_grant;

    always @(posedge clk) begin
        if (reset) begin
            mem_running_q <= 1'b0;
            mem_layer_active_q <= 1'b0;

            mem_core_cycles <= '0;
            mem_dma_cycles <= '0;
            mem_overlap_cycles <= '0;
            mem_axi_overlap_beats <= '0;

            mem_a_compute_wait <= '0;
            mem_b_compute_wait <= '0;
            mem_a_load_wait <= '0;
            mem_b_load_wait <= '0;

            mem_layer_core <= '0;
            mem_layer_dma <= '0;
            mem_layer_overlap <= '0;
            mem_layer_axi_overlap <= '0;
            mem_layer_a_compute_wait <= '0;
            mem_layer_b_compute_wait <= '0;
            mem_layer_a_load_wait <= '0;
            mem_layer_b_load_wait <= '0;

            mem_layer_core_sum <= '0;
            mem_layer_dma_sum <= '0;
            mem_layer_overlap_sum <= '0;

        end else if (start && !busy) begin
            mem_running_q <= 1'b1;
            mem_layer_active_q <= 1'b0;

            mem_core_cycles <= '0;
            mem_dma_cycles <= '0;
            mem_overlap_cycles <= '0;
            mem_axi_overlap_beats <= '0;

            mem_a_compute_wait <= '0;
            mem_b_compute_wait <= '0;
            mem_a_load_wait <= '0;
            mem_b_load_wait <= '0;

            mem_layer_core <= '0;
            mem_layer_dma <= '0;
            mem_layer_overlap <= '0;
            mem_layer_axi_overlap <= '0;
            mem_layer_a_compute_wait <= '0;
            mem_layer_b_compute_wait <= '0;
            mem_layer_a_load_wait <= '0;
            mem_layer_b_load_wait <= '0;

            mem_layer_core_sum <= '0;
            mem_layer_dma_sum <= '0;
            mem_layer_overlap_sum <= '0;

        end else begin

            if (mem_running_q) begin
                mem_core_cycles <=
                    mem_core_cycles + 64'(mem_core_event);

                mem_dma_cycles <=
                    mem_dma_cycles + 64'(mem_dma_event);

                mem_overlap_cycles <=
                    mem_overlap_cycles + 64'(mem_overlap_event);

                mem_axi_overlap_beats <=
                    mem_axi_overlap_beats +
                    64'(mem_axi_overlap_event);

                mem_a_compute_wait <=
                    mem_a_compute_wait +
                    64'(mem_a_compute_wait_event);

                mem_b_compute_wait <=
                    mem_b_compute_wait +
                    64'(mem_b_compute_wait_event);

                mem_a_load_wait <=
                    mem_a_load_wait +
                    64'(mem_a_load_wait_event);

                mem_b_load_wait <=
                    mem_b_load_wait +
                    64'(mem_b_load_wait_event);
            end

            if (u_dut.perf_layer_start) begin
                mem_layer_active_q <= 1'b1;

                mem_layer_core <= '0;
                mem_layer_dma <= '0;
                mem_layer_overlap <= '0;
                mem_layer_axi_overlap <= '0;

                mem_layer_a_compute_wait <= '0;
                mem_layer_b_compute_wait <= '0;
                mem_layer_a_load_wait <= '0;
                mem_layer_b_load_wait <= '0;

            end else if (mem_layer_active_q) begin

                mem_layer_core <=
                    mem_layer_core + 64'(mem_core_event);

                mem_layer_dma <=
                    mem_layer_dma + 64'(mem_dma_event);

                mem_layer_overlap <=
                    mem_layer_overlap + 64'(mem_overlap_event);

                mem_layer_axi_overlap <=
                    mem_layer_axi_overlap +
                    64'(mem_axi_overlap_event);

                mem_layer_a_compute_wait <=
                    mem_layer_a_compute_wait +
                    64'(mem_a_compute_wait_event);

                mem_layer_b_compute_wait <=
                    mem_layer_b_compute_wait +
                    64'(mem_b_compute_wait_event);

                mem_layer_a_load_wait <=
                    mem_layer_a_load_wait +
                    64'(mem_a_load_wait_event);

                mem_layer_b_load_wait <=
                    mem_layer_b_load_wait +
                    64'(mem_b_load_wait_event);
            end

            if (
                u_dut.perf_layer_done &&
                mem_layer_active_q
            ) begin
                mem_layer_active_q <= 1'b0;

                mem_layer_core_sum <=
                    mem_layer_core_sum + mem_layer_core +
                    64'(mem_core_event);

                mem_layer_dma_sum <=
                    mem_layer_dma_sum + mem_layer_dma +
                    64'(mem_dma_event);

                mem_layer_overlap_sum <=
                    mem_layer_overlap_sum + mem_layer_overlap +
                    64'(mem_overlap_event);
            end

            if (done)
                mem_running_q <= 1'b0;
        end
    end

    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin
            $display(
                "PERF_MEMORY_LAYER,index=%0d,core=%0d,dma=%0d,overlap=%0d,axi_overlap=%0d,a_compute_wait=%0d,b_compute_wait=%0d,a_load_wait=%0d,b_load_wait=%0d",
                p_completed_layer_index,
                mem_layer_core,
                mem_layer_dma,
                mem_layer_overlap,
                mem_layer_axi_overlap,
                mem_layer_a_compute_wait,
                mem_layer_b_compute_wait,
                mem_layer_a_load_wait,
                mem_layer_b_load_wait
            );
        end
    end

`endif
'''

report = r'''
`ifdef NPU_PERF_ENABLE

        $display(
            "PERF_MEMORY_TOTAL,core=%0d,dma=%0d,overlap=%0d,axi_overlap=%0d,a_compute_wait=%0d,b_compute_wait=%0d,a_load_wait=%0d,b_load_wait=%0d",
            mem_core_cycles,
            mem_dma_cycles,
            mem_overlap_cycles,
            mem_axi_overlap_beats,
            mem_a_compute_wait,
            mem_b_compute_wait,
            mem_a_load_wait,
            mem_b_load_wait
        );

        if (mem_overlap_cycles > mem_core_cycles ||
            mem_overlap_cycles > mem_dma_cycles)
            $fatal(1, "Invalid DMA/compute overlap count");

        if (mem_axi_overlap_beats > p_r_beats)
            $fatal(1, "Invalid AXI overlap beats");

        if (mem_layer_core_sum != mem_core_cycles ||
            mem_layer_dma_sum != mem_dma_cycles ||
            mem_layer_overlap_sum != mem_overlap_cycles)
            $fatal(
                1,
                "Memory layer/global counter mismatch"
            );

        $display("PERF_MEMORY_CHECK,PASS");

`endif
'''

updated = src.replace(
    run_anchor, probe + "\n" + run_anchor
)

updated = updated.replace(
    report_anchor, report + "\n" + report_anchor
)

path.write_text(updated)

print("Installed memory/compute overlap probe.")
print("Modified:", path)
print("Synthesizable RTL unchanged.")
