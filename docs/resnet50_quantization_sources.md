# ResNet-50 模型与量化资料来源核查

核查日期：2026-10-24。结论是 NVIDIA 确实公开了真实 ResNet-50 校准表，但目前找到的表均不能直接作为项目内这份 1001 类 ONNX 模型的完整量化配置。可以继续完成编译器与结构验证；数值部署仍需匹配模型的校准参数，或者明确切换到提供校准表的 NVIDIA 模型及其图变换流程。

## 当前项目使用的模型

本地文件为 `build/nvidia_reference_models/resnet50/resnet50_v1.onnx`：

| 项目 | 值 |
| --- | --- |
| 来源 | Zenodo record 4735647，`resnet50_v1.onnx` |
| 格式 | FP32、ONNX opset 11、tf2onnx 导出 |
| 大小 | 102160076 字节 |
| SHA-256 | `358c5906f4057cfff3506a63bcf7b502e69e566bdaa9ea598466fe002c3bd3fa` |
| MD5 | `f6a4da60cd5f084d97efc2c1ddb10beb` |
| 输入 | `input_tensor:0`，NCHW `[1,3,224,224]` |
| 项目选定输出 | `resnet_model/dense/BiasAdd:0`，1001 类 logits |

这些身份字段取自项目现有的 `audit_tail_tiles.json`。NVIDIA 的 DLA 准备说明指向相同 Zenodo 模型；其引用的 MLCommons 文档说明该文件来自 TensorFlow MLPerf ResNet-50 v1.5 FP32 模型（Zenodo 2535873），经 tf2onnx 转换。文件名中的 `v1` 不能据此理解成原始 Caffe ResNet-50。[NVIDIA 下载说明](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW/blob/729e3c8074305fed87ba1b3a1acb5cf948440ec7/scripts/prepare_models/README.md)、[MLCommons 模型表](https://github.com/mlcommons/inference/blob/2acca351fbdf7821a5d8fa1d9a9799d50ab270f1/vision/classification_and_detection/README.md)、[原始转换脚本](https://github.com/mlcommons/inference/blob/2acca351fbdf7821a5d8fa1d9a9799d50ab270f1/vision/classification_and_detection/tools/convert-to-onnx.sh)。

NVIDIA 的 `resnet50.py` 截取输入到分类 logits 的子图，并将末尾 ReduceMean、Squeeze、MatMul、Add 改写成 AveragePool 和 1×1 Conv；它没有收集激活动态范围，也没有生成校准表。准备 ONNX 图与完成 INT8 量化是两个步骤。[准备脚本](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW/blob/729e3c8074305fed87ba1b3a1acb5cf948440ec7/scripts/prepare_models/resnet50.py)。

## NVIDIA 已提供哪些真实校准资料

| 资料 | 已核实内容 | 与当前模型的关系 |
| --- | --- | --- |
| 旧 NVDLA `resnet50.json` / `resnet50.txt` | 229 个 Caffe 层名的尺度，JSON 偏移均为 0；TXT 头标识 TensorRT 5.1 EntropyCalibration2 | 面向 Kaiming He 的 Caffe 模型，不能移植给当前 TF 模型 |
| NVIDIA MLPerf v3.1 `calibrator.cache` | 124 个张量尺度，TensorRT 9.0 EntropyCalibration2；有官方命名映射、预处理及校准清单 | 原模型下载指向 opset 8，图中分类器裁成 1000 类；不覆盖当前 1001 类原始输出 |
| DLA QDQ Translator 的 TensorFlow 流程 | 从自行训练得到的 QAT ONNX 提取尺度并生成 TensorRT cache | 需要取得或训练该 QAT 模型，不能凭当前 FP32 文件生成真实尺度 |

### 旧 NVDLA 文档中的失效链接

`nvdla/sw/LowPrecision.md` 的示例链接写成了 `umd/utils/calibdata/calib.json`，但核查 master 的完整文件树后，实际文件是 [resnet50.json](https://github.com/nvdla/sw/blob/79538ba1b52b040a4a4645f630e457fa01839e90/umd/utils/calibdata/resnet50.json) 和 [resnet50.txt](https://github.com/nvdla/sw/blob/79538ba1b52b040a4a4645f630e457fa01839e90/umd/utils/calibdata/resnet50.txt)。JSON blob SHA 为 `8001e2802013550e01685f12716875793b7e1cf4`，TXT blob SHA 为 `d28b3059302e7a174b66e9d6c1113ee41918a9ea`。文档明确把示例关联到 Kaiming He 的 Caffe ResNet-50；其中 `bn_conv1`、`scale_conv1`、`fc1000` 等名字也与当前 TF ONNX 的边界不同。[NVDLA 量化说明](https://github.com/nvdla/sw/blob/79538ba1b52b040a4a4645f630e457fa01839e90/LowPrecision.md)。

这些文件是已校准的尺度，不是校准图片，也不是本项目 ABI 的 INT8 权重、偏置和重定标参数。旧转换脚本还混用了 Python 2 写法与 Python 3 shebang；新工具应按格式独立解析，不应直接照搬执行。[原始 TXT 转 JSON 脚本](https://github.com/nvdla/sw/blob/79538ba1b52b040a4a4645f630e457fa01839e90/umd/utils/calibdata/calib_txt_to_json.py)。

### NVIDIA MLPerf 提交中的可复现资料

已定位到官方 `mlcommons/inference_results_v3.1` 中的 NVIDIA 提交，固定提交为 `f7b504d40dfb65180fe59438d4b4d6f9f8598647`。相关小文件均位于 `closed/NVIDIA/` 下：

| 路径 | 用途 |
| --- | --- |
| `code/resnet50/tensorrt/calibrator.cache` | 3792 字节的真实尺度缓存，blob SHA `63798e587414c984795a426b0e53677da08cd65c` |
| `code/resnet50/tensorrt/onnx_node_names.json` | ONNX 节点到 NVIDIA 简写层名的映射 |
| `code/resnet50/tensorrt/rn50_graphsurgeon.py` | 重命名、替换分类头及张量边界变换 |
| `code/resnet50/tensorrt/preprocess_data.py` | FP32 校准输入及 INT8 验证输入预处理 |
| `code/resnet50/tensorrt/calibrator.py` | `IInt8EntropyCalibrator2` 实现 |
| `data_maps/imagenet/cal_map.txt` | 500 张校准图片的文件名与标签，图片需另行取得 |

官方说明给出了先预处理再运行 `make calibrate RUN_ARGS="--benchmarks=resnet50"` 的复现步骤，也明确新权重需要重新校准。[NVIDIA 提交说明](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/README.md)、[缓存](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/calibrator.cache)、[校准图片清单](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/data_maps/imagenet/cal_map.txt)。

当前不能声明此缓存与本地模型严格匹配，原因具体如下：

1. [下载脚本](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/download_model.sh) 指向 Zenodo 2592612 的 opset 8 文件，本地使用的是 4735647 的 opset 11 文件。本次没有重复下载另一份百兆模型，也没有证明两份图的全部参数和运算语义相同。
2. [图变换脚本](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/rn50_graphsurgeon.py) 删除分类器第 0 个权重列，生成 1000 类 `fc_replaced`。缓存中有 `fc_replaced_out_0`，没有本地保留的 1001 类 `resnet_model/dense/BiasAdd:0` 尺度。不能把前者作为后者的已校准结果。
3. [节点映射](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/onnx_node_names.json) 使用诸如 `Conv__128` 的特定图节点名。BN 折叠、转换器版本和分类头替换会改变尺度应挂接的位置，不能仅按遍历顺序或相似名称匹配。

缓存值是 IEEE754 FP32 尺度的十六进制位表示；不是直接写入硬件的整数 multiplier，也不是动态范围本身。TensorRT 官方样例读出尺度 `s` 后用 `[-127*s,127*s]` 设置动态范围。导入时应解码浮点位，而非把十六进制串转成普通整数使用。[TensorRT 8.6 缓存解析实现](https://github.com/NVIDIA/TensorRT/blob/release/8.6/samples/common/sampleEngines.cpp)。

该 NVIDIA 缓存中，末次 ReLU 与替换后的全局池化输出使用相同尺度，符合本项目 GAP 不做额外重定标的约束；但这只证明这两条缓存记录一致，不能据此补全另一个模型缺失的尺度或证明整个网络的精度。[同一缓存文件](https://github.com/mlcommons/inference_results_v3.1/blob/f7b504d40dfb65180fe59438d4b4d6f9f8598647/closed/NVIDIA/code/resnet50/tensorrt/calibrator.cache)。

## 当前 TF 模型应使用的校准输入

MLCommons 在固定提交 `2acca351fbdf7821a5d8fa1d9a9799d50ab270f1` 的 `calibration/ImageNet/` 目录公开了 option 1 和 option 2 两个清单，各 500 张；它们是文件名列表，不含 JPEG 数据。目录说明要求最多使用其中一个清单。NVIDIA 上述 `cal_map.txt` 的文件名与 option 1 开头对应，但不能把所有提交版本的校准参数视为相同。[官方校准目录](https://github.com/mlcommons/inference/tree/2acca351fbdf7821a5d8fa1d9a9799d50ab270f1/calibration/ImageNet)。

保持当前模型时，预处理应复现其参考路径：

1. OpenCV 读图后 BGR 转 RGB。
2. 保持宽高比，使用 `INTER_AREA`，把短边缩放到 256，再中心裁剪为 224×224。
3. 转 FP32，RGB 分别减去 `[123.68,116.78,103.94]`，不再除以 255 或标准差。
4. ONNX 参考执行使用 NCHW；本项目存入加速器前再转换成 HWC，并按已经确认的输入量化参数编码。
5. 保留 1001 类输出时，ImageNet 类别比较采用 `argmax(logits)-1`，与参考实现的背景类别约定一致。

上述规则分别由 [MLCommons 预处理](https://github.com/mlcommons/inference/blob/2acca351fbdf7821a5d8fa1d9a9799d50ab270f1/vision/classification_and_detection/python/dataset.py)、[模型与数据集配置](https://github.com/mlcommons/inference/blob/2acca351fbdf7821a5d8fa1d9a9799d50ab270f1/vision/classification_and_detection/python/main.py) 确认。不要套用同名 PyTorch ResNet-50 的 `/255` 加 mean/std 预处理。

## 无校准图片时可继续与待补的工作

当前图的BN已经折入Conv，编译器可以完成FP32图解析、分类偏置折叠、HWC布局转换、残差分支生命周期规划、描述符校验与小图整数参考验证。若使用人工尺度检查部署链路，产物必须明确标记为结构验证，不能标成真实模型已校准或有已验证的ImageNet精度。

若保持当前模型和 1001 类接口，需要获得针对这个模型的完整尺度，或用实际 ImageNet 校准图片重新生成。若以后明确改用 NVIDIA MLPerf 的 opset 8 模型及 1000 类分类头，可以继续研究它的公开缓存，但必须先证明参数、图变换和所有量化边界一致，并把模型 SHA-256、缓存 SHA-256、来源提交、预处理规则写进量化配置。缺失输出尺度、分类维度不符或边界域不一致时应直接拒绝导入。

NVIDIA 另有 TensorFlow QAT → ONNX → QDQ Translator → calibration cache 的完整流程；该流程需要准备 ImageNet 并微调 QAT 模型，不会从本地 FP32 文件自动恢复训练得到的尺度。[DLA QAT 流程](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW/blob/729e3c8074305fed87ba1b3a1acb5cf948440ec7/tools/qdq-translator/e2e_workflow/tensorflow_workflow/README.md)、[TensorRT QAT 数据要求](https://github.com/NVIDIA/TensorRT/blob/release/8.6/tools/tensorflow-quantization/examples/README.md)。DLA 准备说明中的无 cache `trtexec --int8` 示例明确允许使用 dummy scales 比较延迟；其成功执行不构成分类精度证据。
