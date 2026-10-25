# 从一个 PE 开始学习 UVM

这一阶段的目标是跑通一条完整验证链：产生输入、驱动 PE、观察实际信号、自动判断结果。被验证的电路仍然是项目中的 `rtl/compute/gemm_pe.sv`，采用默认的 8 位有符号输入和 32 位累加器。

当前代码保留了学习时的修改：第二笔有效输入是 `2×6`，定向输入后有一次clear和10笔小范围随机输入。先把一笔输入的路径读懂，再展开更多UVM机制。

## 先只看一笔输入

先看两段实际赋值：

```systemverilog
// sequence：把数据写进一个对象。
req.a_in = 3;
req.b_in = -4;

// driver：在时钟下降沿，把对象里的数据写到实际引脚。
vif.a_in = req.a_in;
vif.b_in = req.b_in;
```

`req` 是一个 `pe_item` 对象，保存这一拍想送的数据。`vif` 引用实际的 `pe_if` 接口，它的信号已经连接到PE。sequence填写对象时，PE引脚还没有改变；driver执行第二段赋值后，引脚才改变。

对于代码中的 `first_mac`，实际过程是：

| 时间 | 发生的事 |
| --- | --- |
| 17 ns | sequence填写 `a=3,b=-4,valid=11,reset=0,clear=0` 的对象 |
| 20 ns，下降沿 | driver把对象字段写到PE引脚 |
| 25 ns，上升沿 | PE计算 `0+3×(-4)`，累加器变成 `-12` |
| 26 ns | monitor读取真实输入和输出，scoreboard独立计算并检查 `-12` |
| 27 ns | driver报告这笔完成，sequence才继续 |

本机日志中的 `@26000` 以ps显示，对应表中的26ns。

这里的monitor会创建一个新的观察对象，从实际引脚填写数据。scoreboard根据观察到的输入计算期望值，再与观察到的输出比较。sequencer负责sequence和driver之间的对象交接；先理解上面两段赋值，再读它的端口连接。

第一遍只沿着 `pe_sequence.svh` 的 `first_mac`、`pe_driver.svh` 的 `vif.a_in = req.a_in` 和 `pe_monitor.svh` 的 `observed.a_in = vif.a_in` 看即可。

## 1. 先运行一次

在项目根目录执行：

```bash
make uvm-pe
```

这个入口使用本机 VCS 自带的 UVM 1.2，通过 `-ntb_opts uvm-1.2` 编译。它只编译 PE 和这套 UVM 环境，不需要加载 NPU 模型或整机测试。

默认输出目录是 `build/vcs/pe_uvm/default/`，编译日志为 `compile.log`，仿真日志为 `simulation.log`。使用 `CONFIG=experiment` 可以将输出放到 `build/vcs/pe_uvm/experiment/`；也可以通过 `UVM_RUN_DIR` 指定整个输出目录。

查看编译与仿真日志，观察测试名、组件层级和逐拍检查结果。当前用例发出26笔输入，加上启动时的一拍复位，共检查27个周期。最终应看到下面的信息，UVM统计中的 `UVM_ERROR` 和 `UVM_FATAL` 都应为0：

```text
[TEST_PASS] pe_smoke_test checked 27 cycles
```

需要波形时运行：

```bash
make uvm-pe UVM_WAVE=1
```

默认会生成 `build/vcs/pe_uvm/default/pe_uvm.vcd`，可以在波形查看器中观察时钟、输入和输出。先看 `reset`、`clear`、两个 `valid` 以及 `acc_out`，再看输入和转发输出。

下面这些选项方便后续实验：

```bash
make uvm-pe UVM_TEST=pe_smoke_test
make uvm-pe UVM_VERBOSITY=UVM_HIGH
make uvm-pe RUN_ARGS="+ntb_random_seed=7"
```

`UVM_TEST` 选择要运行的UVM测试类；它与顶层模块 `pe_uvm_tb` 是两个概念。`UVM_VERBOSITY=UVM_HIGH` 会多打印driver和monitor的动作。前15笔输入固定，最后10笔通过 `$urandom_range` 产生，改变随机种子会改变它们；这里尚未使用对象的 `randomize()`。中间另有一笔 `clear_before_random`。

## 2. 先理解 PE 做什么

PE 在每个时钟上升沿更新输出：

```text
reset = 1                  → acc_out = 0，数据输出和 valid 输出也清零
reset = 0，clear = 1       → acc_out = 0，数据和 valid 继续转发
reset = 0，clear = 0：
  a_valid_in && b_valid_in → acc_out = 原 acc_out + a_in × b_in
  其他 valid 组合          → acc_out 保持
```

有两个容易混淆的地方：

- `reset` 是同步复位，PE 在时钟上升沿响应它。
- `clear` 只清累加器。即使 `clear=1`，输入数据和各自的 valid 仍然通过寄存器转发；即使输入无效，数据输出仍然更新。

例如复位后依次送入两拍有效输入：

| 输入 | 计算 | 该拍上升沿更新后的 `acc_out` |
| --- | --- | --- |
| `a=3, b=-4`，两个 valid 都为 1 | `0 + 3 × (-4)` | `-12` |
| `a=2, b=5`，两个 valid 都为 1 | `-12 + 2 × 5` | `-2` |
| 任意输入，只要有一个 valid 为 0 | 不累加 | `-2` |
| `clear=1` | 清累加器 | `0` |

注意这里比较的是该拍寄存器完成更新后的结果。

## 3. 这套框架怎样连接

```text
pe_smoke_test
└── pe_env
    ├── pe_agent
    │   ├── sequencer ← pe_smoke_sequence 产生 pe_item
    │   ├── driver ──→ pe_if ──→ gemm_pe
    │   └── monitor ←─ pe_if ←── gemm_pe
    │          │
    │          └── analysis port ──→ pe_scoreboard
    └── pe_scoreboard：维护期望值，比较实际输出

pe_uvm_tb：产生时钟，实例化 pe_if 和 gemm_pe，启动 UVM
```

沿着一笔输入走一遍，比同时记住所有术语更容易：

1. `sequence` 创建一笔 `pe_item`，填入 `a`、`b`、valid、reset 和 clear。
2. `sequencer` 把这笔输入交给 `driver`。
3. `driver` 通过 `pe_if` 把字段变成 PE 引脚上的信号。
4. PE 在上升沿执行计算。
5. `monitor` 读取真实输入和输出，创建一笔观察记录。
6. `scoreboard` 用观察到的输入计算期望值，再与观察到的输出比较。

计分板依据监视器在 PE 引脚上采到的输入建模，再核对实际输出；它不依赖 sequence 里的手算注释。

## 4. 每个文件负责什么

文件都放在 `sim/uvm/pe/`，建议按下面的顺序读：

| 顺序 | 文件 | 先理解这一点 |
| --- | --- | --- |
| 1 | `pe_if.sv` | 把 PE 的输入输出信号集中放在一个 interface 里 |
| 2 | `pe_item.svh` | 用一个对象描述一拍输入及观察结果 |
| 3 | `pe_sequence.svh` | 按顺序列出这一轮要送给 PE 的数据 |
| 4 | `pe_driver.svh` | 把对象字段赋给实际信号 |
| 5 | `pe_monitor.svh` | 采集真实信号，发送观察记录 |
| 6 | `pe_scoreboard.svh` | 维护参考累加器并比较五个输出 |
| 7 | `pe_agent.svh` | 创建并连接 sequencer、driver、monitor |
| 8 | `pe_env.svh` | 创建 agent、scoreboard，连接观察通路 |
| 9 | `pe_test.svh` | 选择 sequence、启动它、控制测试结束 |
| 10 | `pe_pkg.sv` | 按依赖顺序组织这些类 |
| 11 | `pe_uvm_tb.sv` | 连接模块世界与 UVM 类世界 |

第一遍可以先读 1～6，并结合波形理解数据通路。第二遍再读 agent、env 和 test，理解对象是怎样组织起来的。

这里复用了 UVM 已提供的 `uvm_sequencer #(pe_item)`，没有额外写一个只转交数据的 sequencer 子类。

## 5. 为什么 driver 和 monitor 在不同时间工作

这套练习把时序刻意写得直观：

```text
下降沿                  上升沿                 上升沿后 1 ns      上升沿后 2 ns
  │                       │                         │                  │
driver 写输入          PE 更新寄存器            monitor 采样       driver 完成本笔
```

驱动器在下降沿设置输入，让输入在下一个上升沿前稳定。监视器在上升沿后等待 1 ns，再读取已经更新的输出，避免读到旧值。驱动器在上升沿后 2 ns 才调用 `item_done()`，使序列结束时，最后一笔检查也已经完成。

这是针对当前固定时钟周期的小型教学环境所做的安排。后续学习 clocking block 时，可以把驱动与采样时序进一步集中到 interface 中。

`pe_if` 在时间 0 就把 `reset` 初始化为 1。监视器会检查第一个启动复位周期，之后再检查 sequence 发出的各笔输入，因此观察周期数会比 sequence 的笔数多 1。

## 6. 现在先认识四个 UVM 机制

### phase：按阶段做事

- `build_phase`：创建子组件，获取配置。
- `connect_phase`：连接组件之间的端口。
- `run_phase`：随着仿真时间推进，驱动和采样信号。
- `check_phase`：确认所有应检查的周期都被检查了。
- `report_phase`：报告最终结果。

多个组件的 `run_phase` 并发工作：driver 等待时钟，monitor 也在等待时钟。它们不是依次执行完一个才运行下一个。

### config_db：把 interface 交给类

`pe_uvm_tb` 是 SystemVerilog 模块，直接连接了实际 interface。driver 和 monitor 是类，需要获得这个 interface 的引用才能访问信号。

顶层先通过 `uvm_config_db` 放入 `virtual pe_if`，driver 和 monitor 在 `build_phase` 取出它。可以先把它理解成“按名字传递配置”。这里的 virtual interface 是实际 interface 的引用，不是复制一套引脚。

### port：组件之间传数据

这套框架有两条主要连接：

- driver 的 `seq_item_port` 连接 sequencer 的 `seq_item_export`，用于取一笔激励并确认完成。
- monitor 的 analysis port 连接 scoreboard 的接收端，用于发送观察记录。

analysis 通路只传递观察结果，不控制 PE 的引脚。

### objection：告诉 UVM 测试还在进行

测试启动 sequence 前调用 `raise_objection()`，sequence 完成后调用 `drop_objection()`。这样 UVM 才知道这段有时间推进的工作尚未结束。

driver 和 monitor 的循环会一直等待下一笔输入或下一个时钟。测试结束由 objection 控制，无需让它们主动退出循环。

## 7. 这一轮检查到什么程度

定向部分覆盖基本乘加、连续累加、负数、INT8边界、不同valid组合、clear优先级，以及计算过程中的重新复位。下面按当前 `send_cycle` 的顺序列出结果；启动时额外的一拍复位不在表内：

| 序列标签 | 输入或操作 | 期望 `acc_out` |
| --- | --- | --- |
| `reset` | reset 和 clear 同为 1，valid 为 11 | 0 |
| `first_mac` | `3 × (-4)` | -12 |
| `second_mac` | `2 × 6` | 0 |
| `hold_00` | valid 为 00 | 0 |
| `hold_10` | valid 为 10 | 0 |
| `hold_01` | valid 为 01 | 0 |
| `clear` | clear 为 1，输入为 `9 × 9` 且 valid 为 11 | 0 |
| `negative_pair` | `(-2) × (-3)` | 6 |
| `min_times_neg` | `(-128) × (-1)` | 134 |
| `max_pair` | `127 × 127` | 16263 |
| `min_times_max` | `(-128) × 127` | 7 |
| `zero` | `0 × (-128)` | 7 |
| `reset_again` | reset 为 1，valid 为 11 | 0 |
| `restart` | `4 × (-5)` | -20 |
| `idle` | valid 为 00 | -20 |
| `clear_before_random` | clear 为1 | 0 |
| `random_mac` × 10 | a、b各为-8～7，valid分别随机 | scoreboard逐拍计算 |

scoreboard 用独立的有符号整数变量保存期望累加值，并核对：

```text
acc_out
 a_out、b_out
 a_valid_out、b_valid_out
```

比较使用四态检查，因此实际输出出现 X 或 Z 也会报错。结束时还会核对实际观察周期数，防止最后一笔没有检查就提前结束。

这些用例足以练习UVM的基本结构，但不代表已经穷尽所有PE行为。当前10笔随机输入只覆盖很小的数值范围，没有做长时间随机测试、32位累加溢出专项测试、其他位宽配置或功能覆盖率收集。

## 8. 第一个练习：先预测，再改一笔输入

你已经把第二笔从 `2×5` 改成了 `2×6`，当前代码如下。先保持这笔输入，核对日志中的结果：

```systemverilog
send_cycle("second_mac", 0, 0, 2, 6, 1, 1); // -12 + 2*6 = 0
```

`send_cycle` 的参数依次是：标签、reset、clear、a、b、a_valid、b_valid。标签只方便人读日志，不参与 PE 的计算。

先写下预测，再看日志：

```text
第一笔：0 + 3 × (-4) = -12
第二笔：-12 + 2 × 6 = 0
```

重新运行 `make uvm-pe`，在日志或波形中确认第二笔之后 `acc_out=0`。scoreboard 应当自动算出新的期望值，你不需要手动修改它。

然后只把 `second_mac` 的一个valid改成0，预测累加器是否仍会变成0。查看该笔日志后恢复valid，保留已有的 `2×6` 和随机练习。

熟悉之后，可以再添加一笔输入；序列发包计数和测试结束时的观察计数应当相应增加。请先确认这一笔在哪里被计数，再添加它。

## 9. 后续按这个顺序扩展

1. 只改 sequence：补一个自己想到的定向场景，先手算结果。
2. 引入 `rand` 和 `randomize()`：随机产生输入，继续复用现有 driver、monitor 和 scoreboard。
3. 加功能覆盖率：统计 valid 组合、正负数、clear 和 reset 等场景是否实际发生。
4. 学 clocking block：把接口的驱动和采样规则整理清楚。
5. 再考虑验证 `gemm_array`：复用已经理解的组件职责，扩展参考模型和接口。

当前这一阶段，只要能讲清楚“一笔输入如何从 sequence 到 PE，再到 scoreboard”，就已经抓住了这套 UVM 框架的主线。

## 10. 在现有环境里新增自己的测试

第二个可运行示例在 `sim/uvm/pe/pe_user_test.svh`，保留原smoke练习，复用原driver、monitor和scoreboard。

```bash
make uvm-pe UVM_TEST=pe_clear_priority_test CONFIG=clear-priority
```

这次只看两处：

| 位置 | 你写什么 |
| --- | --- |
| `pe_clear_priority_sequence::body()` | 哪些输入按什么顺序出现 |
| `pe_clear_priority_test::run_phase()` | 创建哪个sequence，在哪个sequencer上启动 |

四笔输入依次为：reset；3×4使acc=12；clear与7×8同时有效使acc=0；恢复2×3使acc=6。加上启动复位，最终应检查5个周期。clear这一拍还会核对a/b与valid继续转发。

`send_cycle()`由原sequence继承，负责创建item、填写字段、发送并等待完成。test沿用继承的 `seq` 句柄，因此原来的发包/观察数量检查仍然有效。派生的body替换原场景；派生run_phase启动新场景，均无需先运行原smoke场景。

`pe_pkg.sv`末尾已包含新增文件；`UVM_TEST`通过命令行选择注册的测试类。新增其他测试类时，也需要保证其定义进入编译，并使用对应注册宏。

在检查器已经支持的功能范围内，先练习修改sequence和选择test。新增功能还要补独立检查规则与功能覆盖目标；本用例不自动生成覆盖率。
