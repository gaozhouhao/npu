#!/usr/bin/env python3
"""Compile a supported quantized TFLite ResNet-8 graph for NPU V1.

Requires: pip install numpy tflite
Artifacts: ddr.bin, ddr.hex, descriptors.bin, manifest.json.

Supported operations:
    CONV_2D
    ADD
    AVERAGE_POOL_2D (global only)
    FULLY_CONNECTED
    RESHAPE (alias)
    SOFTMAX (argmax bypass)

Descriptor dataflow flags:
    bit 5: Multi-K A reuse with PSUM
    bit 6: B-stationary, K_tiles == 1

Modes:
    --dataflow a
    --dataflow b
    --dataflow auto

Environment alternative:
    NPU_DATAFLOW=a|b|auto

The NPU arithmetic is not bit-exact TFLite arithmetic.

Batch-1 FC is issued with complete array rows/columns. Physical input rows
repeat the one runtime vector (A stride 0); classification uses only the
logical classes in output row 0. Manifest fields describe both layouts.
"""

import argparse
import json
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np

try:
    import tflite
except ImportError as exc:
    raise SystemExit(
        "Install flatbuffer bindings: pip install tflite"
    ) from exc


OP_GEMM = 1
OP_CONV = 2
OP_AVG = 4
OP_ADD = 5

DESC_WORDS = 16

FLAG_MULTI_K_A_REUSE = 1 << 5
FLAG_B_STATIONARY = 1 << 6

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'compiler'))
from target import hardware_defaults
from fc_layout import plan_fc_layout, pack_fc_weights, pack_fc_params

HARDWARE = hardware_defaults()
PE_ROWS = HARDWARE['pe_rows']
PE_COLS = HARDWARE['pe_cols']
K_TILE_SIZE = HARDWARE['k_tile_size']


def align(v, a):
    return ((v + a - 1) // a) * a


def words(*items):
    return b"".join(
        struct.pack("<I", int(v) & 0xffffffff)
        for v in items
    )


def qscale(t):
    q = t.Quantization()
    if q is None:
        return [], []

    scales = [
        float(q.Scale(i))
        for i in range(q.ScaleLength())
    ]

    zp = [
        int(q.ZeroPoint(i))
        for i in range(q.ZeroPointLength())
    ]

    return scales, zp


def scale_1(t):
    s, z = qscale(t)

    if len(s) != 1 or len(z) != 1:
        raise ValueError(
            f"Activation requires per-tensor scale/ZP: {t.Name()}"
        )

    return s[0], z[0]


def tensor_shape(t):
    return [
        int(t.Shape(i))
        for i in range(t.ShapeLength())
    ]


def quant_mr(ratio):
    """Choose maximum safe fixed-point precision."""

    if ratio < 0 or not math.isfinite(ratio):
        raise ValueError(f"Invalid scale ratio: {ratio}")

    if ratio == 0:
        return 0, 0

    max_multiplier = (1 << 31) - 1
    max_int64 = (1 << 63) - 1
    max_acc = (1 << 32) - 1

    for shift in range(62, -1, -1):
        m = round(ratio * (1 << shift))

        if m < 0 or m > max_multiplier:
            continue

        rounding_offset = (
            (1 << (shift - 1)) if shift else 0
        )

        if (
            max_acc * m + rounding_offset
            > max_int64
        ):
            continue

        return int(m), int(shift)

    raise ValueError(
        f"No safe fixed-point representation for ratio={ratio}"
    )


def options(op, cls):
    tab = op.BuiltinOptions()

    if tab is None:
        raise ValueError(f"Missing options: {cls}")

    obj = cls()
    obj.Init(tab.Bytes, tab.Pos)
    return obj


def fused_relu(op, cls):
    act = int(
        options(op, cls).FusedActivationFunction()
    )

    if act not in (0, 1):
        raise NotImplementedError(
            f"Fused activation {act} not supported"
        )

    return act == 1


def select_dataflow(m, n, k, preference="auto"):
    """Select an execution policy for one GEMM/Conv layer.

    Returns:
        (dataflow_name, descriptor_flag)

    Current hardware limitation:
        B-stationary supports only K_tiles == 1.
        Multi-K always uses the existing A reuse path.

    Auto is deliberately a first-order tile-shape heuristic,
    not a cycle-accurate cost model.
    """

    if preference not in ("a", "b", "auto"):
        raise ValueError(
            "dataflow must be a, b or auto"
        )

    m_tiles = (m + PE_ROWS - 1) // PE_ROWS
    n_tiles = (n + PE_COLS - 1) // PE_COLS
    k_tiles = (k + K_TILE_SIZE - 1) // K_TILE_SIZE

    if k_tiles > 1:
        if n_tiles > 1:
            return (
                "N_BLOCKED_A_REUSE_PSUM",
                FLAG_MULTI_K_A_REUSE,
            )

        return "OUTPUT_STATIONARY", 0

    if preference == "b":
        selected = "b"
    elif preference == "a":
        selected = "a"
    else:
        # Equal-cost first approximation:
        # B reuse is favored when M_tiles > N_tiles.
        selected = "b" if m_tiles > n_tiles else "a"

    if selected == "b" and m_tiles > 1:
        return "B_STATIONARY", FLAG_B_STATIONARY

    if n_tiles > 1:
        return "OUTPUT_STATIONARY_A_REUSE", 0

    return "OUTPUT_STATIONARY", 0


class DDR:
    def __init__(self):
        self.raw = bytearray(0x10000)
        self.cursor = 0x10000

    def put(self, b, boundary=64):
        b = bytes(b)

        start = align(self.cursor, boundary)
        end = start + len(b)

        if end > len(self.raw):
            self.raw.extend(
                b"\0" * (end - len(self.raw))
            )

        self.raw[start:end] = b
        self.cursor = end
        return start

    def reserve(self, nbytes, boundary=64):
        return self.put(
            b"\0" * align(nbytes, 4),
            boundary,
        )


class Compiler:
    def __init__(self, blob, dataflow="auto"):
        self.model = tflite.Model.GetRootAsModel(
            bytearray(blob), 0
        )

        if self.model.SubgraphsLength() != 1:
            raise ValueError(
                "Only single-subgraph models supported"
            )

        self.graph = self.model.Subgraphs(0)

        self.tensors = [
            self.graph.Tensors(i)
            for i in range(self.graph.TensorsLength())
        ]

        self.mem = DDR()
        self.address = {}
        self.desc = []
        self.layers = []
        self.fc_layouts = {}
        self.dataflow = dataflow

        self.input_tid = int(self.graph.Inputs(0))
        self.input_tensor = self.tensors[self.input_tid]
        self.input_shape = tensor_shape(self.input_tensor)

        if (
            len(self.input_shape) != 4
            or self.input_shape[0] != 1
        ):
            raise ValueError(
                "Expected NHWC batch-1 input"
            )

        _, input_zp = scale_1(self.input_tensor)

        input_length = int(
            np.prod(self.input_shape)
        )

        self.address[self.input_tid] = self.mem.put(
            bytes([input_zp & 0xff]) * align(input_length, 8)
        )

        self.logits_tid = None

    def tensor_array(self, idx, dtype):
        t = self.tensors[idx]
        buf = self.model.Buffers(t.Buffer())

        raw = bytes(
            int(buf.Data(i))
            for i in range(buf.DataLength())
        )

        expected = (
            int(np.prod(tensor_shape(t)))
            * np.dtype(dtype).itemsize
        )

        if len(raw) != expected:
            raise ValueError(
                f"Tensor data length mismatch: "
                f"tensor {idx}, {len(raw)} != {expected}"
            )

        return np.frombuffer(
            raw, dtype=dtype
        ).reshape(tensor_shape(t))

    def output_addr(self, tid):
        if tid in self.address:
            raise ValueError(
                f"Output tensor {tid} already allocated"
            )

        t = self.tensors[tid]

        actual_bytes = int(
            np.prod(tensor_shape(t))
        )

        addr = self.mem.reserve(
            # Operand DMA may fetch a complete 64-bit beat at a logical tail.
            align(actual_bytes, 8)
        )

        self.address[tid] = addr
        return addr

    def encode(
        self,
        opcode,
        flags=0,
        m=0,
        n=0,
        k=0,
        a=0,
        b=0,
        c=0,
        sa=0,
        sb=0,
        sc=0,
        param=0,
    ):
        if any(
            int(z) > 0xffffffff or int(z) < 0
            for z in (a, b, c, param)
        ):
            raise ValueError(
                "Address beyond 32-bit range"
            )

        desc = [0] * DESC_WORDS

        desc[0] = (int(flags) << 8) | int(opcode)
        desc[1:4] = [int(m), int(n), int(k)]

        desc[4:6] = [
            a & 0xffffffff,
            a >> 32,
        ]

        desc[6:8] = [
            b & 0xffffffff,
            b >> 32,
        ]

        desc[8:10] = [
            c & 0xffffffff,
            c >> 32,
        ]

        desc[10:13] = [
            int(sa),
            int(sb),
            int(sc),
        ]

        desc[13:15] = [
            param & 0xffffffff,
            param >> 32,
        ]

        self.desc.append(desc)

    @staticmethod
    def select_dataflow(
        m, n, k, preference="auto"
    ):
        return select_dataflow(
            m, n, k, preference
        )

    def compile_conv_or_fc(self, op, kind):
        ids = [
            int(op.Inputs(i))
            for i in range(op.InputsLength())
        ]

        output_id = int(op.Outputs(0))
        src, w_id = ids[:2]

        bias_id = (
            ids[2] if len(ids) > 2 else -1
        )

        tx, tw, ty = (
            self.tensors[i]
            for i in (src, w_id, output_id)
        )

        input_scale, input_zp = scale_1(tx)
        out_scale, out_zp = scale_1(ty)

        weight = self.tensor_array(
            w_id, np.int8
        )

        if kind == "conv":
            ish = tensor_shape(tx)
            osh = tensor_shape(ty)
            ws = tensor_shape(tw)

            if (
                len(ish) != 4
                or len(osh) != 4
                or len(ws) != 4
            ):
                raise ValueError("Bad CONV shapes")

            _, hin, win, cin = ish
            _, hout, wout, cout = osh
            wo, kh, kw, wcin = ws

            if wo != cout or wcin != cin:
                raise ValueError(
                    "CONV weight shape inconsistent"
                )

            opts = options(
                op, tflite.Conv2DOptions
            )

            if (int(opts.DilationHFactor()) != 1
                    or int(opts.DilationWFactor()) != 1):
                raise NotImplementedError(
                    "Dilated CONV is not supported by the hardware"
                )

            sh = int(opts.StrideH())
            sw = int(opts.StrideW())
            padtype = int(opts.Padding())

            same = (
                padtype == int(tflite.Padding.SAME)
            )

            if padtype not in (
                int(tflite.Padding.SAME),
                int(tflite.Padding.VALID),
            ):
                raise ValueError(
                    "Unknown Conv padding"
                )

            if sh not in (1, 2) or sw not in (1, 2):
                raise ValueError(
                    "Hardware supports stride 1/2"
                )

            pad_h = (
                max(0, (hout - 1) * sh + kh - hin)
                if same else 0
            )

            pad_w = (
                max(0, (wout - 1) * sw + kw - win)
                if same else 0
            )

            pt = pad_h // 2
            pl = pad_w // 2

            if (
                any(
                    v >= 256
                    for v in (
                        kh, kw, sh, sw, pt, pl
                    )
                )
                or cin >= 65536
            ):
                raise ValueError(
                    "Conv descriptor geometry overflow"
                )

            m = hout * wout
            n = cout
            k = kh * kw * cin

            flags = (
                1 | 2 | 8 |
                (16 if same else 0)
            )

            if fused_relu(
                op, tflite.Conv2DOptions
            ):
                flags |= 4

            sa = (win << 16) | hin
            sb = (
                (kw << 24)
                | (kh << 16)
                | cin
            )

            sc = (
                (pl << 24)
                | (pt << 16)
                | (sw << 8)
                | sh
            )

            opcode = OP_CONV

        else:
            ws = tensor_shape(tw)

            if (
                len(ws) != 2
                or len(tensor_shape(tx)) < 2
            ):
                raise ValueError(
                    "Unexpected FC dimensions"
                )

            n = int(ws[0])
            k = int(ws[1])
            fc_layout = plan_fc_layout(
                1, n, k, rows=PE_ROWS, cols=PE_COLS,
                output_element_bytes=1,
            )
            m = fc_layout['physical_m']

            if (
                int(np.prod(tensor_shape(tx)))
                != k
            ):
                raise ValueError(
                    "FC K inconsistent"
                )
            if int(np.prod(tensor_shape(ty))) != n:
                raise ValueError("FC output element count inconsistent")

            flags = 1 | 2 | 8

            if fused_relu(
                op, tflite.FullyConnectedOptions
            ):
                flags |= 4

            # The batch-1 vector is produced at runtime, commonly by GAP.
            # A zero row stride makes every physical lane read that same real
            # vector. Only output row 0 is logically visible; no fake input
            # row or runtime copy is needed.
            sa = 0
            sb = fc_layout['b_stride_bytes']
            sc = fc_layout['c_stride_bytes']

            opcode = OP_GEMM

        sweight, zweight = qscale(tw)

        if any(z != 0 for z in zweight):
            raise ValueError(
                "Only symmetric int8 weights supported"
            )

        if len(sweight) not in (1, n):
            raise ValueError(
                f"Unexpected per-channel scales "
                f"count {len(sweight)}"
            )

        if bias_id >= 0:
            bias = self.tensor_array(
                bias_id, np.int32
            ).reshape(-1).astype(np.int64)

            if bias.size != n:
                raise ValueError(
                    "Bias channels mismatch"
                )
        else:
            bias = np.zeros(
                n, dtype=np.int64
            )

        padded_n = align(n, PE_COLS)
        row_stride = align(k, 8)
        weight_data = weight.reshape(n, k).tobytes()

        if kind == "fc":
            padded_n = fc_layout['physical_n']
            weightbuf = pack_fc_weights(weight_data, fc_layout)
            requant = [quant_mr(
                input_scale * sweight[c if len(sweight) > 1 else 0]
                / out_scale
            ) for c in range(n)]
            parambuf = pack_fc_params(
                weight_data, bias.tolist(), fc_layout,
                input_zero_point=int(input_zp),
                output_zero_point=int(out_zp), requant=requant,
            )
        else:
            qweights = weight.reshape(n, k).astype(np.int64)
            folded_bias = bias - int(input_zp) * qweights.sum(axis=1)
            if np.any((folded_bias < -2147483648) |
                      (folded_bias > 2147483647)):
                raise OverflowError("Folded INT32 bias overflow")
            weightbuf = bytearray(padded_n * row_stride)
            for c in range(n):
                begin = c * row_stride
                weightbuf[begin:begin + k] = weight.reshape(n, k)[c].tobytes()

            parambuf = bytearray(words(0, 0, input_zp, out_zp))
            for c in range(padded_n):
                if c < n:
                    r = (input_scale
                         * sweight[c if len(sweight) > 1 else 0]
                         / out_scale)
                    mul, shift = quant_mr(r)
                    biasc = int(folded_bias[c])
                else:
                    mul, shift, biasc = 0, 0, 0
                parambuf += words(biasc, mul, shift)

        baddr = self.mem.put(weightbuf)
        paddr = self.mem.put(parambuf)
        if kind == "fc":
            if output_id in self.address:
                raise ValueError(f"Output tensor {output_id} already allocated")
            caddr = self.mem.reserve(fc_layout['c_bytes'])
            self.address[output_id] = caddr
            self.fc_layouts[output_id] = fc_layout
        else:
            caddr = self.output_addr(output_id)

        # Conv activations are tightly packed logical HWC tensors. The native
        # tail masks handle partial M/N tiles; declaring padded N here would
        # change the pixel stride and overwrite the logical output allocation.
        # FC retains its published physical row/column layout and extraction.
        descriptor_n = padded_n if kind == "fc" else n
        dataflow, dataflow_flag = (
            self.select_dataflow(
                m,
                descriptor_n,
                k,
                self.dataflow,
            )
        )

        flags |= dataflow_flag

        self.encode(
            opcode,
            flags,
            m,
            descriptor_n,
            k,
            self.address[src],
            baddr,
            caddr,
            sa,
            sb,
            sc,
            paddr,
        )

        layer = {
            "opcode": kind.upper(),
            "input": src,
            "output": output_id,
            "shape": tensor_shape(ty),
            "a": self.address[src],
            "b": baddr,
            "c": caddr,
            "params": paddr,
            "flags": flags,
            "dataflow": dataflow,
            "input_zp": input_zp,
            "output_zp": out_zp,
        }
        if kind == "fc":
            layer.update(
                fc_layout=fc_layout,
                input_row_policy="repeat_logical_row",
                actual_a_stride_bytes=sa,
                input_read_span_bytes=align(k, 8),
                logical_output_bytes=n,
                physical_output_bytes=fc_layout['c_bytes'],
                c_stride_bytes=sc,
            )
        self.layers.append(layer)

    def compile_add(self, op):
        a = int(op.Inputs(0))
        b = int(op.Inputs(1))
        out = int(op.Outputs(0))

        ta, tb, to = (
            self.tensors[i]
            for i in (a, b, out)
        )

        if (
            tensor_shape(ta) != tensor_shape(tb)
            or tensor_shape(tb) != tensor_shape(to)
        ):
            raise ValueError(
                "No broadcasting supported for ResidualAdd"
            )

        sa, za = scale_1(ta)
        sb, zb = scale_1(tb)
        so, zo = scale_1(to)

        ra = sa / so
        rb = sb / so

        if not all(
            math.isfinite(r) and r >= 0
            for r in (ra, rb)
        ):
            raise ValueError(
                "Invalid ResidualAdd scale ratio"
            )

        max_multiplier = (1 << 31) - 1
        max_int64 = (1 << 63) - 1
        max_centered = 255

        for shift in range(62, -1, -1):
            ma = round(ra * (1 << shift))
            mb = round(rb * (1 << shift))

            if not (
                0 <= ma <= max_multiplier
                and 0 <= mb <= max_multiplier
            ):
                continue

            rounding_offset = (
                (1 << (shift - 1))
                if shift else 0
            )

            max_product = (
                max_centered * (ma + mb)
            )

            if (
                max_product + rounding_offset
                > max_int64
            ):
                continue

            break
        else:
            raise ValueError(
                "No safe ResidualAdd fixed-point representation"
            )

        parambuf = words(
            za, zb, zo, ma, mb, shift
        )

        paddr = self.mem.put(parambuf)
        caddr = self.output_addr(out)

        elements = int(
            np.prod(tensor_shape(to))
        )

        if elements % 4:
            raise ValueError(
                "ResidualAdd tensor elements must be multiple 4"
            )

        flags = (
            1 if fused_relu(
                op, tflite.AddOptions
            ) else 0
        )

        self.encode(
            OP_ADD,
            flags,
            elements,
            0,
            0,
            self.address[a],
            self.address[b],
            caddr,
            0,
            0,
            0,
            paddr,
        )

        self.layers.append({
            "opcode": "ADD",
            "input_a": a,
            "input_b": b,
            "output": out,
            "shape": tensor_shape(to),
            "a": self.address[a],
            "b": self.address[b],
            "c": caddr,
            "params": paddr,
            "flags": flags,
        })

    def compile_average(self, op):
        src = int(op.Inputs(0))
        out = int(op.Outputs(0))

        tx = self.tensors[src]
        ty = self.tensors[out]

        shape = tensor_shape(tx)
        shape_out = tensor_shape(ty)

        if (
            len(shape) != 4
            or shape[0] != 1
            or len(shape_out) != 4
            or shape_out[:3] != [1, 1, 1]
            or shape_out[3] != shape[3]
        ):
            raise ValueError(
                "Only global average pool supported"
            )

        if scale_1(tx) != scale_1(ty):
            raise ValueError(
                "TFLite AVG scales/zero points must match"
            )

        _, h, w, c = shape

        opts = options(op, tflite.Pool2DOptions)
        kh, kw = int(opts.FilterHeight()), int(opts.FilterWidth())
        sh, sw = int(opts.StrideH()), int(opts.StrideW())
        padding = int(opts.Padding())
        if (h <= 0 or w <= 0 or kh != h or kw != w
                or sh <= 0 or sw <= 0):
            raise ValueError(
                "Global average pool must cover the complete input height/width"
            )
        if padding == int(tflite.Padding.SAME):
            # SAME is equivalent to global averaging only when its single
            # output window covers the complete input without padded samples.
            if (h+sh-1)//sh != 1 or (w+sw-1)//sw != 1:
                raise ValueError("Average pool geometry is not global")
        elif padding != int(tflite.Padding.VALID):
            raise ValueError("Unknown average pool padding")
        if int(opts.FusedActivationFunction()) != 0:
            raise NotImplementedError(
                "Global average pool fused activation is not supported"
            )

        if c % 4:
            raise ValueError(
                "Global avg channels not multiple 4"
            )

        caddr = self.output_addr(out)

        self.encode(
            OP_AVG,
            0,
            h,
            w,
            c,
            self.address[src],
            0,
            caddr,
        )

        self.layers.append({
            "opcode": "GLOBAL_AVG",
            "input": src,
            "output": out,
            "shape": shape_out,
            "a": self.address[src],
            "c": caddr,
        })

    def compile(self):
        enum = tflite.BuiltinOperator

        codes = {
            enum.CONV_2D: "conv",
            enum.ADD: "add",
            enum.AVERAGE_POOL_2D: "avg",
            enum.FULLY_CONNECTED: "fc",
            enum.RESHAPE: "reshape",
            enum.SOFTMAX: "softmax",
        }

        for i in range(
            self.graph.OperatorsLength()
        ):
            op = self.graph.Operators(i)

            code = int(
                self.model.OperatorCodes(
                    op.OpcodeIndex()
                ).BuiltinCode()
            )

            name = codes.get(code)

            if name is None:
                raise NotImplementedError(
                    "Unsupported TFLite operator: "
                    f"index={i} code={code}"
                )

            if name in ("conv", "fc"):
                self.compile_conv_or_fc(op, name)

            elif name == "add":
                self.compile_add(op)

            elif name == "avg":
                self.compile_average(op)

            elif name == "reshape":
                a = int(op.Inputs(0))
                b = int(op.Outputs(0))

                size_a = int(
                    np.prod(
                        tensor_shape(self.tensors[a])
                    )
                )

                size_b = int(
                    np.prod(
                        tensor_shape(self.tensors[b])
                    )
                )

                if size_a != size_b:
                    raise ValueError(
                        "Reshape element count changed"
                    )

                self.address[b] = self.address[a]
                if a in self.fc_layouts:
                    self.fc_layouts[b] = self.fc_layouts[a]

                self.layers.append({
                    "opcode": "RESHAPE_ALIAS",
                    "input": a,
                    "output": b,
                })

            else:
                self.logits_tid = int(
                    op.Inputs(0)
                )

                self.layers.append({
                    "opcode": "SOFTMAX_BYPASS_ARGMAX",
                    "input": self.logits_tid,
                    "output": int(op.Outputs(0)),
                })

        if self.logits_tid is None:
            self.logits_tid = int(
                self.graph.Outputs(0)
            )

    def save(self, outdir):
        outdir.mkdir(
            parents=True,
            exist_ok=True,
        )

        descbytes = b"".join(
            words(*d)
            for d in self.desc
        )

        daddr = self.mem.put(descbytes)

        (outdir / "ddr.bin").write_bytes(
            self.mem.raw
        )

        (outdir / "descriptors.bin").write_bytes(
            descbytes
        )

        raw = self.mem.raw

        raw += b"\0" * (
            align(len(raw), 4) - len(raw)
        )

        (outdir / "ddr.hex").write_text(
            "".join(
                f'{int.from_bytes(raw[i:i+4], "little"):08x}\n'
                for i in range(0, len(raw), 4)
            )
        )

        manifest = {
            "model": (
                "MLPerf Tiny pretrainedResnet_quant.tflite"
            ),
            "dataflow_preference": self.dataflow,
            "input_shape": self.input_shape,
            "input_scale_zp": scale_1(
                self.input_tensor
            ),
            "input_addr": self.address[
                self.input_tid
            ],
            "descriptor_addr": daddr,
            "descriptor_count": len(self.desc),
            "logits_addr": self.address[
                self.logits_tid
            ],
            "logits_shape": tensor_shape(
                self.tensors[self.logits_tid]
            ),
            "memory_size": len(raw),
            "layers": self.layers,
        }
        if self.logits_tid in self.fc_layouts:
            manifest['logits_layout'] = self.fc_layouts[self.logits_tid]
            manifest['logits_logical_bytes'] = int(np.prod(
                tensor_shape(self.tensors[self.logits_tid])
            ))
            manifest['logits_read_policy'] = (
                'Read only the logical classes from physical row 0; '
                'ignore padded columns and all additional physical rows'
            )

        (outdir / "manifest.json").write_text(
            json.dumps(manifest, indent=2)
        )

        print(
            json.dumps(
                {
                    k: v
                    for k, v in manifest.items()
                    if k != "layers"
                },
                indent=2,
            )
        )

        print(
            f"Compiled {len(self.desc)} "
            f"hardware descriptors; output: {outdir}"
        )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()

    ap.add_argument(
        "model",
        type=Path,
    )

    ap.add_argument(
        "--output",
        type=Path,
        default=Path("build/resnet8_model"),
    )

    ap.add_argument(
        "--input-npy",
        type=Path,
        help=(
            "Optional CIFAR-10 32x32x3 input, "
            "uint8 or quantized int8"
        ),
    )

    ap.add_argument(
        "--dataflow",
        choices=("a", "b", "auto"),
        default=os.environ.get(
            "NPU_DATAFLOW", "auto"
        ).strip().lower(),
    )

    ns = ap.parse_args()

    compiler = Compiler(
        ns.model.read_bytes(),
        dataflow=ns.dataflow,
    )

    if ns.input_npy is not None:
        raw = np.load(ns.input_npy)

        if raw.shape == tuple(
            compiler.input_shape
        ):
            raw = raw.reshape(
                compiler.input_shape[1:]
            )

        if raw.shape != tuple(
            compiler.input_shape[1:]
        ):
            raise ValueError(
                f"Input shape {raw.shape} != "
                f"{compiler.input_shape[1:]}"
            )

        if raw.dtype == np.int8:
            q = raw

        elif raw.dtype == np.uint8:
            scale, zp = scale_1(
                compiler.input_tensor
            )

            q = np.clip(
                np.rint(
                    raw.astype(np.float64)
                    / scale + zp
                ),
                -128,
                127,
            ).astype(np.int8)

        else:
            raise ValueError(
                "Input dtype must be uint8 "
                "or quantized int8"
            )

        addr = compiler.address[
            compiler.input_tid
        ]

        compiler.mem.raw[
            addr:addr + q.size
        ] = q.tobytes()

    compiler.compile()
    compiler.save(ns.output)
