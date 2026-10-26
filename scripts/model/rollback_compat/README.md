These recipes reproduce the historical RTL sources used by the full ResNet-50
rollback benchmark. They do not change production RTL or regenerate model data.

```sh
python3 scripts/model/prepare_resnet50_rollback.py --out /tmp/resnet50-rollback-sources
```

The destination must be new. The Git checkout must contain commits
`00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47`,
`46f756efffccfb9da44fd255661507afca353c05`, and
`af66f524875d78d443309a25754f049dbe4d4999`.

Each variant starts with all original RTL files. The descriptor reader, top-level
functional shell, performance monitor and external 32-to-64 read adapter use
`46f756e` as their common source. The old internal operand path stays 32-bit.
The top-level patches connect identical Add/Pool/GAP hardware, admit logical
convolution tails, and preserve each historical executor interface. In `legacy00`
the later A/B dataflow flags are accepted by the shell and execute through the
original scheduler, without importing A reuse, PSUM blocking or B residency.

The common Add/Pool/GAP operators and their AXI masters come from `af66f52`.
Only whole-identifier module/instantiation names change; the recorded replacement
counts and SHA256 values must match. Two pool unit-test modules are restored
with the same lexical rename because the frozen benchmark compilation included
them; they are classified as verification only and are not elaborated under the
selected graph testbench top. The `legacy00` patches also add per-channel
quantization compatible with the common workload. Both variants bound output
tail writes and ignore inactive parameter lanes. Complete-tile DMA state
sequences remain unchanged.

Every source records its origin commit, original SHA256, final SHA256 and one of
three classifications: `historical_unchanged`, `shared_functional_shell`, or
`functional_compatibility_patch`. Every diff has its own SHA256. `common.json`
records the shared operators separately. Preparation rejects changed originals,
changed patches, fuzzy contexts, unexpected renamed identifiers, changed final
sources and existing output directories. It writes a complete `preparation.json`
manifest alongside the fresh source trees.

The result is a historical implementation with declared functional backports,
not an unmodified checkout that was already capable of running ResNet-50.


The C++ driver in `graph_driver.cpp` ports the DDR model, reset/start sequence
and layer checker from `sim/tb/system/graph_model_npu_tb.sv`. Compile the actual
`npu_top` with `NPU_PERF_ENABLE` using Verilator `--cc --exe`; the wrapper
`benchmark_graph_verilator.py` handles this. It evaluates every RTL clock edge.
It does not compute network outputs, feed expected outputs into the network or
skip simulated clocks. DDR contents change only through accepted RTL write beats.

For each cycle, the driver samples settled AXI handshakes before the rising
edge, evaluates the RTL edge, updates DDR state and byte writes using the old
state, and settles the new memory inputs without another rising edge. It then
evaluates the falling edge and checks any registered completed-layer pulse.
The initial reset lasts five full cycles, followed by one idle cycle and one
start cycle; completion receives two additional settling cycles. This matches
the SV authority's reset/start and nonblocking-assignment ordering.

The memory supports the same 64-bit reads, 32-bit writes, byte strobes, first-beat
read delay and delayed B responses. Every layer byte is checked at its boundary;
independent AXI counters are checked against the RTL monitor; the complete DDR
image is dumped. All benchmark counters remain 64-bit. Image and layer limits
match the SV testbench defaults: 8,388,608 words and 262,144 golden words.

Before using another simulator for reported measurements, compare its complete
layer/total cycle and traffic counters and full DDR image against the validated
VCS run. The C++ memory unit test uses inert DUT-port stubs and verifies the driver
memory logic only; it is separate from that required RTL cross-validation.
To run it from the repository root with a C++17 compiler:

```sh
c++ -std=c++17 -O2 -I scripts/model/rollback_compat/cpp_tests \
  scripts/model/rollback_compat/cpp_tests/memory_unit.cpp -o /tmp/npu_graph_memory_unit
/tmp/npu_graph_memory_unit
```

The unit test covers first-beat latency, burst reads, backpressure, old-state
AW/W/B ordering, zero/delayed B, byte strobes, 4 KiB crossing rejection and reset.
The port's frozen SHA256 is
`5c9f8707ebe6343f407a7237edb93835e7f3c0031933a5f29490840ff2fe750b`.
