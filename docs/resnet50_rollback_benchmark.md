# ResNet50历史版本回退测量

本实验按GitHub历史恢复优化前的计算与读取实现，使用与当前版本相同的完整ResNet50部署包、非零输入和独立整数黄金结果。当前生产RTL不回退、不修改。历史实现只在隔离仿真目录中补齐运行该网络必需的功能，并逐项保留补丁与来源。

## 历史节点

| 组 | 固定提交 | 保留的历史实现 |
| --- | --- | --- |
| legacy00 | `00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47` | 双Bank、内部32位操作数、Conv逐字节单拍读取；无A复用、连续段Burst和C SRAM PSUM |
| legacy46 | `46f756efffccfb9da44fd255661507afca353c05` | 原生64位之前的内部32位实现，已具备早期A复用、Burst、部分和、运行时数据流及写回解耦 |
| current | 已验证精简实现，发布提交 `34358ce46fb3df5d925a9e95910f0c7b179b7679` | 内部64位、早期复用/Burst和现有功能；卷积读缓存与后期获取快路径已删除 |

GitHub确认的早期优化链为 [00fd93c→5ab663a](https://github.com/gaozhouhao/npu/compare/00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47...5ab663ad082f58825e26b823543a8eb6f680a4a0)：`82d10c8` A复用、`fd4a041` 连续读取/流式打包、`fb4545a` C SRAM、`5ab663a` 多K复用。后期为 [46f756e→984c253](https://github.com/gaozhouhao/npu/compare/46f756efffccfb9da44fd255661507afca353c05...984c253c7adbd1daec1f6f6d80b2688d62e82ebd)，包含原生64位、卷积缓存/片段前瞻及调度快路径。

相邻节点间还有功能和写回组织演进。因此完整版本对照给出组合收益，不能把它单独归因于某一个优化，或将阶段百分比直接相加。

## 共同功能与边界

原始旧版不能直接执行全部72条任务。两个历史组使用相同的46版描述符译码/路由和外部AXI64适配接口；历史GEMM、调度器、卷积读取和内部操作数存储保持各自版本。外部总线统一64位读、32位写，读burst首拍等待20周期、额外写响应等待0。00组的内部32位请求通过共同适配器访问外部64位DDR，不把它描述成逐位未改的原始AXI32整机。

必要功能兼容包括：

- 00组补逐通道量化的参数与算术功能，继续使用原单参数bank，不导入PSUM、输入复用、参数槽或写回解耦。为支持同一网络，其参数头/每tile记录由原2/4个word变为4/12个word，并增加全局参数就绪等待；这是明确纳入基线周期的功能开销，并非原版所有时序均不变。
- 两组采用相同的独立Pool/GAP/Add硬件，支持真实网络的3×3补边MaxPool；兼容模块仅从固定当前源码做模块名替换。
- 允许M49卷积进入原计算路径；原loader已经会将无效空间位置填零。
- 原输出DMA只增加逻辑行列边界和末拍WSTRB，完整块的状态与总线事件时序不变。
- 无效分类尾列不再解码邻接DDR中的伪量化参数；保持历史完整参数请求和FSM时序。历史多余lane的物理读取仍保留，所有外部地址继续由testbench检查。
- 卷积权重行按同一部署包的8字节物理对齐，仅改变布局兼容，不引入原生64位读取。

所有72条任务都由RTL执行，未以主机软件代算缺失层，也不省略其周期。输入、权重、描述符、黄金结果保持原始字节。完整网络为224×224×3、53Conv、16Add、1MaxPool、1GAP、1FC和1001输出，部署DDR为29,404,672字节；最终期望哈希为 `2c20633f1688bd23f1686548b8d1f4729b92a6863aa97f3cec1e056cf83e4f86`。固定scale0.0625及seed8非零输入仅用于整数执行/性能，分类精度未测量。

## 当前测量状态

46组已通过全部72层、独立AXI计数及完整29,404,672字节DDR检查。以下两个完整VCS运行采用同一模型、输入、golden、测试平台、运行器、读等待20周期与写等待0周期：

| 版本 | 整网周期 | 外部读取字节 | 外部写入字节 |
| --- | ---: | ---: | ---: |
| legacy46：内部32位 | 621,469,835 | 1,278,799,472 | 16,837,097 |
| current：精简后的内部64位 | 489,351,345 | 1,278,406,224 | 16,837,097 |

该阶段周期减少132,118,490，降低 **21.259035%**，加速 **1.269987倍**。53个卷积合计由537,172,494降至405,341,653周期，降低24.541622%；这些卷积的外部读取量完全一致，均为1,250,357,584字节。因此这部分收益主要体现为内部供数/执行效率提高，不能说成DDR读取流量降低。FC由930,498降至642,849周期；共用Add、MaxPool和GAP周期完全相同。

完整逐层对照、运行条件及源码/报告哈希归档于[机器可读结果](reference/resnet50_rollback_legacy46_to_current.json)。该文件保留实际测量的本地提交 `7c58e5c`，其源码树与发布提交 `34358ce` 相同；没有改写旧报告中的来源。

最早00组仍在运行，尚未填写00到当前的完整优化链收益。中间阶段的21.26%不能替代该数字，也不能用于证明某个独立特性的单项收益。当前已删除卷积缓存和后期获取快路径，这里的收益包含保留下来的64位内部供数及其他版本演进。

运行前已完成必要功能检查：七组历史writer场景通过，完整tile的36条总线事件及周期与未修改历史writer一致；逐通道算术560个独立预期lane向量、参数读取与尾列非法值专项通过；共用Pool的42项配置/补边检查及GAP四项检查通过。

另生成五算子小图，覆盖M49、残差、3×3四侧补边池化、GAP、FC1001尾列和逐通道量化。两组全部五层及完整22,528字节DDR均通过：00组116,242周期，46组49,477周期。小图只验证兼容层，不能用其比例替代完整ResNet50收益。

本地产物位于 `build/resnet50-rollback-compare/`：`legacy00/`、`legacy46/` 保留恢复源码与兼容补丁，`compat/` 保存共用算子，`smoke-check/` 保存烟测，`check/` 保存完整网络运行。每次运行编译的是独立冻结副本，记录全部源码、模型、输入、golden、测试和运行器哈希。

## 复现入口

需要包含上述历史提交的完整Git历史、VCS和Python3/NumPy。使用独立新目录恢复源码，工具拒绝覆盖已有目录：

```bash
python scripts/model/prepare_resnet50_rollback.py \
  --out build/resnet50-rollback-replay
```

准备工具逐项校验原始Git文件、精确补丁和最终源码SHA256。用同一个现有ResNet50参考目录的 `reference.json`、`expected.bin`、`input.hex`、`layers.txt` 原样复制到新的 `build/resnet50-rollback-replay/check/`，保持原golden路径有效，然后分别运行：

```bash
python scripts/model/benchmark_resnet50_rollback.py --variant legacy00 \
  --snapshots build/resnet50-rollback-replay \
  --package build/resnet50-benchmark/model --out build/resnet50-rollback-replay/check
python scripts/model/benchmark_resnet50_rollback.py --variant legacy46 \
  --snapshots build/resnet50-rollback-replay \
  --package build/resnet50-benchmark/model --out build/resnet50-rollback-replay/check
```

两组默认读首拍等待20周期，超时上限200,000,000,000周期，计数为64位。最早版本每个有效字节单独请求，完整仿真可能较长，不能把未结束的部分层计数当作整网结果。运行器使用同一个现有 `run_graph_model.py` 检查器；当前版本可按[精简对照入口](npu_control_cleanup.md)用相同包和时序运行后，再由 `compare_graph_benchmarks.py` 比较完整PASS报告。

兼容性配方还保留两份未实例化的Pool验证模块，以精确复现本次已冻结的编译源码集合。VCS明确指定 `-top graph_model_npu_tb`，这两个模块不执行，也不贡献推理周期。

## 加快历史RTL仿真

`scripts/model/benchmark_graph_verilator.py` 与 `rollback_compat/graph_driver.cpp` 提供逐时钟执行实际RTL的另一种入口。C++只承接原SV测试平台的DDR、复位/启动和检查职责；不代算算子，不跳过时钟，不向DDR注入golden。编译时保留所有冻结源码副本与SHA256，仅排除不再使用的SV测试平台及未实例化的验证模块。Verilator为两态仿真，VCS为四态仿真，因此采用它之前必须核对逐层周期、流量及完整DDR内容；小图已在两个历史版本上通过该核对，整网交叉检查也在进行中。

快慢仿真器只影响主机等待时间，报告中的NPU周期均来自RTL性能计数器。完整对照要求相同模型与内存时序，以及同一驱动和工具条件，或明确记录已通过的完整交叉校验。小图和前缀运行均不能代替完整72层PASS。

本机快速入口需要先准备 `build/rollback-tools/bin/verilator`、`bin/zig-cxx` 两个包装器，以及其使用的 `python/verilator/bin/verilator_bin`、`python/ziglang/zig`。本次使用Verilator wheel 5.48.0内的开发版二进制（自报5.49）及Zig 0.13.0，均只放在build目录，实际二进制和包装器SHA256记录在运行元数据中。它们不是仓库自带或自动安装的依赖；旧VCS入口不依赖这些工具。

```bash
python scripts/model/benchmark_graph_verilator.py \
  --source-metadata build/resnet50-rollback-replay/check/legacy00-rtl/source.json \
  --driver-sha256 5c9f8707ebe6343f407a7237edb93835e7f3c0031933a5f29490840ff2fe750b \
  --package build/resnet50-benchmark/model \
  --reference build/resnet50-rollback-replay/check \
  --out build/resnet50-rollback-cpp-replay --label legacy00
```

入口从已有冻结运行的 `source.json` 及相邻 `source/` 恢复编译输入，并拒绝哈希不符、覆盖已有运行或在编译后修改驱动/源码。对已通过VCS的组，加 `--compare-report <对应VCS报告>` 可生成独立的交叉校验结果。最早版本仍须完成实际RTL推理；不会根据已完成层推算其整网周期。
