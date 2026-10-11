
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MODEL="${1:-models/resnet8/pretrainedResnet_quant.tflite}"
OUTDIR="build/resnet8_perf"

DATAFLOW="${NPU_DATAFLOW:-auto}"

mkdir -p "$OUTDIR"

# ============================================================
# Step 1: Compile TFLite graph
# ============================================================

python3 scripts/compile_resnet8_tflite.py \
    "$MODEL" \
    --output "$OUTDIR/model" \
    --dataflow "$DATAFLOW"

# ============================================================
# Step 2: Compiler dataflow optimization
# ============================================================

python3 scripts/optimize_dataflow.py \
    --model-dir "$OUTDIR/model" \
    --dataflow "$DATAFLOW"

# ============================================================
# Step 3: Read runtime addresses
# ============================================================

python3 - "$OUTDIR/model/manifest.json" \
    > "$OUTDIR/runtime.env" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)

print(f"DESC_BASE={manifest['descriptor_addr']:x}")
print(f"DESC_COUNT={manifest['descriptor_count']}")
print(f"LOGITS_BASE={manifest['logits_addr']:x}")
PY

# shellcheck source=/dev/null
source "$OUTDIR/runtime.env"

# ============================================================
# Step 4: Build RTL simulator
# ============================================================

verilator \
    --binary \
    --timing \
    --assert \
    --trace \
    -Wall \
    -Wno-TIMESCALEMOD \
    -DNPU_PERF_ENABLE \
    -j 4 \
    --top-module resnet8_npu_tb \
    --Mdir "$OUTDIR/obj_dir" \
    $(find rtl -type f -name '*.sv' | sort) \
    sim/tb/resnet8_npu_tb.sv

# ============================================================
# Step 5: Optional waveform tracing
# ============================================================

TRACE_ARGS=()

if [[ "${TRACE_WAVE:-0}" == "1" ]]; then
    TRACE_ARGS=(
        "+TRACE_WAVE"
        "+TRACE_LAYER=${TRACE_LAYER:-5}"
        "+TRACE_CYCLES=${TRACE_CYCLES:-12000}"
    )
fi

# ============================================================
# Step 6: Run inference
# ============================================================

"$OUTDIR/obj_dir/Vresnet8_npu_tb" \
    "+DDR_HEX=$OUTDIR/model/ddr.hex" \
    "+DESC_BASE=$DESC_BASE" \
    "+DESC_COUNT=$DESC_COUNT" \
    "+LOGITS_BASE=$LOGITS_BASE" \
    "${TRACE_ARGS[@]}" \
    | tee "$OUTDIR/perf.log"

echo
echo "Dataflow mode: $DATAFLOW"
echo "Manifest: $OUTDIR/model/manifest.json"
echo "Performance log: $OUTDIR/perf.log"
