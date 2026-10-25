# 分类层的软件对齐：真实1×1001，硬件4×1004

ResNet-50 的分类层接收2048个特征数字，为1001个类别分别计算一个分数。逻辑计算是一行输入、1001个输出；默认阵列每组处理4行、4列，需要完整安排物理读写空间。

本次不修改计算阵列。新增 `compiler/fc_layout.py`，统一规划物理尺寸、打包输入/权重/参数、生成描述符和提取真实输出，并接入已有TFLite全连接编译入口。下面的代码为实际实现的关键片段；范围、类型和溢出检查保留在完整源码中。

## 第一步：同时保存真实尺寸和物理尺寸

`plan_fc_layout()` 中：

```python
physical_m = _align(logical_m, rows)
physical_n = _align(logical_n, cols)
a_stride_bytes = _align(k, 8)
b_stride_bytes = _align(k, 8)
c_stride_bytes = _align(physical_n * output_element_bytes, 4)
```

`logical_m=1`、`logical_n=1001` 是模型真正需要的数量，始终保留。对齐函数把数量向上补到整数个阵列块：1补成4，1001补成1004。K仍为2048，不增加参与点积的元素。

输入和权重每行的存储长度向上对齐到8字节，供64位读接口访问。比如K=9时，每行占16字节，但仍只计算前9个数字；尾部7字节只属于存储空间。

| 区域 | 默认4×4、K2048、逻辑输出1001时的布局 |
|---|---|
| 输入，普通补行方案 | 4×2048字节 |
| 权重 | 1004×2048字节，前1001行是真实权重 |
| 8位输出 | 4行，每行1004字节 |
| 32位输出 | 4行，每行4016字节 |

## 第二步：输入必须来自真实运行结果

独立的 `pack_fc_input()` 接收已经存在的输入数字，复制真实行，其余位置用输入量化零点填充：

```python
packed = bytearray([input_zero_point & 255]) * layout['a_bytes']
for row in range(m):
    begin = row * layout['a_stride_bytes']
    packed[begin:begin+k] = data[row*k:(row+1)*k]
```

普通量化零点为0时，这相当于把输入补成4行：第一行是真实数据，后三行是零。如果零点为-5，表示真实零的数字就是-5，不能机械地填数值0。补出来的行只为满足硬件读写，不是新增的图片。

已有TFLite编译入口面对的是前一层运行时生成的输入，此时不能在编译时把“未来的数据”复制到新地址。本次选择重复读取同一行：

```python
m = fc_layout['physical_m']
sa = 0
sb = fc_layout['b_stride_bytes']
sc = fc_layout['c_stride_bytes']
```

输入某一行的读取起点是 `输入基址 + 行号 × sa`。`sa=0` 时，四个物理行都读取上一层输出的同一条真实向量；它们会算出四份相同分数，只使用第0行。权重仍正常逐行读取，输出也正常分开存放。这个策略仅用于当前batch-1全连接输入，已用真实描述符通过硬件验证。

源向量至少分配 `align(K,8)` 个字节，覆盖读接口尾拍。元数据记录 `input_row_policy=repeat_logical_row` 与 `actual_a_stride_bytes=0`；规范的普通补行布局仍独立保留，二者不混用。

## 第三步：权重和参数一起补齐

`pack_fc_weights()` 中：

```python
packed = bytearray(layout['b_bytes'])
for channel in range(n):
    begin = channel * layout['b_stride_bytes']
    packed[begin:begin+k] = data[channel*k:(channel+1)*k]
```

先把整块物理权重空间初始化为零，再复制1001个真实输出对应的权重。最后三个输出通道的权重保留为零。硬件的权重排列是 `[输出通道,K]`；ONNX原分类矩阵是 `[K,输出通道]`，接入ONNX图时还须转换排列。

`pack_fc_params()` 同时补偏置和量化参数：

```python
folded_bias, multiplier, shift = 0, 0, 0
if channel < n:
    # 真实通道计算其偏置与量化参数。
    folded_bias = bias[channel] - input_zero_point * weight_sum
```

占位通道的权重、偏置、乘数和移位均为零，避免读取未初始化参数。非零输入零点的修正折入偏置，真实通道计算语义保持一致。32位占位输出为0；8位重定量占位输出通常为输出零点，未必是数值0。普通补行方案中的额外行还可能产生真实偏置，不能断言全部额外输出都为零。

## 第四步：分配完整输出，命令使用物理尺寸

共享布局的输出空间为：

```python
c_bytes = physical_m * c_stride_bytes
```

TFLite入口据此分配：

```python
caddr = self.mem.reserve(fc_layout['c_bytes'])
```

描述符使用补齐后的行列数。若只把命令中的1001改成1004，却继续按1×1001分配内存，硬件写出的其他列和其他行会覆盖后续区域。

输入、权重和输出的每行存储跨度单独保存，不用逻辑类别数代替物理行跨度。真实的类别数与输出形状另存元数据，不因为物理尺寸变化而修改模型。

## 第五步：分类前只提取真实结果

`extract_fc_output()` 中：

```python
logical_row_bytes = layout['logical_n'] * layout['output_element_bytes']
return b''.join(data[row*layout['c_stride_bytes']:
                    row*layout['c_stride_bytes']+logical_row_bytes]
                for row in range(layout['logical_m']))
```

它只处理真实行，每行按物理跨度找到起点，再取真实类别的字节。对ResNet-50，就是取第0行的前1001项；其余三行和最后三列都不参加分类。多行输入同样逐行截取，不能把整个物理缓冲的前 `M×N` 项直接当作紧凑结果。

`fc_argmax()` 先调用上述提取函数，再在每行真实分数中找最大值。测试故意让所有真实分数都小于0，占位列为0：不裁剪会选中无效索引1001；正确裁剪后选中真实索引1000。索引从0开始。

## 验证与范围

```bash
make fc-alignment-check
```

该入口使用Python标准库生成真实部署数据和描述符，交给 `npu_top` 执行，核对全部物理输出后再将硬件结果交给真实软件裁剪/分类函数：

- `resnet50`：逻辑1×1001、K2048，输入零点-5，普通补行，32位输出。
- `resnet50-repeat`：相同尺寸，仅存一条真实输入，描述符输入行步长为0，验证TFLite采用的重复行策略。
- `small-int8`：逻辑3×5、K9，验证8字节行对齐、非零输入/输出零点、逐通道参数和多行裁剪。

这些用例使用确定性整数输入和真实分类层尺寸，没有使用下载模型的训练权重，也不证明模型分类精度。另有4项标准库单测；TFLite实际FC方法使用外部张量接口替身检查过，但环境缺少Python3/NumPy/TFLite，完整前端仍未运行。

本次解决分类层物理对齐与逻辑输出提取，不包含完整ONNX编译器、浮点模型校准量化或7×7卷积尾块。具体日志见 [验证记录](validation.md)。
