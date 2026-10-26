# 模块逐端口接口索引

本索引以当前 `sim/filelists/rtl.f` 为准，覆盖顶层与全部功能子模块。职责、连接关系、数据布局和握手说明见[架构说明](architecture.md)。下表直接来自 RTL 声明；方括号保留参数表达式，`signed` 表示有符号数，数组维度写在单独一列。未标宽度的标量为 1 位。

时序接口采用 `clk` 上升沿；模块有 `reset` 时为高电平同步复位。只有 `valid && ready` 或约定的请求/接受条件成立才发生传输。AXI 地址单位为字节，本地 SRAM 地址是词或行索引；参数名相同但局部含义不同的情况以对应模块表为准。

## npu_top

源码：[rtl/npu_top.sv](../rtl/npu_top.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DESC_COUNT_WIDTH` | `int unsigned` | `16` |
| `TILE_COUNT_WIDTH` | `int unsigned` | `16` |
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `DATA_WIDTH` | `int unsigned` | `8` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `MEM_WORD_WIDTH` | `int unsigned` | `32` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `K_TILE_SIZE` | `int unsigned` | `256` |
| `A_BUFFER_COUNT` | `int unsigned` | `2` |
| `B_BUFFER_COUNT` | `int unsigned` | `2` |
| `PSUM_SLOT_COUNT` | `int unsigned` | `4` |
| `A_REUSE_BLOCK_SIZE` | `int unsigned` | `4` |
| `CONV_MAX_REQUEST_BEATS` | `int unsigned` | `64` |
| `POOL_LINE_WORDS` | `int unsigned` | `1024` |
| `POOL_OUTPUT_FIFO_DEPTH` | `int unsigned` | `16` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `desc_base` | 输入 | `[63:0]` | — |
| `desc_count` | 输入 | `[DESC_COUNT_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `acc_out` | 输出 | `signed [ACC_WIDTH-1:0]` | `[ROWS][COLS]` |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[63:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |
| `m_axi_wstrb` | 输出 | `[(MEM_WORD_WIDTH/8)-1:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |
| `perf_total_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_executor_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_pool_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_ar_transactions（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_r_beats（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_aw_transactions（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_w_beats（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_written_bytes（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_ar_stall_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_r_wait_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_aw_stall_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_w_stall_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_b_wait_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_layer_done_pulse（可选性能口）` | 输出 | `1 位` | — |
| `perf_completed_layer_index（可选性能口）` | 输出 | `[31:0]` | — |
| `perf_completed_layer_opcode（可选性能口）` | 输出 | `[7:0]` | — |
| `perf_completed_layer_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_executor_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_pool_cycles（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_ar（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_r_beats（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_aw（可选性能口）` | 输出 | `[63:0]` | — |
| `perf_completed_layer_w_beats（可选性能口）` | 输出 | `[63:0]` | — |

## gemm_tile_order

源码：[rtl/control/gemm_tile_order.sv](../rtl/control/gemm_tile_order.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `TILE_COUNT_WIDTH` | `int unsigned` | `16` |
| `ENABLE_A_REUSE` | `bit` | `1'b1` |
| `ENABLE_MULTI_K_A_REUSE` | `bit` | `1'b0` |
| `A_REUSE_BLOCK_SIZE` | `int unsigned` | `4` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `enable_multi_k_a_reuse` | 输入 | `1 位` | — |
| `enable_b_stationary` | 输入 | `1 位` | — |
| `enable_pool_channel_tiling` | 输入 | `1 位` | — |
| `m_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `n_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `k_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `cursor_m` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `cursor_n` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `cursor_k` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `next_m` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `next_n` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `next_k` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `next_valid` | 输出 | `1 位` | — |
| `resident_a_valid` | 输入 | `1 位` | — |
| `resident_a_m` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `resident_a_k` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `reuse_a` | 输出 | `1 位` | — |
| `allow_new_a_load` | 输出 | `1 位` | — |
| `compute_n` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `release_a` | 输出 | `1 位` | — |
| `a_reuse_enabled` | 输出 | `1 位` | — |

## gemm_tile_scheduler

源码：[rtl/control/gemm_tile_scheduler.sv](../rtl/control/gemm_tile_scheduler.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `TILE_COUNT_WIDTH` | `int unsigned` | `16` |
| `K_TILE_SIZE` | `int unsigned` | `256` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_TILE_SIZE + 1)` |
| `ENABLE_MULTI_K_A_REUSE` | `bit` | `1'b0` |
| `A_REUSE_BLOCK_SIZE` | `int unsigned` | `4` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `enable_multi_k_a_reuse` | 输入 | `1 位` | — |
| `enable_b_stationary` | 输入 | `1 位` | — |
| `enable_pool_channel_tiling` | 输入 | `1 位` | — |
| `m_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `n_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `k_tile_count` | 输入 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `last_k_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `a_load_req` | 输出 | `1 位` | — |
| `a_load_accept` | 输入 | `1 位` | — |
| `a_load_done` | 输入 | `1 位` | — |
| `b_load_req` | 输出 | `1 位` | — |
| `b_load_accept` | 输入 | `1 位` | — |
| `b_load_done` | 输入 | `1 位` | — |
| `load_m_tile_idx` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `load_n_tile_idx` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `load_k_tile_idx` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `load_k_size` | 输出 | `[K_SIZE_WIDTH-1:0]` | — |
| `a_compute_req` | 输出 | `1 位` | — |
| `a_compute_grant` | 输入 | `1 位` | — |
| `a_compute_done` | 输出 | `1 位` | — |
| `a_release_bank` | 输出 | `1 位` | — |
| `b_compute_req` | 输出 | `1 位` | — |
| `b_compute_grant` | 输入 | `1 位` | — |
| `b_compute_done` | 输出 | `1 位` | — |
| `b_release_bank` | 输出 | `1 位` | — |
| `matrix_start` | 输出 | `1 位` | — |
| `matrix_done` | 输入 | `1 位` | — |
| `writeback_done` | 输入 | `1 位` | — |
| `clear_acc` | 输出 | `1 位` | — |
| `writeback_en` | 输出 | `1 位` | — |
| `compute_k_size` | 输出 | `[K_SIZE_WIDTH-1:0]` | — |
| `compute_m_tile_idx` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `compute_n_tile_idx` | 输出 | `[TILE_COUNT_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |

## npu_command_reader

源码：[rtl/control/npu_command_reader.sv](../rtl/control/npu_command_reader.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `DESC_COUNT_WIDTH` | `int unsigned` | `16` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `desc_base` | 输入 | `[63:0]` | — |
| `desc_count` | 输入 | `[DESC_COUNT_WIDTH-1:0]` | — |
| `mem_read_req` | 输出 | `1 位` | — |
| `mem_read_addr` | 输出 | `[63:0]` | — |
| `mem_read_ready` | 输入 | `1 位` | — |
| `mem_read_valid` | 输入 | `1 位` | — |
| `mem_read_data` | 输入 | `[31:0]` | — |
| `cmd_valid` | 输出 | `1 位` | — |
| `cmd_ready` | 输入 | `1 位` | — |
| `cmd_opcode` | 输出 | `[7:0]` | — |
| `cmd_flags` | 输出 | `[23:0]` | — |
| `cfg_m` | 输出 | `[31:0]` | — |
| `cfg_n` | 输出 | `[31:0]` | — |
| `cfg_k` | 输出 | `[31:0]` | — |
| `cfg_a_base` | 输出 | `[63:0]` | — |
| `cfg_b_base` | 输出 | `[63:0]` | — |
| `cfg_c_base` | 输出 | `[63:0]` | — |
| `cfg_a_stride` | 输出 | `[31:0]` | — |
| `cfg_b_stride` | 输出 | `[31:0]` | — |
| `cfg_c_stride` | 输出 | `[31:0]` | — |
| `cfg_param0` | 输出 | `[31:0]` | — |
| `cfg_param1` | 输出 | `[31:0]` | — |
| `cfg_pool_config` | 输出 | `[31:0]` | — |
| `exec_done` | 输入 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |

## npu_gemm_engine

源码：[rtl/control/npu_gemm_engine.sv](../rtl/control/npu_gemm_engine.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `TILE_COUNT_WIDTH` | `int unsigned` | `16` |
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `DATA_WIDTH` | `int unsigned` | `8` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `MEM_WORD_WIDTH` | `int unsigned` | `32` |
| `OPERAND_WORD_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `K_TILE_SIZE` | `int unsigned` | `256` |
| `A_BUFFER_COUNT` | `int unsigned` | `2` |
| `B_BUFFER_COUNT` | `int unsigned` | `2` |
| `PSUM_SLOT_COUNT` | `int unsigned` | `4` |
| `A_REUSE_BLOCK_SIZE` | `int unsigned` | `4` |
| `CONV_MAX_REQUEST_BEATS` | `int unsigned` | `64` |
| `POOL_LINE_WORDS` | `int unsigned` | `1024` |
| `POOL_OUTPUT_FIFO_DEPTH` | `int unsigned` | `16` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_TILE_SIZE + 1)` |
| `CORE_ADDR_WIDTH` | `int unsigned` | `((K_TILE_SIZE > ROWS ? K_TILE_SIZE : ROWS) <= 1) ? 1 : $clog2(K_TILE_SIZE > ROWS ? K_TILE_SIZE : ROWS)` |
| `ELEMS_PER_WORD` | `int unsigned` | `OPERAND_WORD_WIDTH / DATA_WIDTH` |
| `WORD_DEPTH` | `int unsigned` | `(K_TILE_SIZE + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `A_LANE_WIDTH` | `int unsigned` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |
| `B_LANE_WIDTH` | `int unsigned` | `(COLS <= 1) ? 1 : $clog2(COLS)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `cmd_valid` | 输入 | `1 位` | — |
| `cmd_ready` | 输出 | `1 位` | — |
| `cmd_m` | 输入 | `[31:0]` | — |
| `cmd_n` | 输入 | `[31:0]` | — |
| `cmd_k` | 输入 | `[31:0]` | — |
| `cmd_a_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_b_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_c_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_a_stride_bytes` | 输入 | `[31:0]` | — |
| `cmd_b_stride_bytes` | 输入 | `[31:0]` | — |
| `cmd_c_stride_bytes` | 输入 | `[31:0]` | — |
| `cmd_conv_mode` | 输入 | `1 位` | — |
| `cmd_conv_input_h` | 输入 | `[31:0]` | — |
| `cmd_conv_input_w` | 输入 | `[31:0]` | — |
| `cmd_conv_input_c` | 输入 | `[31:0]` | — |
| `cmd_conv_kernel_h` | 输入 | `[31:0]` | — |
| `cmd_conv_kernel_w` | 输入 | `[31:0]` | — |
| `cmd_conv_stride_h` | 输入 | `[31:0]` | — |
| `cmd_conv_stride_w` | 输入 | `[31:0]` | — |
| `cmd_conv_pad_top` | 输入 | `[31:0]` | — |
| `cmd_conv_pad_left` | 输入 | `[31:0]` | — |
| `cmd_conv_output_w` | 输入 | `[31:0]` | — |
| `cmd_conv_output_positions` | 输入 | `[31:0]` | — |
| `cmd_bias_en` | 输入 | `1 位` | — |
| `cmd_requant_en` | 输入 | `1 位` | — |
| `cmd_relu_en` | 输入 | `1 位` | — |
| `cmd_per_channel_en` | 输入 | `1 位` | — |
| `cmd_multi_k_a_reuse` | 输入 | `1 位` | — |
| `cmd_b_stationary` | 输入 | `1 位` | — |
| `cmd_fuse_maxpool` | 输入 | `1 位` | — |
| `cmd_pool_config` | 输入 | `[31:0]` | — |
| `cmd_param_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `acc_out` | 输出 | `signed [ACC_WIDTH-1:0]` | `[ROWS][COLS]` |
| `operand64_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `operand64_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `operand64_arlen` | 输出 | `[7:0]` | — |
| `operand64_arsize` | 输出 | `[2:0]` | — |
| `operand64_arburst` | 输出 | `[1:0]` | — |
| `operand64_arvalid` | 输出 | `1 位` | — |
| `operand64_arready` | 输入 | `1 位` | — |
| `operand64_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `operand64_rdata` | 输入 | `[63:0]` | — |
| `operand64_rresp` | 输入 | `[1:0]` | — |
| `operand64_rlast` | 输入 | `1 位` | — |
| `operand64_rvalid` | 输入 | `1 位` | — |
| `operand64_rready` | 输出 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |
| `m_axi_wstrb` | 输出 | `[(MEM_WORD_WIDTH/8)-1:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## npu_perf_counters

源码：[rtl/control/npu_perf_counters.sv](../rtl/control/npu_perf_counters.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `DATA_WIDTH` | `int unsigned` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `run_start` | 输入 | `1 位` | — |
| `run_done` | 输入 | `1 位` | — |
| `layer_start` | 输入 | `1 位` | — |
| `layer_done` | 输入 | `1 位` | — |
| `layer_opcode` | 输入 | `[7:0]` | — |
| `executor_busy` | 输入 | `1 位` | — |
| `pool_busy` | 输入 | `1 位` | — |
| `arvalid` | 输入 | `1 位` | — |
| `arready` | 输入 | `1 位` | — |
| `rvalid` | 输入 | `1 位` | — |
| `rready` | 输入 | `1 位` | — |
| `rlast` | 输入 | `1 位` | — |
| `awvalid` | 输入 | `1 位` | — |
| `awready` | 输入 | `1 位` | — |
| `wvalid` | 输入 | `1 位` | — |
| `wready` | 输入 | `1 位` | — |
| `wstrb` | 输入 | `[(DATA_WIDTH/8)-1:0]` | — |
| `wlast` | 输入 | `1 位` | — |
| `bvalid` | 输入 | `1 位` | — |
| `bready` | 输入 | `1 位` | — |
| `total_cycles` | 输出 | `[63:0]` | — |
| `executor_cycles` | 输出 | `[63:0]` | — |
| `pool_cycles` | 输出 | `[63:0]` | — |
| `ar_transactions` | 输出 | `[63:0]` | — |
| `r_beats` | 输出 | `[63:0]` | — |
| `aw_transactions` | 输出 | `[63:0]` | — |
| `w_beats` | 输出 | `[63:0]` | — |
| `written_bytes` | 输出 | `[63:0]` | — |
| `ar_stall_cycles` | 输出 | `[63:0]` | — |
| `r_wait_cycles` | 输出 | `[63:0]` | — |
| `aw_stall_cycles` | 输出 | `[63:0]` | — |
| `w_stall_cycles` | 输出 | `[63:0]` | — |
| `b_wait_cycles` | 输出 | `[63:0]` | — |
| `layer_done_pulse` | 输出 | `1 位` | — |
| `completed_layer_index` | 输出 | `[31:0]` | — |
| `completed_layer_opcode` | 输出 | `[7:0]` | — |
| `completed_layer_cycles` | 输出 | `[63:0]` | — |
| `completed_layer_executor_cycles` | 输出 | `[63:0]` | — |
| `completed_layer_pool_cycles` | 输出 | `[63:0]` | — |
| `completed_layer_ar` | 输出 | `[63:0]` | — |
| `completed_layer_r_beats` | 输出 | `[63:0]` | — |
| `completed_layer_aw` | 输出 | `[63:0]` | — |
| `completed_layer_w_beats` | 输出 | `[63:0]` | — |

## gemm_array

源码：[rtl/compute/gemm_array.sv](../rtl/compute/gemm_array.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int` | `4` |
| `COLS` | `int` | `4` |
| `DATA_WIDTH` | `int` | `8` |
| `ACC_WIDTH` | `int` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `clear` | 输入 | `1 位` | — |
| `a_in` | 输入 | `signed [DATA_WIDTH-1:0]` | `[ROWS]` |
| `a_valid_in` | 输入 | `1 位` | `[ROWS]` |
| `b_in` | 输入 | `signed [DATA_WIDTH-1:0]` | `[COLS]` |
| `b_valid_in` | 输入 | `1 位` | `[COLS]` |
| `acc_out` | 输出 | `signed [ACC_WIDTH-1:0]` | `[ROWS][COLS]` |

## gemm_cycle_controller

源码：[rtl/compute/gemm_cycle_controller.sv](../rtl/compute/gemm_cycle_controller.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int` | `4` |
| `COLS` | `int` | `4` |
| `DEPTH` | `int` | `256` |
| `ADDR_WIDTH` | `int` | `(DEPTH <= 1) ? 1 : $clog2(DEPTH)` |
| `K_SIZE_WIDTH` | `int` | `$clog2(DEPTH + 1)` |
| `ROW_INDEX_WIDTH` | `int` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `tile_k_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `clear_acc` | 输入 | `1 位` | — |
| `writeback_en` | 输入 | `1 位` | — |
| `clear` | 输出 | `1 位` | — |
| `read_en` | 输出 | `1 位` | — |
| `read_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `feed_valid` | 输出 | `1 位` | — |
| `c_wen` | 输出 | `1 位` | — |
| `c_row` | 输出 | `[ROW_INDEX_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |

## gemm_pe

源码：[rtl/compute/gemm_pe.sv](../rtl/compute/gemm_pe.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `DATA_WIDTH` | `int` | `8` |
| `ACC_WIDTH` | `int` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `clear` | 输入 | `1 位` | — |
| `a_in` | 输入 | `signed [DATA_WIDTH-1:0]` | — |
| `b_in` | 输入 | `signed [DATA_WIDTH-1:0]` | — |
| `a_valid_in` | 输入 | `1 位` | — |
| `b_valid_in` | 输入 | `1 位` | — |
| `a_out` | 输出 | `signed [DATA_WIDTH-1:0]` | — |
| `b_out` | 输出 | `signed [DATA_WIDTH-1:0]` | — |
| `a_valid_out` | 输出 | `1 位` | — |
| `b_valid_out` | 输出 | `1 位` | — |
| `acc_out` | 输出 | `signed [ACC_WIDTH-1:0]` | — |

## gemm_postprocess

源码：[rtl/compute/gemm_postprocess.sv](../rtl/compute/gemm_postprocess.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `LANES` | `int unsigned` | `4` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `OUT_WIDTH` | `int unsigned` | `8` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `bias_en` | 输入 | `1 位` | — |
| `requant_en` | 输入 | `1 位` | — |
| `relu_en` | 输入 | `1 位` | — |
| `data_in` | 输入 | `signed [ACC_WIDTH-1:0]` | `[LANES]` |
| `bias` | 输入 | `signed [ACC_WIDTH-1:0]` | `[LANES]` |
| `multiplier` | 输入 | `[31:0]` | `[LANES]` |
| `shift` | 输入 | `[5:0]` | `[LANES]` |
| `output_zero_point` | 输入 | `signed [OUT_WIDTH-1:0]` | — |
| `data_out_int32` | 输出 | `signed [ACC_WIDTH-1:0]` | `[LANES]` |
| `data_out_int8` | 输出 | `signed [OUT_WIDTH-1:0]` | `[LANES]` |

## gemm_psum_accumulator

源码：[rtl/compute/gemm_psum_accumulator.sv](../rtl/compute/gemm_psum_accumulator.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `PSUM_SLOTS` | `int unsigned` | `4` |
| `SLOT_WIDTH` | `int unsigned` | `(PSUM_SLOTS <= 1) ? 1 : $clog2(PSUM_SLOTS)` |
| `ROW_WIDTH` | `int unsigned` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |
| `DATA_WIDTH` | `int unsigned` | `COLS * ACC_WIDTH` |
| `TILE_WIDTH` | `int unsigned` | `ROWS * DATA_WIDTH` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `first_k` | 输入 | `1 位` | — |
| `slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `pe_tile` | 输入 | `[TILE_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `sram_rd_en` | 输出 | `1 位` | — |
| `sram_rd_slot` | 输出 | `[SLOT_WIDTH-1:0]` | — |
| `sram_rd_row` | 输出 | `[ROW_WIDTH-1:0]` | — |
| `sram_rd_valid` | 输入 | `1 位` | — |
| `sram_rd_data` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `sram_wr_en` | 输出 | `1 位` | — |
| `sram_wr_slot` | 输出 | `[SLOT_WIDTH-1:0]` | — |
| `sram_wr_row` | 输出 | `[ROW_WIDTH-1:0]` | — |
| `sram_wr_data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `alu_use_psum` | 输出 | `1 位` | — |
| `alu_a` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `alu_b` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `alu_sum` | 输入 | `[DATA_WIDTH-1:0]` | — |

## gemm_tile_compute

源码：[rtl/compute/gemm_tile_compute.sv](../rtl/compute/gemm_tile_compute.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int` | `4` |
| `COLS` | `int` | `4` |
| `DATA_WIDTH` | `int` | `8` |
| `ACC_WIDTH` | `int` | `32` |
| `A_BUFFER_COUNT` | `int` | `1` |
| `B_BUFFER_COUNT` | `int` | `1` |
| `DEPTH` | `int` | `256` |
| `ADDR_WIDTH` | `int` | `((DEPTH > ROWS ? DEPTH : ROWS) <= 1) ? 1 : $clog2(DEPTH > ROWS ? DEPTH : ROWS)` |
| `K_SIZE_WIDTH` | `int` | `$clog2(DEPTH + 1)` |
| `MEM_WORD_WIDTH` | `int` | `32` |
| `ELEMS_PER_WORD` | `int` | `MEM_WORD_WIDTH / DATA_WIDTH` |
| `WORD_DEPTH` | `int` | `(DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `A_LANE_WIDTH` | `int` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |
| `B_LANE_WIDTH` | `int` | `(COLS <= 1) ? 1 : $clog2(COLS)` |
| `ROW_INDEX_WIDTH` | `int` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `tile_k_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `clear_acc` | 输入 | `1 位` | — |
| `writeback_en` | 输入 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `c_base_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `a_wen` | 输入 | `1 位` | — |
| `a_wlane` | 输入 | `[A_LANE_WIDTH-1:0]` | — |
| `a_waddr` | 输入 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `a_wdata` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `a_wbank` | 输入 | `1 位` | — |
| `a_rbank` | 输入 | `1 位` | — |
| `b_wen` | 输入 | `1 位` | — |
| `b_wlane` | 输入 | `[B_LANE_WIDTH-1:0]` | — |
| `b_waddr` | 输入 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `b_wdata` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `b_wbank` | 输入 | `1 位` | — |
| `b_rbank` | 输入 | `1 位` | — |
| `c_ren` | 输入 | `1 位` | — |
| `c_raddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `c_rdata` | 输出 | `[COLS*ACC_WIDTH-1:0]` | — |
| `acc_out` | 输出 | `signed [ACC_WIDTH-1:0]` | `[ROWS][COLS]` |

## npu_add_engine

源码：[rtl/compute/npu_add_engine.sv](../rtl/compute/npu_add_engine.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `cmd_valid` | 输入 | `1 位` | — |
| `cmd_ready` | 输出 | `1 位` | — |
| `cmd_a_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_b_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_c_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_param_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_elements` | 输入 | `[31:0]` | — |
| `cmd_relu` | 输入 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[31:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[31:0]` | — |
| `m_axi_wstrb` | 输出 | `[3:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## npu_pool_engine

源码：[rtl/compute/npu_pool_engine.sv](../rtl/compute/npu_pool_engine.sv)

独立最大池化支持四侧补边，`cmd_pool_padding={right,bottom,left,top}`，每侧8位且小于对应窗口；越界位置不发起读取，也不参与有符号最大值比较。补边全零兼容原路径。全局平均池化要求该字段为0。

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `cmd_valid` | 输入 | `1 位` | — |
| `cmd_ready` | 输出 | `1 位` | — |
| `cmd_global_avg` | 输入 | `1 位` | — |
| `cmd_input_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_output_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `cmd_input_h` | 输入 | `[31:0]` | — |
| `cmd_input_w` | 输入 | `[31:0]` | — |
| `cmd_channels` | 输入 | `[31:0]` | — |
| `cmd_pool_config` | 输入 | `[31:0]` | — |
| `cmd_pool_padding` | 输入 | `[31:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[31:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[31:0]` | — |
| `m_axi_wstrb` | 输出 | `[3:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## axi_read_master

源码：[rtl/dma/axi_read_master.sv](../rtl/dma/axi_read_master.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DATA_WIDTH` | `int unsigned` | `32` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `req_valid` | 输入 | `1 位` | — |
| `req_ready` | 输出 | `1 位` | — |
| `req_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `req_beats` | 输入 | `[31:0]` | — |
| `data_valid` | 输出 | `1 位` | — |
| `data_ready` | 输入 | `1 位` | — |
| `data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `data_last` | 输出 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |

## axi_read_mux

源码：[rtl/dma/axi_read_mux.sv](../rtl/dma/axi_read_mux.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DATA_WIDTH` | `int unsigned` | `32` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `desc_arid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `desc_araddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `desc_arlen` | 输入 | `[7:0]` | — |
| `desc_arsize` | 输入 | `[2:0]` | — |
| `desc_arburst` | 输入 | `[1:0]` | — |
| `desc_arvalid` | 输入 | `1 位` | — |
| `desc_arready` | 输出 | `1 位` | — |
| `desc_rid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `desc_rdata` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `desc_rresp` | 输出 | `[1:0]` | — |
| `desc_rlast` | 输出 | `1 位` | — |
| `desc_rvalid` | 输出 | `1 位` | — |
| `desc_rready` | 输入 | `1 位` | — |
| `gemm_arid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `gemm_araddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `gemm_arlen` | 输入 | `[7:0]` | — |
| `gemm_arsize` | 输入 | `[2:0]` | — |
| `gemm_arburst` | 输入 | `[1:0]` | — |
| `gemm_arvalid` | 输入 | `1 位` | — |
| `gemm_arready` | 输出 | `1 位` | — |
| `gemm_rid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `gemm_rdata` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `gemm_rresp` | 输出 | `[1:0]` | — |
| `gemm_rlast` | 输出 | `1 位` | — |
| `gemm_rvalid` | 输出 | `1 位` | — |
| `gemm_rready` | 输入 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |

## axi_read_width_adapter

源码：[rtl/dma/axi_read_width_adapter.sv](../rtl/dma/axi_read_width_adapter.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `s_arid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `s_araddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `s_arlen` | 输入 | `[7:0]` | — |
| `s_arsize` | 输入 | `[2:0]` | — |
| `s_arburst` | 输入 | `[1:0]` | — |
| `s_arvalid` | 输入 | `1 位` | — |
| `s_arready` | 输出 | `1 位` | — |
| `s_rid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `s_rdata` | 输出 | `[31:0]` | — |
| `s_rresp` | 输出 | `[1:0]` | — |
| `s_rlast` | 输出 | `1 位` | — |
| `s_rvalid` | 输出 | `1 位` | — |
| `s_rready` | 输入 | `1 位` | — |
| `m_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_arlen` | 输出 | `[7:0]` | — |
| `m_arsize` | 输出 | `[2:0]` | — |
| `m_arburst` | 输出 | `[1:0]` | — |
| `m_arvalid` | 输出 | `1 位` | — |
| `m_arready` | 输入 | `1 位` | — |
| `m_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_rdata` | 输入 | `[63:0]` | — |
| `m_rresp` | 输入 | `[1:0]` | — |
| `m_rlast` | 输入 | `1 位` | — |
| `m_rvalid` | 输入 | `1 位` | — |
| `m_rready` | 输出 | `1 位` | — |

## axi_write_master

源码：[rtl/dma/axi_write_master.sv](../rtl/dma/axi_write_master.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DATA_WIDTH` | `int unsigned` | `32` |
| `ID_WIDTH` | `int unsigned` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `req_valid` | 输入 | `1 位` | — |
| `req_ready` | 输出 | `1 位` | — |
| `req_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `req_beats` | 输入 | `[31:0]` | — |
| `data_valid` | 输入 | `1 位` | — |
| `data_ready` | 输出 | `1 位` | — |
| `data` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `m_axi_wstrb` | 输出 | `[(DATA_WIDTH/8)-1:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## conv_patch_reader

源码：[rtl/dma/conv_patch_reader.sv](../rtl/dma/conv_patch_reader.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ROWS` | `int unsigned` | `4` |
| `K_DEPTH` | `int unsigned` | `256` |
| `MEM_WORD_WIDTH` | `int unsigned` | `64` |
| `BUFFER_COUNT` | `int unsigned` | `2` |
| `MAX_REQUEST_BEATS` | `int unsigned` | `64` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_DEPTH + 1)` |
| `WORD_DEPTH` | `int unsigned` | `(K_DEPTH + MEM_WORD_WIDTH/8 - 1) / (MEM_WORD_WIDTH/8)` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `LANE_WIDTH` | `int unsigned` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |
| `BANK_WIDTH` | `int unsigned` | `(BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `load_req` | 输入 | `1 位` | — |
| `load_accept` | 输出 | `1 位` | — |
| `input_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `input_h` | 输入 | `[31:0]` | — |
| `input_w` | 输入 | `[31:0]` | — |
| `input_c` | 输入 | `[31:0]` | — |
| `kernel_h` | 输入 | `[31:0]` | — |
| `kernel_w` | 输入 | `[31:0]` | — |
| `stride_h` | 输入 | `[31:0]` | — |
| `stride_w` | 输入 | `[31:0]` | — |
| `pad_top` | 输入 | `[31:0]` | — |
| `pad_left` | 输入 | `[31:0]` | — |
| `pad_zero_point` | 输入 | `signed [7:0]` | — |
| `output_w` | 输入 | `[31:0]` | — |
| `output_positions` | 输入 | `[31:0]` | — |
| `m_start` | 输入 | `[31:0]` | — |
| `k_start` | 输入 | `[31:0]` | — |
| `load_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `load_done` | 输出 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `bank_load_req` | 输出 | `1 位` | — |
| `bank_load_grant` | 输入 | `1 位` | — |
| `bank_load_bank` | 输入 | `[BANK_WIDTH-1:0]` | — |
| `bank_load_done` | 输出 | `1 位` | — |
| `rd_req_valid` | 输出 | `1 位` | — |
| `rd_req_ready` | 输入 | `1 位` | — |
| `rd_req_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `rd_req_beats` | 输出 | `[31:0]` | — |
| `rd_data_valid` | 输入 | `1 位` | — |
| `rd_data_ready` | 输出 | `1 位` | — |
| `rd_data` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `rd_data_last` | 输入 | `1 位` | — |
| `rd_done` | 输入 | `1 位` | — |
| `rd_error` | 输入 | `1 位` | — |
| `buffer_wen` | 输出 | `1 位` | — |
| `buffer_wbank` | 输出 | `[BANK_WIDTH-1:0]` | — |
| `buffer_wlane` | 输出 | `[LANE_WIDTH-1:0]` | — |
| `buffer_waddr` | 输出 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `buffer_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |

## matrix_operand_reader

源码：[rtl/dma/matrix_operand_reader.sv](../rtl/dma/matrix_operand_reader.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ELEM_WIDTH` | `int unsigned` | `8` |
| `LANE_COUNT` | `int unsigned` | `4` |
| `MEM_WORD_WIDTH` | `int unsigned` | `32` |
| `K_DEPTH` | `int unsigned` | `256` |
| `BUFFER_COUNT` | `int unsigned` | `2` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_DEPTH + 1)` |
| `ELEMS_PER_WORD` | `int unsigned` | `MEM_WORD_WIDTH / ELEM_WIDTH` |
| `WORD_DEPTH` | `int unsigned` | `(K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `LANE_WIDTH` | `int unsigned` | `(LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT)` |
| `BANK_WIDTH` | `int unsigned` | `(BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `load_req` | 输入 | `1 位` | — |
| `load_accept` | 输出 | `1 位` | — |
| `base_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `stride_bytes` | 输入 | `[31:0]` | — |
| `load_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `valid_lanes` | 输入 | `[31:0]` | — |
| `load_done` | 输出 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `bank_load_req` | 输出 | `1 位` | — |
| `bank_load_grant` | 输入 | `1 位` | — |
| `bank_load_bank` | 输入 | `[BANK_WIDTH-1:0]` | — |
| `bank_load_done` | 输出 | `1 位` | — |
| `rd_req_valid` | 输出 | `1 位` | — |
| `rd_req_ready` | 输入 | `1 位` | — |
| `rd_req_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `rd_req_beats` | 输出 | `[31:0]` | — |
| `rd_data_valid` | 输入 | `1 位` | — |
| `rd_data_ready` | 输出 | `1 位` | — |
| `rd_data` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `rd_data_last` | 输入 | `1 位` | — |
| `rd_done` | 输入 | `1 位` | — |
| `rd_error` | 输入 | `1 位` | — |
| `buffer_wen` | 输出 | `1 位` | — |
| `buffer_wbank` | 输出 | `[BANK_WIDTH-1:0]` | — |
| `buffer_wlane` | 输出 | `[LANE_WIDTH-1:0]` | — |
| `buffer_waddr` | 输出 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `buffer_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |

## pool_coordinate_mapper

源码：[rtl/compute/pool_coordinate_mapper.sv](../rtl/compute/pool_coordinate_mapper.sv)

卷积坐标透传；全连接第0个物理行使用 `pixel_q`、`channel_q` 输出坐标，其他补齐行不输出。复位、接受新命令时清零；`start` 锁存已校验配置的末通道起点并从零开始。仅 `fc_fire` 时按 COLS 推进通道，到末通道组后回绕并推进像素。模块不缓冲数据，反压期间坐标保持稳定。引擎在启动前检查形状，并用仿真断言检查源输出编号与累计接收数量一致。

| 参数 | 类型 | 默认值 |
|---|---|---|
| `COLS` | `int unsigned` | `4` |

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---|---|
| `clk` | 输入 | 1 | 时钟 |
| `reset` | 输入 | 1 | 高有效同步复位 |
| `clear` | 输入 | 1 | 接受新命令时清零并取消配置 |
| `start` | 输入 | 1 | `fc_pool_start`，初始化计数器并锁存配置 |
| `fc_fire` | 输入 | 1 | 真实 FC 结果被池化成功接收；一次接收完整 COLS 通道 |
| `fc_mode` | 输入 | 1 | 全连接坐标模式 |
| `source_spatial_index` | 输入 | 32 | 原结果的物理行号/卷积空间索引 |
| `source_channel_base` | 输入 | 32 | 原结果的输出神经元/通道起点 |
| `fc_channels` | 输入 | 32 | 软件声明的重排通道数，`start` 时采样，整层保持稳定 |
| `mapped_valid` | 输出 | 1 | 当前数据是否应送池化 |
| `mapped_spatial_index` | 输出 | 32 | 池化输入的空间索引 |
| `mapped_channel_base` | 输出 | 32 | 池化输入的通道起点 |
| `mapping_error` | 输出 | 1 | 真实 FC 行尚未配置或逻辑通道数非法 |

## operand_fetch

源码：[rtl/dma/operand_fetch.sv](../rtl/dma/operand_fetch.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ELEM_WIDTH` | `int unsigned` | `8` |
| `MEM_WORD_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `A_LANE_COUNT` | `int unsigned` | `4` |
| `B_LANE_COUNT` | `int unsigned` | `4` |
| `K_DEPTH` | `int unsigned` | `256` |
| `A_BUFFER_COUNT` | `int unsigned` | `2` |
| `B_BUFFER_COUNT` | `int unsigned` | `2` |
| `CONV_MAX_REQUEST_BEATS` | `int unsigned` | `64` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_DEPTH + 1)` |
| `ELEMS_PER_WORD` | `int unsigned` | `MEM_WORD_WIDTH / ELEM_WIDTH` |
| `WORD_DEPTH` | `int unsigned` | `(K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `A_LANE_WIDTH` | `int unsigned` | `(A_LANE_COUNT <= 1) ? 1 : $clog2(A_LANE_COUNT)` |
| `B_LANE_WIDTH` | `int unsigned` | `(B_LANE_COUNT <= 1) ? 1 : $clog2(B_LANE_COUNT)` |
| `A_BANK_WIDTH` | `int unsigned` | `(A_BUFFER_COUNT <= 1) ? 1 : $clog2(A_BUFFER_COUNT)` |
| `B_BANK_WIDTH` | `int unsigned` | `(B_BUFFER_COUNT <= 1) ? 1 : $clog2(B_BUFFER_COUNT)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `conv_mode` | 输入 | `1 位` | — |
| `conv_input_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `conv_input_h` | 输入 | `[31:0]` | — |
| `conv_input_w` | 输入 | `[31:0]` | — |
| `conv_input_c` | 输入 | `[31:0]` | — |
| `conv_kernel_h` | 输入 | `[31:0]` | — |
| `conv_kernel_w` | 输入 | `[31:0]` | — |
| `conv_stride_h` | 输入 | `[31:0]` | — |
| `conv_stride_w` | 输入 | `[31:0]` | — |
| `conv_pad_top` | 输入 | `[31:0]` | — |
| `conv_pad_left` | 输入 | `[31:0]` | — |
| `conv_pad_zero_point` | 输入 | `signed [7:0]` | — |
| `conv_output_w` | 输入 | `[31:0]` | — |
| `conv_output_positions` | 输入 | `[31:0]` | — |
| `conv_m_start` | 输入 | `[31:0]` | — |
| `conv_k_start` | 输入 | `[31:0]` | — |
| `a_load_req` | 输入 | `1 位` | — |
| `a_load_accept` | 输出 | `1 位` | — |
| `a_base_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `a_stride_bytes` | 输入 | `[31:0]` | — |
| `a_load_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `a_valid_lanes` | 输入 | `[31:0]` | — |
| `a_load_done` | 输出 | `1 位` | — |
| `a_load_error` | 输出 | `1 位` | — |
| `b_load_req` | 输入 | `1 位` | — |
| `b_load_accept` | 输出 | `1 位` | — |
| `b_base_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `b_stride_bytes` | 输入 | `[31:0]` | — |
| `b_load_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `b_valid_lanes` | 输入 | `[31:0]` | — |
| `b_load_done` | 输出 | `1 位` | — |
| `b_load_error` | 输出 | `1 位` | — |
| `a_bank_load_req` | 输出 | `1 位` | — |
| `a_bank_load_grant` | 输入 | `1 位` | — |
| `a_bank_load_bank` | 输入 | `[A_BANK_WIDTH-1:0]` | — |
| `a_bank_load_done` | 输出 | `1 位` | — |
| `b_bank_load_req` | 输出 | `1 位` | — |
| `b_bank_load_grant` | 输入 | `1 位` | — |
| `b_bank_load_bank` | 输入 | `[B_BANK_WIDTH-1:0]` | — |
| `b_bank_load_done` | 输出 | `1 位` | — |
| `a_wen` | 输出 | `1 位` | — |
| `a_wbank` | 输出 | `[A_BANK_WIDTH-1:0]` | — |
| `a_wlane` | 输出 | `[A_LANE_WIDTH-1:0]` | — |
| `a_waddr` | 输出 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `a_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |
| `b_wen` | 输出 | `1 位` | — |
| `b_wbank` | 输出 | `[B_BANK_WIDTH-1:0]` | — |
| `b_wlane` | 输出 | `[B_LANE_WIDTH-1:0]` | — |
| `b_waddr` | 输出 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `b_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_arid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_araddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_arlen` | 输出 | `[7:0]` | — |
| `m_axi_arsize` | 输出 | `[2:0]` | — |
| `m_axi_arburst` | 输出 | `[1:0]` | — |
| `m_axi_arvalid` | 输出 | `1 位` | — |
| `m_axi_arready` | 输入 | `1 位` | — |
| `m_axi_rid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_rdata` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `m_axi_rresp` | 输入 | `[1:0]` | — |
| `m_axi_rlast` | 输入 | `1 位` | — |
| `m_axi_rvalid` | 输入 | `1 位` | — |
| `m_axi_rready` | 输出 | `1 位` | — |

## operand_request_arbiter

源码：[rtl/dma/operand_request_arbiter.sv](../rtl/dma/operand_request_arbiter.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DATA_WIDTH` | `int unsigned` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `m0_req_valid` | 输入 | `1 位` | — |
| `m0_req_ready` | 输出 | `1 位` | — |
| `m0_req_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `m0_req_beats` | 输入 | `[31:0]` | — |
| `m0_data_valid` | 输出 | `1 位` | — |
| `m0_data_ready` | 输入 | `1 位` | — |
| `m0_data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `m0_data_last` | 输出 | `1 位` | — |
| `m0_done` | 输出 | `1 位` | — |
| `m0_error` | 输出 | `1 位` | — |
| `m1_req_valid` | 输入 | `1 位` | — |
| `m1_req_ready` | 输出 | `1 位` | — |
| `m1_req_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `m1_req_beats` | 输入 | `[31:0]` | — |
| `m1_data_valid` | 输出 | `1 位` | — |
| `m1_data_ready` | 输入 | `1 位` | — |
| `m1_data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `m1_data_last` | 输出 | `1 位` | — |
| `m1_done` | 输出 | `1 位` | — |
| `m1_error` | 输出 | `1 位` | — |
| `s_req_valid` | 输出 | `1 位` | — |
| `s_req_ready` | 输入 | `1 位` | — |
| `s_req_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `s_req_beats` | 输出 | `[31:0]` | — |
| `s_data_valid` | 输入 | `1 位` | — |
| `s_data_ready` | 输出 | `1 位` | — |
| `s_data` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `s_data_last` | 输入 | `1 位` | — |
| `s_done` | 输入 | `1 位` | — |
| `s_error` | 输入 | `1 位` | — |

## quant_param_loader

源码：[rtl/dma/quant_param_loader.sv](../rtl/dma/quant_param_loader.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `COLS` | `int unsigned` | `4` |
| `DATA_WIDTH` | `int unsigned` | `32` |
| `BIAS_WIDTH` | `int unsigned` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `global_load_req` | 输入 | `1 位` | — |
| `global_load_accept` | 输出 | `1 位` | — |
| `global_param_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `fc_pool_en` | 输入 | `1 位` | — |
| `global_load_done` | 输出 | `1 位` | — |
| `bias_load_req` | 输入 | `1 位` | — |
| `bias_load_accept` | 输出 | `1 位` | — |
| `bias_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `per_channel_en` | 输入 | `1 位` | — |
| `bias_valid_cols` | 输入 | `[31:0]` | — |
| `bias_load_done` | 输出 | `1 位` | — |
| `multiplier_out` | 输出 | `[31:0]` | — |
| `shift_out` | 输出 | `[5:0]` | — |
| `input_zero_point_out` | 输出 | `signed [7:0]` | — |
| `output_zero_point_out` | 输出 | `signed [7:0]` | — |
| `fc_pool_h_out` | 输出 | `[31:0]` | — |
| `fc_pool_w_out` | 输出 | `[31:0]` | — |
| `fc_pool_c_out` | 输出 | `[31:0]` | — |
| `fc_pool_batch_out` | 输出 | `[31:0]` | — |
| `bias_out` | 输出 | `signed [BIAS_WIDTH-1:0]` | `[COLS]` |
| `multiplier_lane_out` | 输出 | `[31:0]` | `[COLS]` |
| `shift_lane_out` | 输出 | `[5:0]` | `[COLS]` |
| `busy` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `read_req_valid` | 输出 | `1 位` | — |
| `read_req_ready` | 输入 | `1 位` | — |
| `read_req_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `read_req_beats` | 输出 | `[31:0]` | — |
| `read_data_valid` | 输入 | `1 位` | — |
| `read_data_ready` | 输出 | `1 位` | — |
| `read_data` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `read_data_last` | 输入 | `1 位` | — |

## result_write_dma

源码：[rtl/dma/result_write_dma.sv](../rtl/dma/result_write_dma.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `AXI_DATA_WIDTH` | `int unsigned` | `32` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `C_ADDR_WIDTH` | `int unsigned` | `8` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `tile_valid` | 输入 | `1 位` | — |
| `tile_accept` | 输出 | `1 位` | — |
| `tile_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `tile_stride_bytes` | 输入 | `[31:0]` | — |
| `tile_valid_rows` | 输入 | `[31:0]` | — |
| `tile_valid_cols` | 输入 | `[31:0]` | — |
| `int8_mode` | 输入 | `1 位` | — |
| `c_ren` | 输出 | `1 位` | — |
| `c_raddr` | 输出 | `[C_ADDR_WIDTH-1:0]` | — |
| `c_rdata` | 输入 | `[COLS*ACC_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[AXI_DATA_WIDTH-1:0]` | — |
| `m_axi_wstrb` | 输出 | `[(AXI_DATA_WIDTH/8)-1:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## strided_axi_reader

源码：[rtl/dma/strided_axi_reader.sv](../rtl/dma/strided_axi_reader.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `DATA_WIDTH` | `int unsigned` | `32` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `base_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `row_count` | 输入 | `[31:0]` | — |
| `bytes_per_row` | 输入 | `[31:0]` | — |
| `stride_bytes` | 输入 | `[31:0]` | — |
| `rd_req_valid` | 输出 | `1 位` | — |
| `rd_req_ready` | 输入 | `1 位` | — |
| `rd_req_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `rd_req_beats` | 输出 | `[31:0]` | — |
| `rd_data_valid` | 输入 | `1 位` | — |
| `rd_data_ready` | 输出 | `1 位` | — |
| `rd_data` | 输入 | `[DATA_WIDTH-1:0]` | — |
| `rd_data_last` | 输入 | `1 位` | — |
| `rd_done` | 输入 | `1 位` | — |
| `rd_error` | 输入 | `1 位` | — |
| `out_valid` | 输出 | `1 位` | — |
| `out_ready` | 输入 | `1 位` | — |
| `out_data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `done` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |

## operand_bank_controller

源码：[rtl/memory/operand_bank_controller.sv](../rtl/memory/operand_bank_controller.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `BUFFER_COUNT` | `int` | `1` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `load_req` | 输入 | `1 位` | — |
| `load_grant` | 输出 | `1 位` | — |
| `load_bank` | 输出 | `1 位` | — |
| `load_done` | 输入 | `1 位` | — |
| `compute_req` | 输入 | `1 位` | — |
| `compute_grant` | 输出 | `1 位` | — |
| `compute_bank` | 输出 | `1 位` | — |
| `compute_done` | 输入 | `1 位` | — |
| `release_bank` | 输入 | `1 位` | — |

## operand_banks

源码：[rtl/memory/operand_banks.sv](../rtl/memory/operand_banks.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ELEM_WIDTH` | `int unsigned` | `8` |
| `LANE_COUNT` | `int unsigned` | `4` |
| `MEM_WORD_WIDTH` | `int unsigned` | `32` |
| `K_DEPTH` | `int unsigned` | `256` |
| `BUFFER_COUNT` | `int unsigned` | `2` |
| `K_ADDR_WIDTH` | `int unsigned` | `(K_DEPTH <= 1) ? 1 : $clog2(K_DEPTH)` |
| `ELEMS_PER_WORD` | `int unsigned` | `MEM_WORD_WIDTH / ELEM_WIDTH` |
| `WORD_DEPTH` | `int unsigned` | `(K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `LANE_SEL_WIDTH` | `int unsigned` | `(LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT)` |
| `BANK_SEL_WIDTH` | `int unsigned` | `(BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)` |
| `ELEM_SEL_WIDTH` | `int unsigned` | `(ELEMS_PER_WORD <= 1) ? 1 : $clog2(ELEMS_PER_WORD)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `wen` | 输入 | `1 位` | — |
| `wbank` | 输入 | `[BANK_SEL_WIDTH-1:0]` | — |
| `wlane` | 输入 | `[LANE_SEL_WIDTH-1:0]` | — |
| `waddr` | 输入 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `wdata` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `ren` | 输入 | `1 位` | — |
| `rbank` | 输入 | `[BANK_SEL_WIDTH-1:0]` | — |
| `r_k_index` | 输入 | `[K_ADDR_WIDTH-1:0]` | — |
| `rdata` | 输出 | `[LANE_COUNT*ELEM_WIDTH-1:0]` | — |

## operand_packer

源码：[rtl/memory/operand_packer.sv](../rtl/memory/operand_packer.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ELEM_WIDTH` | `int unsigned` | `8` |
| `LANE_COUNT` | `int unsigned` | `4` |
| `MEM_WORD_WIDTH` | `int unsigned` | `32` |
| `K_DEPTH` | `int unsigned` | `256` |
| `BUFFER_COUNT` | `int unsigned` | `2` |
| `K_SIZE_WIDTH` | `int unsigned` | `$clog2(K_DEPTH + 1)` |
| `ELEMS_PER_WORD` | `int unsigned` | `MEM_WORD_WIDTH / ELEM_WIDTH` |
| `WORD_DEPTH` | `int unsigned` | `(K_DEPTH + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD` |
| `WORD_ADDR_WIDTH` | `int unsigned` | `(WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH)` |
| `LANE_WIDTH` | `int unsigned` | `(LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT)` |
| `BANK_WIDTH` | `int unsigned` | `(BUFFER_COUNT <= 1) ? 1 : $clog2(BUFFER_COUNT)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `load_req` | 输入 | `1 位` | — |
| `load_accept` | 输出 | `1 位` | — |
| `load_size` | 输入 | `[K_SIZE_WIDTH-1:0]` | — |
| `load_done` | 输出 | `1 位` | — |
| `busy` | 输出 | `1 位` | — |
| `bank_load_req` | 输出 | `1 位` | — |
| `bank_load_grant` | 输入 | `1 位` | — |
| `bank_load_bank` | 输入 | `[BANK_WIDTH-1:0]` | — |
| `bank_load_done` | 输出 | `1 位` | — |
| `data_valid` | 输入 | `1 位` | — |
| `data_ready` | 输出 | `1 位` | — |
| `data` | 输入 | `[MEM_WORD_WIDTH-1:0]` | — |
| `buffer_wen` | 输出 | `1 位` | — |
| `buffer_wbank` | 输出 | `[BANK_WIDTH-1:0]` | — |
| `buffer_wlane` | 输出 | `[LANE_WIDTH-1:0]` | — |
| `buffer_waddr` | 输出 | `[WORD_ADDR_WIDTH-1:0]` | — |
| `buffer_wdata` | 输出 | `[MEM_WORD_WIDTH-1:0]` | — |

## operand_sram

源码：[rtl/memory/operand_sram.sv](../rtl/memory/operand_sram.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `DATA_WIDTH` | `int` | `64` |
| `DEPTH` | `int` | `32` |
| `ADDR_WIDTH` | `int` | `(DEPTH <= 1) ? 1 : $clog2(DEPTH)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `ren` | 输入 | `1 位` | — |
| `raddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `rdata` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `wen` | 输入 | `1 位` | — |
| `waddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `wdata` | 输入 | `[DATA_WIDTH-1:0]` | — |

## psum_sram

源码：[rtl/memory/psum_sram.sv](../rtl/memory/psum_sram.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `PSUM_SLOTS` | `int unsigned` | `4` |
| `SLOT_WIDTH` | `int unsigned` | `(PSUM_SLOTS <= 1) ? 1 : $clog2(PSUM_SLOTS)` |
| `ROW_WIDTH` | `int unsigned` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |
| `DATA_WIDTH` | `int unsigned` | `COLS * ACC_WIDTH` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `rd_en` | 输入 | `1 位` | — |
| `rd_slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `rd_row` | 输入 | `[ROW_WIDTH-1:0]` | — |
| `rd_valid` | 输出 | `1 位` | — |
| `rd_data` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `wr_en` | 输入 | `1 位` | — |
| `wr_slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `wr_row` | 输入 | `[ROW_WIDTH-1:0]` | — |
| `wr_data` | 输入 | `[DATA_WIDTH-1:0]` | — |

## result_param_buffer

源码：[rtl/memory/result_param_buffer.sv](../rtl/memory/result_param_buffer.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `SLOTS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `TAG_WIDTH` | `int unsigned` | `16` |
| `SLOT_WIDTH` | `int unsigned` | `(SLOTS <= 1) ? 1 : $clog2(SLOTS)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `clear` | 输入 | `1 位` | — |
| `fill_valid` | 输入 | `1 位` | — |
| `fill_ready` | 输出 | `1 位` | — |
| `fill_slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `fill_n_tile` | 输入 | `[TAG_WIDTH-1:0]` | — |
| `fill_bias` | 输入 | `signed [31:0]` | `[0:COLS-1]` |
| `fill_multiplier` | 输入 | `[31:0]` | `[0:COLS-1]` |
| `fill_shift` | 输入 | `[5:0]` | `[0:COLS-1]` |
| `read_valid` | 输入 | `1 位` | — |
| `read_slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `read_n_tile` | 输入 | `[TAG_WIDTH-1:0]` | — |
| `read_hit` | 输出 | `1 位` | — |
| `read_bias` | 输出 | `signed [31:0]` | `[0:COLS-1]` |
| `read_multiplier` | 输出 | `[31:0]` | `[0:COLS-1]` |
| `read_shift` | 输出 | `[5:0]` | `[0:COLS-1]` |
| `retire_valid` | 输入 | `1 位` | — |
| `retire_slot` | 输入 | `[SLOT_WIDTH-1:0]` | — |
| `retire_n_tile` | 输入 | `[TAG_WIDTH-1:0]` | — |
| `retire_hit` | 输出 | `1 位` | — |

## result_tile_buffer

源码：[rtl/memory/result_tile_buffer.sv](../rtl/memory/result_tile_buffer.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `ROWS` | `int unsigned` | `4` |
| `COLS` | `int unsigned` | `4` |
| `ACC_WIDTH` | `int unsigned` | `32` |
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `C_ADDR_WIDTH` | `int unsigned` | `8` |
| `ROW_WIDTH` | `int unsigned` | `(ROWS <= 1) ? 1 : $clog2(ROWS)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `clear` | 输入 | `1 位` | — |
| `capture_start` | 输入 | `1 位` | — |
| `capture_ready` | 输出 | `1 位` | — |
| `capture_addr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `capture_stride_bytes` | 输入 | `[31:0]` | — |
| `capture_spatial_base` | 输入 | `[31:0]` | — |
| `capture_channel_base` | 输入 | `[31:0]` | — |
| `capture_int8_mode` | 输入 | `1 位` | — |
| `capture_valid_rows` | 输入 | `[31:0]` | — |
| `capture_valid_cols` | 输入 | `[31:0]` | — |
| `capture_row_valid` | 输入 | `1 位` | — |
| `capture_row_ready` | 输出 | `1 位` | — |
| `capture_row_index` | 输入 | `[ROW_WIDTH-1:0]` | — |
| `capture_row_data` | 输入 | `[COLS*ACC_WIDTH-1:0]` | — |
| `capture_done` | 输出 | `1 位` | — |
| `result_valid` | 输出 | `1 位` | — |
| `result_accept` | 输入 | `1 位` | — |
| `result_done` | 输入 | `1 位` | — |
| `result_addr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `result_stride_bytes` | 输出 | `[31:0]` | — |
| `result_spatial_base` | 输出 | `[31:0]` | — |
| `result_channel_base` | 输出 | `[31:0]` | — |
| `result_int8_mode` | 输出 | `1 位` | — |
| `result_valid_rows` | 输出 | `[31:0]` | — |
| `result_valid_cols` | 输出 | `[31:0]` | — |
| `dma_ren` | 输入 | `1 位` | — |
| `dma_raddr` | 输入 | `[C_ADDR_WIDTH-1:0]` | — |
| `dma_rdata` | 输出 | `[COLS*ACC_WIDTH-1:0]` | — |
| `busy` | 输出 | `1 位` | — |

## pool_window_buffer 与 pool_max_reducer

源码：[pool_window_buffer.sv](../rtl/compute/pool_window_buffer.sv)、[pool_max_reducer.sv](../rtl/compute/pool_max_reducer.sv)。

`pool_window_buffer` 保存最近 KH 行未经池化的 INT8 数据，并以 `sample_valid/ready`、`sample_data`、`sample_first/last`、输出空间及通道坐标逐样本提供完整窗口。它不执行最大值或其它归约，窗口读取反压时数据与元数据保持稳定。`pool_max_reducer` 是当前使用的独立运算消费者，通过 `result_valid/ready` 向写回端输出每个4通道窗口的最大值；未来其它运算可以复用原始窗口接口。详细端口语义和容量规则见[原始池化输入缓存](pooling_input_buffer.md)。

## stream_maxpool2x2

源码：[rtl/compute/stream_maxpool2x2.sv](../rtl/compute/stream_maxpool2x2.sv)

逐空间位置接收 COLS 路 INT8，先保存原始池化输入，再按窗口读取并完成可配置窗口/步长的 VALID MaxPool。结果通过 `pool_result_dma` 的地址/数据 FIFO 写入外存。历史模块名保留。`cfg_pool_config={stride_w,stride_h,kernel_w,kernel_h}`，每项8位且非零；全零兼容 2×2/步长2。`start` 仅在排空后接受；`busy` 覆盖窗口回放、归约结果、FIFO及未完成的写响应。本地窗口可接收时 `in_ready` 为高，DMA忙不直接关闭输入，FIFO满后逐级反压。每个通道块的空间坐标必须按光栅顺序到达，全通道缓存模式下不同通道块可交错。全通道原始行容量需求为 `kernel_h*input_w*(channels/4)` 个32位字；卷积可按通道块执行，将活跃容量降至 `kernel_h*input_w*(COLS/4)`。最小通道块仍超限时报错且禁止输入/写出。FC 只采用全通道缓存。缓冲保存后处理后的 INT8 原始样本，最大值归约放在读取端，未来可以复用读取端扩展其他池化算子。

| 参数 | 类型 | 默认值 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `COLS` | `int unsigned` | `4` |
| `LINE_WORDS` | `int unsigned` | `1024` |
| `OUTPUT_FIFO_DEPTH` | `int unsigned` | `16` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `reset` | 输入 | `1 位` | — |
| `start` | 输入 | `1 位` | — |
| `cfg_input_h` | 输入 | `[31:0]` | — |
| `cfg_input_w` | 输入 | `[31:0]` | — |
| `cfg_channels` | 输入 | `[31:0]` | — |
| `cfg_pool_config` | 输入 | `[31:0]` | — |
| `cfg_output_base` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `in_valid` | 输入 | `1 位` | — |
| `in_ready` | 输出 | `1 位` | — |
| `in_data` | 输入 | `[COLS*8-1:0]` | — |
| `in_spatial_index` | 输入 | `[31:0]` | — |
| `in_channel_base` | 输入 | `[31:0]` | — |
| `busy` | 输出 | `1 位` | — |
| `error` | 输出 | `1 位` | — |
| `m_axi_awid` | 输出 | `[ID_WIDTH-1:0]` | — |
| `m_axi_awaddr` | 输出 | `[ADDR_WIDTH-1:0]` | — |
| `m_axi_awlen` | 输出 | `[7:0]` | — |
| `m_axi_awsize` | 输出 | `[2:0]` | — |
| `m_axi_awburst` | 输出 | `[1:0]` | — |
| `m_axi_awvalid` | 输出 | `1 位` | — |
| `m_axi_awready` | 输入 | `1 位` | — |
| `m_axi_wdata` | 输出 | `[31:0]` | — |
| `m_axi_wstrb` | 输出 | `[3:0]` | — |
| `m_axi_wlast` | 输出 | `1 位` | — |
| `m_axi_wvalid` | 输出 | `1 位` | — |
| `m_axi_wready` | 输入 | `1 位` | — |
| `m_axi_bid` | 输入 | `[ID_WIDTH-1:0]` | — |
| `m_axi_bresp` | 输入 | `[1:0]` | — |
| `m_axi_bvalid` | 输入 | `1 位` | — |
| `m_axi_bready` | 输出 | `1 位` | — |

## pool_result_dma

源码：[rtl/dma/pool_result_dma.sv](../rtl/dma/pool_result_dma.sv)

在 `in_valid && in_ready` 时将绝对字节地址和32位数据入队。写回状态机独立取队头，复制到活动寄存器后释放队列位置，再由 `axi_write_master` 完成单拍 AW/W/B。地址必须四字节对齐；不连续的地址按入队顺序分别写入。满队列可在同拍出队时接收新项，支持深度1及非二次幂。`clear` 只用于空闲时开始新任务；`error` 锁存请求、BRESP或BID错误，直到 `clear/reset`。`busy` 覆盖队列、活动写和写响应完成事件。

| 参数 | 类型 | 默认值 |
|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | `64` |
| `ID_WIDTH` | `int unsigned` | `1` |
| `FIFO_DEPTH` | `int unsigned` | `16`，正整数 |

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---|---|
| `clk` | 输入 | 1 | 时钟 |
| `reset` | 输入 | 1 | 高有效同步复位 |
| `clear` | 输入 | 1 | 仅空闲时清队列状态和错误 |
| `in_valid` | 输入 | 1 | 入队有效 |
| `in_ready` | 输出 | 1 | 入队可接收 |
| `in_addr` | 输入 | ADDR_WIDTH | 绝对字节地址 |
| `in_data` | 输入 | 32 | 四个INT8池化结果 |
| `busy` | 输出 | 1 | 有排队结果或在途写事务 |
| `error` | 输出 | 1 | 粘性错误 |
| `m_axi_awid` | 输出 | ID_WIDTH | 固定为零的写ID |
| `m_axi_awaddr` | 输出 | ADDR_WIDTH | 写地址 |
| `m_axi_awlen` | 输出 | 8 | 固定为零，单拍写 |
| `m_axi_awsize` | 输出 | 3 | 固定为2，四字节 |
| `m_axi_awburst` | 输出 | 2 | INCR |
| `m_axi_awvalid` | 输出 | 1 | 地址有效 |
| `m_axi_awready` | 输入 | 1 | 地址接收 |
| `m_axi_wdata` | 输出 | 32 | 写数据 |
| `m_axi_wstrb` | 输出 | 4 | 全字节有效 |
| `m_axi_wlast` | 输出 | 1 | 单拍末尾 |
| `m_axi_wvalid` | 输出 | 1 | 写数据有效 |
| `m_axi_wready` | 输入 | 1 | 写数据接收 |
| `m_axi_bid` | 输入 | ID_WIDTH | 写响应ID |
| `m_axi_bresp` | 输入 | 2 | 写响应状态 |
| `m_axi_bvalid` | 输入 | 1 | 写响应有效 |
| `m_axi_bready` | 输出 | 1 | 写响应接收 |

## sync_sram

源码：[rtl/memory/sync_sram.sv](../rtl/memory/sync_sram.sv)

| 参数 | 类型 | 默认值/派生表达式 |
|---|---|---|
| `DATA_WIDTH` | `int` | `32` |
| `DEPTH` | `int` | `256` |
| `ADDR_WIDTH` | `int` | `$clog2(DEPTH)` |

| 端口 | 方向 | 数据类型/每项位宽 | 数组维度 |
|---|---|---|---|
| `clk` | 输入 | `1 位` | — |
| `ren` | 输入 | `1 位` | — |
| `raddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `rdata` | 输出 | `[DATA_WIDTH-1:0]` | — |
| `wen` | 输入 | `1 位` | — |
| `waddr` | 输入 | `[ADDR_WIDTH-1:0]` | — |
| `wdata` | 输入 | `[DATA_WIDTH-1:0]` | — |
