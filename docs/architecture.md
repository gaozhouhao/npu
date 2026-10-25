# NPU 项目阅读说明

本项目是一套由 DDR 描述符驱动的整数 NPU。默认计算阵列为 4×4，输入为有符号 INT8，乘加结果为 INT32。一次启动可以顺序执行 GEMM、Conv2D、可配置 MaxPool、Global Average Pool 和残差 ADD；全连接层通过 GEMM 执行。Bias、逐张量或逐通道重定量以及 ReLU 位于矩阵乘加之后。

阅读顺序建议是 `rtl/npu_top.sv` → `rtl/control/npu_gemm_engine.sv` → `rtl/compute/gemm_tile_compute.sv`。这三处分别回答“当前执行哪一层”“一个矩阵任务怎样分块搬运”“一个本地 tile 怎样算出来”。本说明给出职责和接口含义，端口定义与接口约定见 [模块接口索引](module_interfaces.md)。

## 目录与命名

```text
rtl/
  npu_top.sv          整机接口、描述符译码、执行单元选择、外部总线路由
  control/           命令读取、GEMM任务组织、tile顺序与调度、性能计数
  compute/           PE阵列、单tile计算、PSUM累加、后处理、Pool与ADD
  dma/               AXI主机、读请求仲裁、矩阵/卷积读取、参数读取、结果写回
  memory/            操作数bank、bank所有权、数据装载、PSUM与结果缓存
sim/
  filelists/rtl.f    活动RTL的统一源文件清单
  tb/unit/           独立功能单元自检，目录与RTL功能分组对应
  tb/integration/    操作数、计算、调度、DMA之间的联合自检
  tb/system/         完整NPU、卷积池化、参数复用与模型测试
  tb/support/        AXI内存模型和验证监视器
  golden/            小规模软件参考计算
  memory/            外部内存仿真及DPI示例
  mbist/             DesignWare MBIST学习用例
compiler/            MNIST部署数据的编译和验证工具
scripts/model/       TFLite模型编译、量化核对、数据流选择
scripts/analysis/    性能日志分析
scripts/synth/       综合与SRAM库的Tcl配置
scripts/dft/         扫描链配置
scripts/atpg/        ATPG配置
scripts/mbist/       MBIST配置
constraints/         时钟与时序约束
artifacts/npu/       已提供的部署镜像、描述符、权重和golden张量
build/               编译产物、运行日志、波形、生成模型与EDA报告
```

模块名以其处理对象和职责命名。`npu_*` 面向整层或整机，`gemm_*` 面向矩阵计算，`operand_*` 表示输入操作数，`result_*` 表示输出结果，`quant_*` 表示量化参数，`axi_*` 表示总线协议。`reader` 产生读取请求，`packer` 将返回的数据流写入指定 lane/bank，`banks` 保存数据，`bank_controller` 管理使用权。

信号中的 `a` 是输入矩阵或卷积展开后的输入，`b` 是权重矩阵，`c` 是输出；`m/n/k` 分别是输出行、输出列、归约维度。`*_q` 是时钟寄存器，`*_addr` 是字节地址或明确注明的本地 SRAM 地址，`*_stride_bytes` 是物理行间距，`*_size` 是逻辑元素数，`*_beats` 是总线拍数。看到 `load_*`、`compute_*`、`capture_*`、`dma_*` 时，可以直接判断信号所在阶段。

## 数据怎样经过整机

```text
CPU / testbench
  start + desc_base + desc_count
                  |
                  v
        +---------------------+
DDR --->| npu_command_reader  |---- opcode / flags / geometry / addresses
        +---------------------+                         |
                                                       v
        +---------------------------- npu_top ----------------------------+
        |                         layer dispatch                          |
        |             /                   |                    \          |
        |            v                    v                     v         |
        |   npu_gemm_engine        npu_pool_engine       npu_add_engine    |
        |    GEMM / Conv / FC       MaxPool / GAP         residual ADD    |
        |            |                    |                     |         |
        +------------|--------------------|---------------------|---------+
                     |                    |                     |
DDR A / B --AXI64--> operand_fetch         |                     |
                     | packed 64-bit words                      |
                     v                                          |
               operand_banks A/B                                |
                     | R x INT8 + C x INT8 each valid K cycle    |
                     v                                          |
              gemm_tile_compute                                 |
              + gemm_array / gemm_pe                            |
                     | R x C x INT32                            |
              +------+-------------------+                      |
              |                          |                      |
        PE accumulator             PSUM SRAM slots              |
        ordinary K tiling          multi-K A reuse               |
              +------------+-------------+                      |
                           v                                    |
                  gemm_postprocess                              |
                  bias / requant / ReLU                         |
                           |                                    |
                    result_tile_buffer                          |
                           |                                    |
                    result_write_dma                            |
                           +----------------+-------------------+
                                            |
                                    AXI32 write -> DDR C
```

整机只有一组外部 AXI 读接口和一组外部 AXI 写接口。外部读数据固定为 64 位，写数据固定为 32 位。操作数走原生 64 位读通路；描述符、量化参数、Pool 和 ADD 使用内部 32 位读取，再通过 `axi_read_width_adapter` 合并到外部 64 位接口。`axi_read_mux` 在读事务期间保留返回数据的归属。写通路由当前活动的 GEMM、Pool 或 ADD 单元驱动。

同一时刻只执行一条层描述符。GEMM 内部可以让操作数预取、当前 tile 计算和此前结果写回发生重叠；层与层之间以完整执行完成为边界。

已有局部融合与通用层间流水的区别、片上特征图交接和后续改造顺序，见[层间流式结构路线图](streaming_roadmap.md)。

GEMM和卷积保留逻辑M/N/K尺寸，按向上取整的块数执行。操作数读取器只读取有效源lane，结果缓冲携带有效行列数，DMA通过动态字节掩码和有效行数结束条件处理尾块。卷积输出仍是紧凑HWC，融合池化跳过物理补齐行。实现与约束见[通用计算尾块](tail_tiles.md)。

设置 Conv 描述符 flags bit7 后，一条描述符执行 Conv → 原 Bias/Requant/ReLU → 可配置 MaxPool。word15 的四个字节依次指定窗口高、窗口宽、纵向步长、横向步长，每项为1～255；word15=0兼容原2×2/步长2。`result_tile_buffer` 的 bank 同时保存空间起点和通道起点；融合消费者按行读取量化后的结果，交给历史模块名 `stream_maxpool2x2`。池化用片上原始 INT8 行缓冲跨计算块保留窗口输入，窗口就绪后读取原始样本交给最大值运算，只将最终池化张量通过 AXI 写回。容量足够时，多K A复用的部分和路径继续使用同一个融合消费者；全通道状态超限时改为 N→M→K，完成一组COLS通道的全部空间位置再复用缓冲，关闭跨N的A复用。只有最小通道块也放不下才保留独立卷积、池化任务。输入字缓存每层失效一次，在层内跨通道块保留。独立池化引擎使用相同几何配置。容量、标志、实测输入重读代价与软件使用方式见 [融合说明](conv_pool_fusion.md)。

## 实际实例关系

全连接显式重排后接池化时，仍按GEMM取数和计算。新增`pool_coordinate_mapper`只转换结果坐标：真实样本的第`j`个输出对应空间索引`j/C`、通道号`j%C`，物理补齐行不送入池化；卷积坐标直接透传。高、宽、通道由软件写入该模式的32字节参数头，完整校验后才启动计算。该模式暂限单样本、完整通道块、VALID池化及全量池化状态可驻留；参见[全连接池化融合](fc_pool_fusion.md)。

融合池化结果通过 `pool_result_dma` 的输出 FIFO 交给独立 AXI writer。FIFO 保存绝对地址与 32 位数据，默认 16 项；地址随数据入队，通道分块产生的非连续地址保持原样。计算端的 ready 由本地窗口缓冲和逐级背压决定，写响应不直接关停输入。源 tile 的有效行全部交接后即可释放，整层完成仍等待窗口、归约、FIFO 和在途写响应排空。

下图按源码中的模块实例展开。`×2` 表示独立的 A/B 实例，`×R×C` 或 `×bank×lane` 表示生成循环；性能计数器由 `NPU_PERF_ENABLE` 决定是否实例化。活动清单包含顶层和 38 个功能子模块，共 39 个模块定义。

```text
npu_top
|-- u_frontend : npu_command_reader
|-- u_desc_reader : axi_read_master                    [32-bit client]
|-- u_npu_gemm_engine : npu_gemm_engine
|   |-- u_gemm_tile_scheduler : gemm_tile_scheduler
|   |   `-- u_gemm_tile_order : gemm_tile_order
|   |-- u_a_buffer_manager / u_b_buffer_manager : operand_bank_controller
|   |-- u_read_path : operand_fetch
|   |   |-- u_a_read_dma / u_b_read_dma : matrix_operand_reader
|   |   |   |-- u_strided_reader : strided_axi_reader
|   |   |   `-- u_operand_packer : operand_packer
|   |   |-- u_conv_patch_reader : conv_patch_reader
|   |   |   `-- u_operand_packer : operand_packer
|   |   |-- u_conv_word_cache : conv_word_cache
|   |   |-- u_read_arbiter : operand_request_arbiter
|   |   `-- u_axi_read_master : axi_read_master          [64-bit operand]
|   |-- u_quant_param_loader : quant_param_loader
|   |-- u_param_axi : axi_read_master                   [32-bit client]
|   |-- u_gemm_tile_compute : gemm_tile_compute
|   |   |-- u_controller : gemm_cycle_controller
|   |   |-- u_a_buffer / u_b_buffer : operand_banks
|   |   |   `-- gen_bank[].gen_lane[].u_lane_sram : operand_sram
|   |   |-- u_gemm_array : gemm_array
|   |   |   `-- gen_row[].gen_col[].u_gemm_pe : gemm_pe
|   |   `-- u_result_sram : sync_sram
|   |-- u_psum_engine : gemm_psum_accumulator
|   |-- u_psum_sram : psum_sram
|   |-- u_result_param_buffer : result_param_buffer
|   |-- u_postprocess : gemm_postprocess
|   |-- u_result_tile_buffer : result_tile_buffer
|   |-- u_result_write_dma : result_write_dma
|   |-- u_pool_coordinate_mapper : pool_coordinate_mapper
|   `-- gen_fused_pool.u_pool : stream_maxpool2x2     [AXI32, optional result consumer]
|       |-- u_input_buffer : pool_window_buffer
|       |-- u_max : pool_max_reducer
|       `-- u_result_dma : pool_result_dma             [result FIFO + DMA]
|           `-- u_writer : axi_write_master
|-- u_pool : npu_pool_engine
|   |-- u_rd : axi_read_master
|   `-- u_wr : axi_write_master
|-- u_residual_add : npu_add_engine
|-- u_axi_read_mux : axi_read_mux                       [32-bit clients]
|-- u_axi_read_width_adapter : axi_read_width_adapter
|-- u_axi64_arbiter : axi_read_mux                      [64-bit external]
`-- u_perf_monitor : npu_perf_counters                  [optional]
```

`npu_add_engine` 与 `result_write_dma` 自己维护 AXI 状态机，其下没有额外的 AXI 主机实例。`operand_sram` 的行为仿真直接保存数据；定义 `NPU_TSMC28` 时，其内部实例为真实 SRAM 宏。

## 模块职责和输入输出

下表按信号组说明接口。所有时序模块共用上升沿 `clk`；有 `reset` 的模块使用高电平同步复位。`gemm_postprocess` 和 `gemm_tile_order` 为组合逻辑，普通 SRAM 内容不做整体复位。

位宽简记：`R=ROWS`、`C=COLS`、`D=DATA_WIDTH`、`A=ACC_WIDTH`、`X=ADDR_WIDTH`、`I=ID_WIDTH`、`T=TILE_COUNT_WIDTH`、`K=clog2(K_TILE_SIZE+1)`；索引位宽至少为 1。默认 `R=C=4`、`D=8`、`A=32`、`X=64`、`I=1`、`T=16`、`K=9`。本地结果一行是 `C×A` 位，默认 128 位。

### 顶层与任务控制

| 模块 | 职责 | 输入信号组及宽度含义 | 输出信号组及宽度含义 |
|---|---|---|---|
| `npu_top` | 启动整段描述符，选择执行单元，汇合总线与运行状态 | `start`；`desc_base[63:0]`；`desc_count[DESC_COUNT_WIDTH-1:0]`；AXI `AR/AW/W ready`、`R data[63:0]`、`B response` | `busy/done/error`；`acc_out[R][C]` 每项 A 位；读地址 X 位、读握手；写地址 X 位、`wdata[31:0]`、`wstrb[3:0]`；可选 64 位性能计数 |
| `npu_command_reader` | 顺序读取每条 64 字节描述符，等待当前层结束后读取下一条 | 启动地址 64 位、描述符数量；32 位 `mem_read_data` 及请求/返回握手；`cmd_ready`、`exec_done` | 64 位 `mem_read_addr`、`mem_read_req`；8 位 `cmd_opcode`、24 位 `cmd_flags`；32 位 M/N/K、stride/param 字段；64 位 A/B/C 基址；`cmd_valid/busy/done` |
| `npu_gemm_engine` | 组织一个 GEMM/Conv/FC 层的分块、搬运、计算、量化和写回 | `cmd_valid`；32 位 M/N/K、stride 和卷积几何；X 位 A/B/C/参数地址；Bias/Requant/ReLU/复用模式；原生 64 位操作数读响应及内部 32 位参数读响应；写响应 | `cmd_ready/busy/done/error`；`acc_out[R][C]` 每项 A 位；操作数 AXI64 读请求；参数 AXI32 读请求；结果 AXI32 写请求 |
| `gemm_tile_scheduler` | 协调 load/compute 两条状态机；申请 bank、触发矩阵、等待写回 | `start`；T 位 M/N/K tile 数；K 位最后一块 K 长度；复用模式；A/B `load_accept/load_done`、`compute_grant`；`matrix_done/writeback_done` | A/B 加载与计算请求、释放许可；T 位加载/计算 tile 索引；K 位加载/计算长度；`matrix_start/clear_acc/writeback_en/busy/done` |
| `gemm_tile_order` | 计算下一个 tile 坐标及 A 复用/释放条件 | T 位 tile 数、当前 `cursor_m/n/k`、计算 N 索引、驻留 A 的 M/K 标签；运行时复用模式 | T 位 `next_m/n/k`；`next_valid`；`reuse_a/allow_new_a_load/release_a/a_reuse_enabled` |
| `npu_perf_counters` | 观察整机和每层的周期、事务、拍数及停顿 | 运行/层开始结束脉冲；8 位 opcode；执行单元忙信号；AXI 握手、last 与写字节使能 | 各项 64 位累计计数；每层完成脉冲；32 位完成层号、8 位层 opcode 及该层的 64 位统计 |

### 运算数据通路

| 模块 | 职责 | 输入信号组及宽度含义 | 输出信号组及宽度含义 |
|---|---|---|---|
| `gemm_tile_compute` | 从本地 A/B bank 执行一个 K tile，保存原始矩阵结果 | `start`、K 位 `tile_k_size`、`clear_acc/writeback_en`；A/B bank/lane/word 地址与打包写数据；本地 C 基址、读使能和读地址 | `busy/done`；`acc_out[R][C]` 每项 A 位；`c_rdata` 一行 C×A 位 |
| `gemm_cycle_controller` | 发出连续 K 索引、等待同步 SRAM 返回、排空阵列、逐行写结果 | `start`、K 位 K 长度、是否清累加器/是否写回 | `clear`；K 索引 `read_addr` 和 `read_en`；延迟一拍的 `feed_valid`；结果 `c_wen` 和行号；`busy/done` |
| `gemm_array` | 对 A/B lane 做行列错拍，连接 R×C 个 PE | `clear`；R 路 D 位有符号 A、C 路 D 位有符号 B；每 lane 的 valid | R×C 个 A 位有符号 `acc_out` |
| `gemm_pe` | 一个有符号乘加单元，逐拍向相邻 PE 传递操作数 | D 位 `a_in/b_in`、各自 valid、`clear` | D 位 `a_out/b_out` 及 valid；A 位有符号累加器 `acc_out` |
| `gemm_psum_accumulator` | 把 PE tile 按行写入指定 PSUM 槽，后续 K 块与旧值相加 | `start/first_k`、槽号；R×C×A 位 `pe_tile`；C×A 位 SRAM 返回行与 `alu_sum` | SRAM 读写槽号、行号、读写使能、C×A 位写数据；借用后处理加法器的 `alu_use_psum/alu_a/alu_b`；`busy/done` |
| `gemm_postprocess` | 每 lane 加 Bias，整数乘法/移位舍入，加输出零点，执行 ReLU 和输出饱和 | 每 lane 的 A 位有符号数据/Bias、32 位 multiplier、6 位 shift；输出零点默认 8 位；Bias/Requant/ReLU 使能 | 每 lane 的 A 位 `data_out_int32`；`OUT_WIDTH` 位 `data_out_int8`，整机取 8 位 |
| `npu_pool_engine` | 在 HWC 特征图上执行可配置四侧补边 MaxPool 或全空间平均池化；越界样本不读取、不比较 | 层命令、GAP 模式；32位窗口/步长及32位四侧补边配置；X 位输入/输出地址；32 位 H/W/channel 数；内部 AXI32 读返回与写响应 | `cmd_ready/busy/done/error`；AXI32 读请求与写数据，输出按四个 INT8 channel 打包 |
| `stream_maxpool2x2` | 接收后处理结果行，复用原始输入行缓冲和窗口读取执行可配置 VALID MaxPool | `start`；32 位高/宽/通道数及窗口/步长配置；输出基址；带 valid/ready 的 COLS×8 位数据和32位空间/通道坐标；AXI写响应 | 输入 ready、busy/error；AXI32 写地址与池化结果，无外存读取接口 |
| `npu_add_engine` | 两个量化 INT8 张量逐元素相加，使用各自零点和乘数映射到输出量化域 | 层命令；X 位 A/B/C/参数地址；32 位元素数；ReLU；内部 AXI32 返回与写响应 | `cmd_ready/busy/done/error`；AXI32 的参数/A/B 读取及打包 C 写回 |

### DMA、读取和写回

表内“读流”包含 `valid/ready/data/last`，“请求”包含 `valid/ready/addr/beats`；地址是 X 位字节地址，`beats` 是 32 位拍数。AXI 的 LEN 为 8 位、SIZE 为 3 位、BURST 为 2 位、RESP 为 2 位、ID 为 I 位。

| 模块 | 职责 | 输入信号组及宽度含义 | 输出信号组及宽度含义 |
|---|---|---|---|
| `operand_fetch` | 汇合 GEMM A、卷积 A、权重 B 的加载路径，连接共享操作数读主机 | A/B 的加载命令、X 位基址、32 位 stride、K 位长度；卷积几何和 padding 零点；A/B bank 授权；AXI64 读返回 | A/B `load_accept/load_done/error`；bank 加载请求/完成；64 位 `a_wdata/b_wdata` 及 bank/lane/word 写地址；AXI64 读请求；总忙/错状态 |
| `matrix_operand_reader` | 将一个矩阵 tile 的逐行读取和操作数装载配合起来 | `load_req`、X 位基址、32 位 stride、K 位 load_size；bank 授权；共享读流、done/error | 加载接受/完成；bank 请求/完成；读请求；对应 SRAM 的 bank/lane/word 写地址与打包词；`busy/error` |
| `strided_axi_reader` | 按 base、行数、有效行字节数及 stride 生成二维读请求 | `start`、X 位 `base_addr`；32 位 `row_count/bytes_per_row/stride_bytes`；共享读流和完成状态；`out_ready` | 各行的读请求；保持行优先顺序的 `out_valid/out_data`；`busy/done/error`；数据宽度取实例 `DATA_WIDTH`，整机操作数为 64 位 |
| `conv_patch_reader` | 从 HWC 输入按卷积坐标采样、补 padding、拼出本地 A tile | 加载请求；32 位图像/卷积几何、M/K 起始位置；8 位 padding 零点；K 位长度；bank 授权；64 位读流 | 64 位读请求与接收握手；64 位缓存写数据和 bank/lane/word 地址；加载/bank 完成；`busy/error` |
| `conv_word_cache` | 卷积专用、直接映射的 64 位读穿缓存；命中返回本地数据，缺失下发读取 | `invalidate`；上游 `s_req_*`；下游 `m_data_* / m_done / m_error`；上游接收许可 | 上游 `s_data_* / s_done / s_error`；下游 `m_req_*` 和数据接收许可；默认 256 行，每行 64 位 |
| `operand_request_arbiter` | 在 A 与 B 请求之间选择一个，并把完整请求的数据和完成路由回原申请者 | `m0_req_*`、`m1_req_*`；两端读流接收许可；共享 `s_data_* / s_done / s_error` | 共享 `s_req_*`；两端各自的 `m0/m1_data_* / done / error`；读数据按实例宽度，整机为 64 位 |
| `quant_param_loader` | 读取逐张量量化头、逐 tile Bias 与可选逐通道乘数/移位 | `global_load_req`、X 位参数头地址；`bias_load_req`、X 位 Bias 地址、逐通道使能；32 位参数读流 | 全局/通道加载接受与完成；全局 32 位 multiplier、6 位 shift、8 位输入/输出零点；C 路 32 位 Bias/乘数和 6 位 shift；读请求及 `busy/error` |
| `axi_read_master` | 将一条内部连续读请求拆成合法 AXI INCR burst，并组合返回流 | X 位 `req_addr`、32 位 `req_beats`；`data_ready`；AXI R 返回和 AR 接收许可 | `req_ready`；AXI AR；内部读流和请求级 `data_last`；`busy/done/error`。数据宽度按实例取 32 或 64 位 |
| `axi_read_mux` | 在两个 AXI 读主机之间选择事务并保留响应归属 | `desc_*`、`gemm_*` 两组 AR；各端 R ready；共享 AXI R | 共享 AR、共享 R ready；分发给获选端的 R 和 AR ready。顶层分别使用一个 32 位和一个 64 位实例 |
| `axi_read_width_adapter` | 将内部 32 位读请求映射到对齐的外部 64 位读，并逐半词返回 | 内部 `s_ar*` 和 `s_rready`；外侧 64 位 `m_rdata`、响应及 `m_arready` | 外侧 64 位读请求及 R ready；内部 32 位 `s_rdata`、response/last/valid 和 AR ready |
| `axi_write_master` | 将内部连续写请求拆成 AXI burst，并等待写响应 | X 位 `req_addr`、32 位 `req_beats`；实例数据宽度的写流；AXI AW/W ready 和 B response | 请求/数据 ready；AXI AW/W/B ready；`busy/done/error`。Pool 实例使用 32 位数据、4 位字节使能 |
| `result_write_dma` | 逐行读取最终 C tile，选择 INT32 或打包 INT8 格式后写 DDR | `tile_valid`、X 位输出地址、32 位行 stride、`int8_mode`；C×A 位同步 C 行返回；AXI写接收/响应 | `tile_accept`；本地 `c_ren/c_raddr`；AXI32 AW/W/B ready；最后不足四字节时的 `wstrb`；`busy/done/error` |
| `pool_result_dma` | 缓存池化结果，独立完成单字 AXI 写回 | `clear`；带 valid/ready 的 X 位地址与32位数据；AXI写接收/响应 | 输入 ready；AXI32 AW/W/B ready；覆盖队列及在途响应的 busy；粘性 error |

### 缓存与存储

| 模块 | 职责 | 输入信号组及宽度含义 | 输出信号组及宽度含义 |
|---|---|---|---|
| `operand_bank_controller` | 管理一个操作数的单/双 bank 所有权和复用 | `load_req/load_done`、`compute_req/compute_done`、`release_bank` | `load_grant/compute_grant`；稳定的 1 位 `load_bank/compute_bank` |
| `operand_packer` | 申请目标 bank，按 lane 优先顺序把打包数据流写入 SRAM | `load_req`、K 位逻辑长度；bank grant/编号；实例 `MEM_WORD_WIDTH` 位数据流，整机为 64 位 | `load_accept/load_done/busy`；bank request/done；`buffer_wen`、bank/lane/word 地址及原宽度 `buffer_wdata` |
| `operand_banks` | 每个 bank、每个 lane 一块 SRAM；按逻辑 K 索引取出各 lane 的元素 | bank/lane/word 写地址、打包写数据；`ren/rbank/r_k_index` | `rdata` 为 `LANE_COUNT×ELEM_WIDTH` 位。A 实例输出 R 个 D 位元素，B 实例输出 C 个 D 位元素 |
| `operand_sram` | 操作数的同步 SRAM 与工艺宏边界 | `ren/raddr`、`wen/waddr/wdata`；宽深由实例参数给出，整机默认 32×64 | 下一拍有效的 `rdata`，默认 64 位 |
| `sync_sram` | 通用行为同步 SRAM，保存本地原始 C 结果 | `ren/raddr`、`wen/waddr/wdata`；本地结果实例数据宽度为 C×A | 下一拍返回一整行 `rdata`；结果深度至少为 `max(K_TILE_SIZE, ROWS)` |
| `psum_sram` | 保存多个输出 tile 的跨 K 部分和，每个槽有 R 行 | 读槽号/行号/使能；写槽号/行号/使能；每行 C×A 位 `wr_data` | 延迟一拍的 `rd_valid` 和 C×A 位 `rd_data` |
| `result_param_buffer` | 以槽号和 N tile 标签保存逐通道 Bias/乘数/shift | `fill_valid/slot/n_tile` 与 C 路 32 位 Bias、32 位乘数、6 位 shift；读取与退休的槽号/T 位标签；clear | `fill_ready`；命中时的 `read_hit` 与 C 路参数；`retire_hit` |
| `result_tile_buffer` | 两个输出 bank，保存后处理 tile 及其空间/通道起点，隔开采集和结果消费 | `capture_start/addr/stride/spatial_base/channel_base/int8_mode`；按行输入 `capture_row_valid/index/data`，行数据 C×A 位；消费者接受/完成及本地读地址 | `capture_ready/capture_row_ready/capture_done`；`result_valid/addr/stride/spatial_base/channel_base/int8_mode`；下一拍的 C×A 位 `dma_rdata`；`busy` |

## 一次启动与接口时序

1. DDR 先放好描述符、输入、权重和量化参数；每条描述符为 16 个小端 32 位字，共 64 字节。opcode `1/2/3/4/5` 分别对应 GEMM、Conv、MaxPool、GAP、ADD。
2. 在 `busy=0` 时设置 `desc_base/desc_count` 并给 `start` 一个时钟脉冲。运行期间保留这些值，新的任务等到当前任务结束后再启动。
3. 命令读取器读取描述符，保持 `cmd_valid`，直到目标引擎给出 `cmd_ready`。GEMM/Conv 的 flags 位 0～6 依次表示 Bias、Requant、ReLU、逐通道参数、SAME、多 K 的 A 复用、B 驻留；bit7 用于 Conv 或显式 FC→HWC→MaxPool 的片上融合。word15 仅独立 MaxPool 与融合 Conv/FC 可非零，其余算子要求为零；融合 FC 的形状由扩展参数头提供。
4. 执行单元完成当前层的计算和外部写回后产生完成事件，命令读取器前进到下一条描述符。全部描述符完成时，顶层输出 `done` 脉冲。
5. 顶层 `error` 保存本次运行遇到的错误，复位或下一次有效启动时清零。检查任务结果时同时查看 `done` 与 `error`。

数据流统一遵守 `valid && ready` 才发生传输：在 valid 已给出而 ready 尚未给出时，上游保持数据和控制信息。请求类接口使用 `req/accept` 或 `req/grant`，完成类接口使用 `done` 脉冲。SRAM 的 `ren` 在当前拍提交读地址，读数据下一拍可用。`axi_read_master.data_last` 表示整条内部请求的最后一拍，AXI `rlast` 表示当前 burst 的最后一拍；跨 burst 的请求可能经历多个 `rlast`。

PE 每个有效 K 周期接收一组 A 行向量和 B 列向量。第 r 行 A 延迟 r 拍，第 c 列 B 延迟 c 拍，相同 k 的操作数在对应 PE 相遇。控制器先清零或保留累加器，发出 K 次读取，再等待阵列排空，最后按行保存原始结果。Bias 和重定量不会改变 `acc_out` 所观察到的原始 PE 累加值。

## 数据布局与数值格式

DDR 中采用小端字节顺序。INT8 数据占一个字节，INT32 占四个字节，64 位操作数 SRAM 词按低字节到高字节保存连续的 8 个 K 元素。

| 对象 | 逻辑布局 | 物理访问含义 |
|---|---|---|
| GEMM A | `A[M][K]`，行优先 | `A_base + m*A_stride_bytes + k`，每条 A lane 是一个输出行 |
| GEMM B | 外部保存 `BT[N][K] = B[K][N]` | `B_base + n*B_stride_bytes + k`，每条 B lane 是一个输出列的权重 |
| Conv 输入 | `input[H][W][C]`，HWC | `base + (h*W+w)*C+c`，channel 连续；patch reader 按 kernel_h/kernel_w/channel 展平为 K |
| Conv 权重 | 每个输出 channel 的完整 kernel 连续，等价于 BT | 输出 channel 为 N，`kernel_h*kernel_w*input_c` 为 K |
| GEMM/Conv 输出 | `C[M][N]` 行优先；Conv 的 M 为输出空间位置 | INT32 时每列四字节，重定量后每列一字节；C stride 为物理行字节数 |
| Pool/ADD | INT8，Pool 使用 HWC | 内部 32 位词同时处理四个相邻 channel/元素 |

矩阵 A/BT 的物理基址及行 stride 使用 8 字节对齐，以适配原生 AXI64 读。最后不足 8 个元素的行由部署数据提供完整物理读词，计算长度仍取逻辑 K；最后一个 K tile 不会把补齐字节计入乘加。输出的 32 位写地址要符合字对齐要求；不足一整个写词的有效字节由 `wstrb` 表示。模型部署负责分配完整物理范围，并对阵列边缘所需的数据做 padding；改变阵列形状后需要重新生成相匹配的模型镜像。

后处理先计算 `acc + bias`，INT32 分支保留累加器宽度。重定量分支计算乘数乘法，按 shift 右移并采用“四舍五入、恰好一半时远离零”的整数舍入，然后加输出零点。ReLU 的下界为输出零点，最终饱和到 INT8 的 `[-128,127]`。逐通道模式为每个输出 channel 使用独立的 Bias、multiplier 和 shift；乘数按正的 31 位有效数使用，shift 字段为 6 位。

## 四类缓存的生命周期

操作数 bank 的状态为 `EMPTY → LOADING → READY → COMPUTING`。加载者取得 EMPTY bank 后写入，完成后转 READY；计算者取得 READY bank 后读出。`compute_done` 时，`release_bank=1` 将其释放为 EMPTY，`release_bank=0` 则保留为 READY，供另一个 tile 复用。A 与 B 各有独立的 bank 控制器。

普通 K 分块保留 PE 中的部分和：第一块清零，中间块继续累加，最后一块写出结果。多 K 的 A 复用会让计算在不同 N tile 间切换，各 N tile 的部分和保存在 `psum_sram` 槽中；第一块直接覆盖目标槽，后续块读取旧行并加上本次 PE 行。默认槽号由 `n_tile % A_REUSE_BLOCK_SIZE` 决定。B 驻留模式用于单个 K tile 的任务。

逐通道量化参数保存在 `result_param_buffer`，以槽号和 N tile 标签命中。其有效期覆盖最终后处理，不能把仍被使用的槽交给不同标签。普通结果路径在快照采集完成时退休参数，因为后处理结果已经固定在结果 bank 中；PSUM 路径在 DMA 写回完成时退休参数。复位或新命令开始时清除有效标签。

普通结果路径将后处理完成的 tile 存入 `result_tile_buffer`。每个 bank 的状态为 `EMPTY → CAPTURE → READY → WRITING → EMPTY`；采集与发送分别按 bank 0、1 交替。采集时已经固定数据、目的地址、stride 与格式。只有收到 DMA 完成事件后，发送 bank 才重新可用。PSUM 路径从槽中的最终行完成后处理并写回。GEMM 层的完成条件包含未结束的结果写回。

## 顶层参数与传播关系

硬件配置入口是 [rtl/npu_top.sv](../rtl/npu_top.sv)。下层索引宽度、每个 SRAM 的词深、lane 数与 tile 计数由上层参数推导。下表中的数据格式参数体现整机模型 ABI；局部计算模块具有独立位宽能力，完整模型路径按 INT8/INT32 格式执行。

Python 模型工具通过 `compiler/target.py` 的 `hardware_defaults()` 读取该顶层的默认值，软件配置文件只保存内存与布局选项。编译不受旧 RTL 源码 SHA256 快照限制。修改顶层参数后，重新编译硬件并生成匹配的部署镜像即可；描述符格式、物理对齐和模型尺寸的实际条件仍然适用。当前 SmallCNN 编译工具自身面向正方形阵列和相同 A/B bank 数量，完整条件见 [部署工具说明](../compiler/README.md)。

| 顶层参数 | 默认值 | 传播路径与作用 | 支持边界 |
|---|---:|---|---|
| `ADDR_WIDTH` | 64 | 顶层路由 → GEMM/Pool/ADD、各读写 DMA、AXI适配器和仲裁器 | 默认使用 64 位地址；描述符地址字段固定 64 位。AXI burst 引擎读取低 12 位页偏移，不能用少于 12 位的地址配置 |
| `DESC_COUNT_WIDTH` | 16 | `npu_top → npu_command_reader` | 描述符数量必须能由该宽度表示，默认最多 65535 条 |
| `TILE_COUNT_WIDTH` | 16 | `npu_gemm_engine → gemm_tile_scheduler → gemm_tile_order`，以及参数标签 | M/N/K 各维的 tile 数、索引和标签都必须能由此宽度表示 |
| `ROWS` | 4 | GEMM引擎 → tile计算/周期控制/阵列、A lane、卷积patch、结果行数、PSUM | 正整数；局部计算已验证 1、2、3、4 行。部署镜像的 M 方向须与硬件和padding一致 |
| `COLS` | 4 | GEMM引擎 → tile计算/阵列、B lane、参数lane、后处理、结果写回 | 正整数；局部计算已验证矩形阵列，结果写回覆盖 2/3/4/5 列。部署镜像的 N/channel 布局须匹配 |
| `DATA_WIDTH` | 8 | GEMM引擎 → 操作数读取/缓存 → tile计算 → 阵列 → PE | 完整描述符/Conv/Pool/ADD路径采用 8 位；局部 GEMM 另有 4/16 位验证 |
| `ACC_WIDTH` | 32 | GEMM引擎 → tile计算/PE、PSUM、后处理、结果缓存与写回 | 完整模型的Bias、参数与输出格式采用 32 位；局部 GEMM 另有 24/48 位验证 |
| `MEM_WORD_WIDTH` | 32 | 内部描述符/参数读通路、写回通路、Pool/ADD连接与性能计数 | 整机 ABI 固定为 32。操作数读通路使用独立的 64 位词宽，外部读端口也是 64 位 |
| `ID_WIDTH` | 1 | 所有AXI主机、仲裁器和宽度适配器 | 至少 1 位；总线返回的 ID 要对应当前请求。增加位数不会增加设计的并发事务能力 |
| `K_TILE_SIZE` | 256 | GEMM引擎 → 调度器、操作数reader/packer/banks、周期控制器 | 完整 GEMM 分块使用正的 8 倍数以保持64位DMA对齐；局部计算的深度可为1。最后一块的有效K可小于此值 |
| `A_BUFFER_COUNT` | 2 | GEMM引擎 → A bank控制器、读取/装载器、A存储bank | 1或2；bank选择接口为1位，可与B独立配置 |
| `B_BUFFER_COUNT` | 2 | GEMM引擎 → B bank控制器、读取/装载器、B存储bank | 1或2，可与A独立配置 |
| `PSUM_SLOT_COUNT` | 4 | GEMM引擎 → `gemm_psum_accumulator/psum_sram/result_param_buffer` | 正整数；启用多K A复用时至少覆盖 `A_REUSE_BLOCK_SIZE` 个槽 |
| `A_REUSE_BLOCK_SIZE` | 4 | GEMM引擎 → scheduler/order；同时用于PSUM与参数槽号计算 | 正整数；须不大于PSUM槽数。值大于1且存在多个K/N tile时才能形成相应复用 |
| `CONV_CACHE_LINES` | 256 | GEMM引擎 → `operand_fetch → conv_word_cache` | 至少2，取2的幂；地址宽度须为缓存索引和tag保留足够位数 |
| `CONV_CACHE_ENABLE` | 1 | GEMM引擎 → `operand_fetch → conv_word_cache.ENABLE` | 0或1；关闭时卷积读请求经旁路发送 |
| `CONV_MAX_REQUEST_BEATS` | 64 | GEMM引擎 → `operand_fetch → conv_patch_reader.MAX_REQUEST_BEATS` | 1～256，以64位拍计；决定连续卷积片段的请求上限，底层AXI主机继续负责burst和4KB边界拆分 |
| `POOL_LINE_WORDS` | 1024 | GEMM引擎 → 融合池化原始输入行缓冲 | 以32位字计，容量按窗口高、输入宽和活跃通道数计算 |
| `POOL_OUTPUT_FIFO_DEPTH` | 16 | GEMM引擎 → `stream_maxpool2x2.OUTPUT_FIFO_DEPTH → pool_result_dma.FIFO_DEPTH` | 正整数，支持1及非二次幂；每项保存ADDR_WIDTH位地址和32位结果，活动写另存一项 |

常用派生关系为：

```text
K_SIZE_WIDTH       = clog2(K_TILE_SIZE + 1)
ELEMS_PER_WORD     = 64 / DATA_WIDTH               # 整机操作数词为64位
OPERAND_WORD_DEPTH = ceil(K_TILE_SIZE / ELEMS_PER_WORD)
RESULT_DEPTH       = max(K_TILE_SIZE, ROWS)
RESULT_ADDR_WIDTH  = max(1, clog2(RESULT_DEPTH))
ROW/LANE/SLOT位宽  = max(1, clog2(对应数量))
```

`NPU_TSMC28` 分支连接固定的 32×64 SRAM 宏。默认 `K_TILE_SIZE=256、DATA_WIDTH=8` 对应每 lane 32 个64位词。选择不同的缓存形状时，行为仿真按参数工作，工艺实现需要匹配的宏与库配置。硬件参数变化还应与编译器生成的内存布局和模型数据一起核对。

## Makefile 使用方式

所有常用入口从仓库根目录调用，`make` 显示帮助。默认仿真器为 VCS。`PARAMS` 覆盖的是所选 testbench 暴露的参数；testbench 再将其传给被测顶层。`CONFIG` 用于区分不同参数的输出目录。

```bash
make list-tests
make test TEST=gemm_tile_compute_tb
make test TEST=gemm_tile_compute_tb CONFIG=rect PARAMS="ROWS=2 COLS=3 A_BUFFER_COUNT=2 B_BUFFER_COUNT=1"
make test TEST=npu_top_tb CONFIG=small PARAMS="K_TILE_SIZE=16 PSUM_SLOT_COUNT=2 A_REUSE_BLOCK_SIZE=2 CONV_CACHE_LINES=32 CONV_MAX_REQUEST_BEATS=8"
make regression
make parameter-check
make stress
make wave
```

| 入口 | 用途与主要输出 |
|---|---|
| `make compile TEST=...` | 编译所选testbench；输出 `build/vcs/<TEST>/<CONFIG>/compile.log` 和可执行文件 |
| `make test TEST=...` | 编译并运行；同目录保存 `simulation.log` 和波形 |
| `make regression` | 运算、缓存、调度、DMA、整机、卷积与池化的功能自检集合 |
| `make parameter-check` | 矩形/1×1阵列、独立A/B bank、小K深度、不同局部位宽和不同输出列数 |
| `make stress` | 参数槽、PSUM/A复用和写回停顿组合 |
| `make wave` | PE自检及VCD/FSDB波形，VCS使用Verdi PLI |
| `make mnist` / `make mnist-all` | 使用仓库部署数据运行一个/全部MNIST图像，并启用性能接口 |
| `make compiler-test` | 运行Python编译器测试，需要Python3及相应依赖 |
| `make resnet8 MODEL=...` | 编译指定TFLite模型、选择数据流并运行整网 |
| `make resnet8-perf MODEL=...` | 整网执行及性能报告；可设置 `DDR_RD_LATENCY` |
| `make synth DESIGN=npu` / `DESIGN=gemm_pe` | 用本地工艺库综合；`synth-hold`为时序修复流程 |
| `make sram-generate` / `make sram-lib` | 生成操作数宏、建立供综合使用的库 |
| `make dft-precheck` / `make dft` | DFT预检查和扫描链插入 |
| `make atpg` / `make atpg-resume` / `make atpg-smoke` | 生成/继续ATPG，并对模式进行仿真 |
| `make mbist` / `make mbist-sim` | SRAM MBIST学习流程与故障注入仿真 |
| `make clean` | 清理build内的对象/依赖文件，保留日志、报告、可执行文件和波形 |

`SIM=verilator` 选择Verilator入口，`DEFINES="NPU_PERF_ENABLE"` 添加宏，`COMPILE_ARGS` 增加编译选项，`RUN_ARGS` 传递仿真plusargs，例如 `RUN_ARGS="+K=260 +INT8=1 +WRITE_GAP=3"`。EDA目标依赖本机的Synopsys工具、PDK、标准单元和SRAM库路径。

## 已验证的范围与当前运行条件

最终目录下的VCS自检覆盖23个功能testbench、10组参数配置和3组stress配置；PE波形入口生成VCD/FSDB。参数配置包括2×3、3×2和1×1阵列、独立A/B bank、4×3阵列且本地K深度为1、INT4/ACC24/word32、INT16/ACC48/word64，以及结果DMA的2/3/4/5列。两组非默认位宽各比较176项计算/结果数据；深度1配置比较84项。

完整顶层的 `K_TILE_SIZE=16、PSUM_SLOT_COUNT=2、A_REUSE_BLOCK_SIZE=2、CONV_CACHE_LINES=32、CONV_MAX_REQUEST_BEATS=8` 配置已通过三条描述符的纯GEMM、Bias INT32、Bias+Requant+ReLU INT8结果核对。该用例运行13213周期，原始最终累加器为6500，操作数读请求1632次，总读请求1689次，写地址请求48次、写数据144拍。这个用例证明这些顶层参数能够一起传播并完成系统执行；卷积缓存的运行行为还需结合卷积自检判断。

MNIST四张图的五层输出均与仓库黄金张量逐字节一致，预测分别为7、2、1、0；每图68542周期。四图使用相同描述符及权重，不重新训练或修改黄金张量。部署manifest的62个文件均通过长度与SHA256核对。

当前执行环境可以运行VCS；未发现Python3与Verilator可执行文件，也未提供ResNet-8 TFLite模型，因此未执行Python编译器测试、Verilator回归、ResNet整网精度/性能验证或本轮工艺综合/DFT/ATPG/MBIST签核。12个EDA Tcl配置已检查语法与路径。全部命令、结果和日志位置见[验证记录](validation.md)。
