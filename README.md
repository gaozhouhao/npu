# INT8 NPU

这是一个由 DDR 描述符驱动的 SystemVerilog NPU。卷积读取直接进入共享AXI通路，片段规划和计算bank获取各走一条固定状态路径；卷积读缓存与提前获取快路径已删除。默认 4×4 脉动阵列，执行 GEMM、Conv2D、MaxPool、全局平均池化和残差 ADD；全连接层使用 GEMM。矩阵运算支持 Bias、逐通道重定量和 ReLU。

项目的完整阅读入口是 [架构与模块说明](docs/architecture.md)，包括逻辑框图、实际实例树、模块职责和输入输出、参数传播、数据布局及接口时序。[接口索引](docs/module_interfaces.md) 说明当前 38 个模块的接口。[验证记录](docs/validation.md) 说明当前已验证的范围。

不同命令之间保持独立执行、通过 DDR 交接，保留已有局部融合，不增加跨层特征驻留或片上/DDR混合溢出控制。[层间流式结构路线图](docs/streaming_roadmap.md) 保留此前的技术讨论；真实 ResNet 网络的整数执行与性能结果见下文。

融合池化计算结果先进入默认 16 项的输出 FIFO，每项保存目标地址和 32 位数据；独立 DMA 负责写 DDR。源 tile 全部有效行交接后即可释放，整层完成仍等待池化、FIFO 和全部写响应排空。顶层通过 `POOL_OUTPUT_FIFO_DEPTH` 配置容量，支持深度 1 和非二次幂；运行 `make pool-fifo-check` 验证满队列反压和写回解耦。

卷积—池化融合通过描述符 flags bit7 选择，word15 定义窗口高宽和纵横步长，零配置兼容原 `2×2 / stride 2`。后处理结果经结果双缓冲送入池化原始输入行缓冲，窗口回放后再求最大值，只写回池化结果；全部通道状态放不下时按通道块复用缓冲，只有最小通道块仍放不下才回退到独立 Conv/Pool。通道分块可能增加卷积输入读取，需同时比较总流量与周期。融合目前只支持不补边，独立池化支持软件配置四侧补边，越界位置不读取、不参与最大值比较。描述符与状态机见 [最大池化补边](docs/maxpool_padding.md)，融合约束和对照记录见 [卷积—池化融合](docs/conv_pool_fusion.md)。

全连接也可按软件显式指定的高、宽、通道重排后流入同一池化模块。坐标转换只接收真实样本的输出，过滤为4行阵列补齐的其他行。该模式使用扩展参数头，支持单样本、INT8、不补边且完整池化状态可放入缓冲的配置；普通全连接和卷积描述符不变。运行 `make fc-pool-check`，接口和软件生成方式见 [全连接池化融合](docs/fc_pool_fusion.md)。

[NVIDIA 参考模型适配记录](docs/nvidia_reference_model.md)给出已下载 ResNet-50 的实际算子与逐层形状。ONNX入口支持真实权重的72条独立层命令，新增显式 `--benchmark-only` 整数性能模式；该模式使用固定尺度和合成输入，保持 `calibrated=false`，不声称分类精度。运行 `make resnet50-benchmark` 或 `make resnet50-compare`；原SmallCNN/ResNet8入口保留。ResNet-8可用 `make resnet8-benchmark` 做同输入、同DDR时序的版本对照。具体数据和复现方式见[ResNet性能测量](docs/resnet_performance.md)、[编译器说明](compiler/README.md)；ImageNet校准资料边界见[来源核查](docs/resnet50_quantization_sources.md)。

真实ResNet50的72层与完整29,404,672字节DDR已通过整数RTL检查，503,021,224周期；原ResNet8的14层及完整1MiB DDR也通过，1,735,928周期。FIFO改动前后两网的周期和流量均相同，实测加速0%，因为均未使用融合池化输出路径。两网均未测数据集分类精度。

`make resnet50-readpath-benchmark` 固定读取旧版 `f7419986`，用真实ResNet50测量卷积缓存、片段前瞻与tile调度快路径的受控消融，保留相同native64、尾块和补边池化能力，复用相同部署包和黄金结果。实测四项开启后读字节减少9.36%，整网周期增加2.79%，两组均通过72层及完整DDR检查。对照边界与结果见[ResNet50读取优化消融](docs/resnet50_readpath_ablation.md)。

[分类层软件对齐](docs/fc_alignment.md)说明原TFLite入口的1×1001到物理4×1004布局，已通过真实分类层尺寸的整数硬件用例。新增ONNX入口使用尾块支持直接提交逻辑1×1001，保留同一硬件ABI。

当前精简实现已删除卷积读缓存、片段前瞻和计算bank提前获取分支，功能RTL净少335行。相同条件下，ResNet50周期减少2.72%，ResNet8增加14.31%，MNIST普通/融合增加5.09%/6.79%；这些是按网络分别测得的取舍。完整功能、正确性和复现见[控制逻辑精简](docs/npu_control_cleanup.md)。

最新ResNet50测量采用[Burst三组对照](docs/resnet50_burst_matrix.md)：相同Burst的无A/B双缓冲、有A/B双缓冲，以及当前精简优化版。三组均通过72层及完整DDR校验，周期为1,212,904,532→948,269,129→489,351,345；双缓冲减少21.82%，后续优化组合再减少48.40%，相对统一Burst串行基线总减少59.65%。

用户于2026-10-27取消旧卷积无Burst基线的未完成整网运行，状态为`CANCELLED_BY_USER`；旧源码与已通过的小图证据保留。[历史回退测量](docs/resnet50_rollback_benchmark.md)中legacy46→current的621,469,835→489,351,345周期、降低21.26%仍是有效的中间阶段结果；legacy46已含其他优化，不作为新三组的有双缓冲组。

## 从哪里开始

```text
rtl/npu_top.sv                 整机接口与层分发，硬件参数入口
rtl/control/npu_gemm_engine.sv 一层矩阵任务的调度、搬运、计算与写回
rtl/compute/gemm_tile_compute.sv 一个本地 tile 的实际计算和存储
rtl/compute/gemm_array.sv      输入错拍与 PE 网格
rtl/dma/                      AXI、矩阵与卷积读取、量化参数、结果写回
rtl/memory/                   操作数 bank、PSUM、参数与结果缓存
```

`sim/tb/` 分为 unit、integration、system 和 support。仿真与综合共用 `sim/filelists/rtl.f`。`compiler/` 包含共享描述符后端、ONNX与MNIST部署入口，`scripts/model/` 包含TFLite及模型检查工具，`scripts/analysis/` 处理性能日志。综合、DFT、ATPG、MBIST 的工具配置采用 Tcl；常用操作统一由根 Makefile 调用。生成文件都放在 `build/`。

学习 UVM 可以从 [单个 PE 的 UVM 入门实验](docs/uvm_pe_tutorial.md) 开始。`sim/uvm/pe/` 提供一个固定 8 位输入、32 位累加器的最小完整框架，先用定向输入理解 sequence、driver、monitor 和 scoreboard 的连接，再逐步扩展。

## 运行

默认仿真器为 VCS，`make` 显示帮助。

```bash
make regression
make parameter-check
make stress
make mnist-all
make mnist-fused
make fusion-check
make pool-fifo-check
make wave
make uvm-pe
make list-tests
make test TEST=gemm_tile_compute_tb
make test TEST=npu_top_tb CONFIG=small PARAMS="K_TILE_SIZE=16 PSUM_SLOT_COUNT=2 A_REUSE_BLOCK_SIZE=2 CONV_MAX_REQUEST_BEATS=8"
```

使用 `SIM=verilator` 切换仿真器。`PARAMS` 覆盖所选 testbench 暴露的参数，`RUN_ARGS` 传递 plusargs，`DEFINES` 增加宏，`CONFIG` 区分输出目录。日志位于 `build/<SIM>/<TEST>/<CONFIG>/`。

## 配置与部署

可变硬件参数集中在 `rtl/npu_top.sv`，下层容量与索引位宽自动推导。模型工具通过 `compiler/target.py` 读取顶层默认值。模型的描述符、地址、padding 和物理 stride 必须与目标配置匹配，修改阵列形状后应重新生成部署数据。

完整模型 ABI 为 INT8 输入、INT32 累加/参数、64 位 AXI 读和 32 位 AXI 写。局部计算模块支持其他位宽，测试覆盖 INT4/ACC24 和 INT16/ACC48。工艺 SRAM 宏为固定 32×64 规格，选用不同存储容量时需要匹配的工艺宏。

仓库提供四张 MNIST 的完整部署镜像与逐层黄金张量，预测分别为 7、2、1、0。部署格式和编译命令见 [compiler/README.md](compiler/README.md)。ResNet-8 需要本地 TFLite 模型和 Python3 依赖：

```bash
make resnet8 MODEL=models/resnet8/pretrainedResnet_quant.tflite
make resnet8-perf MODEL=models/resnet8/pretrainedResnet_quant.tflite
make resnet8-benchmark
make resnet50-benchmark
```

EDA 入口包括 `make synth`、`make synth DESIGN=gemm_pe`、`make dft-precheck`、`make dft`、`make atpg` 和 `make mbist`，依赖本机工具与工艺库。`scripts/technology.tcl` 集中管理工艺路径；Makefile 可通过 `PDK_ROOT` 和 `BUILD_DIR` 指定位置。

历史审计、迁移和旧实验测量存放在 `docs/history/`。EDA 学习笔记保存实验背景，实际命令与目录以本说明和 Makefile 为准。
