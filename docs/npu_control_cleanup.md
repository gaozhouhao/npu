# NPU控制逻辑精简（2026-10-26）

本次将已验证的简化控制路径作为生产实现，直接删除卷积读缓存及其接口，去掉片段前瞻和计算bank获取快路径。不同描述符仍独立执行、通过DDR交接。功能RTL净删除335行（剔除注释/空行后净删除275行），活动模块由39个减至38个。

## 删除与保留

- 删除 `conv_word_cache` 模块及文件列表入口，去掉数据/tag/valid存储、miss扫描状态机、层开始失效控制、缓存参数和中间接口。Conv patch请求直接接入已有A/B读仲裁器。
- 删除卷积读完成阶段的下一片段前瞻，统一回到 `ST_PREP` 规划。
- 删除 `CP_IDLE` 发起计算bank请求及快速获取/部分授权分支，统一在 `CP_ACQUIRE` 获取；普通分拍授权记录仍保留，避免丢失真实授权。
- B驻留模式等待当前N块释放，再加载下一N块，保留同一N跨M的B复用。
- 保留原生64位操作数读取、A/B双Bank、输出驻留累加、跨K输入复用和部分和槽、量化、逻辑尾块、残差ADD、独立/融合池化及输出FIFO。

没有删除当前模型所需的算子、描述符和错误处理。移除接口后同步更新testbench和当前接口文档；缓存专属断言随模块删除，连续命令、原址写后读、数值、反压与完成检查仍保留。

## 与此前实验的关系

此前[四项功能消融](resnet50_readpath_ablation.md)的关闭组是隔离副本中的参数旁路，本次实际删除生产RTL中的相应逻辑。此前测得关闭组489,351,345周期、原配置503,021,224周期，不能直接当作本次删除后的实测结果。历史实验仍固定读取旧源码，其工具和精确补丁不变；测试fixture也从固定提交读取，避免随当前RTL漂移。

## 本次实测

对照为精简前 `61b2e6516d6c513e99ba0d7915e6a916b3f9d0df` 与精简实现。整网源码在仿真前冻结，两组复用同一模型、输入、golden、testbench和内存时序；ResNet读burst首拍等待20周期、额外写响应等待0。MNIST使用原testbench内存模型，不能跨网络直接比较周期。

| 工作负载 | 精简前周期 | 精简后周期 | 周期变化 |
| --- | ---: | ---: | ---: |
| ResNet50，完整72条任务 | 503,021,224 | 489,351,345 | 减少2.72% |
| ResNet8，14条任务，零输入/seed8 | 1,735,928 | 1,984,411 | 增加14.31% |
| MNIST，普通5条任务，每图 | 68,542 | 72,029 | 增加5.09% |
| MNIST，融合3条任务，每图 | 51,318 | 54,805 | 增加6.79% |

ResNet50两组均通过全部72层、累计16,837,097字节层输出及完整29,404,672字节DDR，最终哈希相同；实际删除后的周期与此前参数旁路组相同。读取1,158,799,696→1,278,406,224字节，增加10.32%，实际写入均为16,837,097字节。此次周期减少2.717555%的分母是精简前503,021,224周期；此前“开启后慢2.793469%”使用关闭组周期作分母，二者不能混用。

ResNet8两种输入各跑前后两组，共四次14层及完整1MiB DDR检查通过，前后结果逐字节一致。读字节3,608,696→4,227,752，增加17.15%；实际写均为114,800字节。MNIST普通和融合路径均分别核对四张图，预测7、2、1、0；每图普通读131,632→164,384字节、写11,952字节不变，融合读112,560→145,312字节、写2,544字节不变。

这轮按简化控制逻辑的目标保留精简主线。缓存对小网络确实有收益，删除后ResNet8/MNIST会退化，因此不把全部旧优化判定为无效，也不声称本次是所有模型的性能提升。简历中的历史缓存收益必须注明对应版本，不能作为当前已删除缓存实现的指标；当前完整网络指标见上表。分类精度仍未测量。

## 验证与来源

- 34/34个现有功能testbench通过，包含分拍bank授权、B驻留切换、卷积padding、逻辑尾块、错误恢复、量化、残差及池化。
- 融合专项19组、FIFO专项7组通过；重复命令、通道分块、满缓冲、反压和最终写响应均保留检查。缓存专属压力配置随缓存删除，已有通道分块测试继续运行。
- 编译器145项、模型脚本38项、分析脚本7项，共190项Python测试通过。顶层小参数配置通过。
- Design Compiler分析、展开和连接通过。`check_design`仍报告悬空/常量等lint信息，本次未做lint清零、工艺映射、面积/频率/功耗或新DFT评估。

[机器实测摘要](reference/npu_control_cleanup_summary.json)保留逐层结果、完整源码/日志/golden哈希及验证记录。完整本地产物在 `build/npu-control-cleanup/`。实际仿真的本地提交为 `7c58e5cd734c474561645cf5184c867da9f1e27d`，已发布等价实现提交为 `34358ce46fb3df5d925a9e95910f0c7b179b7679`；两者完整Git源码树均为 `a116c1c1f8a001d68fa6e4a39d46a2c911e4148c`，原始实测来源记录保持不变。

## 复现

使用本地VCS与Python3/NumPy。已有真实ResNet50模型及黄金结果时，先将 `build/resnet50-benchmark/check/` 中的 `reference.json`、`expected.bin`、`input.hex`、`layers.txt` 原样复制到新的对照输出目录，保持golden路径有效。对同一输出目录分别执行：

```bash
python scripts/model/run_graph_model.py run --package build/resnet50-benchmark/model \
  --out build/npu-control-cleanup/resnet50-replay --source-ref 61b2e65 --label baseline \
  --read-latency 20 --write-latency 0
python scripts/model/run_graph_model.py check --package build/resnet50-benchmark/model \
  --out build/npu-control-cleanup/resnet50-replay --label baseline
python scripts/model/run_graph_model.py run --package build/resnet50-benchmark/model \
  --out build/npu-control-cleanup/resnet50-replay --source-ref 34358ce --label current \
  --read-latency 20 --write-latency 0
python scripts/model/run_graph_model.py check --package build/resnet50-benchmark/model \
  --out build/npu-control-cleanup/resnet50-replay --label current
python scripts/analysis/compare_graph_benchmarks.py \
  --baseline build/npu-control-cleanup/resnet50-replay/baseline-report.json \
  --current build/npu-control-cleanup/resnet50-replay/current-report.json \
  --out build/npu-control-cleanup/resnet50-replay/comparison.json
```

ResNet8可使用[已有对照入口](resnet_performance.md)，将前后版本设为 `61b2e65`/`34358ce`，输出放入新目录。常规功能验证仍使用 `make regression`、`make fusion-check`、`make pool-fifo-check`、`make compiler-test`、`make mnist-all` 和 `make mnist-fused`。
