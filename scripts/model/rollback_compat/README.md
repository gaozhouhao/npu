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
