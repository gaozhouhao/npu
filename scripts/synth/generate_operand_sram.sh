#!/bin/bash
# 在工程根目录执行：bash scripts/synth/generate_operand_sram.sh
set -e

compiler_dir=/home/ICer/eda/pdk/tsmc28/Memory/compilers
macro_dir=/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64
mkdir -p "$macro_dir"
cp scripts/synth/operand_32x64.txt "$macro_dir/"

# 仅对这次运行设置路径，不修改 bashrc。
export MC_HOME="$compiler_dir/tsn28hpcp1prf_20120200_130a"
export PATH="$compiler_dir/MC2_2012.02.00.d/bin/Linux-64:$PATH"
cd "$macro_dir"
perl "$MC_HOME/tsn28hpcp1prf_130a.pl" \
    -file operand_32x64.txt -SVT -NonBWEB -NonBIST -NonSLP -NonSD
