"""Physical FC layout, INT8 packing and logical output extraction.

No model parser or numeric library is required. Weights are symmetric INT8 in
output-major [N,K] order. Input/output zero points use signed INT8 encoding.
This module works with Python 2.7 and Python 3.
"""
from __future__ import print_function

import struct

try:
    INTEGER_TYPES = (int, long)
except NameError:
    INTEGER_TYPES = (int,)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _integer(value, low, high, name):
    _require(type(value) in INTEGER_TYPES and low <= value <= high,
             name + ' is outside its integer range')


def _align(value, multiple):
    return ((value + multiple - 1) // multiple) * multiple


def _payload(data, expected_bytes, name):
    _require(isinstance(data, (bytes, bytearray)), name + ' must be bytes')
    _require(len(data) == expected_bytes, name + ' byte count does not match logical shape')
    return bytes(data)


def plan_fc_layout(logical_m, logical_n, k, rows=4, cols=4,
                   output_element_bytes=4):
    """Keep logical sizes while reserving complete array tiles and DMA rows."""
    for name, value in [('logical_m', logical_m), ('logical_n', logical_n),
                        ('k', k), ('rows', rows), ('cols', cols)]:
        _integer(value, 1, 2**32-1, name)
    _require(type(output_element_bytes) in INTEGER_TYPES and
             output_element_bytes in (1, 4), 'Output elements must be INT8 or INT32')

    physical_m = _align(logical_m, rows)
    physical_n = _align(logical_n, cols)
    a_stride_bytes = _align(k, 8)
    b_stride_bytes = _align(k, 8)
    c_stride_bytes = _align(physical_n * output_element_bytes, 4)
    for value in (physical_m, physical_n, a_stride_bytes, b_stride_bytes, c_stride_bytes):
        _require(value < 2**32, 'Physical dimension or stride exceeds 32 bits')

    return dict(schema_version=1, logical_m=logical_m, logical_n=logical_n, k=k,
                physical_m=physical_m, physical_n=physical_n, rows=rows, cols=cols,
                output_element_bytes=output_element_bytes,
                a_stride_bytes=a_stride_bytes, b_stride_bytes=b_stride_bytes,
                c_stride_bytes=c_stride_bytes,
                a_bytes=physical_m*a_stride_bytes,
                b_bytes=physical_n*b_stride_bytes,
                c_bytes=physical_m*c_stride_bytes,
                logical_output_bytes=logical_m*logical_n*output_element_bytes)


def _check_layout(layout):
    expected = plan_fc_layout(layout['logical_m'], layout['logical_n'], layout['k'],
                              layout['rows'], layout['cols'], layout['output_element_bytes'])
    _require(all(layout.get(key) == value for key, value in expected.items()),
             'FC layout fields are inconsistent')


def pack_fc_input(data, layout, input_zero_point=0):
    """Copy real rows into a full allocation; dummy rows encode real zero."""
    _check_layout(layout)
    _integer(input_zero_point, -128, 127, 'Input zero point')
    m, k = layout['logical_m'], layout['k']
    data = _payload(data, m*k, 'FC input')
    packed = bytearray([input_zero_point & 255]) * layout['a_bytes']
    for row in range(m):
        begin = row * layout['a_stride_bytes']
        packed[begin:begin+k] = data[row*k:(row+1)*k]
    return bytes(packed)


def pack_fc_weights(data, layout):
    """Copy [logical_N,K] weights; dummy output channels have zero weights."""
    _check_layout(layout)
    n, k = layout['logical_n'], layout['k']
    data = _payload(data, n*k, 'FC weights')
    packed = bytearray(layout['b_bytes'])
    for channel in range(n):
        begin = channel * layout['b_stride_bytes']
        packed[begin:begin+k] = data[channel*k:(channel+1)*k]
    return bytes(packed)


def pack_fc_params(weight_data, bias, layout, input_zero_point=0,
                   output_zero_point=0, requant=None):
    """Fold input zero point into bias; pad every output-channel parameter.

    requant=None emits ordinary INT32 bias parameters. Otherwise requant holds
    one (multiplier,shift) pair per logical channel and emits INT8 per-channel
    records. Dummy INT8 channels produce output_zero_point, not necessarily 0.
    """
    _check_layout(layout)
    n, k = layout['logical_n'], layout['k']
    weight_data = _payload(weight_data, n*k, 'FC weights')
    _require(len(bias) == n, 'FC bias count must equal logical output channels')
    _integer(input_zero_point, -128, 127, 'Input zero point')
    _integer(output_zero_point, -128, 127, 'Output zero point')
    _require((requant is not None) == (layout['output_element_bytes'] == 1),
             'Requantization parameters do not match output element size')
    if requant is None:
        _require(output_zero_point == 0, 'INT32 output has no output zero point')
    else:
        _require(len(requant) == n, 'FC requantization count must equal logical channels')

    packed = bytearray(struct.pack('<4I', 0, 0, input_zero_point & 0xffffffff,
                                   output_zero_point & 0xffffffff))
    for channel in range(layout['physical_n']):
        folded_bias, multiplier, shift = 0, 0, 0
        if channel < n:
            _integer(bias[channel], -2**31, 2**31-1, 'FC bias')
            row = bytearray(weight_data[channel*k:(channel+1)*k])
            weight_sum = sum(value if value < 128 else value-256 for value in row)
            folded_bias = bias[channel] - input_zero_point * weight_sum
            _integer(folded_bias, -2**31, 2**31-1, 'Folded FC bias')
            if requant is not None:
                _require(len(requant[channel]) == 2, 'FC requantization pair is malformed')
                multiplier, shift = requant[channel]
                _integer(multiplier, 0, 2**31-1, 'FC multiplier')
                _integer(shift, 0, 62, 'FC shift')
                # Conservatively cover an INT32 accumulator plus INT32 bias
                # before the signed INT64 multiply and rounding offset.
                max_acc = 2**32
                half = (1 << (shift-1)) if shift else 0
                _require(max_acc*multiplier+half < 2**63,
                         'FC requantization may overflow signed INT64')
        packed.extend(struct.pack('<i', folded_bias))
        if requant is not None:
            packed.extend(struct.pack('<2I', multiplier, shift))
    return bytes(packed)


def make_fc_descriptor(layout, a, b, c, param, requantized=False, relu=False):
    """Generate one existing GEMM descriptor using physical M/N and strides."""
    _check_layout(layout)
    _require(bool(requantized) == (layout['output_element_bytes'] == 1),
             'Descriptor output mode does not match layout')
    _require(not relu or requantized, 'ReLU requires requantized output')
    for name, address, size, alignment in [
            ('A', a, layout['a_bytes'], 8), ('B', b, layout['b_bytes'], 8),
            ('C', c, layout['c_bytes'], 4),
            ('parameters', param, 16+layout['physical_n']*(12 if requantized else 4), 4)]:
        _integer(address, 0, 2**64-1, name + ' address')
        _require(address % alignment == 0, name + ' address is unaligned')
        _require(address+size <= 2**64, name + ' allocation exceeds address range')
    flags = 1 | (2 | 8 if requantized else 0) | (4 if relu else 0)
    return dict(opcode=1, flags=flags, m=layout['physical_m'], n=layout['physical_n'],
                k=layout['k'], a=a, b=b, c=c, param=param,
                words10_12=[layout['a_stride_bytes'], layout['b_stride_bytes'],
                            layout['c_stride_bytes']])


def extract_fc_output(data, layout):
    """Copy only logical output elements, respecting each physical row stride."""
    _check_layout(layout)
    data = _payload(data, layout['c_bytes'], 'FC output')
    logical_row_bytes = layout['logical_n'] * layout['output_element_bytes']
    return b''.join(data[row*layout['c_stride_bytes']:
                        row*layout['c_stride_bytes']+logical_row_bytes]
                    for row in range(layout['logical_m']))


def fc_argmax(data, layout):
    """Classify real rows/classes only. Dummy columns must never compete."""
    logical = extract_fc_output(data, layout)
    m, n = layout['logical_m'], layout['logical_n']
    fmt = 'b' if layout['output_element_bytes'] == 1 else 'i'
    scores = struct.unpack('<' + str(m*n) + fmt, logical)
    return [max(range(n), key=lambda col: scores[row*n+col]) for row in range(m)]
