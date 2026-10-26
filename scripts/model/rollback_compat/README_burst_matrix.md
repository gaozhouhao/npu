# Matched Burst comparison source preparation

`../prepare_resnet50_burst_matrix.py` prepares two declared mixed-source NPU
variants. It leaves production RTL and the supplied validated legacy00 snapshot
unchanged. A fresh destination is required.

```sh
python3 scripts/model/prepare_resnet50_burst_matrix.py \
  --base-metadata build/resnet50-rollback-compare/check/legacy00-rtl/source.json \
  --out build/resnet50-burst-matrix
```

| Source component | `burst_serial` | `burst_double` |
| --- | --- | --- |
| Conv Burst loader | Exact `fd4a041265034c466b9aa3056786dbe863684f4e` file | Same bytes |
| Scheduler | Exact `1dc5b2d5d1981f08a8c2cb6efeee73327d2846f4` file | Validated `00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47` file |
| Executor | Validated legacy00 with the pinned serial port/completion bridge | Validated legacy00 unchanged |
| Physical A/B banks | 1 / 1 | 2 / 2 |
| Internal operand width | 32 bits | 32 bits |
| External read width | Common AXI64 adapter | Same bytes |
| Other functional compatibility | Per-channel quantization, Add/Pool/GAP routing, SAME and output tails | Same bytes |

Only `rtl/dma/conv_patch_loader.sv` is imported from the Burst commit. Its
executor and scheduler are deliberately excluded because that commit already
contains the earlier A-reuse optimization. Neither comparison variant imports
A/B dataflow reuse, PSUM slots, internal native64, Conv cache/lookahead or
decoupled C writeback.

Every generated source is hashed in `source.json`; `provenance.json` records
the source roles and diffs from the validated functional legacy00 snapshot.
`matrix-provenance.json` checks that the two source sets differ only in the
scheduler, executor bridge, bank parameters and observation-only verification
sources/listing. Source preparation itself makes no correctness or speed claim.

Both variants include the same observation-only `burst_prefetch_guard.sv`
template, prefixed with the expected bank count (1 or 2). It observes accepted
Conv Burst requests and requested/received words, fresh A/B loads for every
tile, and actual load/read/SRAM-write overlap with the core. It never drives a
DUT signal. The serial variant also retains the existing serial schedule guard.

The preparer reuses the serial preparer's strict checks for the complete base
snapshot and historical serial bridge. It also pins the exact Burst loader
hash, refuses existing destinations and removes a newly created destination
if writing fails. Run its boundary checks with:

```sh
python3 scripts/model/rollback_compat/test_burst_matrix_prepare.py
```
