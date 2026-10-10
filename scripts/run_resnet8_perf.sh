
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MODEL="${1:-models/resnet8/pretrainedResnet_quant.tflite}"
OUTDIR="build/resnet8_perf"

mkdir -p "$OUTDIR"

python3 scripts/compile_resnet8_tflite.py \
    "$MODEL" \
    --output "$OUTDIR/model"

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

"$OUTDIR/obj_dir/Vresnet8_npu_tb" \
    "+DDR_HEX=$OUTDIR/model/ddr.hex" \
    "+DESC_BASE=$DESC_BASE" \
    "+DESC_COUNT=$DESC_COUNT" \
    "+LOGITS_BASE=$LOGITS_BASE" \
    | tee "$OUTDIR/perf.log"

echo
echo "Performance log: $OUTDIR/perf.log"
