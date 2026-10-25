# NVIDIA 参考模型选择与适配记录

选择 **ResNet-50** 作为首个 NVIDIA 公开参考网络。真实模型已完成ONNX图转换、72条命令生成与DDR规划，首个池化补边已按真实尺寸独立验证。当前增加真实权重的显式整数性能模式和整网逐层RTL检查入口，保留独立层与DDR交接；固定激活尺度不冒充校准，ImageNet精度验证留到后续。入口见[编译器说明](../compiler/README.md)，整网测量状态见[性能记录](resnet_performance.md)，公开校准资料的适用范围见[来源核查](resnet50_quantization_sources.md)。

## 来源与文件身份

- [NVIDIA 模型下载与准备说明](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW/blob/main/scripts/prepare_models/README.md#resnet-50)引用这份模型。
- [公开模型记录](https://zenodo.org/records/4735647)：文件 `resnet50_v1.onnx`，未量化的 FP32（32 位浮点）模型。
- 本地路径：`build/nvidia_reference_models/resnet50/resnet50_v1.onnx`，102,160,076 字节；模型与完整生成报告放在被忽略的 `build/` 中。
- MD5：`f6a4da60cd5f084d97efc2c1ddb10beb`，与公开记录一致。
- SHA256：`358c5906f4057cfff3506a63bcf7b502e69e566bdaa9ea598466fe002c3bd3fa`。
- 实际文件声明 ONNX 算子集版本 **11**。公开记录中的转换命令写了版本 12，适配以实际文件为准。ONNX 全称 Open Neural Network Exchange，意为开放神经网络交换格式。

采用 [NVIDIA 准备脚本](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW/blob/main/scripts/prepare_models/resnet50.py)相同的图边界：输入 `input_tensor:0`，输出 `resnet_model/dense/BiasAdd:0`。只取到分类分数，Softmax（归一化概率）与 ArgMax（最大值索引）在主机处理。本次按每次一张图检查输入 `[1,3,224,224]`；NVIDIA 示例测速命令每批两张图，两者不能直接比较吞吐量。

[NVIDIA 精度表](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW#accuracy-on-dla-and-gpu)使用 ImageNet 2012；其引用的 MLCommons 任务说明对应验证集。该数据集用于后续分类精度评价，校准样本选择需要单独记录，不能把网络结构检查或随机输入测速当成精度验证。

## 实际算子与当前硬件的对应

原图 125 个节点，取上述边界后 123 个节点，所有选中节点的输出形状均已推导。

| 实际节点 | 数量 | 对应方法与限制 |
|---|---:|---|
| Conv，卷积 | 53 | 无分组和膨胀卷积；已支持逻辑空间尾块，后9层7×7输出不再因49个位置被拒绝 |
| Relu，修正线性激活 | 49 | 满足消费者与量化条件时并入卷积或残差加的后处理 |
| Add，加法 | 17 | 16 个残差加；另 1 个为分类头偏置，应折入全连接参数 |
| MaxPool，最大池化 | 1 | 3×3 窗口、步长 2、右侧和下侧补边已由独立池化支持；融合仍不支持补边 |
| ReduceMean，求平均 | 1 | 沿高宽求平均，保留维度，对应全局平均池化 |
| Squeeze，移除单元素维度 | 1 | `[1,2048,1,1]` 到 `[1,2048]`，由编译器处理布局与别名 |
| MatMul，矩阵乘法 | 1 | 已接入ONNX后端，权重转为[N,K]并折入分类偏置；保留1001类，逻辑M/N使用尾块支持 |

图转换现已实现权重排列、HWC布局、参数编码、残差地址保活和量化配置检查；真实模型权重的INT8部署仍需匹配的校准参数与数值验证。原图的批归一化参数已经折入卷积，不需要增加独立的批归一化硬件。

相比之下，SSD-MobileNetV1 涉及深度可分离卷积，RetinaNet ResNeXt-50 涉及分组卷积，检测网络还需要处理检测头和结果后处理。ResNet-50 更接近当前算子范围；其他公开模型本次没有下载和逐节点检查。

## 具体适配问题与当前状态

### 1. 九层卷积输出 7×7，空间尾块已支持

卷积输出空间分布为：112×112 共 1 层，56×56 共 11 层，28×28 共 13 层，14×14 共 19 层，7×7 共 9 层。

矩阵化后 M 表示输出位置数、N 表示输出通道数、K 表示一次点积长度。后段九层保持 M=49，默认4行阵列调度13个块，最后一个块只有1行有效。输入端屏蔽无效位置，结果缓冲传递有效行列数，写回端只写真实结果。不得把描述符 M 改成52，因为逻辑形状仍为7×7。

通用尾块同时覆盖剩余行数、剩余通道和K块，不依赖49这个特例；卷积输出维持紧凑HWC。实现与专项验证见[通用计算尾块](tail_tiles.md)。这消除了形状准入限制，不表示已经运行这九层的真实量化权重或完成整网部署。

首层使用 7×7 **卷积核**本身没有问题：输入三通道，K=147，输出通道 64，输出空间 112×112。它与后段的 7×7 **输出特征图**是两个不同问题。

### 2. 独立最大池化补边已完成，融合仍有限制

实际最大池化输入为 `[1,64,112,112]`，窗口 `[3,3]`，步长 `[2,2]`，补边 `[上,左,下,右]=[0,0,1,1]`，输出 `[1,64,56,56]`。原先只有 VALID，即不补边，执行会得到55×55。现已增加独立池化四侧补边支持，并按112×112×64真实尺寸通过数值与地址检查，保持模型要求的56×56输出。

实现先判断样本坐标，再决定是否读取；越界位置不参与最大值比较，第一个有效值直接初始化最大值。软件参考与描述符同步支持补边；带补边层明确保留独立任务，融合仍只使用不补边语义。具体字段和状态机见 [最大池化补边](maxpool_padding.md)。

改为原始输入行缓冲后，按该参考输入尺寸估算全通道容量为：

```text
窗口高 × 输入宽 × (通道数/4)
= 3 × 112 × (64/4)
= 5376 个 32 位字 = 21504 字节 = 21 KiB
```

当前 `POOL_LINE_WORDS=1024`，即 4 KiB。首层融合还需要评估容量调整或通道分块；单独增加缓存仍不能解决融合路径尚未支持的补边语义。该公式是容量估算，不是已经验证过的补边融合实现。已完成的独立池化不受这项片上融合缓存容量限制。

此前复核发现的中间融合引擎接线缺口已补齐：`cmd_pool_config`、`cfg_input_h` 和 `cfg_pool_config` 已连通，准入检查同步支持可变 VALID 窗口/步长，并通过3×3、步长2的整机融合对照。此修复不包含融合补边。

### 3. 分类头实际有 1001 个输出

权重形状为 `[2048,1001]`，逻辑矩阵乘法为 `M=1,N=1001,K=2048`。共享工具 `compiler/fc_layout.py` 已实现物理输出 `[4,1004]` 的输入/权重/参数分配、描述符生成和逻辑输出提取，并用真实层尺寸的确定性整数数据通过硬件验证。普通方案把输入补到4行，补齐元素按量化零点编码；已有TFLite入口改用输入行步长0，让4个物理行重复读取运行时真实向量。两种方案最后均只保留第0行的前1001个分数，尾部三个输出不参与分类。逐段代码见 [分类层软件对齐](fc_alignment.md)。

这份模型不是直接输出1000项，必须保留原模型的类别索引与标签映射。NVIDIA准备脚本将分类头改成1×1卷积；本项目ONNX入口保留GEMM，利用通用尾块直接提交M=1、N=1001、K=2048，C行stride为1004字节，只取前1001项，TFLite原有完整物理行列方案继续保留。

## 编译器复用边界

[旧 NVDLA 编译器文档](https://nvdla.org/sw/compilation_tool.html)明确：它根据 NVDLA 硬件配置生成 NVDLA Loadable，即对应硬件的可加载任务文件。[NVIDIA 当前 DLA 软件说明](https://github.com/NVIDIA/Deep-Learning-Accelerator-SW#deep-learning-accelerator)同样说明其编译器通过 TensorRT、NvMedia-DLA 或 cuDLA 调用，依赖对应运行时。

本项目使用 64 字节描述符、自己的权重/量化布局和 `NPUMV0` 部署文件。NVIDIA 的编译结果不能直接驱动这些接口；改变目标阵列大小也不会自动生成我们的命令。

现已新增 `compiler/onnx_frontend.py` 与 `graph_compiler.py`，读取官方ONNX并生成本地描述符。它与原TFLite入口共用硬件ABI，借鉴已有残差加、全局平均和矩阵乘法的参数布局；整数验证由直接解释序列化DDR的 `reference_int8.py` 完成。TFLite入口继续服务原模型，并不直接读取ONNX，也不承诺逐位复现TFLite算术。

此外还需处理：

- 激活由模型的 NCHW（批次、通道、高、宽）转换为本项目 HWC（高、宽、通道），卷积权重转换为输出通道优先的矩阵布局。
- 下载模型的 108 个常量均为 FP32，共 25,532,521 个元素。必须准备有代表性的校准输入，确定 INT8 尺度、零点、逐通道参数与舍入规则；随机尺度不能证明分类精度。
- 当前 `compiler/npu_config.json` 的外存容量仅 32 KiB，是小模型配置。该网络的量化权重与中间张量需要更大的外存地址空间和仿真存储配置；不能把它们全部塞入片上缓存。

## 复现检查

`scripts/model/audit_onnx.py` 只依赖 Python 标准库，兼容 Python 2.7 和 Python 3。它按需要读取 ONNX 元数据，并报告算子、形状和已知目标限制；不执行模型，不替代官方 ONNX 校验器，也不检查完整物理地址或数值正确性。当前实际验证对象为这份模型；其他网络中的动态形状、控制流及新算子版本仍需专门检查。

下载到 `build/nvidia_reference_models/resnet50/` 后，先将 MD5 与上文核对，再运行：

```bash
python scripts/model/audit_onnx.py \
  build/nvidia_reference_models/resnet50/resnet50_v1.onnx \
  --input input_tensor:0 --output resnet_model/dense/BiasAdd:0 \
  --batch 1 --rows 4 --cols 4 --pool-line-words 1024 \
  --report build/nvidia_reference_models/resnet50/audit.json \
  --summary docs/reference/nvidia_resnet50_audit.json

python scripts/model/audit_onnx.py \
  build/nvidia_reference_models/resnet50/resnet50_v1.onnx \
  --report build/nvidia_reference_models/resnet50/audit_full_graph.json
```

精简报告随源码保存在 [nvidia_resnet50_audit.json](reference/nvidia_resnet50_audit.json)。完整报告还含全部53层卷积的M/N/K、参数、形状与乘加次数，可作为后续逐层性能用例的来源。尾块支持后，卷积记录包含块数和末块有效行列数，不再将后9层标为不支持。完整图另报告主机处理的两个分类后处理节点；ONNX全连接降级现已由新入口实现。旧审计报告用于静态结构检查，实际命令及地址以 `make resnet50-prepare` 生成的manifest为准，`deployment_ready` 保持false。

## 快速验证的实施顺序

先保留现有小模型的端到端验证，`make compiler-check` 对照原四张SmallCNN的20份逐层golden，并将8命令小残差图编译后交给RTL，与独立整数参考逐字节比较。完整真实权重网络可用 `make resnet50-benchmark` 进行整数性能验证，另用 `make resnet50-compare` 比较两个RTL版本；具体逐层结果、完整DDR检查与测量条件见[性能记录](resnet_performance.md)。固定尺度性能模式不替代匹配模型的校准或整网精度验证。

本模型仅卷积就有 4,087,136,256 次乘加，加上分类头为 4,089,186,304 次。默认 16 个处理单元即使每周期全部有效，也至少需要 255,574,144 个计算周期，尚未计入分块、填充、访存和流水开销。这只是理想下界，用于说明完整寄存器传输级仿真的规模，不能当成已测性能。

后续应分别报告相同网络形状下的周期、实际总线读写字节、计算单元利用率与仿真访存条件。融合减少外存搬运可支撑节能动机；节省多少功耗仍需功耗分析，不能直接用字节减少比例代替。参考模型来源与测试方法可以写入项目说明；完成数值与硬件验证前，不能写“已跑通 ResNet-50”或沿用 NVIDIA 的精度/性能数字。
