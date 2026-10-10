
#!/usr/bin/env python3
"""Enable existing NPU performance counters in ResNet-8 TB.

Modifies only sim/tb/resnet8_npu_tb.sv.
Requires the existing NPU_PERF_ENABLE interface.
Safe to run repeatedly: already modified files are rejected.
"""

from pathlib import Path
import ast

TB = Path("sim/tb/resnet8_npu_tb.sv")

src = TB.read_text()

if "PERF_LAYER," in src:
    raise SystemExit(
        "Performance instrumentation already present. "
        "No changes made."
    )

ports = [
    "total_cycles",
    "executor_cycles",
    "pool_cycles",
    "ar_transactions",
    "r_beats",
    "aw_transactions",
    "w_beats",
    "written_bytes",
    "ar_stall_cycles",
    "r_wait_cycles",
    "aw_stall_cycles",
    "w_stall_cycles",
    "b_wait_cycles",
    "layer_done_pulse",
    "completed_layer_index",
    "completed_layer_opcode",
    "completed_layer_cycles",
    "completed_layer_executor_cycles",
    "completed_layer_pool_cycles",
    "completed_layer_ar",
    "completed_layer_r_beats",
    "completed_layer_aw",
    "completed_layer_w_beats",
]

single_bit = {"layer_done_pulse"}
bits32 = {"completed_layer_index"}
bits8 = {"completed_layer_opcode"}

decls = []
connections = []

for name in ports:
    width = (
        ""
        if name in single_bit
        else "[31:0]"
        if name in bits32
        else "[7:0]"
        if name in bits8
        else "[63:0]"
    )

    decls.append(
        f"    logic {width} p_{name};"
    )

    connections.append(
        f"        .perf_{name}(p_{name})"
    )

declaration_block = (
    "\n`ifdef NPU_PERF_ENABLE\n"
    + "\n".join(decls)
    + "\n`endif\n"
)

port_block = (
    ",\n`ifdef NPU_PERF_ENABLE\n"
    + ",\n".join(connections)
    + "\n`endif\n"
)

# Existing last port in npu_top instantiation.
old_connection = (
    "        .m_axi_bvalid(bvalid), .m_axi_bready(bready)\n"
    "    );"
)

new_connection = (
    "        .m_axi_bvalid(bvalid), .m_axi_bready(bready)"
    + port_block
    + "    );"
)

if src.count(old_connection) != 1:
    raise SystemExit(
        "Unexpected DUT port layout. "
        "No changes made."
    )

# Insert performance declarations before DUT instance.
dut_anchor = "    npu_top u_dut ("

if src.count(dut_anchor) != 1:
    raise SystemExit(
        "Unexpected DUT instantiation. "
        "No changes made."
    )

# Read every connected performance signal in reporting logic.
# This avoids unused-signal warnings under Verilator -Wall.
report_block = """
`ifdef NPU_PERF_ENABLE

    // Completed-layer values are registered by npu_perf_monitor.
    // Observe at falling edge, after nonblocking assignments.
    always @(negedge clk) begin
        if (!reset && p_layer_done_pulse) begin
            $display(
                "PERF_LAYER,index=%0d,opcode=%0d,cycles=%0d,"
                "executor=%0d,pool=%0d,ar=%0d,read_beats=%0d,"
                "aw=%0d,write_beats=%0d",
                p_completed_layer_index,
                p_completed_layer_opcode,
                p_completed_layer_cycles,
                p_completed_layer_executor_cycles,
                p_completed_layer_pool_cycles,
                p_completed_layer_ar,
                p_completed_layer_r_beats,
                p_completed_layer_aw,
                p_completed_layer_w_beats
            );
        end
    end

`endif
"""

# Add performance readout before original logits loop.
report_at_end = """
`ifdef NPU_PERF_ENABLE

        $display(
            "PERF_TOTAL,cycles=%0d,executor=%0d,pool=%0d,"
            "ar=%0d,read_beats=%0d,aw=%0d,write_beats=%0d,"
            "written_bytes=%0d",
            p_total_cycles,
            p_executor_cycles,
            p_pool_cycles,
            p_ar_transactions,
            p_r_beats,
            p_aw_transactions,
            p_w_beats,
            p_written_bytes
        );

        $display(
            "PERF_WAIT,ar_stall=%0d,r_wait=%0d,"
            "aw_stall=%0d,w_stall=%0d,b_wait=%0d",
            p_ar_stall_cycles,
            p_r_wait_cycles,
            p_aw_stall_cycles,
            p_w_stall_cycles,
            p_b_wait_cycles
        );

        if (p_r_beats != 64'(reads_q))
            $fatal(
                1,
                "Read counter mismatch: monitor=%0d TB=%0d",
                p_r_beats, reads_q
            );

        if (p_w_beats != 64'(writes_q))
            $fatal(
                1,
                "Write counter mismatch: monitor=%0d TB=%0d",
                p_w_beats, writes_q
            );

        $display("PERF_COUNTER_CHECK,PASS");

`endif
"""

end_anchor = "        best = -129;"

if src.count(end_anchor) != 1:
    raise SystemExit(
        "Unexpected inference completion section. "
        "No changes made."
    )

updated = src.replace(
    dut_anchor,
    declaration_block + "\n" + dut_anchor
)

updated = updated.replace(
    old_connection, new_connection
)

# Ensure comma placement is valid in either macro mode.
# The comma belongs inside the enabled block.
updated = updated.replace(
    ".m_axi_bready(bready),\n`ifdef NPU_PERF_ENABLE",
    ".m_axi_bready(bready)\n`ifdef NPU_PERF_ENABLE\n        ,"
)
updated = updated.replace(
    ".m_axi_bready(bready),\n`endif",
    ".m_axi_bready(bready)\n`endif"
)

updated = updated.replace(
    end_anchor,
    report_at_end + "\n" + end_anchor
)

# The monitor block is inserted ahead of the run initial block.
run_anchor = "    initial begin : run"

if updated.count(run_anchor) != 1:
    raise SystemExit(
        "Cannot locate run block. No changes made."
    )

updated = updated.replace(
    run_anchor,
    report_block + "\n" + run_anchor
)

TB.write_text(updated)

print("Updated:", TB)
print("Connected performance outputs:", len(ports))
print("Original functional test preserved.")
