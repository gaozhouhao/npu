"""Explicit single-sample FC -> HWC reshape -> VALID MaxPool builders.

The reshape is model metadata, never inferred from the FC output count. Input
and weights retain the ordinary FC packing. Only the fused C allocation and
parameter header differ. No numeric library or model parser is required; this
module works with Python 2.7 and Python 3.
"""
from __future__ import print_function

import struct

from fc_layout import _integer, _require, plan_fc_layout, pack_fc_params


FUSE_FC_POOL = 128


def _pool_fields(pool_config):
    _integer(pool_config, 0, 2**32-1, 'Pooling configuration')
    if pool_config == 0:
        return 2, 2, 2, 2
    fields = tuple((pool_config >> (8*i)) & 255 for i in range(4))
    _require(all(fields), 'Pooling kernel and stride fields must be nonzero')
    return fields


def plan_fc_pool_layout(k, reshape_shape, logical_batch=1, rows=4, cols=4,
                        pool_config=0, pool_padding=0, pool_line_words=1024,
                        per_channel=True, tile_count_width=16, k_tile_size=256):
    """Plan one INT8 FC output vector reshaped to explicit (H,W,C).

    fc_layout is the existing full-tile input/weight layout and can be passed
    to pack_fc_input/pack_fc_weights. Allocate C with this plan's c_bytes,
    NOT fc_layout['c_bytes']: only the pooled real sample is written.
    """
    _require(isinstance(reshape_shape, (tuple, list)) and len(reshape_shape) == 3,
             'FC pooling requires an explicit (height,width,channels) shape')
    h, w, channels = reshape_shape
    for name, value in [('height', h), ('width', w), ('channels', channels),
                        ('rows', rows), ('cols', cols), ('k', k),
                        ('pool_line_words', pool_line_words)]:
        _integer(value, 1, 2**32-1, name)
    _integer(logical_batch, 1, 1, 'FC pooling logical batch')
    _integer(pool_padding, 0, 0, 'FC pooling padding (VALID only)')
    _integer(tile_count_width, 1, 32, 'FC tile count width')
    _integer(k_tile_size, 8, 2**32-1, 'FC K tile size')
    _require(k_tile_size % 8 == 0, 'FC K tile size must keep DMA offsets 8-byte aligned')
    _require(type(per_channel) is bool, 'per_channel must be a boolean')
    _require(cols >= 4 and cols % 4 == 0,
             'FC pooling requires four-channel PE groups')
    _require(channels >= cols and channels % cols == 0,
             'FC reshape channels must contain complete PE column tiles')
    kh, kw, sh, sw = _pool_fields(pool_config)
    _require(h >= kh and w >= kw, 'Pooling kernel exceeds FC reshape shape')
    oh, ow = (h-kh)//sh+1, (w-kw)//sw+1
    required_words = kh*w*(channels//4)
    _require(required_words <= pool_line_words,
             'Fused FC pooling full-channel raw-input line buffer capacity exceeded')
    n = h*w*channels
    _integer(n, 1, 2**32-1, 'FC reshape element count')
    # The scheduler stores a count, not just the highest tile index. A count
    # of 2**width would truncate to zero even though N itself fits uint32.
    n_tile_count = n//cols
    _require(n_tile_count <= (1 << tile_count_width)-1,
             'FC output tile count exceeds hardware counter width')
    # RTL widens the ceiling addition; validate the resulting stored count.
    k_tile_count = (k+k_tile_size-1)//k_tile_size
    _require(k_tile_count <= (1 << tile_count_width)-1,
             'FC K tile count exceeds hardware counter width')
    fc = plan_fc_layout(1, n, k, rows, cols, output_element_bytes=1)
    return dict(schema_version=1, fc_layout=fc,
                reshape_shape=[h, w, channels], logical_batch=logical_batch,
                pool_config=pool_config, pool_padding=pool_padding,
                pool_output_shape=[oh, ow, channels],
                tile_count_width=tile_count_width, n_tile_count=n_tile_count,
                k_tile_size=k_tile_size, k_tile_count=k_tile_count,
                pool_line_words=pool_line_words, pool_required_line_words=required_words,
                per_channel=per_channel, a_bytes=fc['a_bytes'], b_bytes=fc['b_bytes'],
                c_bytes=oh*ow*channels, param_bytes=32+n*(12 if per_channel else 4))


def _check_plan(plan):
    fc = plan['fc_layout']
    expected = plan_fc_pool_layout(
        fc['k'], plan['reshape_shape'], plan['logical_batch'], fc['rows'], fc['cols'],
        plan['pool_config'], plan['pool_padding'], plan['pool_line_words'],
        plan['per_channel'], plan['tile_count_width'], plan['k_tile_size'])
    _require(all(plan.get(key) == value for key, value in expected.items()),
             'FC pooling plan fields are inconsistent')


def pack_fc_pool_params(weight_data, bias, plan, input_zero_point=0,
                        output_zero_point=0, requant=None, global_requant=None):
    """Emit the 32-byte fused header followed by bias or channel records.

    per_channel=True requires N (M,R) pairs in requant. Otherwise supply one
    global_requant=(M,R); records then contain only signed INT32 biases.
    The old header words and folded-bias arithmetic keep their FC meaning.
    """
    _check_plan(plan)
    fc = plan['fc_layout']
    if plan['per_channel']:
        _require(requant is not None and global_requant is None,
                 'Per-channel FC pooling requires only channel requantization pairs')
        pairs = requant
    else:
        _require(requant is None and isinstance(global_requant, (tuple, list)) and
                 len(global_requant) == 2,
                 'Per-tensor FC pooling requires only one global requantization pair')
        pairs = [global_requant]*fc['logical_n']
    # Reuse all legacy payload, zero-point, bias folding, coefficient and
    # signed INT64 safety checks before inserting the shape extension.
    ordinary = pack_fc_params(weight_data, bias, fc, input_zero_point,
                              output_zero_point, requant=pairs)
    if not plan['per_channel']:
        biases = b''.join(ordinary[16+12*c:20+12*c]
                          for c in range(fc['physical_n']))
        ordinary = struct.pack('<2I', *global_requant)+ordinary[8:16]+biases
    shape = struct.pack('<4I', *(plan['reshape_shape']+[plan['logical_batch']]))
    packed = ordinary[:16]+shape+ordinary[16:]
    _require(len(packed) == plan['param_bytes'], 'FC pooling parameter size mismatch')
    return packed


def make_fc_pool_descriptor(plan, a, b, c, param, relu=False):
    """Build OP_GEMM + bit7, keeping original FC strides and pooled C size."""
    _check_plan(plan)
    fc = plan['fc_layout']
    for name, address, size, alignment in [
            ('A', a, plan['a_bytes'], 8), ('B', b, plan['b_bytes'], 8),
            ('C', c, plan['c_bytes'], 4),
            ('parameters', param, plan['param_bytes'], 4)]:
        _integer(address, 0, 2**64-1, name+' address')
        _require(address % alignment == 0, name+' address is unaligned')
        _require(address+size <= 2**64, name+' allocation exceeds address range')
    flags = FUSE_FC_POOL | 1 | 2 | (8 if plan['per_channel'] else 0) | (4 if relu else 0)
    return dict(opcode=1, flags=flags, m=fc['physical_m'], n=fc['physical_n'], k=fc['k'],
                a=a, b=b, c=c, param=param,
                words10_12=[fc['a_stride_bytes'], fc['b_stride_bytes'],
                            fc['c_stride_bytes']], pool_config=plan['pool_config'])
