"""Integer NumPy descriptor interpreter for practical full-network checking.

This reads only serialized DDR/descriptor bytes and shares no numerical helpers
with the compiler. Matrix products use INT64, then wrap to the hardware's INT32
accumulator before its signed 33-bit bias addition. Im2col and products are
chunked; no floating-point arithmetic or cross-command feature cache is used.
The optional callback permits streaming layer checks without retaining traces.
"""
from __future__ import print_function

import struct

import numpy as np


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _round_shift(values, shifts):
    """Signed magnitude rounding, including negative half ties, without overflow."""
    values = np.asarray(values, dtype=np.int64)
    shifts = np.asarray(shifts, dtype=np.int64)
    _require(bool(np.all((shifts >= 0) & (shifts <= 62))),
             'Invalid requantization shift')
    bits = values.astype(np.uint64)
    magnitudes = np.where(values < 0, ~bits + np.uint64(1), bits)
    amounts = shifts.astype(np.uint64)
    halves = np.left_shift(np.uint64(1), np.maximum(shifts-1, 0).astype(np.uint64))
    halves = np.where(shifts > 0, halves, np.uint64(0))
    rounded = np.right_shift(magnitudes + halves, amounts).astype(np.int64)
    return np.where(values < 0, -rounded, rounded)


def execute(image, commands, max_workspace_bytes=16*1024*1024,
            trace_callback=None, retain_traces=True):
    """Return (final DDR bytearray, traces), like reference_int8.execute.

    Each trace has index/opcode/output_address/shape/flat signed values. Set
    retain_traces=False and provide trace_callback(trace) to consume one layer
    at a time. max_workspace_bytes bounds im2col/product work chunks (one row
    is the minimum), excluding DDR, weights, logical inputs and output traces.
    Fused pooling commands are deliberately rejected; ResNet50 uses independent
    layer commands and stores every boundary in DDR.
    """
    memory, traces = bytearray(image), []
    _require(len(commands) > 0 and len(commands) % 64 == 0,
             'Descriptor bytes must be a positive multiple of 64')
    _require(isinstance(max_workspace_bytes, int) and max_workspace_bytes > 0,
             'Workspace size must be a positive integer')

    def check(address, count):
        _require(0 <= address <= len(memory) and 0 <= count <= len(memory)-address,
                 'Descriptor memory access outside DDR image')

    def read32(address, signed=False):
        check(address, 4)
        return struct.unpack_from('<i' if signed else '<I', memory, address)[0]

    def read_values(address, count):
        check(address, count)
        return np.frombuffer(memory, dtype=np.int8, count=count, offset=address).copy()

    def read_rows(address, rows, count, stride):
        check(address, (rows-1)*stride+count)
        return np.ndarray((rows, count), dtype=np.int8, buffer=memory,
                          offset=address, strides=(stride, 1)).astype(np.int64)

    def write_values(address, values, int8=True):
        payload = np.asarray(values).astype(np.int8 if int8 else np.dtype('<i4')).tobytes()
        check(address, len(payload))
        memory[address:address+len(payload)] = payload

    for index in range(len(commands)//64):
        words = struct.unpack_from('<16I', commands, index*64)
        opcode, flags = words[0] & 255, words[0] >> 8
        m, n, k = words[1:4]
        a, b, c = [words[offset] | words[offset+1] << 32 for offset in (4, 6, 8)]
        geometry, kernel, spatial = words[10:13]
        param = words[13] | words[14] << 32
        pool_config = words[15]
        _require(opcode in (1, 2, 3, 4, 5), 'Unsupported descriptor opcode')
        if opcode in (1, 2):
            _require(m > 0 and n > 0 and k > 0, 'Empty GEMM/Conv dimension')
            bias_en, requant, relu, per_channel = [bool(flags & bit) for bit in (1, 2, 4, 8)]
            _require(not flags & 128, 'Fused pooling is not supported by the NumPy reference')
            _require(not (relu or per_channel) or requant,
                     'Postprocessing requires requantization')
            multiplier, shift, input_zp, output_zp = 0, 0, 0, 0
            if requant:
                multiplier, shift = read32(param), read32(param+4)
                _require(multiplier < 2**31 and shift <= 62, 'Invalid global requantization')
                if per_channel:
                    input_zp, output_zp = read32(param+8, True), read32(param+12, True)
                    _require(-128 <= input_zp <= 127 and -128 <= output_zp <= 127,
                             'Invalid signed INT8 zero point')
            biases = np.zeros(n, dtype=np.int64)
            multipliers = np.full(n, multiplier, dtype=np.int64)
            shifts = np.full(n, shift, dtype=np.int64)
            for channel in range(n):
                if per_channel:
                    offset = param+16+12*channel
                    biases[channel] = read32(offset, True) if bias_en else 0
                    mult, amount = read32(offset+4), read32(offset+8)
                    _require(mult < 2**31 and amount <= 62, 'Invalid per-channel requantization')
                    multipliers[channel], shifts[channel] = mult, amount
                elif bias_en:
                    biases[channel] = read32(param+16+4*channel, True)
            if opcode == 2:
                height, width = geometry & 65535, geometry >> 16
                channels, kh, kw = kernel & 65535, kernel >> 16 & 255, kernel >> 24
                sh, sw, pt, pl = [(spatial >> (8*i)) & 255 for i in range(4)]
                _require(min(height, width, channels, kh, kw) > 0 and
                         sh in (1, 2) and sw in (1, 2), 'Invalid Conv geometry')
                if flags & 16:
                    oh, ow = (height+sh-1)//sh, (width+sw-1)//sw
                else:
                    _require(height+2*pt >= kh and width+2*pl >= kw,
                             'Conv kernel exceeds padded input')
                    oh, ow = (height+2*pt-kh)//sh+1, (width+2*pl-kw)//sw+1
                _require(m == oh*ow and k == kh*kw*channels, 'Conv M/K geometry mismatch')
                b_stride, c_stride = (k+7)//8*8, n*(1 if requant else 4)
                shape = [oh, ow, n]
                source = read_values(a, height*width*channels).reshape(height, width, channels)
                pb = max(0, (oh-1)*sh+kh-height-pt)
                pr = max(0, (ow-1)*sw+kw-width-pl)
                padded = np.full((height+pt+pb, width+pl+pr, channels),
                                 input_zp if requant else 0, dtype=np.int64)
                padded[pt:pt+height, pl:pl+width] = source
            else:
                a_stride, b_stride, c_stride = geometry, kernel, spatial
                shape = [m, n]
                source = read_rows(a, m, k, a_stride)
            weights = read_rows(b, n, k, b_stride)
            outputs = np.empty((m, n), dtype=np.int64)
            chunk_rows = max(1, max_workspace_bytes//(8*(k+4*n)))
            for start in range(0, m, chunk_rows):
                end = min(m, start+chunk_rows)
                if opcode == 2:
                    positions = np.arange(start, end)
                    yy, xx = positions//ow*sh, positions % ow*sw
                    inputs = np.empty((end-start, k), dtype=np.int64)
                    for ky in range(kh):
                        for kx in range(kw):
                            offset = (ky*kw+kx)*channels
                            inputs[:, offset:offset+channels] = padded[yy+ky, xx+kx]
                else:
                    inputs = source[start:end]
                raw = (inputs @ weights.T).astype(np.int32).astype(np.int64)
                biased = raw+biases
                if requant:
                    values = _round_shift(biased*multipliers, shifts)+output_zp
                    if relu:
                        values = np.maximum(values, output_zp)
                    outputs[start:end] = np.clip(values, -128, 127)
                else:
                    outputs[start:end] = biased.astype(np.int32).astype(np.int64)
            for row in range(m):
                write_values(c+row*c_stride, outputs[row], requant)
            outputs = outputs.reshape(-1)
        elif opcode == 3:
            _require(m > 0 and n > 0 and k > 0 and k % 4 == 0, 'Invalid MaxPool dimensions')
            kh, kw, sh, sw = ((2, 2, 2, 2) if not pool_config else
                             tuple(pool_config >> (8*i) & 255 for i in range(4)))
            _require(min(kh, kw, sh, sw) > 0, 'Zero MaxPool kernel/stride')
            pt, pl, pb, pr = tuple(geometry >> (8*i) & 255 for i in range(4))
            _require(pt < kh and pb < kh and pl < kw and pr < kw,
                     'MaxPool padding exceeds kernel')
            _require(m+pt+pb >= kh and n+pl+pr >= kw, 'MaxPool kernel exceeds padded input')
            oh, ow = (m+pt+pb-kh)//sh+1, (n+pl+pr-kw)//sw+1
            _require(all(max(0, y*sh-pt) < min(m, y*sh-pt+kh) for y in range(oh)) and
                     all(max(0, x*sw-pl) < min(n, x*sw-pl+kw) for x in range(ow)),
                     'MaxPool window contains no real input')
            source = read_values(a, m*n*k).reshape(m, n, k)
            padded = np.full((m+pt+pb, n+pl+pr, k), -128, dtype=np.int8)
            padded[pt:pt+m, pl:pl+n] = source
            pooled = np.full((oh, ow, k), -128, dtype=np.int8)
            for ky in range(kh):
                for kx in range(kw):
                    np.maximum(pooled, padded[ky:ky+oh*sh:sh, kx:kx+ow*sw:sw], out=pooled)
            outputs, shape = pooled.reshape(-1), [oh, ow, k]
            write_values(c, outputs)
        elif opcode == 4:
            _require(m > 0 and n > 0 and k > 0 and k % 4 == 0, 'Invalid GAP dimensions')
            _require(m*n <= 16777215, 'GAP sum would exceed hardware capacity')
            source = read_values(a, m*n*k).reshape(m*n, k)
            total = source.sum(axis=0, dtype=np.int64).astype(np.int32).astype(np.int64)
            magnitude = (np.abs(total)+(m*n)//2)//(m*n)
            outputs = np.clip(np.where(total < 0, -magnitude, magnitude), -128, 127)
            shape = [1, 1, k]
            write_values(c, outputs)
        else:
            _require(m > 0 and m % 4 == 0 and n == 0 and k == 0, 'Invalid Add dimensions')
            za, zb, zc = [read32(param+offset, True) for offset in (0, 4, 8)]
            ma, mb, shift = [read32(param+offset) for offset in (12, 16, 20)]
            _require(all(-128 <= zp <= 127 for zp in (za, zb, zc)) and shift <= 62 and
                     ma < 2**31 and mb < 2**31, 'Invalid Add zero points/shift')
            av = read_values(a, m).astype(np.int64)
            bv = read_values(b, m).astype(np.int64)
            outputs = _round_shift((av-za)*ma+(bv-zb)*mb, shift)+zc
            if flags & 1:
                outputs = np.maximum(outputs, zc)
            outputs, shape = np.clip(outputs, -128, 127), [m]
            write_values(c, outputs)
        if retain_traces or trace_callback is not None:
            trace = dict(index=index, opcode=opcode, output_address=c,
                         shape=shape, values=outputs.tolist())
            if trace_callback is not None:
                trace_callback(trace)
            if retain_traces:
                traces.append(trace)
    return memory, traces
