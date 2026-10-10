# ResNet-8 / MLPerf Tiny NPU V1 integration (experimental)

Goal: map the official quantized `pretrainedResnet_quant.tflite` graph to the existing 4x4 INT8 NPU. Keep the GEMM array, C partial-sum SRAM and Parameter Slot Bank unchanged.

**Status: NOT COMPILED OR SIMULATED IN THE USER'S CURRENT LOCAL REPO.** Python scripts pass syntax compilation. The package contains source modifications and a first functional mapping; it does **not** claim bit-exact TFLite or confirmed classification accuracy. This is not a final verified ResNet solution.

## Files

- `scripts/integrate_resnet8_quant.py`: fail-closed retrofit of asymmetric Conv/FC: zero point in 4-word per-channel global header, nonzero padding, output zero point, SAME flag.
- `rtl/core/residual_add_engine.sv`: serialized DDR elementwise INT8 Residual Add; reads two input tensors and writes one output tensor through AXI.
- `scripts/integrate_residual_add.py`: guarded integration of opcode `0x05` and its AXI path into existing `npu_top.sv`.
- `scripts/compile_resnet8_tflite.py`: compile graph, weights, parameters, descriptors into DDR image using Python `numpy`, `tflite`.
- `sim/tb/resnet8_npu_tb.sv`: DDR-backed full-graph NPU testbench; prints first 10 output logits and argmax.
- `scripts/run_resnet8.sh`: model compilation plus Verilator build with `-Wall` and `-j 4`.

## Install

From NPU repository root (`~/npu`):

```bash
# Unpack the ZIP at repo root, preserving directory paths.
unzip resnet8_hw_v1.zip
python3 scripts/integrate_resnet8_quant.py
python3 scripts/integrate_residual_add.py
python3 -m pip install numpy tflite
mkdir -p models
# Save the official model to models/pretrainedResnet_quant.tflite:
# https://github.com/mlcommons/tiny/blob/master/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite
bash scripts/run_resnet8.sh models/pretrainedResnet_quant.tflite
```

Both integration scripts check **all matching source patterns before writing** and write `.before_resnet8` / `.before_residual_add` backups. They do not overwrite unrelated local source code on purpose. If your unpublished local top-level changes differ, a pattern check may fail: do not bypass the check; adapt the script to the actual local code.

`run_resnet8.sh` defaults to a zero-valued real-domain image. To use a CIFAR-10 image, supply `--input-npy` to `scripts/compile_resnet8_tflite.py` (uint8 `[32,32,3]`), then run the Verilator binary with `+DDR_HEX` and descriptor/logit addresses from the JSON manifest.

## Descriptor ABI

- `0x01`: GEMM/FC with flags bits `0=Bias`, `1=Requant`, `2=ReLU`, `3=Per-channel`.
- `0x02`: Conv with the above flags, plus bit `4=SAME` (supports asymmetric trailing padding).
- `0x04`: Global Average Pool (must already exist in local NPU).
- `0x05`: Residual Add, flags bit0=Fused ReLU, `cfg_m=element count`, `cfg_a_base`, `cfg_b_base`, `cfg_c_base`, `cfg_param0/1=parameter address`.

Per-channel Conv/FC parameter format:

```
+00 multiplier_legacy_unused = 0 (u32)
+04 shift_legacy_unused = 0      (u32)
+08 input_zero_point            (signed i32)
+12 output_zero_point           (signed i32)
+16 channel0_bias               (signed i32; includes -Zin*sum(weights))
+20 channel0_multiplier         (u32)
+24 channel0_shift              (u32)
+28 channel1_bias ...
```

Residual Add parameter format: `[ZA, ZB, ZOUT, MULT_A, MULT_B, COMMON_SHIFT]`, 6 signed/unsigned 32-bit words. Arithmetic approximates `(A-ZA)*SA/SOUT + (B-ZB)*SB/SOUT + ZOUT`, using a common right shift. Model compiler chooses multiplier integers.

## Limitations and verification to complete

1. The current NPU round-to-nearest-ties-away arithmetic can differ by +/-1 from TFLite exact reference rounding. No bit-exact TFLite validation is claimed.
2. `ResidualAdd` uses serialized AXI transactions, not an optimized streaming or burst DMA. This is intentional for first full-graph functional execution.
3. `Softmax` is skipped for classification `argmax` only, not for producing numerical probability outputs.
4. Initial memory image uses a placeholder input unless supplied a `uint8` CIFAR image. Passing `top1` output alone does not prove model accuracy.
5. The scripts assume the successful local **per-channel Parameter Slot integration** from the prior tests. GlobalAvg opcode `0x04` must be integrated locally.
6. The `run_resnet8.sh` simulation should be treated as an integration diagnostic. If it fails to compile, preserve the *first* `-Wall` diagnostic and the source; no warnings should be disabled.
7. Confirm all TFLite operator options are in the supported subset (actual official model observed Conv `SAME`, activation `NONE/RELU`, ADD fused `RELU`).
