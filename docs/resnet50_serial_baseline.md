# ResNet50 串行供数基线

本轮按用户明确选择，连A/B双缓冲预取也去掉，再比较简历中的后续性能优化。生产RTL保持当前精简实现；历史基线仅在独立目录中恢复和测量。

## 基线包含什么

| 项目 | 串行基线 |
| --- | --- |
| 调度 | `1dc5b2d5d1981f08a8c2cb6efeee73327d2846f4` 的原文单状态机 |
| A/B存储 | 各一个物理Bank |
| 执行顺序 | 装载→计算→末K的完整DDR写回→下一tile |
| 输入复用 | 每个K tile重新加载A和B，不做跨N/跨K驻留复用 |
| 卷积读取 | `00fd93c` 的逐INT8字节请求；无连续片段Burst合并和流式拼装 |
| 内部操作数 | 32位；无原生64位、卷积缓存或片段前瞻 |
| 输出组织 | 无多输出PSUM槽，无C结果双缓冲写回解耦 |
| 保留功能 | 4×4 INT8阵列、M/N/K分块、PE跨K累加、量化、Conv/Pool/GAP/Add和尾块 |

普通矩阵/权重DMA原本已有的Burst保留，去掉的是后来加入的卷积连续读取合并。分块及PE中的输出驻留累加用于完成同一数学运算，不等同于后期多输出PSUM SRAM驻留优化。

原始`1dc5b2d`尚无完整CNN，因此不存在可直接原样运行ResNet50、同时没有这些优化的旧整机。本基线明确组合以下来源：

- 原文恢复`1dc5b2d`的串行调度器，SHA256为`cbf12ac6a5d377cc5cf252ad544a26c00e6ab1fa0a2875902cc16a263f9177e3`。
- 沿用已经验收的`00fd93c`旧卷积读取和内部32位实现，以及[历史回退实验](resnet50_rollback_benchmark.md)声明的必要功能回补。
- executor仅适配旧调度接口，并恢复原始完成条件`(core_done && !writeback_en) || c_write_done`；末K等待最后一行DDR写响应，期间坐标保持不变。
- 外部接口统一64位读、32位写，读首拍等待20周期、额外写响应等待0。由此测量共同接口条件下的版本组合收益，不单独量化外部AXI32→64的收益。

相对已验收的00快照，仅调度器、executor接口和top单Bank参数三份已有SV发生变化；新增一份只观察、不反馈的验证模块。37份已有SV保持原文。最终源码集合SHA256为`262af25da19469bccc2a6d72845eac58ceb30a2e9e4280566b672b437b2013e2`。它是历史串行调度的功能兼容基线，不能描述成原封不动的`1dc5b2d`整机。

## 已通过的检查

恢复工具的9项检查，加原有历史恢复的7项检查，共16项通过。可移植工具恢复的41份SV与实际冻结仿真输入逐字节一致。

绑定的观察模块检查单Bank、无搬算重叠、每个K tile的新鲜A/B加载、历史M/N/K顺序、首末K控制及总tile数。独立断言测试中，正常两K场景通过；计算期装载、写回等待期装载、缺少新操作数和错误tile顺序四个负例均被相应断言拒绝。

五算子小图覆盖M49、N32、K288、残差、3×3补边MaxPool、GAP和FC1001尾列。输入为seed8非零INT8，输出包含正负值和多种数值，未使用全零结果代替验证。VCS与逐时钟C++驱动得到相同的逐层计数和完整59,072字节DDR：

| 实现 | 小图周期 | 读取字节 | 写入字节 |
| --- | ---: | ---: | ---: |
| 串行基线 | 2,998,508 | 954,824 | 4,681 |
| 当前精简实现 | 131,770 | 206,376 | 4,681 |

串行卷积208个K tile和FC的251个tile均通过新鲜操作数和无重叠检查。该小图用于验收功能与仿真一致性，其比例不能当作完整ResNet50加速比。

机器可读来源、检查及小图结果位于[验证归档](reference/resnet50_serial_baseline_validation.json)。

## 完整网络状态

完整串行ResNet50已启动，尚未填写其总周期或加速比。模型、输入和golden原样复用之前的224×224×3、72条任务、1001输出部署包，DDR为29,404,672字节，期望最终SHA256为`2c20633f1688bd23f1686548b8d1f4729b92a6863aa97f3cec1e056cf83e4f86`。

对照为同一驱动/工具条件下已完整复现VCS的当前实现：489,351,345周期。必须等串行组全部72层、完整DDR和54条Conv/FC的串行观察检查通过，才计算整网收益。固定scale及非零输入用于整数执行/性能，分类精度未验证。

## 复现

保留完整Git历史、Python3/NumPy和已准备好的00功能兼容源码快照。00运行开始时已写出冻结`source.json`，不要求等其旧整网仿真结束；准备工具不会修改它，也拒绝覆盖已有输出目录：

```bash
python scripts/model/prepare_resnet50_serial_baseline.py \
  --base-metadata build/resnet50-rollback-compare/check/legacy00-rtl/source.json \
  --out build/resnet50-serial-replay/sources

python scripts/model/prepare_serial_baseline_smoke.py \
  --package build/resnet50-serial-replay/smoke-model \
  --out build/resnet50-serial-replay/smoke-check

python scripts/model/benchmark_frozen_graph.py \
  --source-metadata build/resnet50-serial-replay/sources/source.json \
  --package build/resnet50-serial-replay/smoke-model \
  --reference build/resnet50-serial-replay/smoke-check \
  --out build/resnet50-serial-replay/smoke-vcs --label serial
```

逐时钟C++入口需要[回退报告](resnet50_rollback_benchmark.md)中声明的本机工具链。驱动不代算算子、不跳时钟、不向DDR注入golden；全网对照继续使用同一输入和参考目录：

```bash
python scripts/model/benchmark_graph_verilator.py \
  --source-metadata build/resnet50-serial-replay/sources/source.json \
  --driver-sha256 5c9f8707ebe6343f407a7237edb93835e7f3c0031933a5f29490840ff2fe750b \
  --package build/resnet50-benchmark/model \
  --reference build/resnet50-rollback-compare/check \
  --out build/resnet50-serial-replay/full --label serial
```

本机实际运行位于`build/resnet50-serial-baseline/full-cpp/`；`final-status.json`记录自动汇总状态，完整通过后生成`serial-to-current.json`。未结束或失败的运行不能作为整网性能结果。
