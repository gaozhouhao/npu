#!/bin/bash
# Run from the project root after ATPG has written npu_stuck_at.stil.
# Check the first 10 patterns with parallel scan loading and real cell models.
set -e

stdcell_v=/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/verilog/tcbn28hpcplusbwp40p140.v
sram_v=/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/VERILOG/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.v
export SYNOPSYS_TMAX=/home/synopsys/txs/O-2018.06-SP1

cd build/atpg/npu_stuck_at_20261018
"$SYNOPSYS_TMAX/bin/stil2verilog" npu_stuck_at.stil npu_patterns_tb.v \
    -parallel 2 -first 0 -last 9 -tb_module_name npu_patterns_tb \
    -replace -log stil2verilog.log

/home/synopsys/vcs/O-2018.09-SP2/bin/vcs \
    -full64 -sverilog -timescale=1ns/1ps \
    +define+UNIT_DELAY +notimingcheck -debug_access+all -debug_region+cell \
    -top npu_patterns_tb "$stdcell_v" "$sram_v" \
    ../../dft/npu_scan_20261018/npu_scan.v npu_patterns_tb.v \
    -o simv_patterns -l vcs_compile.log

./simv_patterns -l vcs_sim.log
