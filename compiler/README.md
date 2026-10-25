# NPU 模型编译与部署工具

该目录把已有 SmallCNN 整数模型编译为 NPU 描述符、权重、量化参数和 DDR 镜像，并提供软件解释器与黄金数据核对。硬件默认值由 `target.hardware_defaults()` 从 `rtl/npu_top.sv` 读取；`npu_config.json` 仅设置 HWC 布局、8 字节分配对齐与 DDR 地址范围。

编译过程检查描述符格式、实际物理读写范围、stride 和容量。源码文字及其 SHA256 快照不参与编译准入。模型文件的 SHA256 保存在部署 manifest 中，用于校验实际部署数据。

新增 ONNX 图入口适配 NVIDIA 参考 ResNet-50，原 SmallCNN 与 TFLite ResNet8 入口和产物格式继续保留。三者共用 `target.py` 的硬件默认值与描述符 ABI；原模型解释器仍服务 SmallCNN，新 `reference_int8.py` 直接解释五种操作的序列化描述符，供通用图验证。

## ResNet-50 ONNX 入口

只依赖标准库，支持 Python 2.7/3，当前环境无需安装 NumPy 或 ONNX 包即可准备图：

```bash
make resnet50-prepare
# 或指定模型和输出目录：
python compiler/compile_onnx.py prepare \
  --model build/nvidia_reference_models/resnet50/resnet50_v1.onnx \
  --out build/resnet50-compiler
make compiler-check
```

`prepare` 输出 `manifest.json` 和 `quantization.template.json`，完成图转换、逻辑形状检查、全部描述符校验和残差分支内存规划，不产生可执行的假量化权重。当前真实模型融合49个ReLU、折入FC偏置、消除Squeeze别名后为72条命令：53个Conv、16个ADD、1个MaxPool、1个GAP、1个FC。保留1001类输出；卷积保持紧凑HWC，GEMM使用原生 `M=1,N=1001,K=2048`，输出行占1004字节，只有前1001项为分类分数。默认规划需要29,404,672字节DDR，其中激活区域按最后使用位置复用；每条命令先分配输出，完成后才回收输入，残差数据保留到ADD完成。

模板中的激活 `scale` 必须用实际校准值补齐，同时记录模型SHA256、校准方法、样本来源/数量和预处理。MaxPool/GAP的 `shared_with` 表示其输入输出必须使用相同尺度和零点。模板的 `input_layout=HWC` 和 `input_shape` 描述部署输入字节布局；校准框架内部仍可用NCHW。编译会拒绝空尺度、错误模型哈希、量化域不一致、输入布局不符以及数值/地址溢出。

```bash
python compiler/compile_onnx.py compile \
  --model build/nvidia_reference_models/resnet50/resnet50_v1.onnx \
  --quantization /path/to/calibrated-profile.json \
  --input-bin /path/to/signed-int8-hwc.bin \
  --out build/resnet50-int8
```

生成 `ddr.bin`、32位小端字格式的 `ddr.hex`、`descriptors.bin` 和manifest。部署控制端从manifest取 `descriptor_base`、`descriptor_count`；此入口使用与原ResNet8相同的DDR/命令装载方式，原SmallCNN的 `NPUMV0` 封装不变。未指定输入文件时输入区按量化零点初始化，manifest明确记录 `input_provided=false`。

Conv权重从ONNX的OIHW转为 `[N,KH,KW,C]`，FC权重转为 `[N,K]`，每行K按8字节对齐。权重使用逐输出通道对称INT8；偏置折入输入零点补偿，输出采用独立逐通道定点倍率。ADD允许两路尺度和零点不同，以公共shift重定标；舍入遵循RTL的半值远离零。GAP直接对原始INT8编码求平均，保持硬件舍入语义；非零零点下不保证与其他量化框架逐位相同，须测模型精度。

原 `npu_config.json` 的32KiB容量继续用于小模型。ONNX入口默认64MiB，可以用 `--ddr-capacity` 或 `--config` 指定；这是外存规划，不增加片上SRAM。新入口接受已折叠BN的Conv、可融合ReLU、无广播ADD、MaxPool、空间GAP、单样本FC及合法别名，明确拒绝其他算子。带补边MaxPool保持独立命令；此版ONNX入口不启用Conv/Pool融合。

`compiler-check` 包含原四张SmallCNN的20份逐层golden对照、旧TFLite生产代码的尾块兼容检查、真实ONNX图准备及一个8命令小残差图的RTL逐字节对照。小图使用明确标注的确定性测试尺度。真实ResNet-50另有下面的整数性能入口，匹配模型的ImageNet校准和分类精度仍需后续验证。所有新manifest的 `deployment_ready` 均保持false，编译成功本身不构成精度验证。官方资料见[量化来源核查](../docs/resnet50_quantization_sources.md)。

### 显式整数性能模式

当前选择保持每层独立、DDR交接，先验证真实网络的整数执行和性能，分类精度后续处理。`--benchmark-only` 使用原ONNX的全部真实权重和原始形状，按既有逐输出通道规则量化权重；激活使用明确的固定尺度和确定性合成INT8输入。它不使用随机权重，不缩小网络，也不填造校准记录。

```bash
make resnet50-model
make resnet50-benchmark
# 与指定旧版本比较，两个版本复用同一部署包、golden和DDR时序：
make resnet50-compare BENCH_BASELINE_REF=9d3ccce BENCH_CANDIDATE_REF=HEAD
```

等价的包生成命令：

```bash
python compiler/compile_onnx.py compile \
  --model build/nvidia_reference_models/resnet50/resnet50_v1.onnx \
  --out build/resnet50-benchmark/model \
  --benchmark-only --benchmark-scale 0.0625 --input-seed 8
```

生成的 `quantization.benchmark.json` 和manifest保留 `purpose=integer_performance`、`calibrated=false`、`accuracy_not_measured=true`，不包含校准数据集/样本数。普通 `compile` 仍拒绝这类profile，必须显式指定性能模式；真实校准profile也不能误用为性能profile。另保存 `input.bin` 和输入生成方式。更改种子、尺度或输入文件会改变整数工作负载，版本对照必须使用同一部署包。

完整模型验证使用Python3和NumPy。`reference_numpy.py` 独立解释序列化DDR和描述符，以INT64整数矩阵乘法加速计算，按照硬件规则处理INT32回绕、33位Bias加法、重定量、补边、残差和GAP；已与标准库 `reference_int8.py` 对照。`scripts/model/run_graph_model.py prepare` 逐层生成golden，`run` 在VCS中逐层核对，再由 `check` 对比最终完整DDR。残差激活区域复用前就检查该层，避免只核对最后分类输出漏掉中间错误。

`graph_model_npu_tb` 的外存和golden缓存容量由包尺寸推导，使用64位超时计数，检查所有1001个输出。`DDR_RD_LATENCY` 表示每个读burst首拍等待，`DDR_WR_LATENCY` 表示WLAST之后的B响应延迟，默认20/0。实际写入字节按WSTRB计数，末尾1001类输出不按1004个有效字节误报。模型可能需要较长RTL仿真时间，逐层结果会及时写入日志。

默认产物在 `build/resnet50-benchmark/`：模型包在 `model/`，golden和报告在 `check/`，其中 `current-report.json`、`current-per_layer.csv` 保存整网/逐层周期和外部读写字节，版本对照另生成 `comparison.json`。比较工具会拒绝模型、输入、参考结果、testbench或DDR时序不同的报告。测量结果见[ResNet性能记录](../docs/resnet_performance.md)。

报告分别记录完整卷积窗口的 `nominal_macs` 和排除边界补零的 `useful_macs`；FC按逻辑M/N/K计数，均不按权重或输入是否为零裁减。`effective_useful_mac_utilization` 使用后者除以默认16个PE与整网周期，和ResNet8的有效MAC口径一致。

## 命令

```bash
python3 compiler/compile_model.py --help
python3 compiler/compile_model.py --model-dir /path/to/mnist_npu --out artifacts/npu
python3 compiler/compile_model.py --model-dir /path/to/mnist_npu --out build/mnist_fused --fuse-conv-pool
python3 compiler/verify_model.py --help
make compiler-test
make fc-alignment-check
make mnist-all
```

编译需要 Python3、NumPy 和原 SmallCNN 模型目录中的训练/PTQ工具、checkpoint、权重、参数和数据集；不会重新训练。参数以 `--help` 显示的实际接口为准。`make mnist-all` 直接使用仓库已提供的四张部署镜像，不需要重新编译模型。

## 文件含义

| 文件 | 内容 |
|---|---|
| `compile_model.py` | 权重布局转换、地址分配、descriptor生成、部署导出及原模型对照 |
| `target.py` | 顶层硬件默认值、描述符编码/解码、内存规划与访问检查 |
| `verify_model.py` | manifest校验、序列化DDR软件执行、逐层golden及RTL dump比较 |
| `test_compiler.py` | 描述符字节布局、容量、量化、数据完整性及错误检测回归 |
| `npu_config.json` | 模型内存与布局配置 |
| `fc_layout.py` | 标准库FC物理布局、输入/权重/参数打包、描述符生成与逻辑输出提取，兼容Python2.7/3 |
| `test_fc_layout.py` | 无NumPy依赖的FC对齐与裁剪检查 |
| `compile_onnx.py` / `onnx_frontend.py` | ONNX准备与编译入口、标准库图解析和按需权重读取 |
| `graph_compiler.py` | 通用HWC图的命令生成、量化检查、残差内存复用与DDR导出 |
| `reference_int8.py` | 从真实DDR和描述符执行的独立整数参考 |
| `reference_numpy.py` | 全网络整数参考，分块矩阵乘法并可流式输出逐层golden；不预测周期 |

`artifacts/npu/commands.bin` 是连续的描述符；`weights.bin`、`params.bin` 是聚合数据；`model.bin` 是48字节 `NPUMV0` 头加零输入DDR模板。`ddr/image_XXXX.bin` 已包含各图输入，仿真时从地址0装入。`memory_map.json` 给出每个区域的地址、shape、大小和布局，`manifest.json` 给出每个文件的长度和SHA256，`golden/` 保存逐层输出及中间累加值。

## 描述符格式

每条64字节，16个小端32位字。地址字段固定为64位。

| 字索引 | 内容 |
|---|---|
| 0 | 低8位opcode，高24位flags |
| 1 / 2 / 3 | M / N / K；Pool为H / W / channels；ADD以M表示元素数 |
| 4～5 / 6～7 / 8～9 | A / B / C基址，低字在前 |
| 10～12 | GEMM的A/B/C物理stride；Conv的输入几何、kernel和空间参数 |
| 13～14 | 量化参数基址，低字在前 |
| 15 | `pool_config`：MaxPool 或融合 Conv/MaxPool 的池化窗口与步长；0兼容原2×2、步长2 |

opcode 1/2/3/4/5 分别为 GEMM/Conv/MaxPool/GAP/ADD。GEMM/Conv的flags位0～6依次为Bias、Requant、ReLU、逐通道参数、SAME、跨K的A复用、B驻留；GEMM/Conv 的 flags 位7为 `FUSE_MAXPOOL`，FC融合另需扩展参数头。SAME仅用于Conv。不同opcode的flags语义由对应引擎定义。

非零 `pool_config` 的位7:0、15:8、23:16、31:24依次为窗口高度、窗口宽度、纵向步长、横向步长，每个字段均为1～255。步长可为1、3、5等任意正整数，也可大于窗口，并允许纵横不同。其他运算的字15必须为0。

独立 MaxPool 的字10新增四侧补边，最低到最高字节为上、左、下、右，字11/12仍须为0。`pack_pool_padding(top=0, left=0, bottom=0, right=0)` 生成该字，各字段为0～255且必须小于对应窗口尺寸。输出高度为 `(输入高度+上补边+下补边−窗口高度)//纵向步长+1`，宽度同理。越界位置不读取、不参加最大值比较；有效数据全负时仍保留真实负数最大值。全零补边兼容旧任务。全局平均池化要求字10为0。完整状态机说明见 [最大池化补边](../docs/maxpool_padding.md)。

外部模型转换工具可调用公开配置接口，再把结果写入池化描述符；融合过程直接继承该层配置：

```python
from target import pack_pool_config, unpack_pool_config, pack_pool_padding, pool_output_shape, pool_line_words

pool_descriptor['pool_config'] = pack_pool_config(3, 2, 1, 5)
assert unpack_pool_config(pool_descriptor['pool_config']) == (3, 2, 1, 5)
height, width = pool_output_shape(28, 28, pool_descriptor['pool_config'])
words = pool_line_words(28, 28, 8, pool_descriptor['pool_config'])

# 独立池化：ResNet-50首个池化右/下各补1。
pool_descriptor['pool_config'] = pack_pool_config(3, 3, 2, 2)
pool_descriptor['words10_12'] = [pack_pool_padding(bottom=1, right=1), 0, 0]
assert pool_output_shape(112, 112, pool_descriptor['pool_config'],
                         pool_descriptor['words10_12'][0]) == (56, 56)
```

`encode()` 缺省把字15写成0；`decode()` 仅在该字非零时返回 `pool_config`，因此原部署报告和原描述符可继续逐字段比对。这里的 SmallCNN 导出入口仍按原模型的2×2、步长2生成池化，后续全连接层形状与原黄金数据保持一致；通用配置用于具有相应层参数和内存布局的模型描述符，不通过全局开关改变已有模型语义。

## 可选的卷积—池化融合

`--fuse-conv-pool` 将符合条件的相邻 Conv 与 MaxPool 合为一条描述符，默认仍导出原来的五条命令。融合描述符保留未池化卷积的 M/N/K 与输入几何，C 基址改为原池化输出地址，flags 位7置1，并继承池化描述符的字15。例如原本 flags=7 的卷积，其描述符字0由 `0x00000702` 变为 `0x00008702`。

融合需要卷积输出为重定量后的 INT8，N满足完整COLS通道组约束，M允许尾块，阵列列数不小于4且为4的倍数，通道为四通道组。卷积输出高宽可为奇数，只要容得下配置的池化窗口。

融合池化仍只支持不补边的 VALID 规则。独立池化字10非零时，融合 pass 明确保留原 Conv 与 Pool 任务和补边字段，并记录回退原因；`pool_line_words(..., pool_padding=...)` 也拒绝非零补边，不能用融合缓存公式表示已支持补边融合。

池化入口保存后处理后的原始 INT8 输入，缓冲和窗口读取不提前计算最大值。令窗口高度为 KH、输入宽度为 W、通道数为 C，全部通道的 KH 行原始数据需要 `KH × W × (C/4)` 个32位字，容量与池化步长无关。全量不超过顶层 `POOL_LINE_WORDS` 时沿用原调度；全量超限但 `KH × W × (pe_cols/4)` 可容纳时，每次完成一组 `pe_cols` 通道的全部空间位置，复用缓冲处理下一组，仍只发一条融合命令。只有最小通道块也放不下才保留原 Conv 与独立 MaxPool 两条命令及原池化配置。FC 按 HWC 输出，仍要求全通道原始行缓冲能够容纳。

`pool_line_words` 继续返回全通道需求；`pool_fusion_buffer_plan` 返回 `full_words`、`minimum_words`、`active_words`、`channel_tiled` 和 `fits`。融合报告增加 `channel_tiled`、`pool_full_line_words`、`pool_active_line_words`、`pool_channel_block_channels`，最终完整输出张量的地址和布局不变。分块模式可能增加卷积输入读取，并关闭跨N块的多K输入复用；容量可容纳不代表总流量或周期一定下降，见[实测取舍](../docs/conv_pool_fusion.md)。

编译器还检查池化输入形状、地址及卷积中间结果是否存在其他消费者或重叠读取，读取范围包括完整池化输入、量化参数头与Bias；池化目的区域按实际池化输出高宽计算，也不得与尚在使用的卷积输入、权重或参数区域重叠，以避免流式提前写回引入读写竞争。不满足的候选保持原两条命令，并在 `compilation_report.json` 的 `fusion.skipped_pairs` 中记录原因。

运行期间，下游写回暂时不能接收数据时，通过 ready/valid 握手暂停池化和上游卷积，已占用缓存不被覆盖；下游恢复后继续。最小通道块仍超限的配置在执行前回退，不依赖执行到一半向DDR溢写，也不修改软件指定的步长。

默认4×4配置下，SmallCNN的两组 Conv/Pool 可将五条命令缩为三条。`memory_map.json`、模型头和 `commands.bin` 使用实际描述符数量；逻辑层到硬件命令的映射存放于 `descriptor_layers`。报告区分 `fused_pair_count`、`original_descriptor_count` 与 `descriptor_count`。

每个融合对分别报告省去的卷积中间写出 `avoided_intermediate_write_bytes = 输入池化的H×W×C`，以及独立池化逐窗口逻辑读取 `avoided_pool_input_read_bytes = 池化输出H×W×KH×KW×C`；`avoided_intermediate_bytes` 为两者之和。重叠窗口会重复读取同一元素，间隔窗口则跳过部分输入，因此通用配置不能简单按两倍完整特征图计算。原 SmallCNN 的偶数高宽、2×2、步长2仍对应两倍完整中间特征图。以上是逻辑字节统计，不表示实测周期、能耗或实际 AXI 读拍数。

原中间特征图的DDR分配暂时保留，以稳定其余地址；融合时不会写入该区域。软件解释器仍生成卷积及池化的逐层 golden，但被省去的卷积中间结果没有硬件 `load_address`，RTL DDR dump 比较只检查实际写回的输出。该路径不改变原量化参数、执行顺序或池化的有符号比较语义。

权重保存为 `BT[N][aligned_K]`，矩阵A为行优先，激活为HWC。64位操作数DMA要求物理行以8字节对齐；例如逻辑K=9的权重行占16字节。逻辑K决定参与计算的元素数，padding不参与乘加。普通量化参数头为16字节，包含multiplier、shift、输入零点和输出零点；Bias从+16开始，逐通道模式按Bias/multiplier/shift记录保存。

当前SmallCNN编译器面向正方形阵列、相同A/B bank数量；硬件和通用描述符准入已支持逻辑M/N尾块、矩形阵列和独立bank数量。每条真实A/B的K行仍按8字节对齐，通用GEMM的C stride按4字节对齐；卷积输出维持紧凑HWC。无效源lane本地补零，写回按有效行列屏蔽。融合池化允许M尾块，但N仍要求完整COLS通道组。细节见[通用计算尾块](../docs/tail_tiles.md)。完整模型ABI固定INT8/INT32，改变阵列形状或K分块后要重新生成布局。当前环境的Python3编译器回归状态见[验证记录](../docs/validation.md)。

共享FC工具以逻辑尺寸规划完整物理空间，独立保存逻辑行列和物理跨度。`make_fc_descriptor()` 对8位输出生成逐通道量化模式，参数校验允许对应flag并要求启用重定量。TFLite入口已复用权重和参数打包、完整输出分配；动态batch-1输入用行步长0重复读取真实向量，避免在编译时复制尚未产生的上一层输出。分类只取真实行列。逐段代码与真实1×1001×2048验证见 [分类层软件对齐](../docs/fc_alignment.md)。
