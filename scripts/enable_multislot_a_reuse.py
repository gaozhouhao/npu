
#!/usr/bin/env python3
"""Enable four-slot C SRAM and multi-K A-tile reuse.

Run from any directory:
    python3 scripts/enable_multislot_a_reuse.py

Requires the updated rtl/core/tile_policy.sv.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

SCHED = ROOT / "rtl/core/tile_scheduler.sv"
EXEC = ROOT / "rtl/core/gemm_executor.sv"
POLICY = ROOT / "rtl/core/tile_policy.sv"


def replace_exact(src, before, after, label, expected=1):
    count = src.count(before)
    if count != expected:
        raise RuntimeError(
            f"{label}: expected {expected} occurrence(s), got {count}"
        )
    return src.replace(before, after)


def modify_scheduler(src):
    src = replace_exact(
        src,
        """    parameter int unsigned K_SIZE_WIDTH     = $clog2(K_TILE_SIZE + 1)
""",
        """    parameter int unsigned K_SIZE_WIDTH     = $clog2(K_TILE_SIZE + 1),
    parameter bit ENABLE_MULTI_K_A_REUSE = 1'b0,
    parameter int unsigned A_REUSE_BLOCK_SIZE = 4
""",
        "Scheduler parameters",
    )

    src = replace_exact(
        src,
        """    tile_policy #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH)
    ) u_tile_policy (""",
        """    tile_policy #(
        .TILE_COUNT_WIDTH      (TILE_COUNT_WIDTH),
        .ENABLE_MULTI_K_A_REUSE (ENABLE_MULTI_K_A_REUSE),
        .A_REUSE_BLOCK_SIZE    (A_REUSE_BLOCK_SIZE)
    ) u_tile_policy (""",
        "Scheduler policy instance",
    )

    return src


def modify_executor(src):
    # ----------------------------------------------------------
    # Compile-time configuration.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        """    localparam int unsigned BIAS_TILE_BYTES = COLS * BIAS_BYTES;
""",
        """    localparam int unsigned BIAS_TILE_BYTES = COLS * BIAS_BYTES;

    // Four physical C slots: 4 x 4 x INT32 x 4 = 256 bytes.
    localparam int unsigned PSUM_SLOT_COUNT = 4;
    localparam int unsigned PSUM_SLOT_WIDTH =
        $clog2(PSUM_SLOT_COUNT);

    // Select 1, 2, 3 or 4 outputs per N block.
`ifdef NPU_PSUM_BLOCK_SIZE
    localparam int unsigned PSUM_BLOCK_SIZE =
        `NPU_PSUM_BLOCK_SIZE;
`else
    localparam int unsigned PSUM_BLOCK_SIZE = 4;
`endif

    // A-reuse requires the C SRAM partial-sum path.
`ifdef NPU_PSUM_EXPERIMENT
`ifdef NPU_AS_REUSE_EXPERIMENT
    localparam bit ENABLE_MULTI_K_A_REUSE = 1'b1;
`else
    localparam bit ENABLE_MULTI_K_A_REUSE = 1'b0;
`endif
`else
    localparam bit ENABLE_MULTI_K_A_REUSE = 1'b0;
`endif
""",
        "Executor configuration",
    )

    # ----------------------------------------------------------
    # Scheduler uses the selected block size.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        """    tile_scheduler #(
        .TILE_COUNT_WIDTH (TILE_COUNT_WIDTH),
        .K_TILE_SIZE      (K_TILE_SIZE),
        .K_SIZE_WIDTH     (K_SIZE_WIDTH)
    ) u_tile_scheduler (""",
        """    tile_scheduler #(
        .TILE_COUNT_WIDTH      (TILE_COUNT_WIDTH),
        .K_TILE_SIZE           (K_TILE_SIZE),
        .K_SIZE_WIDTH          (K_SIZE_WIDTH),
        .ENABLE_MULTI_K_A_REUSE (ENABLE_MULTI_K_A_REUSE),
        .A_REUSE_BLOCK_SIZE    (PSUM_BLOCK_SIZE)
    ) u_tile_scheduler (""",
        "Executor scheduler instance",
    )

    # ----------------------------------------------------------
    # Replace fixed one-bit slot addresses.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        "    logic [0:0] psum_rd_slot;",
        """    logic [PSUM_SLOT_WIDTH-1:0] psum_rd_slot;""",
        "PSUM read slot width",
    )

    src = replace_exact(
        src,
        "    logic [0:0] psum_wr_slot;",
        """    logic [PSUM_SLOT_WIDTH-1:0] psum_wr_slot;""",
        "PSUM write slot width",
    )

    src = replace_exact(
        src,
        "    logic psum_sram_rd_en;",
        """    logic psum_sram_rd_en;
    logic [PSUM_SLOT_WIDTH-1:0] psum_sram_rd_slot;
    logic [PSUM_SLOT_WIDTH-1:0] psum_target_slot;
    logic use_multi_k_a_reuse;""",
        "PSUM slot declarations",
    )

    # ----------------------------------------------------------
    # Multi-K A reuse is activated only for N>1 and B>1.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        """    assign psum_start =
        use_psum_path && core_done;""",
        """    assign use_multi_k_a_reuse =
        ENABLE_MULTI_K_A_REUSE &&
        (PSUM_BLOCK_SIZE > 1) &&
        (k_tile_count_q > TILE_COUNT_WIDTH'(1)) &&
        (n_tile_count_q > TILE_COUNT_WIDTH'(1));

    assign psum_start =
        use_psum_path && core_done;""",
        "A-reuse activation",
    )

    # ----------------------------------------------------------
    # Both modules now have four physical slots.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        ".PSUM_SLOTS (1)",
        ".PSUM_SLOTS (PSUM_SLOT_COUNT)",
        "PSUM engine and SRAM capacity",
        expected=2,
    )

    # ----------------------------------------------------------
    # Select slot by N within the current block.
    #
    # E.g. B=4: N0..N3 -> slots 0..3
    #           N4..N7 -> slots 0..3 after previous
    #                       block was fully written back.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        "        .slot             (1'b0),",
        "        .slot             (psum_target_slot),",
        "PSUM engine slot input",
    )

    src = replace_exact(
        src,
        """    assign psum_sram_rd_en =
""",
        """    assign psum_target_slot =
        PSUM_SLOT_WIDTH'(
            compute_n_tile_idx %
            TILE_COUNT_WIDTH'(PSUM_BLOCK_SIZE)
        );

    // During read-modify-write, select the engine's slot.
    // During final DDR writeback, select the output slot.
    assign psum_sram_rd_slot =
        psum_rd_en ? psum_rd_slot : psum_target_slot;

    assign psum_sram_rd_en =
""",
        "PSUM slot address mapping",
    )

    src = replace_exact(
        src,
        "        .rd_slot   (psum_rd_slot),",
        "        .rd_slot   (psum_sram_rd_slot),",
        "PSUM shared SRAM read slot",
    )

    # ----------------------------------------------------------
    # Bias correctness under K-outer traversal.
    #
    # Legacy:
    #   Request Bias when a new output tile starts (K=0).
    #
    # Multi-K A reuse:
    #   Request Bias at the final K of each N.
    #
    # Otherwise the Bias values for N0 may be overwritten
    # while K0 of N1/N2 is being processed.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        """                scheduler_clear_acc &&
                bias_en_q
""",
        """                (
                    use_multi_k_a_reuse
                        ? scheduler_writeback_en
                        : scheduler_clear_acc
                ) &&
                bias_en_q
""",
        "Bias loading timing",
    )

    # ----------------------------------------------------------
    # Parameter validation.
    # ----------------------------------------------------------

    src = replace_exact(
        src,
        """    initial begin

        if (ADDR_WIDTH < 12)""",
        """    initial begin

        if (
            (PSUM_BLOCK_SIZE < 1) ||
            (PSUM_BLOCK_SIZE > PSUM_SLOT_COUNT)
        )
            $fatal(1, "PSUM_BLOCK_SIZE must be 1..4");

        if (ADDR_WIDTH < 12)""",
        "PSUM block parameter checks",
    )

    return src


def main():
    if not SCHED.exists() or not EXEC.exists():
        raise RuntimeError("Expected NPU RTL files are missing")

    if not POLICY.exists():
        raise RuntimeError("Missing tile_policy.sv")

    policy = POLICY.read_text()
    if "ENABLE_MULTI_K_A_REUSE" not in policy:
        raise RuntimeError(
            "Replace tile_policy.sv with the new complete version first"
        )

    scheduler_old = SCHED.read_text()
    executor_old = EXEC.read_text()

    if (
        "A_REUSE_BLOCK_SIZE" in scheduler_old or
        "PSUM_SLOT_COUNT" in executor_old
    ):
        raise RuntimeError(
            "Multi-slot integration appears to be already applied"
        )

    # Perform all replacements in memory first.
    scheduler_new = modify_scheduler(scheduler_old)
    executor_new = modify_executor(executor_old)

    backup_dir = ROOT / "build/backup/multislot"
    backup_dir.mkdir(parents=True, exist_ok=True)

    (backup_dir / "tile_scheduler.sv").write_text(
        scheduler_old
    )
    (backup_dir / "gemm_executor.sv").write_text(
        executor_old
    )

    # Write full updated RTL files.
    SCHED.write_text(scheduler_new)
    EXEC.write_text(executor_new)

    print("Multi-slot A reuse integration completed.")
    print("Physical C slots: 4")
    print("Default N block size: 4")
    print("Modified:")
    print(f"  {SCHED}")
    print(f"  {EXEC}")
    print(f"Backups: {backup_dir}")
    print()
    print("Enable with:")
    print("  -DNPU_PSUM_EXPERIMENT")
    print("  -DNPU_AS_REUSE_EXPERIMENT")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
