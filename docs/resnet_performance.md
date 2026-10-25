# ResNet 独立层执行与性能记录

记录日期：2026-10-25。当前采用每层独立执行、通过 DDR 交接激活的方式，暂不增加跨层特征缓存、混合溢出或跨层条带调度。Conv/FC 继续使用已有的层内操作数复用、tile 双缓冲及计算/搬运重叠；残差张量按生命周期保留在 DDR。编译器复用已结束生命周期的 DDR 地址，不表示硬件存在跨层片上缓存。

本次先复测原 ResNet8，再用真实 ResNet50 权重验证同一套整数执行链。以下周期和流量来自 RTL 仿真；没有新增频率、面积或功耗结果，也没有测量分类精度。

## ResNet8：同条件前后对照

对照版本为 FIFO 合入前的 `9d3ccce` 和合入后的 `3b233df`。两版使用同一份 `resnet8_npu_tb`、相同的序列化模型文件和内存时序：每个 AXI 读 burst 首拍前等待20周期，写 B 响应无额外延迟。阵列为默认4×4。

模型为原 MLPerf Tiny `pretrainedResnet_quant.tflite`，SHA256：`3c002613d1b2475eb51dd78dfb85a546c8ae658dee71cf6ade43b022fe205415`。两种输入均为32×32×3：

- `zero`：实数零量化后的输入，本模型全部为 INT8 的 `-128`。
- `nonzero`：`numpy.random.RandomState(8).randint(-128,128,size=(32,32,3)).astype(numpy.int8)`，运行前按种子重新生成并核对输入哈希。

每种输入分别运行两版 RTL，共四次完整推理。原14条命令的每层输出以及266,880字节部署映像均与独立整数参考逐字节一致；再检查映像之后的781,696字节仍为零，覆盖完整1,048,576字节仿真 DDR。每种输入在前后两版中的完整 DDR 哈希相同。

| 输入 | 原版本周期 | FIFO版本周期 | 周期减少 | 原/现读字节 | 原/现实际写字节 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zero | 1,735,928 | 1,735,928 | 0（0%） | 3,608,696 / 3,608,696 | 114,800 / 114,800 |
| nonzero | 1,735,928 | 1,735,928 | 0（0%） | 3,608,696 / 3,608,696 | 114,800 / 114,800 |

ResNet8 的14条命令为9个 Conv、3个 Add、1个 GlobalAveragePool 和1个 FC，没有 MaxPool 或 Conv/FC→MaxPool 融合，因此没有经过本次修改的融合池化输出 FIFO。实测加速比为1.0，不能从局部 FIFO 压力测试的收益推导该网络会加速。GlobalAveragePool 仍使用池化引擎，它的活动周期不代表执行了 MaxPool。

两种输入的逐层周期与流量也全部相同。下表数值同时适用于前后两版及两种输入，层编号从0开始。

| 层 | 算子 | 周期 | 外部读字节 | 实际写字节 |
| --- | --- | ---: | ---: | ---: |
| 0 | Conv | 99,730 | 183,312 | 16,384 |
| 1 | Conv | 230,674 | 655,376 | 16,384 |
| 2 | Conv | 230,653 | 655,376 | 16,384 |
| 3 | Add | 208,926 | 65,560 | 16,384 |
| 4 | Conv | 109,276 | 335,888 | 8,192 |
| 5 | Conv | 248,917 | 622,608 | 8,192 |
| 6 | Conv | 45,385 | 61,456 | 8,192 |
| 7 | Add | 104,478 | 32,792 | 8,192 |
| 8 | Conv | 126,188 | 315,408 | 4,096 |
| 9 | Conv | 224,021 | 606,224 | 4,096 |
| 10 | Conv | 22,368 | 47,120 | 4,096 |
| 11 | Add | 52,254 | 16,408 | 4,096 |
| 12 | GlobalAveragePool | 26,705 | 8,192 | 64 |
| 13 | FC | 515 | 1,184 | 48 |

总周期还包含层计数窗口之外的5,838周期；总读流量还包含窗口之外的1,792字节。因此不能直接把逐层求和当作端到端总量。FC 的48字节为原部署布局的物理结果写回，分类只读取首行10个逻辑类别。

## 周期、流量与利用率口径

外部读接口为 AXI64，实测451,087个有效读拍，即3,608,696字节。写接口为 AXI32，实测28,700个有效写拍；写入字节按每拍 `popcount(WSTRB)` 累加，共114,800字节。本次 ResNet8 的所有写拍均为完整4字节。一般带尾块的网络应按 strobe 计数，不能统一用写拍数乘4替代实际写入量。

总外部流量为3,723,496字节，包含输入、权重、参数、描述符和激活读写；它不等于 DDR 部署映像大小。下表区分硬件实际执行的 MAC 与去除卷积边界补零、补齐 lane 后的有效模型 MAC。一次乘加计为一个 MAC。

| 指标 | 原版本与FIFO版本 |
| --- | ---: |
| 实际执行 MAC | 12,504,064 |
| 有效模型 MAC | 11,574,592 |
| 有效/实际执行 MAC | 92.5666% |
| 核心活动周期 | 858,855 |
| DMA活动周期 | 1,148,200 |
| 核心与DMA重叠周期 | 718,665 |
| 重叠/核心活动周期 | 83.6771% |
| tile数 | 6,659 |
| 实际 MAC /（16 × 核心活动周期） | 90.9937% |
| 有效 MAC /（16 × 核心活动周期） | 84.2298% |
| 实际 MAC /（16 × 总周期） | 45.0194% |
| 有效 MAC /（16 × 总周期） | 41.6729% |

核心活动期间的占用率和端到端有效利用率分母不同。90.9937%不能解释为整个网络推理期间的有效利用率；端到端有效值为41.6729%。这些比例基于仿真周期，不代表时钟频率、实际推理秒数、功耗或分类准确率。

完整产物位于 `build/resnet8-benchmark/`：`comparison.json` 保存配置、源码、模型和输入哈希及四次正确性结果，`per_layer.csv` 保存逐层前后对照，`performance_detail.json` 汇总实际PE活动探针。提交到仓库的精简记录为 [resnet8_benchmark_summary.json](reference/resnet8_benchmark_summary.json)。

## ResNet8 复现

需要本地 VCS、Python3，以及已生成的 `build/resnet8-compat/zero/`、`nonzero/` 模型目录；每个目录包含 `manifest.json`、`ddr.bin`、`descriptors.bin` 和 `ddr.hex`。模型权重、局部 Python 环境和仿真产物保存在本地，不随 Git 提交。当前机器可使用 `build/resnet8-compat/runtime/bin/python`，无需修改系统 Python。

从仓库根目录运行：

```bash
make resnet8-benchmark \
  BENCH_BASELINE_REF=9d3ccce BENCH_CANDIDATE_REF=3b233df \
  DDR_RD_LATENCY=20
```

模型目录不同可设置 `RESNET8_BENCH_ZERO`、`RESNET8_BENCH_NONZERO`；Python路径不同可设置 `PYTHON`。完整命令包含原权重与来源记录的哈希检查：

```bash
build/resnet8-compat/runtime/bin/python scripts/model/benchmark_resnet8.py \
  --model-dir zero=build/resnet8-compat/zero \
  --model-dir nonzero=build/resnet8-compat/nonzero \
  --model build/resnet8-compat/pretrainedResnet_quant.tflite \
  --provenance build/resnet8-compat/sources.json \
  --zero-input zero --seeded-input nonzero=8 \
  --baseline-ref 9d3ccce --current-ref 3b233df \
  --ddr-read-latency 20 --output build/resnet8-benchmark
```

脚本通过 `git show` 把两版 RTL 放入独立构建目录，再用同一份 testbench 编译和运行；不会切换工作区版本，也不会重新编译或调整模型数据流。复现时应保留固定版本参数，避免默认 `HEAD` 后续变化造成比较对象改变。

## ResNet50：真实权重整数性能验证

本次使用本地真实 `resnet50_v1.onnx`，模型 SHA256 为 `358c5906f4057cfff3506a63bcf7b502e69e566bdaa9ea598466fe002c3bd3fa`。原模型结构审计见 [nvidia_resnet50_audit.json](reference/nvidia_resnet50_audit.json)。真实浮点权重经现有量化与描述符后端生成整数工作负载，保留网络尺寸和残差分支；没有用缩小网络替代完整网络。

部署包位于 `build/resnet50-benchmark/model/`，共72条命令、29,404,672字节：53个 Conv、16个 Add、1个独立 MaxPool、1个 GlobalAveragePool、1个 FC。ReLU 随已有后处理执行；每个独立命令的输出先写 DDR，下一命令再从 DDR 读取。本模型的带 padding MaxPool 保持独立执行。

性能专用量化配置明确记录 `purpose=integer_performance`、`calibrated=false`、`accuracy_not_measured=true`，使用固定激活 scale `0.0625` 和 seed8 的确定性非零输入。该入口不需要伪造校准记录，也不能作为完成分类精度验证的部署包。原 ONNX 的浮点输出、ImageNet top1/top5 和真实数据集校准均未在本次测量。

独立 NumPy 整数参考只读取序列化 DDR 与描述符，不调用编译器的数值辅助函数。它按硬件语义处理 INT32 累加回绕、33位 bias 和有符号舍入；已通过小图、原CNN黄金结果及数值边界用例与标准库标量参考交叉检查。完整72层的参考结果已生成，RTL在每层完成时立即逐字节核对黄金输出，避免激活 DDR 地址复用后覆盖旧层结果；最后再检查完整部署映像。

| 阶段 | 当前记录 |
| --- | --- |
| 真实权重整数包 | 已生成，72条命令、29,404,672字节 |
| 独立 NumPy 参考 | 已生成72层黄金输出与完整DDR期望值；仅为软件参考完成 |
| `9d3ccce` 完整RTL | 运行中，最终正确性/周期/流量待填 |
| `3b233df` 完整RTL | 运行中，最终正确性/周期/流量待填 |
| 前后性能比较 | 等待两次完整RTL及全部数值检查完成 |

上表不将软件参考完成或 RTL 编译成功记作全网络 RTL 通过。两次仿真沿用相同部署包、read20和额外B延迟0；完成后应补充72层检查、完整DDR比较、总/逐层周期及实际AXI读写字节，再计算前后变化。

本地已有原模型时，可用 `make resnet50-model` 生成性能包，用 `make resnet50-benchmark` 运行参考和候选RTL；`RESNET50_ONNX` 可指定本地ONNX路径，`RESNET50_INPUT_SEED`、`RESNET50_BENCH_SCALE` 指定输入与性能量化配置。完整网络仿真及基线对照采用相同文件与参数，保留日志和源码哈希。分类精度留待真实校准数据和独立精度流程完成后另行记录。
