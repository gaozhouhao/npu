#!/bin/bash
# 在工程根目录执行；依次运行已有的功能测试。
set -e

for top in \
    pe_tb matrix_controller_tb operand_loader_tb operand_path_tb \
    postprocess_unit_tb tile_scheduler_tb tile_scheduler_early_done_tb \
    tile_policy_multik_tb mn_tiling_tb gemm_core_tb gemm_executor_tb \
    gemm_dma_integration_tb
do
    bash scripts/sim/run_vcs.sh "$top"
done

# 矩形阵列与不同 A/B 缓冲数量。
bash scripts/sim/run_vcs.sh gemm_core_tb \
    -pvalue+gemm_core_tb.ROWS=2 -pvalue+gemm_core_tb.COLS=3 \
    -pvalue+gemm_core_tb.A_BUFFER_COUNT=2 -pvalue+gemm_core_tb.B_BUFFER_COUNT=1
bash scripts/sim/run_vcs.sh gemm_core_tb \
    -pvalue+gemm_core_tb.ROWS=3 -pvalue+gemm_core_tb.COLS=2 \
    -pvalue+gemm_core_tb.A_BUFFER_COUNT=1 -pvalue+gemm_core_tb.B_BUFFER_COUNT=2

# 1x1 阵列与 NPU 顶层。
bash scripts/sim/run_vcs.sh gemm_core_tb \
    -pvalue+gemm_core_tb.ROWS=1 -pvalue+gemm_core_tb.COLS=1
bash scripts/sim/run_vcs.sh npu_top_tb
