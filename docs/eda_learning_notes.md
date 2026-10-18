# Synopsys EDA 学习记录

## 当前脚本用法：初学者简化版（2026-10-17）

按用户要求，脚本只负责基本运行流程。之前章节中的源码快照、Git/哈希记录、自动检查和结果汇总属于历史实现，当前已经删除；原有实验记录和产物保留。

所有入口都在工程根目录执行：

```bash
cd /home/ICer/eda/npu-vcs-learning
make vcs-pe
make vcs-pe-wave
# GEMM Core 单项实验：
bash scripts/sim/run_vcs.sh gemm_core_tb
# 已有功能测试全部依次执行：
make vcs-regression
```

`run_vcs.sh` 共 17 行，按下面顺序阅读：

1. `set -e`：一条命令以非零状态退出时，停止继续执行。
2. `top=$1`：第一个参数是 Testbench 顶层名，例如 `pe_tb`。`shift` 移去这个参数，后面的 `"$@"` 将剩余参数传给 VCS。
3. `run_dir=...`：`$PWD` 是当前目录，`date +%Y%m%d_%H%M%S` 产生年月日和时分秒，组成此次输出目录。`mkdir -p` 创建目录。
4. `vcs ...`：编译 RTL 和 Testbench，生成 `simv`。`-full64` 选择 64 位，`-sverilog` 支持 SystemVerilog，`-timescale=1ns/1ps` 设置默认时间尺度，`-top` 选择仿真顶层，`-f` 读取文件表。
5. `-Mdir` 指定中间编译目录，`-o` 指定仿真程序，`-l` 保存工具日志。源码按文件表直接编译，脚本不再复制或计算哈希。
6. `cd "$run_dir"` 后执行 `./simv -l simulation.log`。波形文件也输出到该目录。

参数覆盖仍然直接传给 VCS：

```bash
bash scripts/sim/run_vcs.sh gemm_core_tb   -pvalue+gemm_core_tb.ROWS=2 -pvalue+gemm_core_tb.COLS=3
```

文件表 `sim/filelists/vcs/<top>.f` 明确列出输入。PE 和 GEMM Core 表只列各自需要的模块；其余已有回归表复用 `sim/filelists/rtl.f`。新测试需要手动增加文件表，脚本不再自动搜索源码。Executor 表额外列出 AXI memory model。

波形选项直接放在 `pe_wave_tb.f`：`-debug_access+all` 保留调试访问，`-P` 链接本机 Verdi 的 `novas.tab` 与 `pli.a`，提供 FSDB 系统任务。本机工具路径写在文件表中，方便直接阅读和修改。

每次输出在 `build/vcs/<top>/年月日_时分秒/`，主要看 `compile.log`、`simulation.log`；PE 波形实验还有 `pe.fsdb` 和 `pe.vcd`。

脚本不再生成 `status.txt`，也不额外打印或汇总 PASS。计算结果仍由 Testbench 中的比较和断言判断，在 `simulation.log` 中阅读。本次删除的是运行脚本的额外检查，没有删除硬件测试用例。

删除了两个自制检查/汇总脚本及 `make check`。`make clean` 直接用一条 `find` 命令删除 `BUILD_DIR` 内的 `.o`、`.d`，不再需要清理辅助脚本。旧的结构检查日志及 17 配置结果文件仍作为历史证据保留，不用于声称新脚本已重新完成全部测试。

参数槽压力脚本改为普通、部分和、A 复用三段明确的 Verilator 编译运行命令，去掉路径检查、数组和模式分支。本轮不运行 Verilator 模型流程。

### 简化脚本的本轮真实结果

- `make vcs-pe` 已完成，退出码 0；目录 `build/vcs/pe_tb/20261017_142951/`。`simulation.log` 包含 RESET、MAC、HOLD、CLEAR 四项 PASS 和 `TEST_PASS pe_tb`，结束时间 56000 ps。
- `make vcs-pe-wave` 已完成，退出码 0；目录 `build/vcs/pe_wave_tb/20261017_143216/`。同样四项 PASS；日志显示 Verdi PLI 加载并创建 `pe.fsdb`，生成 FSDB 和 VCD，结束时间 56000 ps。
- 三个修改后的 Shell 脚本通过 `bash -n`；`make -n vcs-pe vcs-pe-wave vcs-regression clean` 已查看命令展开，未执行清理。
- 本轮未重跑 GEMM/顶层完整回归、Verilator 压力测试或 Verdi GUI。原有 17 配置结果文件保持原样。

---

以下为按时间保存的历史实验记录。

## 2026-10-17：PE 成果核对与 GEMM VCS 实验方案

### 已完成的只读核对

- 工程：`/home/ICer/eda/npu-vcs-learning`，分支：`learning/vcs-pe`。
- HEAD 与 PE 保存的 revision 一致：`984c253c7adbd1daec1f6f6d80b2688d62e82ebd`。
- `scripts/sim/run_vcs_pe.sh`、`sim/filelists/vcs/pe_tb.f` 存在，仍未跟踪。
- `build/vcs/pe/run.RRyzia/` 中编译日志、仿真日志、simv、revision 和源码哈希仍存在。
- 当前 `pe.sv`、`pe_tb.sv` 的 SHA256 与归档一致；既有 simulation.log 包含 RESET TEST PASS、MAC TEST PASS，结束时间 46000 ps。本轮没有重新运行。
- 沙箱缺少 bwrap，已通过获准的沙箱外只读命令检查；rg 不可用，使用 find。未检查 License 配置。

### GEMM 架构与接口

默认 4×4 阵列，INT8 有符号乘法、INT32 累加。A 从左向右、B 从上向下传播，input_skew 将第 i 条输入 lane 延迟 i 拍，使相同 k 的数据在 PE(r,c) 相遇。累加值保存在 PE 中，支持多个 K tile 累加。

start 在 IDLE 被接受；tile_k_size、writeback_en 被锁存，clear_acc 决定是否进入 CLEAR。c_base_addr 与读 bank 未锁存，调用方需在使用期间保持稳定。done 在 DONE 状态为高，此时 busy 也为高；下一拍回到 IDLE，busy 才为低。

A/B 每 lane 的 SRAM 为 64×32 bit（默认 K 容量 256）；一个 word 装同一 lane 连续四个 K 元素，低字节对应较小 k。B 按列沿 K 连续存放，即外部组织为 B 转置。逻辑读 k 转为 word=k>>2、elem=k%4；仅 elem=0 时物理读 SRAM，其余元素复用已读 word，elem_sel_q 对齐同步读输出。C 为四个 256×32 bit SRAM bank，共享行地址，一拍写入整行结果。

控制流程：IDLE → 可选 CLEAR → FEED → DRAIN → 可选 WRITEBACK → DONE → IDLE。FEED 发出 K 个请求，最后响应另经 rsp_valid_q/rsp_last_q 跟踪；4×4 的 DRAIN 为 6 拍，WRITEBACK 为 4 拍。需要波形核对最后一次 MAC 与首个 C 写入的边界。

### 静态发现：尚未编译验证

1. gemm_core_tb 漏接 a_wlane/b_wlane，预载 task 使用旧的“同一 k、多 lane”打包；当前接口需要“单 lane、连续 k”打包。TB 地址是 8 bit，物理 word 地址应为 6 bit。
2. bank 初始化在 forever 时钟循环之后，不可达；应移入初始化代码。
3. 首 tile 的 16 个裸 assert 默认失败动作不保证终止，后续 PASS 文本仍可打印；建议统一 else $fatal 并采用四态敏感比较。
4. scratchpad 将 A 的 LANE_COUNT/BUFFER_COUNT 接为 COLS/B_BUFFER_COUNT，B 接为 ROWS/A_BUFFER_COUNT。默认方阵且单 buffer 掩盖此问题，矩形或 A/B buffer 数不同会受影响。修 RTL 前须用户确认。
5. matrix_engine/input_skew/PE 固定 8/32 位，gemm_core 的 DATA_WIDTH/ACC_WIDTH 并非端到端通用参数。

### 现有 TB 意图与验证缺口

意图：两次 K=3；第一次 clear=1、writeback=0，检查 16 个部分和；第二次 clear=0、writeback=1，读取四行 C 并逐元素比较。最终期望行分别为 [301,322,343,364]、[697,754,811,868]、[1093,1186,1279,1372]、[1489,1618,1747,1876]。以上属于测试意图，接口问题修复前不能视为有效覆盖。

缺口：负数/INT8 极值、零、K=1/4/5/256、非法 K、跨 word、非零 C base/边界、reset 中断、忙时 start、连续任务、writeback 禁止时 C 不变、bank 切换/并行预载、矩形阵列、协议断言、功能覆盖统计。

### 待确认方案（尚未执行）

先仅修复 TB 的 lane 接口、连续 K 打包、bank 初始化、断言终止语义；保留原始两 tile 数学用例，不改 RTL。tile0 A lane0 word0 示例为 `{8'd0,8'd3,8'd2,8'd1}`；B lane0 为 `{8'd0,8'd9,8'd5,8'd1}`。第四字节填零但由 tile_k_size=3 屏蔽。

拟创建 sim/vcs/gemm_core.f，按以下顺序列出相对于工程根的源码：

```text
rtl/compute/pe.sv
rtl/compute/input_skew.sv
rtl/compute/systolic_array.sv
rtl/compute/matrix_engine.sv
rtl/memory/sram_model.sv
rtl/memory/operand_buffer.sv
rtl/memory/scratchpad.sv
rtl/core/matrix_controller.sv
rtl/core/gemm_core.sv
sim/tb/integration/gemm_core_tb.sv
```

每次运行创建独立 build/vcs/gemm/run.XXXXXX，保存 git revision、git diff、源码 SHA256 和绝对路径 sources.f。编译与仿真分开保存退出码、工具日志和完整控制台输出。

核心命令（须在创建运行目录和 sources.f 后执行；本轮未执行）：

```bash
vcs -full64 -sverilog -timescale=1ns/1ps \
  -top gemm_core_tb -f sources.f -o simv -l compile.log \
  > compile.console.log 2>&1
timeout 60 ./simv -l simulation.log > simulation.console.log 2>&1
```

- -full64：64 位工具/可执行仿真器；-sverilog：SystemVerilog 解析。
- -timescale：未声明时间单位模块的默认尺度；不覆盖源码显式 timescale。
- -top：唯一仿真根；-f：源文件及选项清单；-o：可执行仿真器路径；-l：工具日志。
- timeout 60：外部墙钟超时；TB 原有 #20000 为 20 us 仿真时间超时，二者解决不同问题。
- > ... 2>&1：同时保存 stdout/stderr，避免遗漏早期诊断。
- 编译内部经历解析、参数展开/generate/端口绑定、代码生成与链接；simv 执行离散事件仿真及 NBA 更新。TB 在 negedge 驱动、posedge 后 #1 采样，避免读取 NBA 更新前数据。
- TB 已有 $dumpfile/$dumpvars，预期输出 gemm_core_tb.vcd。先检查 VCD 层次/信号是否足够；若优化导致必要内部信号不可见，再评估当前 VCS 版本的调试访问选项。不预设 FSDB/Verdi 插件可用。

通过条件：编译和运行退出码正常；没有未解释的端口/位宽警告及断言错误；部分和与 C 共 32 个元素检查通过；有最终 K-TILING TEST PASSED；波形核对请求/响应对齐、最后 MAC、四行 C 写回以及 done/busy。退出码或 PASS 文本不能单独证明成功。

用户确认前不编译、不仿真、不修改 TB/RTL；不进入 UVM、综合或 DFT。

## 2026-10-17：PE 波形实验（用户已授权执行）

### 目的与原理

复用既有 PE 激励，验证 VCS 生成 FSDB 与 VCD 的能力。FSDB 系统任务由 Verdi 的 PLI 接口提供；只保留波形文件而不加载对应源码，无法完整验证 RTL 关联调试。

新增 `sim/tb/unit/compute/pe_wave_tb.sv`，实例化原有 pe_tb，分别调用 `$fsdbDumpfile/$fsdbDumpvars` 和 `$dumpfile/$dumpvars`。未改变原 TB 或 RTL，原 PE 历史结果保持不变。新层次为 `pe_wave_tb.test.dut`。

### 真实执行

- VCS：`/home/synopsys/vcs/O-2018.09-SP2/bin/vcs`。
- Verdi：`/home/synopsys/verdi/Verdi_O-2018.09-SP2/bin/verdi`。
- 已读取厂商 `share/PLI/README.PLI` 与本机 Verdi/Tcl 手册，选用 `share/PLI/VCS/linux64/novas.tab` 和 `pli.a`。
- 执行 `bash scripts/sim/run_vcs_pe_wave.sh`，本次目录 `build/vcs/pe_wave/run.8ANQ9e/`。
- COMPILE_RC=0、SIMULATION_RC=0、RESULT=PASS；日志含 RESET TEST PASS、MAC TEST PASS。
- `pe.fsdb` 约 8.8 KB，`pe.vcd` 约 1.9 KB；FSDB dumper 日志显示成功遍历 pe_wave_tb。
- 新脚本通过 `bash -n`，并已为后续编译增加 180 秒超时；本次首次编译使用的是加超时之前的命令。仿真一直使用 60 秒超时。

编译命令核心如下，脚本使用独立运行目录中的绝对源码清单：

```bash
timeout 180 vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all \
  -P "$pli/novas.tab" "$pli/pli.a" \
  -top pe_wave_tb -f sources.f -o simv -l compile.log \
  > compile.console.log 2>&1
timeout 60 ./simv -l simulation.log > simulation.console.log 2>&1
```

`-P` 注册 FSDB 系统任务并链接对应 PLI 库；`-debug_access+all` 保留调试访问能力，适合本次小设计教学，会增加优化限制与调试开销。无需修改全局 shell 或 License 配置。

### 波形结果

使用厂商工具实际读取 FSDB：

```bash
fsdb2vcd pe.fsdb -o pe.from_fsdb.vcd
```

转换退出码 0。Python 2 文本解析直接 VCD 和转换后的 VCD，在下表时刻得到相同关键值，输出保存在 `waveform-analysis.txt`：

| 时间 | reset | A | B | A/B valid | acc_out |
|---|---|---|---|---|---|
| 5 ns | 1 | 0 | 0 | 0/0 | 0 |
| 20 ns | 0 | 3 | -4 | 1/1 | 0 |
| 25 ns | 0 | 3 | -4 | 1/1 | -12 |
| 35 ns | 0 | 3 | -4 | 1/1 | -24 |
| 45 ns | 0 | 3 | -4 | 1/1 | -36 |

解释：TB 在 20 ns 负沿驱动输入，25 ns 正沿执行第一次 MAC，26 ns 检查得到 -12。随后 valid 没撤销，35/45 ns 继续累加；这是原 TB 的覆盖局限，不能将“Single MAC PASS”理解为已验证无效周期保持。未擅自修复。

### Verdi 加载验证边界

当前 DISPLAY 为空。厂商手册明确 `verdi -batch` 不要求 DISPLAY，且可用 `-play` 执行 Tcl。第一次仅导入源码的 45 秒尝试超时（124），未证明设计导入完成。第二次使用 `sim/verdi/pe_wave_check.tcl`，明确选择 DUT、打开 FSDB、添加关键信号、打印范围并 debExit，退出码 0，输出 `PE_WAVE_TIME_RANGE=0 46000 x 1ps`、`PE_VERDI_WAVE_LOADED`。两次日志均保留；已验证批处理加载链路，可见 GUI 窗口未验证。

成功的批处理命令（在本次运行目录执行）：

```bash
timeout -k 10 120 verdi -batch -sv -f sources.f -top pe_wave_tb \
  -play /home/ICer/eda/npu-vcs-learning/sim/verdi/pe_wave_check.tcl \
  > verdi.console.log 2>&1
```

`-batch` 不需要显示会话；`-sv` 为 Verdi 的 SystemVerilog 输入选项；`-play` 执行 Tcl。`srcSetScope` 选择源代码层次，`wvOpenFile` 打开动态波形，`wvAddSignal` 加入观察信号，`wvGetFileTimeRange` 核对范围，`debExit` 结束进程。命令执行成功不等于已经人工操作过 GUI。

手动 GUI 命令（需在具备图形桌面的终端执行，本轮未验证可见窗口）：

```bash
cd /home/ICer/eda/npu-vcs-learning/build/vcs/pe_wave/run.8ANQ9e
verdi -sv -f sources.f -top pe_wave_tb -ssf pe.fsdb
```

在层次树选择 pe_wave_tb.test.dut，把 clk、reset、a_in、b_in、a_valid_in、b_valid_in、product、acc_out 加到波形；有符号数据选择 Signed Decimal，观察 20/25/35/45 ns。源码文件清单提供层次和定义，FSDB 提供动态值。

### 清理范围

用户已明确：先审查整个项目，列出问题，确认后分批清理。首轮结果见 `docs/code_audit.md`。本轮不删除既有代码与实验产物，不进入 GEMM/UVM/综合/DFT，不检查 License。

## 2026-10-17：工程修复与统一目录（用户授权）

本节更新前面历史检查结论：PE 源码/TB 已按授权修复，旧日志仍描述当时版本，不能继续用旧哈希声称当前源码未变。源码位置与运行命令以本节及项目布局文档为准。

### 原理与修复选择

- 预载接口必须与物理 SRAM 一致：单 lane 连续 K 元素组成一个 word，逻辑 K 地址不等于物理 word 地址。
- native operand AXI64 DMA 要求行首/步长按 8 字节对齐。逻辑 K=260 保持不变，物理行步长改为 ceil(260/8)*8=264；补齐字节不参与 MAC。
- synchronous read 的数据/valid 延迟必须共同验证；控制器测试同时统计请求、响应与写回，包含非法 K。
- TB 初始化过程和总线模型共同写 backing memory 时，不能把写过程声明为单一驱动语义的 always_ff；使用普通测试过程。RTL 中的 always_ff 没有因此改写。
- 声明顺序对旧 VCS 很重要：首次实例连接前声明完整总线，避免隐式 wire 导致位宽不符合预期。顶层操作数总线声明已前移。
- 测试失败使用 $fatal，自动流程仍检查失败日志和唯一成功标记。本次 VCS 的某次 $fatal 运行退出码为 0，证明单看退出码确实不足。
- 先前 PE Single MAC 后继续累加的现象已修复；现在检查 valid=0 时保持，以及 clear 在 valid=1 时优先清零。

### 目录与复现入口

完整命名规范见 `docs/reference/project_layout.md`，52 项路径迁移见 `docs/reference/path_migration.json`。RTL 保留功能分层与合法模块名，测试分层，脚本按用途归类；历史迁移脚本归档，不进入常规构建。

```bash
cd /home/ICer/eda/npu-vcs-learning
make check
bash scripts/sim/run_vcs.sh gemm_core_tb
make vcs-regression
make vcs-pe-wave
python scripts/check/summarize_vcs.py
```

`run_vcs.sh` 接受顶层名及 VCS 参数覆盖选项，使用 -full64、-sverilog、-timescale、-top、-f、-o、-l；波形模式额外链接 FSDB PLI 并保留 debug access。每个 run 保存命令、版本标识、工作区状态、源码哈希与快照、编译日志、仿真日志及判定。外部编译/运行超时与 TB 仿真时间超时分开处理。

矩形/不对称缓冲配置示例：

```bash
VCS_RUN_LABEL=gemm_core_rect_a bash scripts/sim/run_vcs.sh gemm_core_tb \
  -pvalue+gemm_core_tb.ROWS=2 -pvalue+gemm_core_tb.COLS=3 \
  -pvalue+gemm_core_tb.A_BUFFER_COUNT=2 -pvalue+gemm_core_tb.B_BUFFER_COUNT=1
```

### 真实结果与问题过程

17 个 VCS 配置的通过目录与失败尝试保留在 `docs/validation/cleanup_results.json`。GEMM 默认配置完成 176 次比较，原两 K tile 的最终 4x4 矩阵不变；2x3、3x2、不对称 A/B buffer 和 1x1 均有回归。M/N tiling 验证四个 tile 的 64 个 C 元素；executor 验证 8x8、K=260 的 64 个元素；顶层覆盖纯 GEMM、Bias INT32、Bias/Requant/ReLU INT8。

曾在 Bash 脚本执行期间更新同一文件，影响旧 Bash 后续读取位置；受影响项目使用冻结脚本重跑，异常日志未删。native AXI64 对齐问题通过实际失败定位并修复，不通过扩大超时或放宽数值检查绕过。

迁移后的 PE FSDB/VCD 位于 `build/vcs/pe_wave_tb/run.23i6Qt/`；Verdi 批处理读取成功，范围为 0–56000 ps。当前终端仍无 DISPLAY，不声称已人工验证可见 GUI。具备桌面时可执行：

```bash
cd /home/ICer/eda/npu-vcs-learning/build/vcs/pe_wave_tb/run.23i6Qt
verdi -sv -f sources.f -top pe_wave_tb -ssf pe.fsdb
```

Python 3/模型依赖与 Verilator 当前不可用，因此不报告模型端到端回归通过。历史 compiler RTL contract 的严格检查保留，旧哈希漂移需要单独 ABI 审核；没有为了让检查通过而替换全部哈希。没有检查 License，也没有进入 UVM、综合或 DFT。

最终运行器进一步固定了复现边界：在执行外部工具前完整解析 main 函数；复制源码后对快照计算 SHA256，并让 sources.f 指向快照，原始路径另存 source-origin.f。这样后续编辑工作区不会改变已经启动实验的编译输入。实际执行的 main 函数也保存到 run 目录。

顶层当前基线实际流量为 descriptor AR=48、operand AR=192、M/R=1、Bias=8、total AR=249、AW=48、W=144，最后原始 C[4][4]=6500；精确请求数检查与原有逐元素输出检查均保留。


## 2026-10-17：按用途删除旧脚本（用户授权）

判定顺序是先查调用关系，再核对脚本假设与当前 RTL，最后确认替代入口；不能仅凭文件旧或当前缺少 Python 3/Verilator 就判定脚本坏掉。没有执行历史 RTL 迁移脚本。

实际删除三个已完成的迁移脚本：`fix_early_dma_done.py` 的旧模板在当前 scheduler 匹配 0 次；`enable_multislot_a_reuse.py` 的已应用检测成立；`integrate_psum.sh` 的三个目标 generate 名称已存在，重跑仅重复写源码与备份。原 archive 说明文件随之删除。

另删除 `run_vcs_pe.sh`、`run_vcs_pe_wave.sh` 两个薄包装，Makefile 直接调用统一运行器，手动复现如下：

```bash
cd /home/ICer/eda/npu-vcs-learning
make check
make -n vcs-pe vcs-pe-wave
# 真正执行实验时使用：
make vcs-pe
make vcs-pe-wave
# 与上述两个入口分别等价：
bash scripts/sim/run_vcs.sh pe_tb
bash scripts/sim/run_vcs.sh pe_wave_tb
```

前面的历史章节保留当时真实运行的旧命令；新实验使用本节入口。原 52 项路径迁移中，47 项仍保留在 `docs/reference/path_migration.json`，5 个删除项转入 `docs/reference/retired_scripts.md`，包含原因和替代方式。

审查还发现两份性能报告把外部读 beat 仍乘以 4：当前 ResNet TB 的 RDATA 为 64 位，要求 ARSIZE=3，每拍地址增加 8，监控器按外部 rvalid/rready 握手计数，因此读字节应为 beat×8。已修正三处计算，写通道仍为 32 位。只改报告算术，没有改 RTL，也没有重新生成或覆盖旧报告。分析历史 AXI32 日志时应使用对应版本。

本轮执行结构/引用检查、剩余 Shell 语法检查和 Make 命令展开；未编译或运行新的 EDA 实验。原始 VCS 日志、结果、源码快照和波形全部保留，未检查或修改 License。

真实检查日志保存在 `build/maintenance/retire_scripts.nzBjDE/`：`make check` 扫描 71 个 SV 文件/模块及 23 个现行输入，通过；Make 展开显示 PE/波形目标直接调用统一入口；47 个迁移目标全部存在，5 个删除脚本没有现行调用，scheduler/executor 清理前后指纹相同。`git diff --check` 返回 0。两份 Python 3 性能报告本轮只完成源码及计数边界核对，未执行报告生成。


## 2026-10-17：输出缓冲性能实测与简化（用户授权）

实验对比原双缓冲、单缓冲、直接写回和最终固定乒乓实现，数据与时序模型相同。四种实现各 10 组，40 组均通过，每组核对 64 个输出；最终实现周期逐组与原双缓冲相同。完整表、日志位置和 VCS 手动命令见 [性能报告](validation/output_buffer_comparison.md)。

关键结果：K=4、INT32 时三种原方案为 195/225/243 周期；K=260 时为 3303/3303/3294 周期。原顶层三描述符负载为 10241/10241/10214 周期，最终乒乓仍为 10241。K=4、INT8、写等待8周期时为 298/328/383，最终乒乓为 298。

这次学到：输出缓存收益取决于结果到达速度和写回速度。长 K 的某个负载周期相同，不能推出短 K 也相同；PSUM 路径绕过结果缓存，三个方案的 PSUM 周期确实相同。必须用相同输入和完整结果检查比较时钟周期，不能比较工具启动时间。

正式 `c_result_buffer.sv` 从 177 行缩至 103 行。保留两块64B存储，两个指针分别在完整采集和DMA完成时翻转；删除独立FIFO、空闲搜索、重复active/行计数以及数据阵列复位。输入由现有snapshot控制器逐行写满后才READY。结果接收时保存地址、步长和格式，DMA完成后才释放，避免覆盖。

未给正式RTL增加单/双缓冲或直接输出的模式开关；实验候选保存在 `build/output_compare/20261017_145429/`。原17行运行脚本未改。新增153行性能TB用于复现，AXI仿真模型增加32位参数读取和写等待两项实验所需功能，默认64位/无等待保持原时序。

原executor回归目录 `build/vcs/gemm_executor_tb/20261017_150522/`，64结果及AR=64/AW=16/W=64通过。顶层统计宏带来的未连接只读统计输出端口警告已辨明；数据检查未放宽。没有执行综合、DFT或模型端到端推理，也没有检查或修改License。


## 2026-10-17：恢复 VMware 共享文件夹

虚拟机已有 open-vm-tools 和桌面组件 11.0.5，vmtoolsd 正在运行，FUSE 可用。最初 vmware-hgfsclient 返回 1，直接挂载报 `Error -107 cannot open connection!`，说明仅安装 Tools 不足以使宿主机共享目录可访问。

用户在当前 CentOS 虚拟机的 VMware 设置中启用共享，并添加、启用名为 `share` 的条目后，实际读取成功。Ubuntu 的共享设置不能代替这台 CentOS 的设置。本次没有重装 Tools、重启虚拟机或修改系统服务配置。

当前可访问的自动挂载路径为 `/mnt/hgfs/share`。另将指定共享只读挂载到 `/home/ICer/shared/share`，实际挂载选项含 `ro,nosuid,nodev`，便于只读审查宿主机资料。手动复现如下（挂载命令仅在该目录尚未挂载时执行）：

```bash
mkdir -p /home/ICer/shared/share
vmhgfs-fuse .host:/share /home/ICer/shared/share -o ro,nodev,nosuid
findmnt -T /home/ICer/shared/share
```

`.host:/share` 指宿主机导出的共享名称；后面的路径是虚拟机内的访问位置。`ro` 表示只读，`nodev,nosuid` 禁止使用该挂载中的设备节点与特权位。此用户手动挂载没有添加开机持久化配置；本次未测试重启后的状态。

实际可见内容仅为 `basdg/`、`npu.tar.gz`、`ysyx.zip`。在可见目录限定深度内没有发现原先要审查的 Synopsys2018 目录或工艺库文件，未读取压缩包内部。因此共享访问已恢复，但仍需将 `D:\BaiduNetdiskDownload\Synopsys2018\Synopsys2018` 单独共享或放入现有 share，才能检查该批软件包。未检查或修改任何 Synopsys License 文件、服务或配置。


## 2026-10-18：准备并启动 Synopsys Installer 5.0

用户授权完成教程截图中的安装器准备步骤。本次安装器目标为 `/home/synopsys/synopsysinstaller_v5.0`，源目录为 `/home/ICer/shared/share/Synopsys2018/synopsysinstaller_v5.0`。使用 ICer 普通用户复制、解出和启动，无需 sudo，也没有执行 chmod 777。

实际复制和解出命令：

```bash
cp -r /home/ICer/shared/share/Synopsys2018/synopsysinstaller_v5.0 /home/synopsys/
cd /home/synopsys/synopsysinstaller_v5.0
chmod u+x SynopsysInstaller_v5.0.run
./SynopsysInstaller_v5.0.run -d /home/synopsys/synopsysinstaller_v5.0 > extract.log 2>&1
```

`cp -r` 递归复制目录；`chmod u+x` 只为文件所有者增加执行权限；`-d` 指定安装器文件的解出位置，省去交互式输入。这里准备的是 Installer 本身，尚未执行 DC、ICC2、TetraMAX 等产品安装。

真实结果：`extract.log` 显示 `Unpacking: SynopsysInstaller.tgz`、`Unpacking: singularity.tar.gz` 和 `Installation complete.`；生成的 `setup.sh` 属于 ICer，模式为 755。解出期间出现当前会话 C.UTF-8 不可用的 locale 警告，程序退出码为 0，文件成功生成；没有为此修改全局语言设置。

启动脚本要求 DISPLAY。虽然远程命令环境未设置 DISPLAY，但用 `DISPLAY=:0 LC_ALL=C xdpyinfo` 实际确认可连接已有 X.Org 桌面。为本次安装器进程移除继承的库搜索路径，使用前台会话启动：

```bash
cd /home/synopsys/synopsysinstaller_v5.0
env -u LD_LIBRARY_PATH -u LD_PRELOAD DISPLAY=:0 LC_ALL=C ./setup.sh > setup.log 2>&1
```

这里的环境设置仅影响该命令，不修改 shell 启动文件。后台启动尝试没有保留安装器进程，因此改为保留前台会话；随后确认 setup.sh、installer、wish、tclsh 进程链持续运行，setup.log 没有错误输出。额外的桌面窗口标题检查两次因自动审批超时未执行，因此没有读取图形画面，启动状态以进程和日志为证。

安装器没有选择任何产品或执行产品安装；未检查或修改 Synopsys License 文件、服务或配置，也没有改动原有 VCS、Verdi 安装。


## 2026-10-18：Library Compiler 安装后的启动检查

LC 读取 Liberty 文本时序库（`.lib`），将库模型编译成 Synopsys 二进制库（`.db`），供 DC、PrimeTime 等工具使用。Liberty 描述单元的功能、引脚、面积、时序和功耗；标准单元及 SRAM 宏都可提供这种模型。SRAM/Memory Compiler 根据存储容量和端口等参数生成存储器宏及其配套文件，LC 负责其中库模型的格式转换。

确认用户安装目录 `/home/synopsys/lc/O-2018.06-SP1` 已存在，`bin/lc_shell` 链接到 `snps_shell`。实际启动并保存日志：

```bash
mkdir -p /home/ICer/eda/npu-vcs-learning/build/lc/startup_check_20261018
cd /home/ICer/eda/npu-vcs-learning/build/lc/startup_check_20261018
env LC_ALL=C /home/synopsys/lc/O-2018.06-SP1/bin/lc_shell 2>&1 | tee startup.log
```

`LC_ALL=C` 仅为该程序指定语言环境；`2>&1 | tee startup.log` 将输出及错误信息显示在终端并保存。进入 `lc_shell>` 后实际执行：

```tcl
puts "LC_TCL_OK"
help read_lib
help write_lib
exit
```

真实输出包含 `Version O-2018.06-SP1 for linux64`、`LC_TCL_OK`、`read_lib # read a .lib file` 和 `write_lib # write lib file to db`，最后正常退出。日志为 `build/lc/startup_check_20261018/startup.log`。基础启动与 Tcl 命令解释器可用；尚未读取实际工艺库或执行 `.lib` 到 `.db` 的转换，具体库的兼容性仍需后续实验验证。

本次远程终端的 `command -v lc_shell` 没有找到短命令，检查使用上述绝对路径。用户若要在当前 Bash 终端直接输入 `lc_shell`，可以先执行：

```bash
export PATH=/home/synopsys/lc/O-2018.06-SP1/bin:$PATH
```

这只修改当前终端及子进程的搜索路径。本次没有修改 Shell 启动文件，也没有检查或修改 License 配置。过程中部分只读命令及向交互会话发送命令的请求因自动审批超时未执行；改用直接启动、并重试输入后完成了上述验证。


## 2026-10-18：在 Bash 中持久设置 LC 程序路径

经用户明确授权，在 `/home/ICer/.bashrc` 末尾追加：

```bash
# Library Compiler
export PATH=/home/synopsys/lc/O-2018.06-SP1/bin:$PATH
```

`.bashrc` 是用户主目录中的隐藏文件，交互式 Bash 启动时读取。新增目录让终端找到 LC，`$PATH` 保留原有程序搜索路径。实际使用 `env LC_ALL=C bash -ic 'command -v lc_shell'` 启动新的交互式 Bash，退出码为 0，输出 `/home/synopsys/lc/O-2018.06-SP1/bin/lc_shell`，确认设置已生效。已打开的桌面终端可执行 `source /home/ICer/.bashrc` 立即加载，或重新打开终端。


## 2026-10-18：DC 系统依赖修复与成功启动

用户安装 DC O-2018.06-SP1 后，直接执行 `/home/synopsys/syn/O-2018.06-SP1/bin/dc_shell`，先报缺少 `libtiff.so.3`。用户曾将 `.so.5` 复制改名成 `.so.3`，随后报缺少 `libmng.so.1`。共享库文件名中的主版本表示二进制接口；复制改名不能保证接口兼容，应安装提供所需接口的正确软件包。

最初包下载还受到 DNS 故障阻塞：公网 IP 1.1.1.1 可达，但 getent 无解析结果、curl 报解析超时。用户调整 DNS 后，实际确认域名可解析，CentOS 官方归档 HTTPS 可访问。系统查询显示当时 compat-libtiff3 未安装，libmng 只有 i686 版本；32 位库不能满足 linux64 DC 的依赖。

从 CentOS 官方归档 `https://vault.centos.org/7.9.2009/os/x86_64/Packages/` 下载 `compat-libtiff3-3.9.4-12.el7.x86_64.rpm` 和 `libmng-1.0.10-14.el7.x86_64.rpm`，保存到 `/home/ICer/eda/installers/dc-deps/centos7-x86_64/`。`rpm -K` 对两个包均返回 OK；所需的 64 位 glibc、libgcc、libjpeg-turbo、libstdc++ 和 zlib 已存在。校验原始输出见该目录的 `verification.log`。

远程会话没有免密码 sudo。用户在虚拟机终端执行本地安装并返回成功输出：

```bash
cd /home/ICer/eda/installers/dc-deps/centos7-x86_64
sudo yum --disablerepo='*' localinstall ./*.rpm
/home/synopsys/syn/O-2018.06-SP1/bin/dc_shell
```

`--disablerepo='*'` 禁用联网软件源，从已下载的 RPM 安装，避免旧镜像源影响本次操作。用户实际启动输出为 `Version O-2018.06-SP1 for linux64 - Jul 19, 2018`、`Initializing...`，随后进入 `dc_shell>`。这是用户手动执行的真实结果；其输出摘录保存在下载目录的 `dc_startup_user_output.log`，没有伪称代理重新运行了 DC。

随后代理只读核对两个 x86_64 包均已安装，`/usr/lib64/libtiff.so.3` 已变为指向 `libtiff.so.3.9.4` 的链接，readelf 显示 SONAME 为 `libtiff.so.3`。原路径的手工改名副本已经被正确兼容库替换，该链接应保留。

本次结论限于 DC 基础启动成功；没有执行 RTL 综合、工艺库读入、DFT 或后端实验。启动横幅中的产品名称不能单独证明各功能流程已经验证。没有检查或修改 Synopsys License 文件、服务或配置。


## 2026-10-18：准备 PE 的 DC 综合脚本（尚未执行）

本次按用户要求只编写脚本，没有启动 LC/DC，没有读取实际工艺库或执行综合。第一轮顶层为 `pe`，输入只有 `rtl/compute/pe.sv`；它包含 INT8 乘法、INT32 累加和输出寄存器，不依赖 SRAM。Testbench 和 VCS 仿真文件清单不作为综合输入。

新增两个文件：

- `scripts/synth/pe.tcl`：填写库路径、读取 RTL、建立设计、加载约束、执行普通 `compile`、保存报告和网表。
- `constraints/pe.sdc`：时钟和接口环境假设。当前教学值为周期 10 ns（100 MHz）、时钟不确定度 0.2 ns、输入延迟 0 至 1 ns、输出延迟 0 至 1 ns、输入转换时间 0.1 ns、输出负载 0.01 pF。它们不是测量结果，也不是已经确认的 NPU 目标。

### 使用前需要填写的内容

`pe.tcl` 最前面的 `stdcell_db` 是明确的占位路径。实际解压 NLDM 包后，需要选择一个 PVT 角的标准单元 `.db`，并填入真实路径；如果交付的是 `.lib`，先通过单独的 LC 实验转换，本脚本不会自动执行转换。库文件的内部名称和角条件尚未核实，因此没有编造一个具体的 TSMC 文件名。

SDC 数值按库单位解释，本版假设时间为 ns、电容为 pF。准备运行时先核对实际库单位；主脚本中的 `report_units` 用于显示单位。一个库角的基础综合不能代替多角时序签核；28nm 物理相关的时序评估后续还需要匹配的物理与 RC 数据。

PE 的 `reset` 是同步高有效复位，`clear` 也是同步清零信号，二者均纳入输入约束。本版没有为它们设置 false path 或固定为无效值。

### 手动运行命令（仅记录，本次未执行）

填好库路径并确认约束后，在 CentOS 终端按顺序运行：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dc/pe
cd build/dc/pe
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/pe.tcl 2>&1 | tee run.log
```

从 `build/dc/pe` 启动，可以把工具日志、工作数据库、网表和报告放在同一个实验目录。`../../../` 表示向上三级回到工程根目录。`-f` 指定 DC 要执行的 Tcl 文件；`LC_ALL=C` 设置本次命令的语言环境；`2>&1` 合并错误和普通输出；`tee run.log` 将终端输出同时保存到日志。

输出路径固定为 `build/dc/pe`，重复运行会覆盖同名结果。需要保留多轮实验时，先手动保留上一轮目录，再启动下一轮；脚本没有添加自动编号或清理逻辑。

### DC 主流程及重要参数

| 命令 | 本次作用 |
| --- | --- |
| `set_app_var target_library` | 指定 `compile` 可以选取的标准单元库。 |
| `set_app_var link_library` | 指定解析单元引用时使用的库；`*` 表示先查当前内存中的设计。 |
| `define_design_lib WORK -path work` | 设置 `analyze` 使用的 HDL 分析目录。 |
| `analyze -format sverilog` | 按 SystemVerilog 语法读取 PE，支持 `logic` 和 `always_ff`。 |
| `elaborate pe` | 建立顶层设计并展开 RTL。 |
| `current_design pe`、`link` | 选中当前设计，解析设计及库单元的引用关系。 |
| `source` | 读取本轮 SDC 约束。 |
| `check_design` | 检查设计结构和连接，保存基础设计检查报告。 |
| `compile` | 优化逻辑并映射到目标标准单元库；本轮使用普通逻辑综合。 |
| `report_timing -max_paths 10` | 输出最多十条最慢的最大延迟路径。 |
| `report_constraint -all_violators` | 汇总工具报告的约束违例。 |
| `change_names -rules verilog -hierarchy` | 按 Verilog 命名规则整理设计中的名字。 |
| `write -format verilog -hierarchy` | 输出映射后的 Verilog 门级网表。 |
| `write -format ddc -hierarchy` | 保存供 DC 重新打开的设计数据库；它与输入库 `.db` 的用途不同。 |
| `write_sdc` | 导出本轮设计约束，供后续分析使用。 |

Tcl 中，`#` 开头是注释，`set` 定义变量，`$变量名` 读取变量，`[...]` 先执行括号内的命令并取得结果，`{...}` 将端口列表作为一组文字传给命令。`get_ports` 选取端口，`all_outputs` 选取全部输出，`list` 建立列表。

### 预期输出（不是已经生成的综合结果）

```text
build/dc/pe/
├── run.log
├── work/
├── reports/
│   ├── check_design.rpt
│   ├── area.rpt
│   ├── timing.rpt
│   └── constraints.rpt
├── pe_mapped.v
├── pe.ddc
└── pe.sdc
```

DC 还可能在该目录生成自身的命令日志。`pe_mapped.v` 用于后续门级检查，`pe.ddc` 用于在 DC 中继续分析；面积和时序报告需要结合本轮库角与接口假设解释。本次没有综合日志、PASS/FAIL 或 PPA 数字可供报告。


## 2026-10-18：PE 第一次真实 DC 综合（TT / 0.9 V / 25°C）

用户放入数字标准单元库后，授权填写脚本并尝试运行。本次已实际运行 DC O-2018.06-SP1，完成 PE 的 RTL 读取、链接、标准单元映射和网表导出；随后读取同一个 DDC 补充结构与 hold 报告。没有修改 PE RTL、没有运行 SRAM Compiler、DFT、布局布线、门级仿真或形式等价验证。

### 1. 先核对交付包和库角

源目录：`/mnt/hgfs/share/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/AN61001_20180509/`。

实际 RLN 第 2 页确认版本配套：NLDM 为 `180a`，DOC 为 `110c`，VLG 为 `110a`，RLN 为 `180b`。各文件后缀版本不同在这里是厂商明确规定的组合。RLN 第 1 页确认 9-track、Standard Vt；第 3 页列有本轮选用的 `tt0p9v25c`。

NLDM 归档里已提供编译好的 `.db`，本次没有执行 LC 转换。实际从归档选取两个文件，保存到虚拟机本地目录：

```text
/home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm/
├── tcbn28hpcplusbwp40p140tt0p9v25c.db
└── tcbn28hpcplusbwp40p140tt0p9v25c.lib
```

`.db` 为 20,144,128 字节，`.lib` 为 87,283,165 字节。Liberty 头部实际写明：

```text
library (tcbn28hpcplusbwp40p140tt0p9v25c)
time_unit : "1ns"
capacitive_load_unit (1,pf)
nom_voltage : 0.9
nom_temperature : 25
nom_process : 1
default_operating_conditions : tt0p9v25c
```

本次通过只提取指定成员的方式保存这两个文件。若手动从同一归档复现，可执行以下命令；`--strip-components=6` 去掉归档内六级前缀目录，仅保留两个原始文件名：

```bash
mkdir -p /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm
tar -xzf /mnt/hgfs/share/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/AN61001_20180509/tcbn28hpcplusbwp40p140_180a_nldm.tar.gz \
  -C /home/ICer/eda/pdk/tsmc28/logic/tcbn28hpcplusbwp40p140_180b/nldm \
  --strip-components=6 \
  TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp40p140_180a/tcbn28hpcplusbwp40p140tt0p9v25c.db \
  TSMCHOME/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp40p140_180a/tcbn28hpcplusbwp40p140tt0p9v25c.lib
```

### 2. 更新脚本并执行

`scripts/synth/pe.tcl` 已填入真实 `.db` 路径。`constraints/pe.sdc` 的时间与电容单位已确认匹配，不需要改变原有 10 ns 时钟、0 至 1 ns 接口延迟、0.1 ns 输入转换时间、0.01 pF 输出负载等教学假设。

实际首次运行命令：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dc/pe
cd build/dc/pe
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/pe.tcl 2>&1 | tee run.log
```

本轮日志为 `build/dc/pe/run.log`。DC 输出 `Presto compilation completed successfully.`、加载所选 `.db`、`Optimization Complete`，并写出 `.v`、`.ddc`、`.sdc` 后正常退出。`report_units` 实际确认时间 ns、电容 pF。DC 在 `compile` 内选择了算术结构、映射到 TSMC 单元，再进行时序优化和面积恢复；它不是只把 RTL 文本换一种写法。

为了分析首次报告暴露的 hold 问题，本次又从已生成的 `pe.ddc` 读取同一设计，补充两个报告，没有重新 `compile`：

```bash
cd /home/ICer/eda/npu-vcs-learning/build/dc/pe
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f review.tcl 2>&1 | tee review.log
```

`build/dc/pe/review.tcl` 是本次补查的简短命令记录：设置同一个库，`read_file -format ddc pe.ddc`、`current_design pe`、`link`，随后输出综合后结构检查和最短路径报告。`review.log` 实际显示 `Loaded 4 designs` 并正常退出。后续运行主脚本时，已经会直接生成这两个补充报告，不需要再单独执行 review。

### 3. 面积与 setup 结果

| 项目 | 实际结果 |
| --- | --- |
| 顶层 | `pe` |
| 库角 | TT / 0.9 V / 25°C |
| 时钟周期 | 10 ns，即 100 MHz |
| 报告实例数 | 329，含 3 个 DW 层次实例 |
| 叶级标准单元 | 326 = 276 个组合单元 + 50 个时序单元 |
| 黑盒数 | 0 |
| 组合单元面积 | 260.315997 |
| 非组合单元面积 | 96.768000 |
| 总单元面积 | 357.083997，按所选库的 area 属性统计 |
| 最慢 setup 路径 | `b_in[7]` → 乘法器 → 累加器 → `acc_out_reg[30]/D` |
| 到达时间 / 要求时间 | 2.57 ns / 9.78 ns |
| setup slack | +7.21 ns，MET |

50 个触发器与 RTL 对应：32 位累加器、8 位 A 传递寄存器、8 位 B 传递寄存器、2 位 valid 寄存器。面积报告中的 Buf/Inv 面积 10.458000 已包含在组合面积中，不能再重复相加。

原始 setup 日志片段见 `reports/timing.rpt`：

```text
data required time        9.78
data arrival time        -2.57
slack (MET)               7.21
```

这里的 2.57 ns 包含 1 ns 的输入外部延迟；不能把整个数字都视为 PE 内部组合延迟。要求时间由 10 ns 周期扣除 0.2 ns 不确定度及约 0.02 ns setup 时间得到。slack 是要求时间减到达时间。

面积报告未打印物理面积单位。暂按“库面积单位”记录 357.083997；RLN/Databook 未明确给出将 Liberty area 再乘 0.81 的规则，因此不自行缩放，也不把它称为 core/die 面积。报告中的互连面积和 total area 为 undefined。

### 4. Hold 尚有违例

`reports/constraints.rpt` 实际列出 118 条 min_delay/hold 违例，最差为 -0.19 ns。不能把“工具运行结束”或“setup 满足”表述为全部时序通过。

从保存的 DDC 补出的 `reports/hold.rpt` 第一条路径为 `a_in[7]` → `a_out_reg_7_/D`：

```text
input external delay      0.00
path delay                0.00
data arrival time         0.00
clock uncertainty         0.20
library hold time        -0.01
data required time        0.19
slack (VIOLATED)          -0.19
```

原因是当前接口最小延迟假设为 0 ns，数据直接进入传递寄存器；本轮 `set_clock_uncertainty 0.2` 同时参与 setup 和 hold 分析。因此最短路径到达 0 ns，而要求约 0.19 ns 后仍保持。它是短路径约束问题，不是乘加路径太慢；降低时钟频率通常不能直接解决同拍 hold 检查。

下一步应先解释并核实真实接口最小延迟和 setup/hold 不确定度，再决定是否需要插入延迟或在物理实现中修复。本次保留原约束和实际违例，没有为了得到全绿而删除 hold 检查。当前也没有用更快工艺角或真实时钟树完成 hold 签核。

### 5. 警告逐项记录

- `VER-318`：`pe.sv:30` 的符号扩展拼接结果类型是 unsigned，导致 signed 到 unsigned 转换提醒。乘积已手动扩展为 32 位，当前加法两侧与接收结果同为 32 位，转换不改变低 32 位的模加结果。该语义分析不等于整个设计已经通过综合前后等价验证；本次没有修改 RTL。
- 首次 `check_design.rpt` 是 compile 前检查，报告中间单元 C132 不驱动网络。该实例在最终网表中已不存在，但不能拿这个早期报告代替综合后检查。
- `check_design_mapped.rpt` 实际还有 19 条警告：11 条 DW 模块未使用端口（CI/CO/TC/B低位）、6 条端口直连、2 条同一网络接到多个输入引脚。已对照网表定位到常量优化、直连和乘积符号扩展；报告未指出顶层输入断连。本次不声称结构检查零告警或功能等价已证明。
- `UCN-1` 与 `VO-4`：对应 DW 加法器的低六位 `assign SUM[i] = A[i]` 直连；实际没有 tran 语句。这些提示没有阻止导出网表，也不代表出现多驱动。

### 6. 输出文件与本轮技术收获

```text
build/dc/pe/
├── run.log
├── review.log
├── review.tcl
├── pe_mapped.v
├── pe.ddc
├── pe.sdc
├── work/
└── reports/
    ├── check_design.rpt
    ├── check_design_mapped.rpt
    ├── area.rpt
    ├── timing.rpt
    ├── hold.rpt
    └── constraints.rpt
```

主脚本新加的命令只有综合后 `check_design` 和 `report_timing -delay_type min -max_paths 10`，用于区分结构检查、setup 和 hold；保持直线流程，没有自动探测库、复杂分支或清理逻辑。

这次实际掌握了：核对厂商库版本配套与 PVT、直接使用预编译 `.db`、确认单位、读 RTL/链接/技术映射、理解 DW 算术层次、区分库面积和芯片面积、读取 setup/hold 路径、重新打开 DDC、保留并解释真实警告。

本轮使用 `ZeroWireload` 和理想时钟，没有布局、CTS 或真实互连寄生，只有 TT 单角和教学接口假设。+7.21 ns 裕量不能当作最终最高频率依据。门级回归或形式等价仍需后续单独实验。

若手动重复实验，先保留当前 `build/dc/pe` 的真实结果。也可新建同层级的 `build/dc/pe_repeat`，从该目录执行相同相对路径的主脚本；所有输出会保存在新的当前目录中。


## 2026-10-18：完整 NPU 的 SRAM 接入准备与 DC 读取检查

本轮目标是先接入真实存储宏，再综合 `npu_top`。截至本记录，真实 SRAM 宏尚未生成、RTL 尚未替换、完整 NPU 尚未执行 `compile`；已经完成存储接口审查、综合脚本与教学约束准备，以及现有 RTL 的 DC `analyze` 检查。

### 1. 主体包与文档包的区别

Windows 的 `D:\share\pdk\tsmc28\Memory` 对应当前虚拟机的 `/mnt/hgfs/share/pdk/tsmc28/Memory`。本次实际目录中有五个文件：1PRF 的 DOC/RLN、2PRF 的 DOC/RLN，以及公共 Memory Compiler 的 RLN。用户已确认以下两个主体包尚未放入，正在补齐：

```text
tsn28hpcp1prf_20120200_130a.tar.gz
tsmc_n28hpcpmc_20120200_110a.tar.gz
```

`_doc` 包提供使用手册，`_rln` 包提供版本说明；它们不能代替生成宏所需的产品数据和公共编译器。文档中的命名示例也不能代替实际生成的 Verilog 模块名和 Liberty 库名。本轮尚未填入虚构的宏名或空壳模型。

### 2. 第一轮存储宏接入范围

NPU 默认是 4×4 INT8 阵列，K tile 为 256。顶层 `MEM_WORD_WIDTH=32` 是外部写接口宽度；内部执行器明确使用 64 位操作数字宽，二者不能一起改成 64。

A、B 各有两个 bank，每个 bank 有四条 lane，每条 lane 需要 32×64 bit。共需 16 个这样的宏，数据容量合计 4 KiB。buffer manager 的装载与计算阶段互斥，同一操作数 bank 不需要同拍读写，因此这一用途可以采用单端口 1PRF。

接入时计划只为 `operand_buffer` 增加薄包装：选择读写地址、转换使能极性、连接生成模型的实际引脚。保留原有同步读延迟，不在宏输出后额外增加一级寄存器。普通 RTL 仿真仍可使用原行为模型，真实宏分支使用 `NPU_TSMC28`。

不能把通用 `sram_model` 全局改成单端口：它原本描述独立的读写端口。C/PSUM 的接口语义需要另行核对；Conv cache 还存在组合读及双 tag 查询，直接换为同步存储宏会改变控制时序。这些存储本轮尚未替换，后续面积报告必须区分宏和由标准单元实现的存储，不能称作所有 SRAM 都已落宏。

### 3. 已准备的综合输入

- `scripts/synth/npu.tcl`：明确列出设计文件，设置标准单元 target library 与 SRAM link library，随后安排 analyze、elaborate、link、加载约束、compile、报告和导出。
- `constraints/npu.sdc`：10 ns 时钟，0.2 ns setup/hold 共用不确定度，输入 max/min 为 1/0 ns，输出 max/min 为 1/0 ns，输入转换 0.1 ns，输出负载 0.01 pF。

这些是延续 PE 实验的教学接口假设，不是芯片最终时序要求。脚本保留 `TODO_GENERATED_SRAM_DB` 和待实现的 `operand_sram.sv` 输入；在真实模型生成、核对引脚和单位之前，不运行这个完整综合脚本。

### 4. 实际完成的 DC analyze 检查

为先发现 RTL 语言兼容问题，本次在 `build/dc/npu_read` 运行了独立的读取检查：

```bash
cd /home/ICer/eda/npu-vcs-learning/build/dc/npu_read
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f read_rtl.tcl 2>&1 | tee read_rtl.log
```

`-f` 指定 DC Tcl 命令文件；`tee` 同时显示和保存标准输出与错误输出。该 Tcl 只定义工作库并执行 `analyze -format sverilog -define SYNTHESIS`，没有 elaborate、link 或 compile。`analyze` 检查语言并保存中间表示，不证明顶层展开、宏链接、功能或时序已通过。

首次按仿真清单读入时遇到：

```text
npu_perf_monitor.sv:180: The system function '$countones' is not supported for synthesis. (ELAB-939)
Cannot recover from previous errors. (VER-518)
```

默认硬件未启用 `NPU_PERF_ENABLE`，但 DC 仍会分析清单中的源文件。因此仅从综合清单移除该可选性能统计模块，保留仿真清单及 RTL。第一次失败的日志保存为 `read_rtl_initial.log`。

调整后，38 个现有 RTL 文件全部完成读取，日志实际显示：

```text
Presto compilation completed successfully.
1
exit
Memory usage for main task 479 Mbytes.
CPU usage for this session 3 seconds ( 0.00 hours ).
```

DC 正常退出。仍有 initial 块被忽略、未标号 `$fatal` 被忽略、`assert property` 被忽略等告警；它们是读取阶段对检查代码的处理提示，不代表这些检查被实现成硬件。本次未为消除这些提示而批量修改 RTL。

实际记录位于 `build/dc/npu_read/read_rtl.tcl`、`read_rtl_initial.log` 和 `read_rtl.log`。没有生成完整 NPU 的门级网表、面积或时序结果。

### 5. LC、库文件与现有 hold 结果

Library Compiler（LC）可以将可读的 Liberty `.lib` 编译为 Synopsys `.db`，用于 DC/PrimeTime 等工具读取；它不是生成 SRAM 电路的 Memory Compiler。`.lib` 描述单元功能、引脚、时序、功耗及面积等属性，`.db` 是对应的编译数据库。有配套 `.db` 时可直接使用，不必再次转换；`.ddc` 则是已读入或综合的设计数据库。

上一轮 PE 的最差 hold slack 为 -0.19 ns。该短路径输入最小延迟为 0，理想时钟下不确定度为 0.2 ns，库 hold 时间约 -0.01 ns，故要求保持约 0.19 ns。这个结果在当前约束下有明确原因，但不能视为时序已经通过，也不能用降低频率直接修复。后续应依据真实接口和物理实现确定约束及修复方式，不为获得全绿而取消检查。


## 2026-10-18：主体包到位、首次宏生成尝试与阶段提交

### 1. 本次安装 TetraMAX 应选哪一个

已实际读取共享目录内的产品安装说明中与产品类型、目录相关的段落：

- 源目录：`/mnt/hgfs/share/Synopsys2018/tx_vO-2018.06-SP1`。
- `tx_INSTALL_README.txt` 标识为 `TetraMAX_Overlay_with_Synthesis`。
- `txs_INSTALL_README.txt` 标识为 `TetraMAX_StandAlone`。

建议在安装器选择 `TetraMAX_StandAlone`（txs）、版本 `O-2018.06-SP1`，最终目录为 `/home/synopsys/txs/O-2018.06-SP1`。若安装器要求的是安装根目录，填写 `/home/synopsys` 并检查最终路径预览。本轮只核对安装说明，没有代用户执行 TetraMAX 安装。

### 2. 存储编译器主体包已实际到位

这次共享 Memory 目录确认新增两个主体包：1PRF 130a 为 30,062,200 bytes，公共 Memory Compiler 110a 为 31,275,076 bytes。外层包还包含同名内层压缩包，公共包内实际引擎版本为 `MC2_2012.02.00.d`，与 1PRF 手册要求一致。

只提取生成必需的 `.mco`、Perl 入口和 64 位引擎到项目之外的 `/home/ICer/eda/pdk/tsmc28/Memory/compilers`，没有运行 `install.sh`。

新增简单的复现输入：

- `scripts/synth/operand_32x64.txt`：一行 `32x64m2f`，表示 32 words × 64 bits、MUX=2、F 分段。
- `scripts/synth/generate_operand_sram.sh`：仅设置本进程的 `MC_HOME`、引擎路径，进入项目外输出目录并调用 Perl 入口。

本次实际生成命令的主要参数是：

```bash
perl "$MC_HOME/tsn28hpcp1prf_130a.pl" \
    -file operand_32x64.txt -SVT -NonBWEB -NonBIST -NonSLP -NonSD
```

显式 `-SVT` 选择标准阈值；本轮不需要按位写掩码、宏内部 BIST 输入复用、sleep 或 shutdown，因此关闭这些选项。以后外部 MBIST 可以通过存储接口复用控制宏，不以本轮启用宏内部 BIST 引脚为前提。

完整复现入口及保存日志方式：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/memory/operand_32x64
LC_ALL=C bash scripts/synth/generate_operand_sram.sh > build/memory/operand_32x64/generation.log 2>&1
```

### 3. 真实执行结果：宏未生成

引擎启动并正确解析了生成配置，日志中实际打印 SVT、32×64、MUX=2、F 分段，并构造实例名称 `TS5N28HPCPSVTA32X64M2F`。随后出现：

```text
FATAL (MC, 044): Failed to get license for feature MC2-tsn28hpcp1prf-CLV or MC2-tsn28hpcp1prf-CPV
```

这是正常生成命令运行时暴露的阻塞。本轮没有据此读取、验证或修改任何 License 文件、服务、配置，也没有继续尝试相关修复。

程序在打印 FATAL 后仍返回退出码 0；因此 `set -e` 和 shell 退出状态不足以证明生成成功。真正的成功依据应是日志及可用的实际模型。本次没有获得 `.v/.lib/.db` 模型，打印出的实例名称不能当作模型已经生成的证据。

没有实施 SRAM RTL 替换，没有填入虚构的库路径，也没有运行依赖这些模型的完整 NPU 综合。`scripts/synth/npu.tcl` 与 `constraints/npu.sdc` 作为准备稿保存，宏 DB 与包装模块仍待完成。

### 4. Commit 与 push 状态

用户已授权分阶段 commit 并 push。本轮先审查并提交此前验证修复、工程目录迁移、旧脚本退役、PE DC 脚本及学习记录：

```text
7b389bf refactor: organize NPU verification and checkpoint EDA learning flows
```

暂存范围明确列出，没有加入外部工艺库、安装包或 build 生成文件。新纳入的 JSON/CSV/TB 行尾格式问题已修正，暂存补丁检查通过。先前记录的回归结果仍按原实验记录说明，没有把本轮格式整理说成重新通过全部回归。

实际执行 `git push origin learning/vcs-pe`，HTTPS 返回无法读取 GitHub 用户名；SSH 非交互测试也未能通过已有主机信任记录。没有成功推送，没有强制推送。用户选择学习 GitHub SSH 认证，已给出生成密钥、上传公钥、核对官方主机指纹、测试连接及切换远程地址的步骤，等待用户完成后重试。


## 2026-10-18：补齐原始 MC2 包的 aux 目录

用户明确要求补齐 `aux`，并计划向厂家取得正式授权。本轮仅部署原始公共主体包内的辅助组件。

- 来源：共享目录中的 `tsmc_n28hpcpmc_20120200_110a.tar.gz`，其同名内层包包含 `MC2_2012.02.00.d.tar.gz`。
- 目标：`/home/ICer/eda/pdk/tsmc28/Memory/compilers/MC2_2012.02.00.d/aux`。
- 部署前目标目录不存在，因此没有覆盖原有文件，也无需对已有文件进行备份。
- 实际提取 447 个归档条目，其中 421 个为普通文件，合计 68,366,863 bytes，约 65.2 MiB。
- 解压前检查归档成员路径和链接的目标范围；解压后仅核对普通文件是否存在及大小是否与归档一致，没有读取配置内容。
- 没有访问 `crk`、运行安装脚本、启动辅助程序或授权服务，也没有重试存储宏生成。

这一步只补齐程序组件，不代表 MC2 的宏生成已经通过。存储宏模型仍待取得正式授权后生成；NPU 的真实 SRAM 替换及完整 DC 综合状态保持未完成。

辅助文件位于项目外，不提交到 Git；本轮仅提交这份部署记录。GitHub 认证此前未完成，推送状态以实际执行结果为准。


## 2026-10-18：真实 A/B 存储宏接入与完整 NPU 综合启动

### 1. 实际生成成功

本次直接重试已有生成入口，日志保存到 `build/memory/operand_32x64/20261018_132723/generation.log`。实际结果为 `Number of errors : 0, Number of warnings : 0` 和 `Normal Termination`，并产生 Verilog、NLDM、LEF 等视图。

生成宏的实际名称是 `TS5N28HPCPSVTA32X64M2F`，接口为 `CLK/CEB/WEB/A[4:0]/D[63:0]/Q[63:0]`，容量 32×64 bit，CEB 和 WEB 均低有效。本轮使用的目录是：

```text
/home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a
```

选择 `tt0p9v25c` 模型，已核对其时间单位为 ns、电容单位为 pF，与标准单元库一致。Liberty 中该单元 area 属性为 2643.049500；16 个宏的属性之和为 42288.792000，最终是否保留 16 个实例仍须看综合报告，不能仅凭配置推定。

### 2. LC 的真实作用和结果

新增 `scripts/synth/operand_sram_lib.tcl`，直线流程只有设置输入输出路径、`read_lib`、`write_lib -format db`、退出。输入是生成的 TT Liberty，输出为同目录同基本文件名的 `.db`，库名为 `ts5n28hpcpsvta32x64m2f_tt0p9v25c`。

LC 实际成功读取库并写出 35,840 bytes 的 `.db`，日志在 `build/lc/operand_sram/run.log`。保留一条 `LBDB-366` 告警：char_config 缺少 `internal_power_calculation` 属性。当前没有据此修改厂商模型或开展功耗签核。

手动复现 LC 转换：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/lc/operand_sram
cd build/lc/operand_sram
LC_ALL=C /home/synopsys/lc/O-2018.06-SP1/bin/lc_shell -f ../../../scripts/synth/operand_sram_lib.tcl 2>&1 | tee run.log
```

### 3. RTL 改动与边界

新增 `rtl/memory/operand_sram.sv`，只为 A/B 操作数存储适配接口：

```systemverilog
assign addr = wen ? waddr : raddr;
// CEB = ~(ren | wen); WEB = ~wen;
```

宏 Q 直接连接 rdata，没有增加寄存器或时钟周期。`NPU_TSMC28` 选择真实 32×64 宏；普通仿真分支仍调用原 `sram_model`，保留小尺寸与其他参数的测试能力。真实宏仿真分支仅检查固定容量/字宽和同 bank 不同时读写这两项必要约定。

`operand_buffer.sv` 的三个存储实例改为该包装。Makefile、公共 RTL 清单、GEMM Core 独立清单及 DC 源列表同步更新。已有模型编译器的依赖记录只同步本次 operand_buffer 和新增包装文件，未放宽其他历史 RTL 差异检查，也未宣称 Python 模型端到端重新验证。

本轮没有合并 C/PSUM、改变 Conv cache 时序、改变顶层 AXI 接口或 descriptor 格式。其他行为 RAM 尚未落到硬宏，因此本轮完整 NPU 的面积仍包含这些由标准单元实现的存储。

### 4. 已完成与正在运行的功能验证

普通行为模型分支的 `operand_path_tb` 已 PASS，日志目录为 `build/vcs/operand_path_tb/20261018_132958`，覆盖双 bank 装载、流暂停、K 尾部和 INT8 选择。

真实宏版本的 `gemm_executor_tb` 已 PASS，目录为 `build/vcs/gemm_executor_tb/20261018_133326`。该测试使用 K=260，覆盖 256+4 的 K 分块、64 个 INT32 输出，以及 AR=64、AW=16、W=64 的事务统计。

真实宏测试的调用方式为：

```bash
PATH=/home/synopsys/vcs/O-2018.09-SP2/bin:$PATH \
LC_ALL=C bash scripts/sim/run_vcs.sh gemm_executor_tb \
    +define+NPU_TSMC28+UNIT_DELAY \
    /home/ICer/eda/pdk/tsmc28/Memory/macros/operand_32x64/ts5n28hpcpsvta32x64m2f_130a/VERILOG/ts5n28hpcpsvta32x64m2f_130a_tt0p9v25c.v
```

`NPU_TSMC28` 选择真实宏连接，`UNIT_DELAY` 是厂商提供的快速功能模式，关闭模型的物理时序检查并保留小延迟；它不是后仿或时序签核。没有使用屏蔽全部模型告警的选项。当前看到 CEB 未知态提示发生在初始复位时钟沿，完整告警汇总与顶层回归结果随后补记。

### 5. 完整 NPU DC 实验已启动

实际运行目录为 `build/dc/npu_20261018_133300`，与 `build/dc/npu` 同一目录层级，因此 Tcl 中三级相对路径仍正确。执行的是：

```bash
cd /home/ICer/eda/npu-vcs-learning/build/dc/npu_20261018_133300
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/npu.tcl > run.log 2>&1
```

脚本已填入真实 SRAM `.db`，标准单元用于 target library，标准单元和 SRAM 同时用于 link library。厂商行为 Verilog 只用于 VCS，不交给 DC 当普通 RTL 综合。保留 10 ns 教学时钟和既有接口约束，添加引用统计和 `check_timing` 报告，以核对宏实例及约束覆盖。

在本阶段记录时，顶层 VCS 回归和完整 DC 仍在执行，尚不能报告最终面积、setup/hold 或完整顶层 PASS；最终结果将在同一笔记后续条目补充。


### 6. 顶层与卷积功能回归完成

真实宏版本的 `npu_top_tb` 已 PASS，目录为 `build/vcs/npu_top_tb/20261018_133637`。实际结果：三个 descriptor 分别验证纯 GEMM INT32、Bias INT32、Bias+Requant+ReLU INT8；总计 10,241 cycles、249 次 AR、48 次 AW、144 个写 beat。该测试采用 8×8 输出、K=260，完整比较其黄金结果。

为了验证 Conv 的 A 装载路径，另复核已有 `conv2d_npu_tb`。其 DDR 读模型仍使用旧的 32 位总线、只接受 ARSIZE=2、每拍固定前进 4B，与当前顶层 64 位读口不符。本次仅修正 Testbench：将读数据改为 64 位，保存每个请求的 ARSIZE，窄读返回一个 32 位字、宽读拼接两个 32 位字，按 4B/8B 前进，并沿用地址对齐检查。DUT 与正在运行的 DC 输入没有因此修改。

新增两行 `sim/filelists/vcs/conv2d_npu_tb.f` 复用普通 VCS 入口。执行方式与前面的宏回归相同，仅将 top 名称换为 `conv2d_npu_tb`。实际结果保存在 `build/vcs/conv2d_npu_tb/20261018_140136`：

```text
Conv2D + Bias + Requant + ReLU + INT8 writeback PASS cycles=381 busy=0 acc00=131
```

该用例以独立输入/权重函数和卷积黄金计算，比较全部 16 个 INT8 输出；输入 4×4×8、kernel 3×3、输出 2×2×4、K=72。本次单端口读写互斥检查未触发。这不是全部 Conv 配置或全部算子覆盖闭合。

| 用例 | 存储分支 | 结果 |
| --- | --- | --- |
| operand_path_tb | 原行为模型，验证包装的普通分支 | PASS |
| gemm_executor_tb | 实际宏，UNIT_DELAY | PASS，64 个输出 |
| npu_top_tb | 实际宏，UNIT_DELAY | PASS，3 个 descriptor |
| conv2d_npu_tb | 实际宏，UNIT_DELAY | PASS，16 个输出 |

三项实际宏测试各出现 16 条 CEB unknown/high-Z 提示，均只发生在 t=5 ns 的第一次复位时钟沿；没有观察到后续时刻的同类提示。同步复位前的控制状态尚未初始化，宏本身也不提供存储阵列复位。日志原样保留，未通过全局关闭告警来获得 PASS。

完整 DC 此时仍在运行，尚未生成最终网表与报告。中间优化表已显示 setup 目标未满足，但表内面积、负裕量和代价仍在变化；这些不作为最终 PPA 或签核结论。


## 2026-10-18：完整 NPU DC 综合完成与结果分析

### 1. 执行结果与保存位置

本轮 `compile` 已结束，DC 正常退出，外层进程退出码为 0；`run.log` 未发现 `Error:`。13:33 启动，14:55 写出结果，DC 记录 CPU 使用 4829 seconds，内存 2176 Mbytes。执行目录为 `build/dc/npu_20261018_133300`，使用的脚本仍为 `scripts/synth/npu.tcl`，没有为了消除违例修改约束或 RTL。

已实际生成：

| 输出 | 内容 |
| --- | --- |
| `run.log` | 读取 RTL、展开、链接、映射优化与导出的完整日志 |
| `npu_mapped.v` | 层级门级网表，约 31 MiB |
| `npu.ddc` | DC 设计数据库，约 18 MiB，供后续在 DC 中继续分析 |
| `npu.sdc` | 本轮导出的时钟、输入输出延迟等约束 |
| `reports/area.rpt`、`area_hierarchy.rpt` | 总单元面积和层级面积 |
| `reports/references.rpt` | 设计引用与存储宏引用 |
| `reports/timing.rpt`、`hold.rpt` | 最差 10 条 setup / hold 路径 |
| `reports/constraints.rpt` | 全部已报告的约束违例 |
| `reports/check_design_mapped.rpt`、`check_timing.rpt` | 综合后结构检查和时序约束检查 |

### 2. SRAM 与面积核对

综合网表中实际包含 **16 个 `TS5N28HPCPSVTA32X64M2F`** 实例，引用报告也列出相同宏，面积报告列出实际 SRAM 库。它们是有时序/面积模型的存储宏；报告中的 `macros/black boxes` 是合并栏目，不能把这 16 个宏理解成 16 个缺失模型。

| 项目 | DC 最终值 |
| --- | ---: |
| 组合叶单元数 | 230770 |
| 时序叶单元数 | 75137 |
| 存储宏数 | 16 |
| 组合单元面积 | 196631.440412 |
| 时序单元面积 | 192724.679911 |
| 存储宏面积 | 42288.792969 |
| 总单元面积 | 431644.913291 |

面积按库中 area 属性单位记录，不将它直接称为芯片面积。`Buf/Inv area` 已包含在组合面积中，不能重复相加。报告的 `Number of cells = 306328` 还包含层级单元；叶标准单元为 230770+75137=305907，宏另计。`Number of ports = 60677` 也包含层级端口，不能解释成芯片外部引脚数量。

16 个宏合计 32768 bit，即 4 KiB，只对应 A/B 操作数存储。C、PSUM、Conv cache 等尚未全部换成硬宏，当前 75137 个时序叶单元不能当成最终 SRAM 化后的寄存器规模。`u_gemm_executor` 占 83.1% 总单元面积，`u_pool` 占 10.4%；这些父层级面积已经包含子层级，不能再次与子模块面积相加。

### 3. Setup：100 MHz 目标没有达到

保留 10 ns 时钟、0.2 ns uncertainty、1 ns 最大输出延迟。最差路径为：

```text
Startpoint: u_pool/sum_q_reg[0][6]
Endpoint:   m_axi_wdata[3]
Data arrival time:  20.49 ns
Data required time:  8.80 ns
Slack (VIOLATED):  -11.69 ns
```

这条路径经过 `u_pool/div_150_C175`。对应 RTL 是 `rtl/compute/pool2d_engine.sv` 的 `rounded_average()`：将累计和与像素数扩展到 64 位，在组合函数中完成带舍入的变量除法，再经输出选择连接写数据。DC 将 `/ divisor` 展开为组合除法电路，除法链很长。即使当前 GEMM 用例没有发出池化命令，这个全 NPU 综合仍保留池化硬件并对路径计时。

`8.80 = 10.00 - 0.20 - 1.00`，因此 20.49 ns 的到达时间无法满足本轮接口预算。`constraints.rpt` 共报告 37589 条 setup 违例项，最差 -11.69 ns；最差 10 路径报告并不表示全设计只有 10 条违例。

这不是简单的 SRAM 包装延迟问题。后续可比较迭代除法、流水除法或有明确数值误差约束的倒数乘法，但会改变延迟、握手或数值实现，属于需要先讲解并确认的设计改动。本轮没有实施，也没有擅自添加 false path / multicycle 或降低目标频率。

### 4. Hold：短路径与当前约束共同造成违例

最差路径从 `u_conv_patch_loader/partial_word_q_reg[0]`，经少量选择逻辑，到 A bank0 lane0 SRAM 的 `D[0]`：

```text
Data arrival time:   0.11 ns
Clock uncertainty:  0.20 ns
Library hold time:  0.10 ns
Data required time: 0.30 ns
Slack (VIOLATED):  -0.20 ns
```

以上数值由报告四舍五入显示，不能要求用显示的 0.11-0.30 精确复算 -0.20。`constraints.rpt` 共报告 18154 条 hold 违例项（包括显示为 0.00、但内部精度仍为负的项）。这是实际需要保留的违例证据。与此前 PE 的 input-min 教学违例不同，本轮最差路径是寄存器到 SRAM 的内部路径，不能仅归因于外部输入延迟。

当前时钟理想化、hold uncertainty 设为 0.2 ns，且尚无 CTS 与实际布线寄生。后续需要复核真实时钟预算，并在物理实现中结合时钟偏斜和数据路径延迟修复 hold；不能仅凭本阶段结果认定最终芯片一定有同样违例，也不能直接将其忽略。

### 5. 告警和实验边界

- `check_timing.rpt` 返回 1，未列出时序环或未约束端点告警；这表示本次检查项没有报告问题，不表示 setup / hold 通过。
- `check_design_mapped.rpt` 仍有告警：unloaded inputs/nets 各 797、unconnected ports 5508、feedthrough 1275、shorted outputs 227、constant outputs 169、同一网接同一单元多个 pin 336。抽查包括固定 AXI 常量、直接连线、被优化或未使用的位；本轮没有逐项证明所有结构告警无害，不能宣称结构检查零告警。
- `TIM-164`：两库的测量阈值定义不同。只读核对后，标准单元 slew 使用 30%～70%，SRAM 使用 10%～90%；输入/输出延迟阈值均为 50%。本轮未改动厂商模型，跨库 slew 解释仍是后续时序模型复核事项。
- `TIM-134`：一个高扇出网络采用 1000 的扇出数作延迟估算；这仍是综合阶段估算。
- 导出保留 `UCN-1/UCN-4` 名称处理和 `VO-4` 的 assign/tran 提示，没有将这些提示隐藏。
- 仅 TT / 0.9 V / 25°C、ZeroWireload、理想时钟；没有多角、多模式、布局布线、SDF 后仿或形式等价验证。本轮结果用于暴露架构和约束问题，尚未时序收敛。
- 前面记录的四项 VCS 测试均 PASS，但使用的实际宏 `UNIT_DELAY` 模式只验证对应功能场景，不验证上述物理时序违例，也未覆盖全局平均池化数值功能。

### 6. 手动复现与本次学到的工具分工

已有宏和 `.db` 时，在单独输出目录复现 DC：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dc/npu
cd build/dc/npu
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/npu.tcl > run.log 2>&1
```

目录层级与脚本相对路径对应；若该目录已有结果，先选择同层的新目录以保留实验记录。`-f` 指定 Tcl 脚本，`> run.log 2>&1` 保存标准输出和错误输出。脚本依次 analyze、elaborate、link、加载约束、compile、生成报告并导出文件；它不会运行 Testbench。

MC2 生成指定容量 SRAM 的模型；LC 将描述 pin、时序弧、查表数据和面积的 `.lib` 文本编译为 `.db`，便于 DC/PT 读取。`.db` 是库数据库，`.ddc` 是设计数据库，两者用途不同。DC 读 RTL、标准单元/SRAM 库和 SDC，把普通逻辑映射为标准单元并保留已实例化 SRAM。VCS 则使用 RTL/Testbench 与宏 Verilog 模型验证功能。

本轮代码阶段提交为 `4b21c32` 与 `3a7f5f0`。用户说明尚未添加 GitHub 公钥，明确推迟推送；本轮最终实验记录另作提交，未声称 push 成功。外部 PDK/模型、安装包和 build 结果不加入 Git，原始实验文件仍保留在本机。


## 2026-10-18：减少存储触发器的分析与 hold 单独修复实验

用户要求先 push，再减少存储触发器，并优先处理 hold。实际推送先尝试现有 HTTPS origin，仍因没有可用用户名凭据失败；再通过已核对主机公钥的 SSH 尝试，返回 `Permission denied (publickey)`。CentOS 7 的旧 Git 不使用较新的 `GIT_SSH_COMMAND`，本次改用临时 `GIT_SSH` 启动脚本完成 SSH 尝试，没有关闭主机身份校验，也没有声称推送成功。已请用户完成公钥添加，等待后重试。

### 存储替换的范围与待确认事项

原面积报告显示，四个 C bank 各 26262.4312，合计约占总单元面积 24.3%；Conv cache 为 103374.1771，占 23.9%。这两处是优先减少触发器存储的对象，状态机、计数器和必要流水寄存器仍保留。

C bank 当前使用通用 `sram_model`，读写地址独立，接口支持同拍读写。现有可用生成器为 1PRF；共享目录的 2PRF 仍只有 doc/rln，没有主体包。完整保留通用接口语义不能直接把独立读写端口接到一个单端口宏上。计划补齐 `tsn28hpcp2prf_20120200_130a.tar.gz` 后，核对真实端口、时序及碰撞规则再替换。

Conv cache 数据和 tag 为组合读数组，当前比较与输出在同周期完成。换成同步 SRAM 会增加查找等待周期，需要修改状态机并测试命中、缺失聚合、反压、冲突替换和失效。已向用户提出保持容量的同步 SRAM 方案并等待确认；本条记录时没有修改这些 RTL，也没有通过缩小容量或删除缓存来降低面积。

### Hold 实验原理与命令

新增 `scripts/synth/npu_fix_hold.tcl`，只加载上轮已映射的 `npu.ddc`，保留其时钟及接口约束，然后执行：

```tcl
set_fix_hold [get_clocks npu_clk]
compile -only_hold_time
```

本机 DC O-2018.06-SP1 官方命令说明中，`set_fix_hold` 启用指定时钟的 hold 修复，`compile -only_hold_time` 仅进行 hold 修复，忽略其他设计规则优化。本实验通过门级缓冲或单元调整增加短路径延迟，不插入功能寄存器或改变协议周期，也不把 hold uncertainty 改为零。需要在结果中同时复查 setup、面积及设计规则，不能把执行该命令当作必然修复成功。

实际运行目录为 `build/dc/npu_hold_20261018`，原目录 `build/dc/npu_20261018_133300` 保留。手动复现命令：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dc/npu_hold
cd build/dc/npu_hold
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/npu_fix_hold.tcl > run.log 2>&1
```

脚本内 `read_ddc ../npu_20261018_133300/npu.ddc` 明确选择本轮基线。输入路径和相对目录层级不变即可复现；输出在自己的目录，不覆盖基线。本条记录时设计已链接，hold 优化正在运行，最终修复数量及残留问题随后补记。

用户随后确认已添加 GitHub 公钥，并明确本阶段“先只修 hold，存储方案稍后讨论”。因此本阶段不修改 Conv cache、C 存储或其他存储 RTL，只继续 hold 修复和推送。使用兼容旧版 Git 的 GIT_SSH 入口重新推送，GitHub 成功创建 learning/vcs-pe 远程分支，已包含 83c8466 及此前提交。未创建 PR，也未修改 origin 的 HTTPS 地址。


### 调整优化优先级：保留约束，优先修 hold

默认优先级实验运行约 15 分钟，优化表仍停留在 `min_path` 修复：末段面积约 440501.5、setup 违例幅度约 11.71 ns、min-delay cost 约 -3575.50。这里的 cost 不是最差 hold slack，不能当成完成后的时序报告。因进展慢且用户明确要求先解决 hold，本轮改用 hold 优先策略。

先向 DC 发出 SIGINT，DC 实际保存了 `build/dc/npu_hold_20261018/CHECKPOINT.ddc`，但随后继续优化；因此在确认检查点写出后，通过 SIGTERM 停止这一实验。该轮是人工中止的阶段实验，外层退出码为 1，没有最终报告，不能记为正常完成或 hold 通过。默认优先级脚本版本已在提交 `83c8466` 中保存。

根据本机官方 `set_cost_priority` 命令说明，在同一入口补充：

```tcl
set_fix_hold [get_clocks npu_clk]
set_cost_priority -min_delay
compile -only_hold_time
```

`-min_delay` 使最小延迟目标的优先级高于最大延迟目标，但低于最大设计规则。它不是时序例外，也不改变实际要求的保持时间；允许优化器在 setup/hold 冲突时优先修 hold，需要如实报告 setup 变化。

新一轮位于 `build/dc/npu_hold_priority_20261018`，重新读取同一原始 `build/dc/npu_20261018_133300/npu.ddc`，便于与基线比较。没有沿用旧实验的部分优化结果，没有重新 analyze/elaborate RTL，也没有修改存储或计算架构。此条记录时该实验正在运行。


### 检查点复核与按 STA 终点插入延迟缓冲

独立读取原始 DDC 与第一轮检查点，在 `build/dc/npu_hold_inspect_20261018` 生成对照报告。原始设计最差 hold -0.20 ns、setup -11.69 ns；检查点最差 hold -0.21 ns、setup -11.71 ns，后者最差 hold 起点为 `m_axi_rdata[11]`，终点为 B SRAM。专用 DEL 系列实例数从 398 增至 411。该检查不是重新综合，也没有修改输入 DDC。

第二轮 hold 优先优化也在缓慢搜索输出短路径。保存 `build/dc/npu_hold_priority_20261018/CHECKPOINT.ddc` 后中止，该轮同样不能记为正常完成。其脚本版本保留在提交 `01b93dc`，该提交已实际推送到 GitHub。

为直接处理已经识别的违例，最终入口改为 STA 驱动的门级缓冲 ECO。使用本机官方 `get_timing_paths`、`insert_buffer` 命令：

1. 读取同一原始 DDC，保留原始时序约束。
2. 查询 hold slack 小于 0 的路径，每个终点取一条最差路径。
3. 先保存终点集合，再在各终点前插入 `DEL200MD1BWP40P140`；这样不会在修改网表后继续读取已失效的旧路径对象。
4. 重新计时，最多三轮；最终仍由报告判断是否修复成功，不能以完成插入当作通过。

该标准单元来自当前 TT 库，功能为 `Z=I`、面积属性为 3.15，有完整延迟与转换时间表。示例低 slew / 低负载下的下降延迟约 0.280 ns，实际值必须由 STA 根据 slew/load 查询，不能把单元名称解读为固定的 200 ps 延迟。没有编写 RTL 的 `#delay`，没有添加功能寄存器，也没有调整 uncertainty 或接口延迟。

新实验目录为 `build/dc/npu_hold_eco_20261018`，入口仍是简单的 `scripts/synth/npu_fix_hold.tcl`。额外保存 `reports/hold_before.rpt` 与 `timing_before.rpt`，修复后以四位小数保存时序和约束报告，避免四舍五入掩盖小负裕量。本条记录时 ECO 正在运行，尚未宣称时序通过。


### ECO 端口处理问题与修正

首轮缓冲 ECO 在 `build/dc/npu_hold_eco_20261018` 完成，但日志存在 `NLE-036/NLE-020`，不能记为通过。第一次插入后剩余 698 个违例，后续两轮未减少，最差 hold -0.1408 ns；内部违例大部分修复，残留集中在顶层输出端口。时序叶单元仍为 75137、宏仍为 16；该轮总单元面积 486631.314956、最差 setup -11.9791 ns，约束报告没有额外列出最大电容/转换时间等违例类别。

在独立目录 `build/dc/npu_hold_port_inspect_20261018` 检查 `acc_out[255]`：端口与网络确实相连，通过 `get_ports` 重新获取端口后，`insert_buffer` 可以正常插入；通过网络对象插入也成功。不是 RTL 的端口没有连线。混合集合中的端口对象交给插入命令时未能正确解析连接，具体内部机制没有据此认定为工具缺陷。

脚本改为先用 Tcl 列表保存终点名称，再以 `get_pins` / `get_ports` 重新取得对应对象后执行插入，避免把混合的端口和引脚集合直接交给编辑接口。随后在 `build/dc/npu_hold_fixed_20261018` 从原始 DDC 重新验证最终入口；不沿用前面含错误日志的输出作为最终候选。本条记录时验证正在进行。


### 最终结果：当前约束下 hold 违例清零

最终候选位于 `build/dc/npu_hold_fixed_20261018`。DC 正常退出，外层退出码 0、日志无 `Error:`，CPU 使用 83 seconds。实际轮次记录：

```text
HOLD_ECO_PASS 1: 18154 violating endpoints
HOLD_ECO_PASS 2: 0 violating endpoints
```

不仅检查了轮次计数，也核对最终 `reports/constraints.rpt`：仅剩 `max_delay/setup` 违例类别（37589 项），没有 `min_delay/hold`、最大电容、最大转换时间等新增违例类别。`get_timing_paths` 运行时保留了 `TIM-104` 提示（不保证返回最差路径顺序），因此不能单靠查询顺序宣称修复；本次以全部约束报告及最终最差路径报告交叉核对。

| 项目 | 原始综合 | 最终 hold ECO |
| --- | ---: | ---: |
| Hold 违例项数 | 18154 | 0 |
| 最差 hold slack / ns | 约 -0.20 | +0.0008 |
| 最差 setup slack / ns | 约 -11.69 | -12.0009 |
| 总单元面积，库属性单位 | 431644.913291 | 488830.015022 |
| 时序叶单元数 | 75137 | 75137 |
| SRAM 宏数 | 16 | 16 |
| DEL200MD1BWP40P140 数量 | 0 | 18154 |

最终组合单元数 248924，较原始 230770 正好增加 18154，网数也增加 18154。新增的是逻辑值不变的延迟缓冲，不是功能寄存器；没有删除或增加状态、没有改变协议周期。总面积增加约 13.25%，这是本轮直接逐终点修复的代价，不将其描述为面积最优方案。

最差 hold 路径已经转移到参数槽 bank 的 bias 寄存器使能端：

```text
Startpoint: u_gemm_executor/param_fill_slot_q_reg_1_
Endpoint: u_gemm_executor/u_output_param_slot_bank/bias_q_reg_1__0__9_
Data arrival:  0.1881 ns
Data required: 0.1873 ns
Slack (MET):  +0.0008 ns
```

该路径原本就接近边界，本轮查询中没有负裕量，因此未加延迟。0.0008 ns 只有 0.8 ps，当前约束下通过但余量很小；它不能代表后续所有 PVT、CTS 和布线条件都通过。

最差 setup 路径仍从池化累加寄存器，经组合除法到 `m_axi_wdata[4]`。新增输出延迟单元在该路径上贡献约 0.3207 ns，最终 arrival 为 20.8009 ns、required 仍为 8.8000 ns，slack -12.0009 ns。相对原始最差 setup 约恶化 0.31 ns，说明 hold 修复需要付出 setup 代价；没有通过放宽时钟或添加时序例外掩盖问题。

`check_timing` 未报告约束覆盖或环路问题。`check_design` 没有 Error，但仍有结构告警，包括 unloaded nets 2065、unloaded inputs 797、unconnected ports 5508 等，不能宣称结构检查零告警。最终网表已实际导出 `npu_mapped.v`、`npu.ddc`、`npu.sdc`；原始模型和宏文件仍在工程外，build 结果不加入 Git。

本轮没有修改任何 RTL，因此没有重复前面的 RTL VCS 回归；没有进行形式等价验证或 SDF 后仿。当前结论限定为 TT / 0.9 V / 25°C、理想时钟、ZeroWireload 和原始 10 ns 教学约束下的门级 STA 修复，后续物理实现仍需重新检查 setup / hold。

最终脚本的手动复现方式保持简单，使用一个新的同层输出目录以保留已有结果：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dc/npu_hold
cd build/dc/npu_hold
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/synth/npu_fix_hold.tcl > run.log 2>&1
```

阅读脚本时，重点理解 `read_ddc`（读取现有网表和约束）、`get_timing_paths -delay_type min -slack_lesser_than 0`（找负裕量 hold 路径）、`-nworst 1`（每个终点一条）、`insert_buffer`（插入真实标准单元）、`report_constraint -all_violators`（检查残留违例）。本轮的核心经验是：保持时间修复增加数据路径传播延迟，并不需要增加一拍；门级 ECO 的逻辑正确与时序达标仍要通过相应检查分别确认。

按用户最新选择，存储触发器的 SRAM 化方案暂停，本轮没有修改 Conv cache、C、PSUM 或计算流水。GitHub 公钥认证已实际打通，最终脚本和记录继续按阶段提交并推送，是否推送成功以实际输出为准。


## 2026-10-18：40 MHz 功能时序复核与 DFT 插入前检查

### 1. 本阶段范围与输入

用户同意开始 40 MHz 时序复核和扫描方案准备。本阶段读取已经完成 hold ECO 的 `build/dc/npu_hold_fixed_20261018/npu.ddc`，不重新综合 RTL，不插入扫描链，不修改存储或计算架构。

将 `constraints/npu.sdc` 的功能时钟从 10 ns 改为 25 ns（40 MHz），保留 0.2 ns uncertainty、输入输出延迟、转换时间和输出负载。历史 100 MHz 结果及对应 DDC/SDC 在原 build 目录中保持原样。功能目标降频是用户明确接受的学习目标调整，不将其描述为仍然满足原来的 100 MHz 性能。

新增 `scripts/dft/npu_precheck.tcl`，实际运行目录为 `build/dft/npu_precheck_40mhz_20261018`：

```bash
cd /home/ICer/eda/npu-vcs-learning
mkdir -p build/dft/npu_precheck_40mhz_20261018
cd build/dft/npu_precheck_40mhz_20261018
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/dft/npu_precheck.tcl > run.log 2>&1
```

手动复现时应使用同层的新输出目录保留已有实验。脚本中的 `../../dc/...` 从当前输出目录指向 build/dc；`../../../constraints/...` 指向工程的功能 SDC。

### 2. 功能时序真实结果

`reports/functional_clock.rpt` 确认 `npu_clk` 周期 25.00 ns、波形 `{0 12.5}`。没有重映射逻辑，单元面积与 hold ECO 结果相同。

| 项目 | 40 MHz 实际结果 |
| --- | ---: |
| 最差 setup slack | +2.9991 ns |
| 最差 hold slack | +0.0008 ns |
| 全部约束违例 | 0 |

最差 setup 仍是池化累加寄存器到 `m_axi_wdata[4]`：arrival 20.8009 ns，required 25.0000-0.2000-1.0000=23.8000 ns。最差 hold 路径与上一轮相同，降频没有替代短路径修复。

`reports/constraints_40mhz.rpt` 实际输出 `This design has no violated constraints.`。这一结论限定为当前 TT / 0.9 V / 25°C、理想时钟和 ZeroWireload，不代表多角或布线后的时序签核。

在任何 DFT 属性配置之前，已保存 `npu_40mhz.ddc` 与 `npu_40mhz.sdc`，供后续扫描综合复用。当前功能 SDC 保持为 40 MHz，测试协议的 100 ns 周期不会写回功能 SDC。

### 3. 测试协议与命令解释

MUX-D 扫描寄存器在 scan_enable=0 时采样功能 D，在 scan_enable=1 时采样链中前一级的扫描数据。扫描移位用于直接设置/观察内部状态，capture 则用功能逻辑产生响应。

本阶段配置普通 MUX-D、暂定 16 条链、单时钟不混合域：

```tcl
set_scan_configuration -style multiplexed_flip_flop -chain_count 16 -clock_mixing no_mix
set test_default_period 100
set test_default_delay 5
set test_default_strobe 40
set_dft_signal -view existing_dft -type ScanClock -port clk -timing {45 55}
set_dft_signal -view existing_dft -type Constant -port reset -active_state 0
create_test_protocol
write_test_protocol -output npu_precheck.spf
dft_drc -pre_dft -verbose > reports/dft_drc_pre.rpt
```

`existing_dft` 描述现有端口的测试用途，不创建硬件。clk 复用原端口，测试周期 100 ns（10 MHz），每周期 45 ns 上升、55 ns 下降；输入在 5 ns 驱动，输出在 40 ns 采样。这种先观察扫描输出、再推进移位的时序属于测试协议，不是功能模式的 25 ns STA 时钟，也不是 at-speed 测试。

官方 `set_dft_signal` 文档将 `Reset` 定义为异步置位/复位。当前 RTL 的 reset 是同步复位，因此此阶段用 `Constant 0` 使其测试时保持无效，不误声明为异步 Reset。这会限制本阶段测试中 reset 有效时的逻辑行为；将来分析 ATPG 覆盖率时必须说明，不能直接宣称复位相关故障已覆盖。

`create_test_protocol` 建立协议，`write_test_protocol` 保存 STIL 格式的 `.spf`，`dft_drc -pre_dft` 检查时钟、顺序单元、扫描等价单元等，`-verbose` 保留详细问题实例。没有运行 `compile -scan`、`insert_dft` 或 ATPG，没有新增 scan_enable / scan_in / scan_out 端口。

库中已找到扫描单元模型；SRAM 也存在独立的 `DFT/ATPG/..._tmax.v` 和 `_fscan.lib`，尚未据此运行 ATPG。SRAM 阵列不作为普通寄存器扫描链中的状态位，本阶段的逻辑扫描也不等同于 MBIST。

此条记录时功能时序复核已完成，DFT pre-DRC 正在检查扫描等价单元。最终预检结果和后续端口方案另行补记。


### 4. Pre-DFT DRC 的实际结论

本次 DC 正常退出，外层退出码 0、run.log 没有 Error。DFT 报告的实际摘要为：

```text
Total violations: 16
16 Cell has unknown model violations (TEST-451)
0 out of 75137 sequential cells have violations
75137 cells are valid scan cells
```

75137 表示本次 pre-DRC 中具备扫描资格的顺序单元，不表示已经全部换成扫描寄存器或连成链。16 条建模告警正好对应 16 个 A/B SRAM 宏，原因是当前 NLDM 视图的 Q 输出功能对 DFT 检查器不完整，形成测试黑盒。它们在 STA 中有实际时序/面积模型，因此不能把测试黑盒告警误解为综合时找不到 SRAM。

本轮没有屏蔽这些告警，也没有将 DFT 预检写成零违例 PASS。该告警是 modeling warning，顺序单元扫描资格检查没有问题；接下来先预览普通逻辑扫描结构，SRAM 的测试模型问题继续单独记录。

已核对生成文件：`_tmax.v` 是包含当前宏名称及 RAM 子模型的 TetraMAX 专用 Verilog；`_fscan.lib` 以 `model ... (model_source = verilog_module; ...)` 建模，是专用 FastScan 模型，不是 Liberty。不能仅凭 `.lib` 扩展名就交给 LC 转成 .db。DC 的 `read_test_model` 接受 DDC/CTL 测试模型，也不能直接将 FastScan 文件当成 CTL 读入。本轮没有换掉 SRAM 的真实时序库，也没有编辑厂商模型。

需要在扫描结构预览后确认扫描接口方案，再进行实际插入。SRAM 阵列的 MBIST/独立存储测试仍未开展，不能声称全 NPU 测试覆盖率已闭合。


### 5. 扫描结构预览与待执行插入方案

在预检入口末尾添加 `preview_dft > reports/scan_preview.rpt`，重新构建相同的检查上下文，于独立目录 `build/dft/npu_preview_40mhz_20261018` 执行。工具正常退出，run.log 无 Error。预览实际结果：16 条链、MUX-D、full_scan、no_mix；第一条 4697 个单元，其他 15 条各 4696 个，总计 75137。没有额外 test point、AutoFix、core wrapper 或 test mode 规划。这里的 full_scan 是普通顺序单元的扫描规划，不包含 SRAM 阵列覆盖。

本次预览使用工具默认的 `test_si1...16` / `test_so1...16` 占位名称。实际接口拟统一为：

| 新接口 | 方向 | 数量 | 作用 |
| --- | --- | ---: | --- |
| scan_enable | 输入 | 1 | 高有效移位使能；低电平为功能路径 |
| scan_in_0 ... scan_in_15 | 输入 | 16 | 16 条链各自的扫描数据入口 |
| scan_out_0 ... scan_out_15 | 输出 | 16 | 对应扫描数据出口 |

共 33 个新增信号位；复用现有 clk，不新增时钟域。16 条链的最大移位长度约 4697，在 10 MHz 下仅移位阶段约需 469.7 us，尚未计入 capture、装载/卸载重叠及协议开销；这不是 ATPG 总测试时间估算。

已准备 `scripts/dft/npu_insert_scan.tcl`，但没有运行。脚本读取已验证的 40 MHz DDC，创建上述接口，用 `set_scan_path` 明确各链输入输出；再次执行 pre-DRC / preview 后由 `insert_dft` 做扫描替换和连接，随后检查 post-DRC、实际链路径并保存 `.v/.ddc/.spf`。

本机官方 `insert_dft` 文档明确支持未做 test-ready compile 时的初始扫描替换；因此本轮可从已映射 DDC 直接插入，不必重新 analyze/elaborate 全部 RTL。`set_dft_insertion_configuration -synthesis_optimization none` 只关闭插入后的时序和设计规则优化，不跳过扫描替换；这样先学习结构插入，再单独分析功能/shift 时序。先前提及的 `compile -scan` 是另一条可用于扫描感知综合的路径，本轮不同时叠加两种入口。

官方 DC 2018 的 `create_port` 只创建标量/单 bit 端口，本轮因此使用简单 for 循环创建明确的标量输入输出，不依赖不存在的总线创建参数。这个循环只表达 16 次相同的接口定义，没有添加运行框架、版本检查或外部环境检查。

实际插链会改变顶层接口和寄存器实现。按用户“重要设计修改先说明并确认”的要求，先完成可审阅的预览与脚本，再请用户确认上述 33 个扫描信号和首阶段普通逻辑扫描范围。SRAM 保留 16 条 TEST-451 建模告警，不将其伪装为测试模型已经解决；阵列测试及 ATPG 模型验证另行开展。此记录时尚未插链，也未运行 ATPG。


## 2026-10-18：普通扫描插入与首轮 ATPG（执行中）

用户确认继续普通扫描并在工具齐全时直接测试；本轮沿用已经讲解的 16 条链、33 个扫描信号、100 ns 测试周期。数据通路 RTL 不变，硬 SRAM 阵列暂不测试；C/PSUM/Conv cache 中仍由触发器实现的部分继续纳入扫描。

运行扫描插入：

```bash
mkdir -p build/dft/npu_scan_20261018
cd build/dft/npu_scan_20261018
LC_ALL=C /home/synopsys/syn/O-2018.06-SP1/bin/dc_shell -f ../../../scripts/dft/npu_insert_scan.tcl > run.log 2>&1
```

`-f` 读取 Tcl，输入是已验证 40 MHz 时序的 DDC 和两个工艺 DB；输出为扫描网表、DDC、STIL 测试协议、链路径和 DRC 报告。插入后尚需检查实际链结构与时序，不能沿用插入前的时序结论。

ATPG 工具 `/home/synopsys/txs/O-2018.06-SP1/bin/tmax` 已实际启动，`report_version` 返回 `O-2018.06-SP1`，日志在 `build/atpg/tool_check_20261018/run.log`。标准单元 Verilog 从官方 VLG 包解至本地工艺库 `logic/tcbn28hpcplusbwp40p140_180b/verilog/tcbn28hpcplusbwp40p140.v`；工艺文件不提交 Git。

准备脚本 `scripts/atpg/npu_stuck_at.tcl`，运行入口：

```bash
mkdir -p build/atpg/npu_stuck_at_20261018
cd build/atpg/npu_stuck_at_20261018
LC_ALL=C /home/synopsys/txs/O-2018.06-SP1/bin/tmax -shell -tcl ../../../scripts/atpg/npu_stuck_at.tcl > run.log 2>&1
```

`-shell` 使用无 GUI 批处理，`-tcl` 明确使用 Tcl。`set_commands exit` 遇到工具命令错误就退出，避免基于错误模型继续生成向量。`read_netlist -library` 读取单元功能模型，`run_build_model npu_top` 展开门级结构，`run_drc` 读取 DC 输出的 `.spf` 并验证移位和捕获协议。`set_faults -model stuck` 选择固定型故障，`add_faults -all` 建立当前模型的故障集合，`run_atpg -auto_compression` 生成并压缩测试向量。`report_summaries` 和 `write_faults` 保留故障分类，`write_patterns -format stil` 输出 STIL 向量。

SRAM 处理：只对 `TS5N28HPCPSVTA32X64M2F` 使用 `set_build -black_box`。按本机 TetraMAX 官方手册，黑盒内部不参与建模，输出为 X，输入端终止；没有将 SRAM 数据伪造为 0，也没有把所有缺失单元设成黑盒。缺失标准单元等真正模型错误仍应使实验失败。SRAM 输出的 X 及黑盒输入不可观测可能使周边逻辑出现无法检测故障，不能把这些故障随意删去提高覆盖率。DC 的 TEST-451 是已知的 SRAM 建模限制，保留原始报告并限定为 16 个 SRAM 实例，不全局压制消息；本机 `set_dft_drc_rules` 也不支持对 TEST-451 做通用 ignore。

MBIST 初步盘点：未找到独立 STAR Memory System / Tessent 安装，但 DC 附带 `libraries/syn/dft_mbist.sldb`，以及 `dw/dw04/lib/dw04/` 中的 `DW_MBIST_CTRL`、`DW_MBIST_APG`、`DW_MBIST_WRAPPER` 等组件及 `libraries/syn/dftc/mbist_t2_*.ctl`。这些是 MBIST 相关构建组件的存在证据，尚不是当前 NPU 已集成且验证的控制器 IP，亦未验证是否有可直接调用的完整生成流程。当前 SRAM 由 MC2 以 NonBIST 生成，没有额外 BIST 端口；这不妨碍后续通过正常读写端口加测试复用器，但需另行设计和验证。StarRC 属于寄生参数提取，不属于 MBIST。

此条记录创建时扫描插入仍在运行；覆盖率需等待实际 ATPG 完成，不能用 75137 个寄存器的扫描资格比例替代故障覆盖率。


### 扫描插入实际结果

`build/dft/npu_scan_20261018/run.log` 正常退出，保存 `npu_scan.v`（36 MB）、`npu_scan.ddc`（20 MB）、`npu_scan.spf`（68 KB）。`reports/scan_chains.rpt` 的 Existing DFT / AS BUILT 表显示：chain_0 长 4697，chain_1～15 各 4696，共 75137 个扫描触发器；所有链均使用 clk、scan_enable 及各自 scan_in/scan_out。

`reports/dft_drc_post.rpt`：0 / 75137 sequential cells have violations；总共 16 条 TEST-451，实例仍严格对应 16 个硬 SRAM。没有新增扫描链违规。标准单元 Verilog 包覆盖插入后网表全部标准单元型号，网表中保留 16 个硬 SRAM。

面积从插入前 488830.015022 增至 543531.280428（约增加 11.19%），组合单元数 248924、时序单元数 75137、宏数 16 均保持；增加主要来自扫描触发器替换。这里是库单元面积，不是布局后的芯片面积。报告 Number of ports 是层次统计，不是本轮新增的顶层引脚数；本轮新增仍为 33 个信号位。

保留了 TIM-134 高扇出、UCN-1 多端口别名、VO-4 网表 assign/tran 等工具消息；这些不能与扫描链功能错误混为一谈，也没有被全局屏蔽。此次未执行插入后的功能/shift STA 或门级向量仿真，不能据此声称扫描后时序已收敛。下一步实际运行 ATPG 的建模与 DRC 检查。
