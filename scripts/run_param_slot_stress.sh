#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f rtl/core/gemm_executor.sv || ! -f sim/tb/param_slot_stress_npu_tb.sv ]]; then
    echo 'Run this script from the NPU repository root (~/npu).' >&2
    exit 1
fi

mapfile -t rtl_files < <(find rtl -type f -name '*.sv' | sort)

for mode in baseline psum a_reuse; do
    defines=()
    case "$mode" in
        baseline) ;;
        psum) defines=(-DNPU_PSUM_EXPERIMENT) ;;
        a_reuse) defines=(-DNPU_PSUM_EXPERIMENT -DNPU_AS_REUSE_EXPERIMENT) ;;
    esac

    echo
    echo "========== PARAM SLOT STRESS: $mode =========="

    verilator --binary --timing --assert --trace \
        -Wall -Wno-TIMESCALEMOD -j 4 \
        "${defines[@]}" \
        --top-module param_slot_stress_npu_tb \
        --Mdir "build/param_slot_stress_${mode}" \
        "${rtl_files[@]}" \
        sim/tb/param_slot_stress_npu_tb.sv

    "./build/param_slot_stress_${mode}/Vparam_slot_stress_npu_tb"
done

echo
printf '%s\n' 'ALL THREE PARAM SLOT STRESS CONFIGURATIONS PASS'
