# ResNet-50：保留 Burst 的三组对照

2026-10-27，按用户要求停止旧的无 Conv Burst 整网任务，改为所有组保留 Burst。旧任务的部分周期不参与下表，也不用于简历。

## 三组配置

| 项目 | A：Burst，串行供数 | B：Burst，双缓冲 | C：当前精简优化版 |
| --- | --- | --- | --- |
| A/B 物理 Bank | 各 1 个 | 各 2 个 | 各 2 个 |
| 下一 tile 装载与当前 tile 计算重叠 | 无 | 有 | 有 |
| Conv 连续片段 Burst | 相同历史读取器 | 与 A 逐字节相同 | 保留 |
| 内部操作数宽度 | 32 bit | 32 bit | 原生 64 bit |
| 后续数据驻留/复用、PSUM 槽、C 写回重叠 | 无 | 无 | 保留当前已实现功能 |
| 已删除的卷积缓存、读取前瞻和复杂快速获取路径 | 无 | 无 | 无 |
| 层间连接 | 完整写回 DDR，下一条任务独立执行 | 同 A | 同 A |

A→B 测量双缓冲及对应预取调度的收益；B→C 测量后续优化的组合收益；A→C 是统一 Burst 基线上的总收益。B→C 不能拆称每项优化各自的提升，也不能把两段百分比相加。外部读接口统一为 64 bit，故这里不单独测量外部 AXI32→64 的收益。

## 版本来源与公平性

不存在同时支持完整 ResNet-50、又原样去掉全部后续优化的早期整机。A/B 是明确声明的历史源码组合，使用共同的旧 CNN 功能基座及必要功能回补，并非直接把整个旧提交当作可运行的 ResNet-50 基线。

- CNN 功能基座：`00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47`，共同保留量化、Add/Pool/GAP、补边、尾块和外部接口适配。
- Conv Burst 只导入 `fd4a041265034c466b9aa3056786dbe863684f4e` 的 `rtl/dma/conv_patch_loader.sv`，SHA256 为 `30cbcdaed1b0ba4f254abf1ddcf9c1be1c4f42ec6bdd1c5be4d4630340865b74`。不导入该提交的 executor/scheduler，避免带入更早的 A 复用优化。
- A 恢复 `1dc5b2d5d1981f08a8c2cb6efeee73327d2846f4` 的原文串行调度器，executor 只做接口、坐标及末 K 写回完成条件适配；B 保持旧双缓冲调度器和 executor。
- 两组 37 份已有 SV 完全相同，差异限于调度器、executor 适配、Bank 参数及只观察的验证模块/文件列表。A/B 最终源码集合 SHA256 分别为 `f8f89395ae13beb77e814ea3c32f883d3c82507b391c34d754e0a2a7d7d890d2`、`cd89ab3d55fff33b9d9dd7e15dc223f5b5b044f16c76578b6efb03ce70f071e8`。
- C 复用此前完整通过、并与 VCS 全网逐层周期和 DDR 结果完全一致的逐时钟 C++ 测量。其测量源码对应已发布的 `34358ce46fb3df5d925a9e95910f0c7b179b7679` 精简实现，生产 RTL 在本实验中未修改。

运行观察模块验证物理 Bank 数、每个 tile 都有新鲜 A/B 装载、完成及计算次数、串行组无重叠、双缓冲组实际发生读数据与计算重叠，并核对 Conv 的多拍请求及返回数量。内部 Conv 请求按 32-bit 字计数，不能当成外部 AXI64 Burst 数；外部事务和字节另由 AXI 计数器统计。

## 共同测试条件

全部运行使用相同 ResNet-50 部署包、非零 INT8 输入、权重、量化参数、NumPy 参考、逐时钟 C++ 驱动、Verilator/编译器及编译选项。读首拍等待 20 周期，额外写响应等待 0；外部 64-bit 读、32-bit 写，读通路一次一笔在途 Burst，写通路独立。

输入为 224×224×3，输出为 1001 类；共 72 条任务（53 Conv、16 Add、1 MaxPool、1 GAP、1 FC）。有用 MAC 为 3,948,253,952，包含补边的名义 MAC 为 4,089,186,304。逐层结果检查通过后还检查完整 29,404,672 字节 DDR，期望 SHA256 为 `2c20633f1688bd23f1686548b8d1f4729b92a6863aa97f3cec1e056cf83e4f86`。

该部署包使用固定 scale 和 seed8 输入以验证整数执行及性能，未做分类精度验收。驱动不代算算子、不跳过 RTL 时钟，也不向硬件结果区注入 golden。

## 整网测量

| 实现 | 整网周期 | 有用 MAC/周期 | 读取字节 | 写入字节 |
| --- | ---: | ---: | ---: | ---: |
| A：Burst，无双缓冲 | 1,212,904,532 | 3.2552 | 2,093,158,512 | 16,837,097 |
| B：Burst，有双缓冲 | 948,269,129 | 4.1636 | 2,093,158,512 | 16,837,097 |
| C：当前精简优化版 | 489,351,345 | 8.0683 | 1,278,406,224 | 16,837,097 |

- A→B：双缓冲及预取调度：周期减少 **21.82%**，加速 **1.2791×**，节省 264,635,403 周期。
- B→C：后续优化组合：周期减少 **48.40%**，加速 **1.9378×**，节省 458,917,784 周期。
- A→C：双缓冲及后续优化的总收益：周期减少 **59.65%**，加速 **2.4786×**，节省 723,553,187 周期。

三组全部 72 层及完整 29,404,672 字节 DDR 检查通过，逐层数值和最终 DDR SHA256 相同。A/B 的逐层读写流量、Conv 请求与计算核心忙周期相同，增益来自装载与执行的组织变化。B→C 的组合优化还使 DDR 读取量减少 38.92%，有用吞吐从 4.1636 提升至 8.0683 MAC/周期；本实验未单独测量 Burst 本身的收益。

运行观察显示，A 的搬算重叠为 0 周期；B 的装载与计算重叠为 272,397,240 周期，其中实际读取与计算重叠 159,350,067 周期。这里的重叠计数并不直接等于整网节省周期，预取也会受到共享读通路及调度开销影响。

| 算子周期 | A | B | C |
| --- | ---: | ---: | ---: |
| Conv | 1,127,547,226 | 863,436,341 | 405,341,653 |
| FullyConnected | 1,990,463 | 1,465,945 | 642,849 |
| Add | 70,372,320 | 70,372,320 | 70,372,320 |
| MaxPool | 12,309,649 | 12,309,649 | 12,309,649 |
| GlobalAveragePool | 654,849 | 654,849 | 654,849 |

逐层数据、运行参数、日志/报告哈希和各组源码集合见[完整机器结果](reference/resnet50_burst_matrix.json)；小图、RGB 非对齐验证、源码审计及各项正负例见[验证归档](reference/resnet50_burst_matrix_validation.json)。

## 已完成的运行前验证

| 验证图 | A 周期 | B 周期 | A/B 读取字节 | A/B 写入字节 |
| --- | ---: | ---: | ---: | ---: |
| 五算子，多 K 分块：Conv M49/N32/K288、Add、Pool、GAP、FC1001 | 291,453 | 257,904 | 307,912 | 4,681 |
| RGB 非对齐：11×13×3，行跨度 39 字节，7×7/s2/pad3 Conv、Pool、GAP、FC1001 | 84,415 | 79,678 | 42,448 | 1,221 |

两图均采用非零输入，A/B 的 VCS 与逐时钟 C++ 仿真逐层周期、观察计数及完整 DDR 完全相同，均匹配独立 NumPy 参考。RGB 图覆盖非对齐读、补边及 K147/M42 尾块；多 K 图覆盖 K288 跨分块累加。小图数据仅用于功能和仿真一致性验证，其比例不代表整网 ResNet-50 加速比。

源码准备边界检查共 23 项，Burst/预取观察模块正负例 8 项，三组比较器正负例 26 项。比较器拒绝部分网络、不同输入/工具/编译选项、缺少 Burst 或观察模块、额外 RTL 差异，以及未发生真实读取重叠的双缓冲运行。

## 复现入口

保留完整 Git 历史、Python3/NumPy、已验证的旧 CNN 功能快照，以及[历史回退实验](resnet50_rollback_benchmark.md)所述工具链。先用新目录准备 A/B，不能覆盖已冻结的测量源：

```bash
python3 scripts/model/prepare_resnet50_burst_matrix.py \
  --base-metadata build/resnet50-rollback-compare/check/legacy00-rtl/source.json \
  --out build/resnet50-burst-replay
```

以下为 A 组，B 组将两个 `burst_serial` 改为 `burst_double`；其余条件保持一致：

```bash
python3 scripts/model/benchmark_graph_verilator.py \
  --source-metadata build/resnet50-burst-replay/burst_serial/source.json \
  --driver-sha256 5c9f8707ebe6343f407a7237edb93835e7f3c0031933a5f29490840ff2fe750b \
  --package build/resnet50-benchmark/model \
  --reference build/resnet50-rollback-compare/check \
  --out build/resnet50-burst-replay/full-cpp --label burst_serial
```

严格汇总三组，默认要求 72 层及完整 DDR：

```bash
python3 scripts/analysis/compare_resnet50_burst_matrix.py \
  --serial-report build/resnet50-burst-matrix/full-cpp/burst_serial-report.json \
  --double-report build/resnet50-burst-matrix/full-cpp/burst_double-report.json \
  --optimized-report build/resnet50-rollback-compare/cpp-full/current-report.json \
  --serial-log build/resnet50-burst-matrix/full-cpp/burst_serial-rtl/simulation.log \
  --double-log build/resnet50-burst-matrix/full-cpp/burst_double-rtl/simulation.log \
  --out build/resnet50-burst-matrix/comparison.json
```

本机完整日志、冻结源、逐层报告及自动汇总位于 `build/resnet50-burst-matrix/`。旧无 Conv Burst 任务均已取消，历史证据保留在[串行基线归档](resnet50_serial_baseline.md)及[历史回退记录](resnet50_rollback_benchmark.md)，不进入本轮三组对照。
