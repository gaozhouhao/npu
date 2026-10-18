#!/bin/bash
# 在工程根目录执行：bash scripts/sim/run_vcs.sh pe_tb
set -e

top=$1
shift
run_dir="$PWD/build/vcs/$top/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$run_dir"

# 编译 RTL 和 Testbench，保存编译日志。
vcs -full64 -sverilog -timescale=1ns/1ps \
    -top "$top" -f "sim/filelists/vcs/$top.f" \
    -Mdir="$run_dir/csrc" -o "$run_dir/simv" -l "$run_dir/compile.log" "$@"

# 在输出目录运行，仿真日志和波形也放在这里。
cd "$run_dir"
./simv -l simulation.log
