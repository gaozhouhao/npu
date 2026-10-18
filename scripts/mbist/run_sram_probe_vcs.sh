#!/bin/bash
# Prepared only: APG synthesis currently fails with SYNH-14.
# Run from the project root after dc_sram_probe.tcl compiles successfully.
set -e
stdcell_v=/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/verilog/tcbn28hpcplusbwp40p140.v
sram_v=/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/VERILOG/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.v
cd build/mbist/dc_sram_20261018
/home/synopsys/vcs/O-2018.09-SP2/bin/vcs \
    -full64 -sverilog -timescale=1ns/1ps +define+UNIT_DELAY +notimingcheck \
    -top dw_mbist_sram_probe_tb "$stdcell_v" "$sram_v" mbist_mapped.v \
    ../../../sim/mbist/dw_mbist_sram_probe_tb.sv -o simv -l vcs_compile.log
./simv -l vcs_sim.log
