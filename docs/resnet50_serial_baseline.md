# ResNet50 串行供数基线

本页归档旧的卷积无Burst、A/B无双缓冲基线。用户于2026-10-27要求所有对照均保留Burst，该基线的未完成整网运行已取消（`CANCELLED_BY_USER`），由[Burst三组对照](resnet50_burst_matrix.md)取代。以下已完成的小图、断言和源码检查继续有效；生产RTL及构建证据保留。

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

旧的卷积无Burst串行ResNet50运行已取消，状态为`CANCELLED_BY_USER`；取消时未完成全部72层，没有整网周期或加速比。其原模型、输入和golden为224×224×3、72条任务、1001输出部署包，DDR为29,404,672字节，期望最终SHA256为`2c20633f1688bd23f1686548b8d1f4729b92a6863aa97f3cec1e056cf83e4f86`。

同一驱动/工具条件下，当前实现已完整复现VCS的489,351,345周期。这个有效结果予以保留，但不与已取消的部分层计数计算整网收益。后续使用保留Burst的无双缓冲、有双缓冲及当前精简实现三组；其中有双缓冲组仅启用对应的预取调度，不使用已含复用、PSUM和写回解耦的legacy46代替。固定scale及非零输入用于整数执行/性能，分类精度未验证。

## 复现

以下入口仅用于复核已归档的旧源码和小图；本轮性能测量使用[Burst三组对照](resnet50_burst_matrix.md)。需要完整Git历史、Python3/NumPy和已经冻结的00功能兼容源码快照；准备工具不会修改它，也拒绝覆盖已有输出目录：

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

逐时钟C++驱动及工具链说明保留在[回退报告](resnet50_rollback_benchmark.md)。旧整网构建、冻结源码与部分日志仍位于`build/resnet50-serial-baseline/full-cpp/`；`final-status.json`记录取消原因和状态，不再等待或自动生成旧基线的整网收益。驱动不代算算子、不跳时钟、不向DDR注入golden；部分层日志继续仅作为审计证据。
