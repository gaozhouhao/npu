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

- 00组补逐通道量化的参数与算术功能，继续使用原单参数bank，不导入PSUM、输入复用、参数槽或写回解耦。
- 两组采用相同的独立Pool/GAP/Add硬件，支持真实网络的3×3补边MaxPool；兼容模块仅从固定当前源码做模块名替换。
- 允许M49卷积进入原计算路径；原loader已经会将无效空间位置填零。
- 原输出DMA只增加逻辑行列边界和末拍WSTRB，完整块的状态与总线事件时序不变。
- 无效分类尾列不再解码邻接DDR中的伪量化参数；保持历史完整参数请求和FSM时序。历史多余lane的物理读取仍保留，所有外部地址继续由testbench检查。
- 卷积权重行按同一部署包的8字节物理对齐，仅改变布局兼容，不引入原生64位读取。

所有72条任务都由RTL执行，未以主机软件代算缺失层，也不省略其周期。输入、权重、描述符、黄金结果保持原始字节。完整网络为224×224×3、53Conv、16Add、1MaxPool、1GAP、1FC和1001输出，部署DDR为29,404,672字节；最终期望哈希为 `2c20633f1688bd23f1686548b8d1f4729b92a6863aa97f3cec1e056cf83e4f86`。固定scale0.0625及seed8非零输入仅用于整数执行/性能，分类精度未测量。

## 当前测量状态

两组历史整网RTL已启动，结果仍在运行中，尚不填写完整网络加速比。当前精简版已通过72层及完整DDR，为489,351,345周期；只有历史组全部通过同一数值检查后，才计算前后差异。

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
