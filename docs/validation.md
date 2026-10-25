# 当前验证记录

更新日期：2026-10-25。下列命令从项目根目录运行，仿真器为VCS O-2018.09-SP2。结果来自实际仿真及自检，不将编译成功当作数值检查通过。下方保留各次历史记录。

## 2026-10-25：池化输出 FIFO 与独立 DMA

Conv/FC 融合池化的32位结果现在先进入 `{绝对地址,数据}` FIFO，由 `pool_result_dma` 独立完成 AXI 写回。顶层 `POOL_OUTPUT_FIFO_DEPTH` 默认16，支持1和非二次幂。源 tile 的有效行全部交接后释放；整层完成继续等待窗口回放、归约、FIFO和所有写响应排空。当前仍是单拍 AXI 写请求，不做 burst 合并。

| 验证入口 | 结果 | 日志 |
|---|---|---|
| `make regression CONFIG=pool-fifo-final` | 34/34个功能testbench通过 | `build/pool-fifo/regression.log` |
| `make compiler-test` | Python3单测128/128通过 | `build/pool-fifo/compiler-tests.log` |
| `make pool-fifo-check` | 7组仿真通过，FIFO深度1/3/16、COLS4/8/12、长写响应停顿 | `build/pool-fifo/fifo-check.log` |
| `make fusion-check` | 20组仿真通过，包括通道分块、跨行、重叠窗口、容量回退及满源bank | `build/pool-fifo/fusion-check.log` |
| `make fc-pool-check FC_PYTHON=build/resnet8-compat/runtime/bin/python` | 13组仿真和19项软件检查通过，包括FC→Conv→FC及真实软件打包数据 | `build/pool-fifo/fc-pool-check.log` |
| `make tail-check FC_PYTHON=build/resnet8-compat/runtime/bin/python` | 11组仿真和26项池化策略检查通过 | `build/pool-fifo/tail-check.log` |
| `make mnist-all CONFIG=pool-fifo`、`make mnist-fused` | 两种模式均四图通过，预测7、2、1、0 | `build/pool-fifo/mnist-all.log`、`mnist-fused.log` |

独立DMA记分板按实际入队和AXI握手逐项核对地址/数据，覆盖满队列同拍入出队、指针回卷、64位非连续地址、AW/W信号稳定、SLVERR/BID错误锁存与恢复，以及复位丢弃活动写和排队数据。池化用例在第一笔B响应被阻塞时继续提交输入，直到所有输出存储占满，再解除停顿，逐字核对全部结果；期间尝试的新start和配置修改不会破坏旧任务。

整机长响应场景设置 `WRITE_RESPONSE_DELAY=2000`、FIFO深度3，观察到B等待期间184次池化输入握手、46次源tile退休，并在最终B响应等待期间保持busy，确认数据交接完成与整层完成已分开。比较提交 `9d3ccce` 的原实现和本次实现，使用相同几何、数值及内存模型配置：

| 融合任务 | 原实现周期 | FIFO深度3周期 |
|---|---:|---:|
| 普通多K，K72 | 35,110 | 34,093 |
| 多K A复用、逐通道量化/ReLU，K72 | 37,561 | 34,506 |
| 单K B驻留，K8 | 33,098 | 32,721 |

上述默认卷积输出为4×8×8，池化2×2/步长2；各任务总读拍和写入字节不变。对照日志为 `build/pool-fifo/before-delay2000.log`、`build/vcs/conv_pool_fused_npu_tb/fifo-overlap/simulation.log`，旧RTL与testbench的隔离副本在 `build/pool-fifo/before/`。

默认MNIST融合每图周期由51,339变为51,318，普通路径仍为68,542，读写流量及全部黄金输出保持一致。默认内存时序下收益很小；FIFO主要吸收有限的写响应停顿，不能提高DDR长期带宽。本次没有进行新的工艺映射或时序/功耗签核。

## 2026-10-25：流式结构核对与发布回归

本次核对已有局部融合与通用层间流水的差距，新增[流式结构路线图](streaming_roadmap.md)，修正文档中的 FC 融合标志及模块数量。路线图中的通用路由、片上 Conv 输入和跨层调度尚未实现；本次没有修改功能 RTL。

发布前重新运行当前工作区的 `make regression CONFIG=streaming-audit`，33/33 个功能 testbench 全部通过；`make compiler-test` 的 Python3 单测 128/128 通过。日志为 `build/streaming-audit/regression.log` 和 `build/streaming-audit/compiler-tests.log`。这一结果验证当前待发布实现，不能作为路线图中未来能力的验证结果。

补充运行 `make mnist-all CONFIG=streaming-publish`、`make mnist-fused` 和 `make uvm-pe CONFIG=streaming-publish UVM_VERBOSITY=UVM_HIGH RUN_ARGS="+ntb_random_seed=1"`：MNIST 两种路径均为四图全部通过，预测 7、2、1、0，普通模式每图 68,542 周期，融合模式每图 51,339 周期；UVM 检查 27 个周期，warning/error/fatal 均为零。捕获日志为同目录的 `mnist-all.log`、`mnist-fused.log` 和 `uvm-pe.log`。

## 2026-10-25：恢复原CNN、ResNet8与UVM学习基线

暂停ResNet-50后，重新运行原模型，不更换主RTL、训练权重或原CNN部署产物。

| 验证 | 结果 | 记录 |
| --- | --- | --- |
| 原SmallCNN普通模式 | 四图的Conv1/Pool1/Conv2/Pool2/FC全部通过，预测7、2、1、0，各68,542周期 | `build/legacy-compat/cnn.log` |
| 原SmallCNN融合模式 | 四图池化/分类输出全部通过，省去的Conv区域保持原值，预测相同，各51,339周期 | `build/legacy-compat/cnn-fused.log` |
| CNN部署包与完整编译器测试 | 文件/描述符/黄金结果检查通过；Python3完整单测128项通过 | `build/legacy-compat/cnn-package-check.log`、`compiler-tests.log` |
| 原ResNet8全零输入 | 原14条命令全部完成；14层及完整266,880字节DDR与独立整数参考零差异 | `build/resnet8-compat/zero-report.json` |
| 原ResNet8非零输入 | `RandomState(8)`生成的INT8输入，原权重不变；同样14层及整个DDR零差异 | `build/resnet8-compat/nonzero-report.json` |
| 用户现有PE UVM练习 | 26笔输入加启动复位，共27次检查；UVM_ERROR/FATAL均0，保留2×6与10笔随机练习 | `build/vcs/pe_uvm/lesson-review/lesson-trace.log` |

两次ResNet8均运行1,735,928周期，使用原 `compile_resnet8_tflite.py`、`optimize_dataflow.py` 和 `resnet8_npu_tb`。新只读工具 `scripts/model/check_legacy_resnet8.py` 直接解释序列化DDR与描述符后比较RTL快照，另用翻转一个DDR字节验证能准确拒绝错误结果。该结果确认NPU整数算术与执行链兼容；不声称TFLite内核逐位一致，也未评测CIFAR数据集精度。CIFAR下载未完成，已停止并删除残缺文件。

恢复的模型来自[MLCommons Tiny固定提交](https://github.com/mlcommons/tiny/blob/bceb91c5ad2e2deb295547d81505721d3a87d578/benchmark/training/image_classification/trained_models/pretrainedResnet_quant.tflite)，SHA256为 `3c002613d1b2475eb51dd78dfb85a546c8ae658dee71cf6ade43b022fe205415`，官方MD5 `2d6dd48722471313e4c4528249205ae3` 已核对。原默认模型路径 `models/resnet8/pretrainedResnet_quant.tflite` 保存同一份本地副本，不纳入Git。来源与固定版本见 `build/resnet8-compat/sources.json`。

系统Python仍保持原配置；局部环境为 `build/resnet8-compat/runtime/bin/python`，含Python3.9、NumPy1.26.4、tflite2.18.0。Miniconda安装器SHA256已与官方索引核对，未修改用户shell配置。Makefile优先使用系统python3，系统没有时使用这份已存在的局部环境。

```bash
make compiler-test
make mnist-all
make mnist-fused
make resnet8
make uvm-pe UVM_VERBOSITY=UVM_HIGH RUN_ARGS="+ntb_random_seed=1"
```

原ResNet8逐字节对照的复现方法：

```bash
make resnet8 MODEL=build/resnet8-compat/pretrainedResnet_quant.tflite \
  MODEL_DIR=build/resnet8-compat/zero RUN_DIR=build/resnet8-compat/zero-rtl \
  RUN_ARGS="+DDR_DUMP=$PWD/build/resnet8-compat/zero-rtl/ddr_dump.hex +DUMP_WORDS=262144"
python scripts/model/check_legacy_resnet8.py \
  --model-dir build/resnet8-compat/zero \
  --rtl-dump build/resnet8-compat/zero-rtl/ddr_dump.hex \
  --rtl-log build/resnet8-compat/zero-rtl/simulation.log \
  --model build/resnet8-compat/pretrainedResnet_quant.tflite \
  --report build/resnet8-compat/zero-report.json
```

UVM教程已同步当前练习：第二笔有效乘加是 `-12+2×6=0`，检查次数为27；从一笔输入的对象赋值、引脚驱动、PE计算、实际采样与比较讲起。只修正过期注释和文档，没有撤回用户练习修改。

## 2026-10-24及此前记录

2026-10-24，新增单样本全连接→显式HWC形状转换→最大池化融合，复用原池化模块，补齐物理行不进入池化。`make regression CONFIG=fc-coordinate-final`的31个功能testbench全部通过；`make fc-pool-check`通过72项坐标检查、6组系统配置和3组真实软件打包数据驱动RTL的逐字节比对。公共及逐输出量化、K260跨块、12通道重叠池化均覆盖。系统检查包含13种非法配置、调度前拒绝、错误恢复及同一硬件的FC→Conv→FC切换；额外四组配置覆盖8列阵列、单K块B驻留及非重复补齐行。修复了新程序读取描述符期间重新锁存上一次子模块错误的问题，并在融合FC准入时拒绝N/K计算块计数截断。

最终软件标准库检查为19项FC池化、4项原FC布局、23项池化策略；完整Python3/NumPy模型前端仍未运行。日志为`build/fc-pool-regression-final.log`、`build/fc-pool-check-final.log`及`build/vcs/fc_pool_fused_npu_tb/fc-final-*/simulation.log`。Design Compiler分析、展开和连接通过，记录为`build/fc-pool-elaborate-final.log`，未进行工艺映射或功耗评估。测试使用确定性整数数据，不是训练模型精度测试。支持范围、参数格式、缓冲容量与复现方法见[全连接池化融合](fc_pool_fusion.md)。

2026-10-23，卷积→池化行缓冲支持容量不足时按COLS通道块复用，软件和硬件容量检查同步。29个功能testbench、融合专项、COLS4/8/12池化单元和原四张MNIST均通过；编译器23项策略测试通过，含90组容量边界，完整Python3/NumPy模型编译仍未运行。4×8×12卷积输出、2×2/步长2、行缓冲仅4个字的测试，周期8,760→7,062、DDR写入480→96字节。但将输入缓存缩小到2个64位字后，原多K A复用场景因输入重读，周期11,513→13,978、总读拍1,394→1,794；因此不把消除中间搬运等同于总流量或功耗降低。日志为`build/pool-channel-regression.log`、`build/pool-channel-fusion-check.log`、`build/pool-channel-compiler.log`及`build/pool-channel-cache-pressure.log`，详细配置和比较口径见[融合说明](conv_pool_fusion.md)。Design Compiler语法、展开和连接通过，未运行工艺映射和功耗时序签核。

2026-10-22 新增分类层软件物理对齐与逻辑输出提取。4项Python标准库单测通过；共享后端生成的部署镜像与描述符已在 `npu_top` 上验证3种场景：逻辑1×1001、K2048的普通补行，等尺寸输入行步长0重复读取，以及逻辑3×5、K9的8位逐通道量化。前两种逐字核对4×1004个32位物理输出，后者覆盖8字节行跨度、非零输入/输出零点、多行裁剪。硬件dump重新调用真实软件提取和分类函数，均通过；真实分数全负的场景证明未裁剪时会误选无效索引1001，裁剪后正确索引为1000。入口为 `make fc-alignment-check`，日志在 `build/fc-alignment/*-driver.log`，数据与结果在对应case目录。用例使用真实层尺寸和确定性整数数据，没有使用ResNet-50训练权重，不是整网或精度测试。

TFLite全连接编译方法已接入共享工具；实际方法提取后用张量接口替身检查通过1×10/K7和1×1001/K2048、非零零点、完整输出分配与非法形状拒绝。记录为 `build/fc-alignment/tflite_fc_checks.py`。该检查不替代本机仍无法运行的Python3/NumPy/TFLite完整前端。代码逐段说明见 [分类层软件对齐](fc_alignment.md)。

2026-10-22 新增独立 MaxPool 四侧补边，描述符字10保存上/左/下/右补边，软件参考与准入同步更新。边界状态机跳过越界读取，首个有效样本初始化最大值。真实尺寸112×112×64到56×56×64的逐字节数值、446,224次有效逻辑读取及50,176次写入检查通过；8种描述符系统场景覆盖负数边缘、四侧补边、小输入、非法配置拒绝和恢复。新增系统用例已纳入完整回归，共28个功能testbench。日志：`build/pool_padding_unit.log`、`build/pool_padding_resnet.log`、`build/vcs/maxpool_padding_npu_tb/padding-system/simulation.log`、`build/pool-padding-regression.log`。

补边为零时保留原读取状态路径。原五描述符及融合三描述符的MNIST四图均通过，预测仍为7、2、1、0；每图周期分别保持68,542和51,312，总线流量也保持下表原值。日志：`build/pool-padding-mnist-all.log`、`build/pool-padding-mnist-fused.log`。可变VALID融合的中间引擎窗口/步长接线也已补齐，并通过3×3、步长2的系统对照；带补边池化仍保留独立路径，不宣称融合支持补边。

本次软件标准库检查通过34项断言，并枚举4,879个非空窗口核对几何和有效坐标，记录为`build/pool-padding/software_checks.py`及同目录日志。完整Python3/NumPy测试仍因环境缺失未运行。DC分析、顶层展开和链接通过，日志`build/pool-padding-elaborate.log`含`POOL_PADDING_ELABORATE_PASS`；未进行映射后面积、时序或功耗评估。实现细节见 [最大池化补边](maxpool_padding.md)。

2026-10-22 新增卷积—池化片上融合，并扩展为运行时可配置1～255窗口/步长。27个功能testbench完整回归通过；专项覆盖重叠窗口、非二次幂和横纵不同步长、跨计算块、反压、容量不足回退及非法配置恢复。原五描述符及融合三描述符的MNIST四图均通过，周期为68,542 → 51,312，写入字节为11,952 → 2,544。运行 `make fusion-check`、`make mnist-all`、`make mnist-fused`；详细约束、数据口径与日志见 [卷积—池化融合](conv_pool_fusion.md)。下列原有记录保留为2026-10-21的验证基线。

| 验证入口 | 实际结果 | 日志 |
|---|---|---|
| `make regression` | 23个功能testbench全部通过，含阵列、控制、bank、参数槽、后处理、调度、DMA、卷积与池化 | `build/vcs/<TEST>/default/simulation.log` |
| `make parameter-check` | 10组配置全部通过 | `build/vcs/gemm_tile_compute_tb/` 与 `build/vcs/result_write_dma_tb/` |
| `make stress` | 普通参数槽、跨K A复用、INT8输出及写背压三组全部通过 | `build/vcs/param_slot_stress_npu_tb/`、`build/vcs/gemm_output_tb/a-reuse/` |
| 顶层小配置 | 三条描述符的INT32、Bias、Requant/ReLU结果全部通过 | `build/vcs/npu_top_tb/small-config/simulation.log` |
| `make mnist-all` | 四图的Conv1/Pool1/Conv2/Pool2/FC逐层黄金数据全部通过 | `build/vcs/mnist_npu_tb/default/simulation.log` |
| `make wave` | PE数值自检通过，生成VCD与FSDB | `build/vcs/gemm_pe_wave_tb/default/` |
| `make uvm-pe` | VCS 自带 UVM 1.2，15 笔定向输入加启动复位，共核对 16 周期的全部 5 个输出；UVM_ERROR/FATAL 均为 0 | `build/vcs/pe_uvm/default/simulation.log` |
| `make uvm-pe UVM_WAVE=1` | 同样通过 16 周期自检，生成包含 PE 引脚的 VCD | `build/vcs/pe_uvm/default/pe_uvm.vcd` |
| UVM 计分板负向检查 | 仅在 build 下将 PE 副本的加法改成减法；计分板报 12 次数值错误，make 返回 2，未输出 TEST_PASS | `build/vcs/pe_uvm/checker_fault/simulation.log` |
| 12个EDA Tcl文件 | 使用Tcl解释器和EDA命令桩检查语法及脚本路径通过 | `build/refactor/eda_tcl.log` |

当时根Makefile中的`REGRESSION_TESTS`列出23个具体testbench；当前数量见本页最新记录，`make list-tests`还可查看独立学习或额外功能用例。Tcl检查未执行真实综合、扫描链插入、ATPG或MBIST流程。

UVM 第一阶段的实现与逐步学习说明见 [PE UVM 入门教程](uvm_pe_tutorial.md)。本轮新增 UVM 后，也重新运行了 `make test TEST=gemm_pe_tb`，原有 PE 用例通过。UVM 定向检查不包含随机测试、功能覆盖率或其他位宽配置。

## 参数覆盖

| 配置 | 自检范围 |
|---|---|
| ROWS2/COLS3，A2/B1 | 矩形阵列、独立bank数量 |
| ROWS3/COLS2，A1/B2 | 反向矩形与反向bank配置 |
| ROWS1/COLS1 | 单PE阵列及最小lane索引 |
| DEPTH1/ROWS4/COLS3 | K存储很小时仍保存完整四行C结果，84次数据比较 |
| DATA4/ACC24/word32 | 局部计算位宽链，176次数据比较 |
| DATA16/ACC48/word64 | 局部计算位宽链，176次数据比较 |
| 输出COLS2/3/4/5 | 各自包含INT32、INT8、WREADY背压及不足整拍的尾字节检查 |

完整顶层小配置为：

```bash
make test TEST=npu_top_tb CONFIG=small-config \
  PARAMS="K_TILE_SIZE=16 PSUM_SLOT_COUNT=2 A_REUSE_BLOCK_SIZE=2 CONV_CACHE_LINES=32 CONV_MAX_REQUEST_BEATS=8"
```

该系统用例运行13213周期，最终原始累加器为6500；操作数读请求1632次，总读请求1689次，写地址请求48次、写数据144拍。卷积读取另有缓存8行、请求上限3拍的实际Conv2D自检通过，证明缓存参数进入卷积功能通路。

参数槽压力测试核对16次参数填充/退休和全部256个输出字节。普通模式1851周期、读请求626次；A复用模式1770周期、读请求434次，并产生128次PSUM行写入。带写背压的GEMM输出用例使用K260、A复用和INT8输出。

## MNIST部署与数据完整性

| 输入 | 预测 | 总周期 | AR事务 | R拍 | AW事务 | W拍 |
|---|---:|---:|---:|---:|---:|---:|
| image_0000 | 7 | 68542 | 3994 | 16454 | 2952 | 2988 |
| image_0001 | 2 | 68542 | 3994 | 16454 | 2952 | 2988 |
| image_0002 | 1 | 68542 | 3994 | 16454 | 2952 | 2988 |
| image_0003 | 0 | 68542 | 3994 | 16454 | 2952 | 2988 |

`artifacts/npu/manifest.json`中62个文件的长度和SHA256均与实际文件一致。52个黄金张量及输入文件保持原始字节。权重按原生64位DMA所需的8字节物理行对齐；逻辑K、量化参数和黄金输出分别独立核对。

## 尚未执行的项目

截至2026-10-21，本机未提供Python3和Verilator，未执行 `make compiler-test` 或Verilator回归。Python3与完整软件回归现已于2026-10-25恢复，见本页最新记录；Verilator回归仍未运行。

截至2026-10-21，本机未提供所需的ResNet8 TFLite模型。该模型现已恢复并完成整网RTL整数对照，仍未评测数据集精度。工艺综合、DFT、ATPG、MBIST与时序签核需在对应工具/库条件下显式运行；固定32×64 SRAM宏的实际工艺实现不由行为仿真结果代替。
