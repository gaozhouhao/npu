# 输出缓冲性能比较与简化（2026-10-17）

## 实验目的与结论

比较输出双缓冲、单缓冲和直接从 C SRAM 写回的实际周期，再选择阅读成本较低的实现。所有实验使用同一份 RTL 依赖、输入数据和 AXI 模型，仅替换输出相关模块。

短 K 下，删除第二块缓冲或整块结果缓冲都会增加周期；长 K 下，输入搬运占主导，单缓冲可能与双缓冲相同，直接写回还能省掉快照的尾部开销。因此最终保留两块存储，改用固定乒乓顺序，删除独立 FIFO 和空闲 bank 搜索。

## 相同负载下的周期数

固定 M=N=8；K=4、32、260。周期从命令握手成功计到 done，包括最终 DMA 完成；单位是 NPU 时钟周期，不是 VCS 启动或运行所花的墙钟时间。

INT8 用例包含逐通道 Bias、乘数、移位、ReLU 和饱和，输入含正负数，每次逐元素检查全部 64 个输出。WRITE_GAP=8 表示每个 AXI 写 beat 前插入 8 个等待周期。A_REUSE=1、K=260 时进入现有外部 PSUM 路径。

| 用例 | 原双缓冲 | 单缓冲 | 直接写回 | 简化乒乓 |
|---|---:|---:|---:|---:|
| k4_int32 | 195 | 225 | 243 | 195 |
| k32_int32 | 370 | 370 | 409 | 370 |
| k260_int32 | 3303 | 3303 | 3294 | 3303 |
| k4_int8 | 224 | 224 | 255 | 224 |
| k260_int8 | 3303 | 3303 | 3294 | 3303 |
| k260_psum_int32 | 2418 | 2418 | 2418 | 2418 |
| k260_psum_int8 | 2403 | 2403 | 2403 | 2403 |
| k4_int32_gap8 | 707 | 737 | 755 | 707 |
| k4_int8_gap8 | 298 | 328 | 383 | 298 |
| k260_psum_int8_gap8 | 2499 | 2499 | 2499 | 2499 |


各列分别为原双缓冲、实验单缓冲、实验直接写回、最终采用的简化乒乓双缓冲。同一用例中，四种实现的读写请求数量和数值结果一致。

原有顶层三描述符回归（纯 GEMM INT32、Bias INT32、Bias/Requant/ReLU INT8）结果：

| 实现 | 总周期 |
|---|---:|
| 原双缓冲 | 10241 |
| 单缓冲 | 10241 |
| 直接写回 | 10214 |
| 简化乒乓 | 10241 |

顶层原双缓冲日志中 compute_dma_overlap=0、snapshot_dma_overlap=0，这解释了这组长 K 负载为什么用不上第二块缓冲。该结论不能推广到短 K 和慢写总线用例。

## 正式实现如何阅读

`rtl/memory/c_result_buffer.sv` 从 177 行减少至 103 行。接口与现有调用方式保持一致。

- 每块缓存只有 EMPTY、CAPTURE、READY、WRITING 四个状态。
- capture_bank 按 0、1、0、1 选择接收位置；最后一行写入后翻转。
- dma_bank 按同样顺序发送；DMA 完成后才翻转并释放旧 bank。
- 上游按 0 到 ROWS-1 逐行供数，因此不需要重复的行顺序计数器。
- 生产和发送的顺序固定，因此不需要另外存一份 ready FIFO、头尾指针和队列计数，也不需要搜索空闲 bank。
- 目标地址、行步长、INT8/INT32 格式仍按 bank 保存，DMA 根据这些信息写回矩阵的相应位置。
- row_mem 不复位；只有完整写入后才进入 READY，未初始化内容不会被读取。

默认每块保存一个 4×4 INT32 tile，即 64 B；两块仍为 128 B。本次降低的是控制逻辑和代码复杂度，没有把结果存储容量减半，也没有进行综合面积测量。C/PSUM 存储和累加算法不在本次修改范围内。

## 手动复现

在工程根目录执行：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/gemm_output
vcs -full64 -sverilog -timescale=1ns/1ps \
  -top gemm_output_tb -f sim/filelists/vcs/gemm_output_tb.f \
  -Mdir=build/gemm_output/csrc -o build/gemm_output/simv \
  -l build/gemm_output/compile.log
cd build/gemm_output
./simv +K=4 +INT8=0 -l k4_int32.log
./simv +K=4 +INT8=1 +WRITE_GAP=8 -l k4_int8_gap8.log
./simv +K=260 +INT8=1 +A_REUSE=1 -l k260_psum_int8.log
```

`-f` 列出 RTL、AXI 模型与 Testbench；`-top` 选择顶层；`-Mdir` 放中间编译文件；`-o` 生成仿真程序；`-l` 保存工具日志。`+K`、`+INT8`、`+A_REUSE`、`+WRITE_GAP` 是 Testbench 的运行参数，传给 simv。

日志中的 `PERF ... cycles=...` 是测量结果，`TEST_PASS gemm_output_tb elements=64` 表示 64 个输出已逐个核对。现有 17 行运行脚本未改。

## 实际日志与边界

本次比较目录为 `build/output_compare/20261017_145429/`：

- baseline、single、direct、pingpong：各有 compile.log、每个用例的日志和完整控制台输出。
- `run_cases.sh` 保存实际执行的十条 simv 命令，各实现运行相同命令。
- 四份 `.f` 和候选源文件保留在实验目录，供复查和重编译，未给正式 RTL 增加实现选择开关。
- single_top、direct_top、pingpong_top 保存顶层对照；原顶层基线位于 `build/vcs/npu_top_tb/20261017_145429/`。
- 本文同目录的 `output_buffer_comparison.csv` 保存逐用例周期表。

四个实现各 10 组，共 40 组 GEMM 测试全部通过，最终乒乓版每一组周期与原双缓冲相同。四个顶层对照均通过，最终正式 RTL 的原 executor 回归也通过：`build/vcs/gemm_executor_tb/20261017_150522/`，64 个输出正确，AR=64、AW=16、W=64。

GEMM 性能 Testbench 中，操作数读口和参数读口使用独立内存模型；顶层回归另行覆盖实际共享读通路。这里的周期数不代表完整神经网络推理的性能结论。没有运行模型端到端流程、综合、DFT 或物理实现。

顶层比较为了打印已有统计，统一启用 NPU_PERF_ENABLE。VCS 提示该 TB 未连接新增的统计输出端口；这些都是只读输出，功能端口和数据检查正常。未通过隐藏警告或改变断言使实验通过。
