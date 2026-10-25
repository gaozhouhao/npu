# Retired scripts — 2026-10-17

The user authorized deletion after review when an old script is broken or its
function is covered by a current entrypoint. The following five older scripts were
removed; their migrations were not executed during that review.

| Original path | Path before removal | Evidence / replacement |
|---|---|---|
| `scripts/fix_early_dma_done.py` | `scripts/archive/fix_early_dma_done.py` | The old replacement template matches zero times. Current `tile_scheduler.sv` already records A/B completion pulses in both `LD_REQ` and `LD_WAIT`. |
| `scripts/enable_multislot_a_reuse.py` | `scripts/archive/enable_multislot_a_reuse.py` | Its already-applied guard is true. Four PSUM slots, A reuse and slot-aware data paths are in current scheduler/executor RTL. |
| `scripts/integrate_psum.py` | `scripts/archive/integrate_psum.sh` | All three intended generate-block names already occur once. Reapplication only rewrites the source and its backup. |
| `scripts/run_vcs_pe.sh` | `scripts/sim/run_vcs_pe.sh` | Thin wrapper fully covered by `bash scripts/sim/run_vcs.sh pe_tb`; `make vcs-pe` now invokes it directly. |
| `scripts/run_vcs_pe_wave.sh` | `scripts/sim/run_vcs_pe_wave.sh` | Thin wrapper fully covered by `bash scripts/sim/run_vcs.sh pe_wave_tb`; `make vcs-pe-wave` now invokes it directly. |

The archive-only README was removed with the three migration scripts. Current
entrypoints have no dependency on them. Historical learning notes retain the
commands actually used at the time; use the replacements above for new runs.

## Retained tools

- `run_param_slot_stress.sh` tests baseline, PSUM and A-reuse configurations; it
  is not covered by the focused VCS cleanup regression.
- `run_resnet8.sh` and `run_resnet8_perf.sh` provide different build modes,
  optimization steps and output directories.
- `report_npu_perf_detail.py` consumes the base report from
  `report_resnet8_perf.py` and adds detailed counters; it does not replace it.
- Model compilation, logits/layer/dataset verification, quantization audit and
  kernel/precision experiments have distinct purposes. Several import each
  other; `optimize_dataflow.py` is invoked by the performance flow.
- The MNIST compiler and tests in `compiler/` and the small GEMM software model
  remain separate tools.

Python 3/model packages and Verilator are unavailable in the current PATH.
That is an environment limitation, not evidence that their scripts are broken;
these model and Verilator flows were reviewed statically, not executed.

The two retained performance reports had three stale read-byte calculations.
They now use 8 bytes per external AXI64 read beat. The current ResNet testbench
requires ARSIZE=3 and increments each read address by 8; both monitor counters
count external read handshakes. Writes remain AXI32 and retain their existing
byte accounting. Historical AXI32 logs must be interpreted with the original
report version; the updated scripts target the current RTL.

This cleanup changes script entrypoints, report arithmetic and documentation.
Existing RTL, saved simulation logs, source snapshots and waveforms are retained.

## Removed teaching helpers

The user then requested scripts containing only the basic running logic. Three
helpers added during the repair have also been removed:

| Removed path | Reason / replacement |
|---|---|
| `scripts/check/check_project.py` | Its repository-wide text checks are outside the basic compile/run flow; `make check` was removed with it. |
| `scripts/check/summarize_vcs.py` | Read testbench output in `simulation.log`; the teaching flow does not need an automatic report generator. |
| `scripts/sim/clean_objects.sh` | `make clean` now contains the object/dependency cleanup command directly. |

The VCS runner now uses explicit filelists and timestamped directories for its
compiler output and logs. Source discovery, Git/hash recording, snapshots,
timeouts and automatic result parsing have been removed. Existing logs,
`cleanup_results.json`, source snapshots and waveforms remain historical records.
The parameter-slot stress script shows its three Verilator configurations as
explicit compile/run sections.

## Earlier retirement validation

Saved checks are in `build/maintenance/retire_scripts.nzBjDE/`:

- `structure.log`: `make check` passed; 71 SV files/modules and 23 active inputs,
  including syntax checks of every remaining shell script.
- `make_preview.log`: `make -n vcs-pe vcs-pe-wave vcs-regression` expands to the
  unified PE/PE-wave runner and the existing regression driver.
- `reference_check.log`: all 47 migration destinations exist; all five retired
  scripts are absent and have no active caller. Scheduler and executor source
  hashes match their pre-cleanup values.
- `diff_check.log`: `git diff --check` exited 0.

No new VCS/Verilator simulation or Python 3 report execution was performed in
that earlier retirement. Those saved checks describe the scripts present at the
time; the custom checker is now retired. Results from subsequent teaching-script
checks are recorded separately in the learning notes.
