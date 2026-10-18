#!/bin/bash
# 在工程根目录执行；三段分别测试普通模式、部分和、A 复用。
set -e

# 1. 普通模式。
verilator --binary --timing --assert --trace -Wall -Wno-TIMESCALEMOD -j 4 \
    --top-module param_slot_stress_npu_tb --Mdir build/param_slot_stress_baseline \
    -f sim/filelists/rtl.f sim/tb/system/param_slot_stress_npu_tb.sv
./build/param_slot_stress_baseline/Vparam_slot_stress_npu_tb

# 2. 部分和模式。
verilator --binary --timing --assert --trace -Wall -Wno-TIMESCALEMOD -j 4 \
    -DNPU_PSUM_EXPERIMENT \
    --top-module param_slot_stress_npu_tb --Mdir build/param_slot_stress_psum \
    -f sim/filelists/rtl.f sim/tb/system/param_slot_stress_npu_tb.sv
./build/param_slot_stress_psum/Vparam_slot_stress_npu_tb

# 3. 部分和与 A 复用模式。
verilator --binary --timing --assert --trace -Wall -Wno-TIMESCALEMOD -j 4 \
    -DNPU_PSUM_EXPERIMENT -DNPU_AS_REUSE_EXPERIMENT \
    --top-module param_slot_stress_npu_tb --Mdir build/param_slot_stress_a_reuse \
    -f sim/filelists/rtl.f sim/tb/system/param_slot_stress_npu_tb.sv
./build/param_slot_stress_a_reuse/Vparam_slot_stress_npu_tb
