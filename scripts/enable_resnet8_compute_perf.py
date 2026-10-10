
#!/usr/bin/env python3
"""Install a non-intrusive compute performance probe.

Only modifies sim/tb/resnet8_npu_tb.sv.
Does not modify synthesizable RTL.
Requires NPU_PERF_ENABLE and the existing 4x4 hierarchy.
"""

from pathlib import Path

path = Path("sim/tb/resnet8_npu_tb.sv")
source = path.read_text()

marker = "// RESNET8_COMPUTE_PERF_PROBE"

if marker in source:
    raise SystemExit(
        "Compute performance probe is already installed."
    )

if "PERF_COUNTER_CHECK,PASS" not in source:
    raise SystemExit(
        "Install the previous performance monitor first."
    )

anchor = "    initial begin : run"

if source.count(anchor) != 1:
    raise SystemExit(
        "Cannot locate the testbench run block."
    )

probe = r'''
`ifdef NPU_PERF_ENABLE

    // RESNET8_COMPUTE_PERF_PROBE
    //
    // Non-intrusive observation of the actual 4x4 PE array.
    // Counts MAC operations when both PE operands are valid
    // and the accumulator is not being cleared.
    //
    // Executed MACs are not necessarily useful model MACs:
    // padded and boundary computations may be included.

    logic [15:0] perf_pe_fire;
    logic [4:0] perf_mac_fires_now;

    logic perf_compute_running;
    logic perf_compute_layer_active;

    logic [63:0] perf_mac_total;
    logic [63:0] perf_mac_layer;
    logic [63:0] perf_mac_layer_sum;

    logic [63:0] perf_active_cycles_total;
    logic [63:0] perf_active_cycles_layer;

    logic [63:0] perf_tile_starts_total;
    logic [63:0] perf_tile_dones_total;
    logic [63:0] perf_tile_starts_layer;
    logic [63:0] perf_tile_dones_layer;

    logic [63:0] perf_mac_capacity_total;

    // Observe the same valid operands as the actual PEs.
    for (genvar r = 0; r < 4; r++) begin : gen_perf_row
        for (genvar c = 0; c < 4; c++) begin : gen_perf_col

            assign perf_pe_fire[r*4+c] =
                !reset &&
                !u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.clear &&
                u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.a_valid_wire[r][c] &&
                u_dut.u_gemm_executor.u_gemm_core
                    .u_matrix_engine.u_array.b_valid_wire[r][c];

        end
    end

    always_comb begin
        perf_mac_fires_now = '0;

        for (int j = 0; j < 16; j++) begin
            perf_mac_fires_now =
                perf_mac_fires_now + 5'(perf_pe_fire[j]);
        end
    end

    // Sample events on the clock edge where MACs execute.
    always @(posedge clk) begin
        if (reset) begin
            perf_compute_running <= 1'b0;
            perf_compute_layer_active <= 1'b0;

            perf_mac_total <= '0;
            perf_mac_layer <= '0;
            perf_mac_layer_sum <= '0;

            perf_active_cycles_total <= '0;
            perf_active_cycles_layer <= '0;

            perf_tile_starts_total <= '0;
            perf_tile_dones_total <= '0;
            perf_tile_starts_layer <= '0;
            perf_tile_dones_layer <= '0;

            perf_mac_capacity_total <= '0;

        end else if (start && !busy) begin
            perf_compute_running <= 1'b1;
            perf_compute_layer_active <= 1'b0;

            perf_mac_total <= '0;
            perf_mac_layer <= '0;
            perf_mac_layer_sum <= '0;

            perf_active_cycles_total <= '0;
            perf_active_cycles_layer <= '0;

            perf_tile_starts_total <= '0;
            perf_tile_dones_total <= '0;
            perf_tile_starts_layer <= '0;
            perf_tile_dones_layer <= '0;

            perf_mac_capacity_total <= '0;

        end else begin

            if (perf_compute_running) begin
                perf_mac_total <=
                    perf_mac_total + 64'(perf_mac_fires_now);

                perf_mac_capacity_total <=
                    perf_mac_capacity_total + 64'd16;

                if (perf_mac_fires_now != 5'd0)
                    perf_active_cycles_total <=
                        perf_active_cycles_total + 64'd1;

                if (u_dut.u_gemm_executor.scheduler_matrix_start)
                    perf_tile_starts_total <=
                        perf_tile_starts_total + 64'd1;

                if (u_dut.u_gemm_executor.core_done)
                    perf_tile_dones_total <=
                        perf_tile_dones_total + 64'd1;
            end

            if (u_dut.perf_layer_start) begin
                perf_compute_layer_active <= 1'b1;

                perf_mac_layer <= '0;
                perf_active_cycles_layer <= '0;
                perf_tile_starts_layer <= '0;
                perf_tile_dones_layer <= '0;

            end else if (perf_compute_layer_active) begin

                perf_mac_layer <=
                    perf_mac_layer + 64'(perf_mac_fires_now);

                if (perf_mac_fires_now != 5'd0)
                    perf_active_cycles_layer <=
                        perf_active_cycles_layer + 64'd1;

                if (u_dut.u_gemm_executor.scheduler_matrix_start)
                    perf_tile_starts_layer <=
                        perf_tile_starts_layer + 64'd1;

                if (u_dut.u_gemm_executor.core_done)
                    perf_tile_dones_layer <=
                        perf_tile_dones_layer + 64'd1;

            end

            if (u_dut.perf_layer_done &&
                perf_compute_layer_active) begin

                perf_compute_layer_active <= 1'b0;

                perf_mac_layer_sum <=
                    perf_mac_layer_sum +
                    perf_mac_layer +
                    64'(perf_mac_fires_now);
            end

            if (done)
                perf_compute_running <= 1'b0;

        end
    end

    // Existing layer performance monitor publishes this
    // pulse after the clock edge. Observe it at negedge.
    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin

            $display(
                "PERF_COMPUTE_LAYER,index=%0d,mac=%0d,active_cycles=%0d,tile_starts=%0d,tile_dones=%0d",
                p_completed_layer_index,
                perf_mac_layer,
                perf_active_cycles_layer,
                perf_tile_starts_layer,
                perf_tile_dones_layer
            );

        end
    end

`endif
'''

report = r'''
`ifdef NPU_PERF_ENABLE
        $display(
            "PERF_COMPUTE_TOTAL,mac=%0d,active_cycles=%0d,tile_starts=%0d,tile_dones=%0d,capacity=%0d,layer_mac_sum=%0d",
            perf_mac_total,
            perf_active_cycles_total,
            perf_tile_starts_total,
            perf_tile_dones_total,
            perf_mac_capacity_total,
            perf_mac_layer_sum
        );

        if (perf_mac_total != perf_mac_layer_sum)
            $fatal(
                1,
                "Compute MAC layer sum mismatch: total=%0d layers=%0d",
                perf_mac_total, perf_mac_layer_sum
            );

        if (perf_tile_starts_total != perf_tile_dones_total)
            $fatal(
                1,
                "Matrix tile start/done mismatch: %0d/%0d",
                perf_tile_starts_total,
                perf_tile_dones_total
            );

        if (perf_mac_total > perf_mac_capacity_total)
            $fatal(
                1,
                "PE MAC count exceeds array capacity"
            );

        $display("PERF_COMPUTE_CHECK,PASS");
`endif
'''

report_anchor = "        best = -129;"

if source.count(report_anchor) != 1:
    raise SystemExit(
        "Cannot locate final results section."
    )

updated = source.replace(
    anchor,
    probe + "\n" + anchor
)

updated = updated.replace(
    report_anchor,
    report + "\n" + report_anchor
)

path.write_text(updated)

print("Installed compute performance probe.")
print("Modified:", path)
print("Synthesizable RTL unchanged.")
