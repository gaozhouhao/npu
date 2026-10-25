# Code repair and structure review — 2026-10-17

The user authorized repair of all findings and a consistent project layout. The
original findings are now repaired; the following records what changed and what
was actually verified. This is not a claim of full-chip verification closure.

## Repairs

| Finding | Repair | Verification |
|---|---|---|
| GEMM TB used old lane/K layout and unreachable initialization | Explicit lane/word preload, initialized banks, fatal comparisons, reference arithmetic | Original two K=3 cases plus K=1/4/5/256 and signed extremes |
| M/N tiling TB used old preload interface | Lane-major contiguous-K words, corrected address widths and bank initialization | Four output tiles and all 64 C elements |
| Controller TB used removed ports | Separate request/response monitoring and writeback-row checks | Six legal/illegal K and clear/writeback cases |
| Operand path used removed parameters/ports | Real INT8 packing and three-lane ping-pong test | Stream stalls, K=7/5, word boundaries, concurrent load/compute bank ownership |
| Operand loader unit test used removed parameters | Explicit one-element-per-word unit configuration | Original word address/stall cases; real INT8 path verified separately |
| Postprocess TB used removed output port | Explicit INT32/INT8 paths and initialized controls | Bias, saturation, ReLU and signed ties-away rounding |
| Scheduler TB used obsolete shared cursors | Separate load/compute metadata and writeback completion handshake | Remainder, single-tile and exact-K cases |
| Focused scheduler tests omitted B-stationary input | Explicit mode tie-offs and success markers | Early-completion and multi-K policy regressions |
| Scratchpad A/B lane/buffer parameters were swapped | A uses ROWS/A_BUFFER_COUNT; B uses COLS/B_BUFFER_COUNT | 2x3 A=2/B=1 and 3x2 A=1/B=2 GEMM |
| GEMM width parameters overstated hardware support | Explicit DATA_WIDTH=8/ACC_WIDTH=32 guard | Default and rectangular INT8/INT32 regressions; other widths remain unsupported |
| 1x1 array drain counter could underflow | Minimum one drain cycle | 1x1 GEMM, including full K depth |
| PE failure paths used $finish and valid remained asserted | Fatal failures, valid deassertion, hold and clear-priority checks | PE self-check and FSDB/VCD experiment |
| npu_top operand64 signals declared after first use | Move complete-width declarations before instances | Later VCS parses eliminate implicit-wire warnings; top-level regression passes |
| Executor/DMA integration tests omitted new inputs and used old buses | Explicit mode inputs; native AXI64 operands; AXI32 writes; shared memory model for executor | K=260 executor with 64 outputs and mixed-sign DMA-to-core test |
| Top-level TB expected AXI32 reads and misused always_ff for initialized memory | AXI64 responder, ordinary TB processes, physical row stride 264 for logical K=260, exact baseline request-count checks at the AXI64 boundary | Pure GEMM, Bias INT32 and Requant/ReLU INT8 results; original element-level checks retained |
| Makefile omitted live RTL dependencies | Add axi_read_32to64, conv_read_cache and c_result_buffer | Make expansion, VCS parsing and top-level execution |
| clean removed all experiment evidence | Object/dependency-only cleanup inside project-local build directory | Isolated dummy objects removed; dummy logs/waves retained |
| .gitignore duplicates | Deduplicate and add FSDB waveform pattern | Structure and diff checks |
| integrate_psum.py contained shell code | Retire the script after confirming all three generate-block names are in current RTL | Existing names each occur once; no active caller |
| One-time source migration scripts mixed with active tools | Remove the three completed migration scripts and archive-only README | Effects are present in RTL; early-done template no longer matches and multi-slot script rejects reapplication |
| PE shell wrappers duplicated the unified VCS runner | Remove both wrappers; Make targets call run_vcs.sh with the selected top | Make expansion and active-reference checks |
| Performance reports used the former AXI32 read width | Convert the three external read-byte calculations to 8 bytes per beat | Current ResNet TB requires ARSIZE=3; monitor counts external read handshakes; writes remain AXI32 |
| Script paths depended on old locations / Bash empty-array behavior | Update root/sibling references and nonempty argument arrays | Shell syntax, structural references and VCS entrypoint execution |

## Layout

The original reorganization moved 52 paths. Five scripts were subsequently retired
with user authorization; their evidence and replacements are recorded in
`docs/reference/retired_scripts.md`. The 47 remaining path migrations are recorded
in `docs/reference/path_migration.json`. Existing
RTL filenames that already match their modules retain their names. Testbenches are
grouped under unit/integration/system/support; active scripts under sim/model/analysis. VCS filelists and Verdi Tcl are separate. Model binaries and ABI artifacts
are preserved. No existing build log or waveform was removed.

The repair originally added structural checks, automated result summaries and
source-snapshot bookkeeping. The user subsequently requested beginner-readable
scripts. The current runner keeps the compile/run commands, explicit filelists
and timestamped log directories. It no longer discovers sources automatically,
records Git revisions or hashes, copies source snapshots, applies timeouts or
parses PASS/failure text. The custom checker, summary generator and object-cleanup
wrapper have been removed. `make clean` directly removes `.o` and `.d` files.

The parameter-slot Verilator script now shows the baseline, PSUM and A-reuse
compile/run commands as three explicit sections, using the shared RTL filelist.

## Historical repair validation

`docs/validation/cleanup_results.json` records the earlier repair's passing run
directories for 17 VCS configurations and retained failed attempts. These results
belong to the scripts and sources used for those runs. `make vcs-regression` reproduces the
16 functional configurations; `make vcs-pe-wave` adds the PE waveform configuration.
Verdi batch import of the new PE FSDB returned 0 and reported 0–56000 ps.

Failed attempts were investigated rather than deleted: old Bash read offsets were
affected by updating an executing shell script; the old physical stride 260 violated
the current native operand DMA's 8-byte alignment; an added diagnostic process also
initially preceded its signal declaration. Corrected runs are recorded separately. At that stage, the runner parsed its complete main function before executing tools and compiled archived source snapshots. The current teaching script has been simplified; do not edit a script or its source inputs while it is running.

## Current teaching script

The current VCS runner reads `sim/filelists/vcs/<top>.f` from the project root.
Compile output and `compile.log` / `simulation.log` go to
`build/vcs/<top>/<YYYYMMDD_HHMMSS>/`. Testbench comparisons remain in the TBs;
read their messages in the simulation log. PE waveform compilation uses the
options recorded in `pe_wave_tb.f`.

The simplified runner was exercised with `make vcs-pe` and `make vcs-pe-wave`.
Both completed with exit code 0 and RESET/MAC/HOLD/CLEAR PASS messages. Runs
are saved under `build/vcs/pe_tb/20261017_142951/` and
`build/vcs/pe_wave_tb/20261017_143216/`; the waveform run generated FSDB and VCD.
The complete regression was not repeated for this script simplification. The
earlier 17-configuration report remains a historical record.

## Remaining environmental / audit limits

- Python 3, required model packages and Verilator are unavailable in the current
  PATH. Model/compiler Python regressions and Verilator regressions were not run.
- The compiler's historical RTL hash contract already disagreed with multiple RTL
  files before this repair. Path keys follow migrations, but historical hashes and
  strict checks were preserved. A refreshed ABI audit is required before approving
  that model compiler for the current hardware; hashes were not blindly replaced.
- Industrial coverage closure, UVM, synthesis, DFT and physical implementation have
  not been claimed or started. No License files, services or configuration were
  inspected or changed.

## Output-buffer simplification and measured comparison

`c_result_buffer.sv` now uses fixed capture/DMA ping-pong pointers and per-bank
states, replacing the ready FIFO, free-bank search and redundant active/row
tracking. The data array is written completely before READY and needs no reset.
The module decreased from 177 to 103 lines; its two 64-byte banks remain.

Forty comparisons (four implementations, ten workloads each), four top-level
runs and the original executor regression passed. The chosen implementation
matched the original double-buffer cycles in every measured workload. Single
buffering and direct writeback had short-K regressions, although the long-K
top-level workload was unaffected or slightly faster. Full results and
reproduction commands are in `docs/validation/output_buffer_comparison.md`.
These are additional focused results; the historical 17-run report is retained.
