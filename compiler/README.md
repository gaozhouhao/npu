# MNIST CNN Model Compiler V0

目标源码：`https://github.com/gaozhouhao/npu`，commit `87cc23c73760820701ebd697d2c04df04fcea050`。

本次只新增 Python 编译工具、配置、说明和编译产物。没有修改 RTL、已有 RTL TB、Makefile、原训练代码或 FP32 checkpoint；没有重新训练或重新校准。

实测：前四张图的五条 descriptor 软件功能解释结果与原 PTQ 逐层一致，预测/标签均为 **7、2、1、0**。完整测试集重新运行原整数参考程序得到 **9833/10000 = 98.33%**。软件精度与原版本一致。10 项 Python 回归通过。未运行 Verilator，因此 `rtl_execution_verified=false`；不把软件解释器当作 RTL 仿真。

## 新增文件和命令

以下路径相对于 NPU 仓库根目录：

```text
compiler/compile_model.py    模型检查、布局转换、地址分配、导出和 PTQ 对照
compiler/target.py           Descriptor ABI、硬件配置检查、内存规划
compiler/verify_model.py     BIN 读回、软件 descriptor 解释、可选 RTL DDR dump 比较
compiler/test_compiler.py    10 项 Python 回归及负例
compiler/npu_config.json    硬件和仿真内存配置
compiler/rtl_contract.json  审核源码的提交号、归一化换行后的 SHA256
compiler/README.md          本文
artifacts/npu/              生成的全部部署和 golden 文件
```

原模型目录 `mnist_npu/` 放在仓库旁边，或显式指定 `--model-dir`。它需包含原 `common.py`、`quantize_export.py`、FP32 checkpoint、原 `artifacts/int8/manifest.json` 和六个原始 INT8 weight/INT32 bias BIN。MNIST 测试集从该目录 data/ 读取，缺失时由原程序下载。

在仓库根目录运行，Python 环境需已有原训练时的 NumPy/PyTorch：

```bash
python compiler/compile_model.py --model-dir ../mnist_npu --full-test
python compiler/verify_model.py
python compiler/test_compiler.py
```

省略 `--full-test` 时只对前四张图执行导出验证，报告明确标记准确率来自原 manifest，不冒充本次全测试集复测。`--out` 和 `--config` 可指定输出目录和配置文件。配置值必须与已审核的 npu_top 默认参数一致，V0 拒绝尚未审核的顶层参数覆盖；DDR 容量和对齐可配置。源码变化会触发 contract 错误，需要重新审查，不能只更新哈希绕过检查。

## RTL 审核结论

| 事实 | 行为依据 |
|---|---|
| descriptor 每条 64 B、小端、word0 低 8 位 opcode，高 24 位 flags | command_frontend.sv 的 word_index case |
| flags bit0 bias、bit1 requant、bit2 ReLU，其他位必须零 | npu_top.sv:130、144 |
| Conv 几何占用 word10–12，B stride 自动向上对齐 4 B | npu_top.sv:133–193 |
| Conv M/N 必须是 ROWS/COLS 整数倍 | npu_top.sv:175 |
| A[M][K]、B转置[N][K]，stride 单位为字节，K 偏移为 k_tile*K_TILE | gemm_address_generator.sv:103、121 |
| Patch K 顺序为 `(ky*Kw+kx)*Cin+ci`；输入地址为 `(y*Win+x)*Cin+ci` | conv_patch_loader.sv:268–345 |
| DMA 每个 lane 读取 ceil(K段长/4) 个 word；stride 跨输出通道 | operand_read_dma.sv、strided_read_engine.sv、operand_loader.sv |
| operand_buffer 每 word 存同 lane 的连续 4 个 K，低字节先 | operand_buffer.sv 的 rword_addr/elem_sel/select_element |
| 只有首个 K tile clear，最后一个 K tile 写回 | tile_scheduler.sv 的 clear_acc/writeback_en |
| 参数块 +0 multiplier、+4 shift、+8/+12 保留；+16 后连续 INT32 bias | postprocess_param_loader.sv:308；gemm_executor.sv:133、1022 |
| Bias 相加后重定标，signed ties-away，最后 ReLU/饱和 | postprocess_unit.sv:42、220 |
| C 按行写满 ROWS×COLS，无 M/N 尾 lane 屏蔽，WSTRB 全 1 | c_write_dma.sv:239、284 及行计数 |
| Pool 读取四个 HWC 像素的相同 4-channel word，signed max，紧凑 HWC 写回 | pool2d_engine.sv:82、86 |

其他依赖包括 gemm_read_path、gemm_core、matrix_controller、SRAM、buffer_manager、AXI 主机/仲裁、PE/skew/阵列也已读过。仓库现有 Python 只有 `sim/golden/gemm.py`，训练与量化代码仍复用原模型目录。

Conv1 的 K=9 不改变成 12；只将每个 B 权重行补成 12 B。DMA 读取三 word，但 engine 只计算有效 9 项。Conv2 K=72，无权重行尾补齐。Conv1/2 原 OIHW 权重转换为 OHWI 后按 output-channel row 存储，完全不使用旧的 8×8 tile 文件。

FC 权重转换为 `fc.weight.reshape(10,16,7,7).transpose(0,2,3,1).reshape(10,784)`，使 Pool2 的 HWC flatten 与原 NCHW FC 数学等价。除了实际样本，也使用独立随机 signed 特征验证此置换。

FC 显式编译为 M=4、N=12、K=784。Pool2 只写 FC A 第 0 行 784 B，额外三行零值在初始化镜像中预留。B 第 10、11 行及其 bias 为零。C 分配完整 4×12×4=192 B。注意：额外 A 行的前十个输出会等于真实 bias，**不应把这些输出误判为必须为零**；只使用第 0 行前十个 logits。

RTL 的 signed ties-away 再 ReLU，与原程序先 ReLU 再正数 ties-up 在本模型正 multiplier 条件下等价。Conv scale、multiplier、shift 和所有权重/bias 完全保持不变。额外的无 ReLU 有符号舍入测试覆盖负半值和饱和。Bias/累加结果检查 INT32 范围，中间重定标检查 INT64 范围。

## 每层编译结果

| 层 | M / N / K | M/N/K tile 数 | 计算 tile 总数 | B 行 stride | C 行 stride |
|---|---|---|---:|---:|---:|
| Conv1 | 784 / 8 / 9 | 196 / 2 / 1 | 392 | 12 B | 8 B |
| Pool1 | 输入28×28×8，输出14×14×8 | 非 GEMM | — | — | 紧凑 HWC |
| Conv2 | 196 / 16 / 72 | 49 / 4 / 1 | 196 | 72 B | 16 B |
| Pool2 | 输入14×14×16，输出7×7×16 | 非 GEMM | — | — | 紧凑 HWC |
| FC | 4 / 12 / 784 | 1 / 3 / 4 | 12 | 784 B | 48 B |

FC K 段是 256+256+256+16，A stride=784 B。编译器仅生成五条层级 descriptor，没有生成逐 tile 指令或完整 im2col，也没有重写 scheduler FSM。

## 内存映射（十进制字节地址）

| 区域 | 起始地址 | 字节数 |
|---|---:|---:|
| Conv1 权重 | 0 | 96 |
| Conv2 权重 | 96 | 1,152 |
| FC 权重 | 1,248 | 9,408 |
| Conv1 参数 | 10,656 | 48 |
| Conv2 参数 | 10,704 | 80 |
| FC 参数 | 10,784 | 64 |
| 输入 | 10,848 | 784 |
| Conv1 输出 | 11,632 | 6,272 |
| Pool1 输出 | 17,904 | 1,568 |
| Conv2 输出 | 19,472 | 3,136 |
| Pool2 输出/FC 输入及零行 | 22,608 | 3,136 |
| FC 完整输出 | 25,744 | 192 |
| Descriptors | 25,984 | 320 |

地址不重叠，所有初始化空隙为零。Pool2 输出和 FC 输入是同一个有意共享的区域，作为同一 allocation 记录。DDR 镜像长 26,304 B，小于现有系统 TB 的 `8192×4=32768 B`。编译器还枚举检查各 B/A 段读的 word 对齐和分配边界、所有 C 行写的边界与 4 KiB 限制。

## 所有 BIN 与大小

`i` 为 0000、0001、0002、0003，每个通配条目实际生成四份。

| 文件（相对 artifacts/npu） | 每文件字节数 |
|---|---:|
| commands.bin | 320 |
| weights.bin | 10,656 |
| params.bin | 192 |
| model.bin | 26,352 |
| inputs/image_i.bin | 784 |
| ddr/image_i.bin | 26,304 |
| golden/image_i/conv1.mac.bin | 25,088 |
| golden/image_i/conv1.acc.bin | 25,088 |
| golden/image_i/conv1.bin | 6,272 |
| golden/image_i/pool1.bin | 1,568 |
| golden/image_i/conv2.mac.bin | 12,544 |
| golden/image_i/conv2.acc.bin | 12,544 |
| golden/image_i/conv2.bin | 3,136 |
| golden/image_i/pool2.bin | 784 |
| golden/image_i/fc.mac.bin | 192 |
| golden/image_i/fc.acc.bin | 192 |
| golden/image_i/fc.bin | 192 |
| golden/image_i/logits.bin | 40 |

共 60 个 BIN。`.mac` 是纯 MAC INT32；`.acc` 是加 bias 后 INT32；层名 `.bin` 是实际写回数据。Conv golden 为 HWC，FC 为 MN，logits 为类别 0–9。manifest 记录每个 BIN 的 dtype、shape（复合 model 容器除外）、字节序、长度与 SHA256，另包含两个报告 JSON 的校验；manifest 不递归校验自身。

## 加载协议：DDR 镜像与模型容器不同

最直接：将 `ddr/image_0000.bin` **原样加载到仿真物理地址 0**。该镜像已经包含权重、参数、输入、零 padding 和五条 descriptor；不含 golden 预计算结果。然后设 `desc_base=25984`、`desc_count=5`，复位后给 start。

对仓库 `sim/memory/memory.cpp`，现有 C++ API 的调用方式为：

```cpp
memory_init(32768);
memory_load_bin("artifacts/npu/ddr/image_0000.bin", 0);
// 顶层：desc_base = 25984; desc_count = 5; 复位完成后 start。
```

这段只是后端加载示例：当前 `cnn_pool_npu_tb.sv` 的 AXI responder 使用本地 SV `mem[]`，**并没有接到该 DPI 内存**。不能仅执行 memory_load_bin 就认为 NPU 已能看到数据。应在已有顶层测试中把同一镜像装入其实际 AXI backing memory，或让已有 responder 调用 C++ API；本次未修改任何 TB。现有测试的两 descriptor 初始化、固定循环上限及小样本比较也需在接入完整模型时调整。

如果分别加载文件：先清零整个模拟内存，再将 weights.bin 放到 0，params.bin 放到 10656，inputs/image_i.bin 放到 10848，commands.bin 放到 25984。所有输出区域/FC 输入 padding 必须保持初始化零值。

`model.bin` 是自定义容器，**不能直接加载到 DDR**：

```text
偏移  长度  类型    含义
0     8     bytes   magic = b"NPUMV0\0\0"
8     4     u32 LE  format version = 1
12    4     u32 LE  header bytes = 48
16    8     u64 LE  DDR load base = 0
24    8     u64 LE  payload bytes = 26304
32    8     u64 LE  descriptor base = 25984
40    8     u64 LE  descriptor count = 5
48    ...   bytes   DDR template（输入/输出/padding 为零）
```

解析头后将 payload 装入指定 DDR 地址，再覆盖输入区域。其余文件是无头 raw bytes，无压缩、无 8×8 专用封装。Byte lanes 小端；参数头是 unsigned word，bias 是 signed INT32。

仿真完成后，从地址 25744 读前 40 B，按 `<10i` 解析并 argmax。也可将实际 RTL DDR 内存从地址零导出为 raw BIN，用软件逐层检查：

```bash
python compiler/verify_model.py --ddr-dump actual_ddr.bin --image image_0000
```

此命令比较全部 Conv/Pool 输出和完整 FC 4×12 输出；不会把软件生成的 dump 计作真实 RTL 运行。

## 当前硬件支持程度与后续顺序

源码约束与软件验证表明：在当前默认 4×4 配置下，五条 descriptor 的字段、地址、参数、读写范围及数值格式均兼容，**本模型没有发现必须修改 RTL 才能表达的算子缺口**。原始 FC 1×10 不安全，已通过明确的 4×12 数据/参数/输出 padding 避开；其软件等价性已验证，但全部五条的实际 RTL 时序执行仍待现有顶层测试接入镜像后确认。

现有 `scratchpad.sv:100/103/127/130` 把 A/B 的 lane-count 和 buffer-count 参数互换。默认方阵/相同 buffer 数相等，因此本次不受影响；若未来要支持非方阵或不同 buffer 数，应先修复该参数连接并回归，再扩展 compiler target。此问题已记录，未修改 RTL。

建议下一步仅扩展已有 `cnn_pool_npu_tb.sv` 的数据加载/检查入口，按顺序验证 Conv1（尤其 K=9）、Pool1、Conv2、Pool2、最后 FC 四段 K。实际运行若发现故障，再根据逐层 golden 定位 DMA、调度或计算时序；本次没有新增独立 RTL testbench，也没有屏蔽 Verilator warning。
