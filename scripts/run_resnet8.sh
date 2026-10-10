#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="${1:-models/pretrainedResnet_quant.tflite}"
python3 scripts/compile_resnet8_tflite.py "$MODEL" --output build/resnet8_model
python3 - <<'PY' >build/resnet8_model/runtime.env
import json
j=json.load(open('build/resnet8_model/manifest.json'))
print('DESC_BASE=%x'%j['descriptor_addr'])
print('DESC_COUNT=%d'%j['descriptor_count'])
print('LOGITS_BASE=%x'%j['logits_addr'])
PY
# shellcheck source=/dev/null
source build/resnet8_model/runtime.env
verilator --binary --timing --assert --trace -Wall -Wno-TIMESCALEMOD -j 4 \
    --top-module resnet8_npu_tb \
    --Mdir build/resnet8_tb \
    $(find rtl -type f -name '*.sv' | sort) \
    sim/tb/resnet8_npu_tb.sv
./build/resnet8_tb/Vresnet8_npu_tb \
    +DDR_HEX=build/resnet8_model/ddr.hex \
    +DESC_BASE="$DESC_BASE" +DESC_COUNT="$DESC_COUNT" \
    +LOGITS_BASE="$LOGITS_BASE"
