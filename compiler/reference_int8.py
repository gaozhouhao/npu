"""Independent, standard-library descriptor interpreter for the NPU ABI.

Reads the emitted DDR image and 64-byte descriptors, with no graph/compiler
numeric helpers. Python 2.7 and Python 3 are supported. This models values and
memory writes; it does not predict timing or model external AXI transactions.
"""
from __future__ import print_function
import struct


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _signed(value, bits):
    value &= (1 << bits)-1
    return value-(1 << bits) if value & (1 << (bits-1)) else value


def _saturate(value):
    return min(127, max(-128, value))


def _round_shift(value, shift):
    _require(0 <= shift <= 62, 'Invalid requantization shift')
    if not shift:
        return value
    magnitude = (abs(value)+(1 << (shift-1))) >> shift
    return -magnitude if value < 0 else magnitude


def _round_divide(value, divisor):
    _require(divisor > 0, 'Invalid average divisor')
    magnitude = (abs(value)+divisor//2)//divisor
    return -magnitude if value < 0 else magnitude


def _pool_geometry(config):
    if config == 0:
        return 2, 2, 2, 2
    result = tuple((config >> (8*i)) & 255 for i in range(4))
    _require(all(result), 'Zero MaxPool kernel/stride')
    return result


def _max_pool(values, height, width, channels, config, padding=0):
    kh, kw, sh, sw = _pool_geometry(config)
    pt, pl, pb, pr = tuple((padding >> (8*i)) & 255 for i in range(4))
    _require(pt < kh and pb < kh and pl < kw and pr < kw,
             'MaxPool padding exceeds kernel')
    _require(height+pt+pb >= kh and width+pl+pr >= kw,
             'MaxPool kernel exceeds padded input')
    oh, ow = (height+pt+pb-kh)//sh+1, (width+pl+pr-kw)//sw+1
    output = []
    for y in range(oh):
        for x in range(ow):
            samples = [((yy*width+xx)*channels)
                       for yy in range(max(0, y*sh-pt), min(height, y*sh-pt+kh))
                       for xx in range(max(0, x*sw-pl), min(width, x*sw-pl+kw))]
            _require(samples, 'MaxPool window contains no real input')
            output.extend(max(values[base+c] for base in samples) for c in range(channels))
    return output, [oh, ow, channels]


def execute(image, commands):
    """Return (final DDR bytearray, per-command output traces).

    Each trace contains index, opcode, output_address, shape and flat signed
    values. Padding bytes outside each logical output remain unchanged. All
    source accesses and writes are checked against the actual image length.
    """
    memory, traces = bytearray(image), []
    _require(len(commands) > 0 and len(commands) % 64 == 0,
             'Descriptor bytes must be a positive multiple of 64')

    def check(address, count):
        _require(0 <= address <= len(memory) and 0 <= count <= len(memory)-address,
                 'Descriptor memory access outside DDR image')

    def read8(address):
        check(address, 1)
        return _signed(memory[address], 8)

    def read32(address, signed=False):
        check(address, 4)
        return struct.unpack_from('<i' if signed else '<I', memory, address)[0]

    def read_values(address, count):
        check(address, count)
        return [_signed(value, 8) for value in memory[address:address+count]]

    def write_values(address, values, int8=True):
        if int8:
            check(address, len(values))
            memory[address:address+len(values)] = bytearray(value & 255 for value in values)
        else:
            check(address, 4*len(values))
            for lane, value in enumerate(values):
                struct.pack_into('<i', memory, address+4*lane, _signed(value, 32))

    for index in range(len(commands)//64):
        words = struct.unpack_from('<16I', commands, index*64)
        opcode, flags = words[0] & 255, words[0] >> 8
        m, n, k = words[1:4]
        a, b, c = [words[offset] | (words[offset+1] << 32) for offset in (4, 6, 8)]
        geometry, kernel, spatial = words[10:13]
        param = words[13] | (words[14] << 32)
        pool_config = words[15]
        _require(opcode in (1, 2, 3, 4, 5), 'Unsupported descriptor opcode')
        if opcode in (1, 2):
            _require(m > 0 and n > 0 and k > 0, 'Empty GEMM/Conv dimension')
            bias_en, requant, relu, per_channel = [bool(flags & bit) for bit in (1, 2, 4, 8)]
            fused = bool(flags & 128)
            _require(not (relu or per_channel or fused) or requant,
                     'Postprocessing requires requantization')
            multiplier, shift, input_zp, output_zp = 0, 0, 0, 0
            if requant:
                multiplier, shift = read32(param), read32(param+4)
                _require(multiplier < 2**31 and shift <= 62, 'Invalid global requantization')
                # The loader reads the two ZPs only for per-channel or FC-pool headers.
                if per_channel or (opcode == 1 and fused):
                    input_zp, output_zp = read32(param+8, True), read32(param+12, True)
                    _require(-128 <= input_zp <= 127 and -128 <= output_zp <= 127,
                             'Invalid signed INT8 zero point')
            header_bytes = 32 if opcode == 1 and fused else 16
            biases, multipliers, shifts = [], [], []
            for channel in range(n):
                if per_channel:
                    offset = param+header_bytes+12*channel
                    biases.append(read32(offset, True) if bias_en else 0)
                    mult, amount = read32(offset+4), read32(offset+8)
                    _require(mult < 2**31 and amount <= 62, 'Invalid per-channel requantization')
                    multipliers.append(mult)
                    shifts.append(amount)
                else:
                    biases.append(read32(param+header_bytes+4*channel, True) if bias_en else 0)
                    multipliers.append(multiplier)
                    shifts.append(shift)
            if opcode == 2:
                height, width = geometry & 65535, geometry >> 16
                channels, kh, kw = kernel & 65535, (kernel >> 16) & 255, kernel >> 24
                sh, sw, pt, pl = [(spatial >> (8*i)) & 255 for i in range(4)]
                _require(min(height, width, channels, kh, kw) > 0 and sh in (1, 2) and sw in (1, 2),
                         'Invalid Conv geometry')
                if flags & 16:
                    oh, ow = (height+sh-1)//sh, (width+sw-1)//sw
                else:
                    _require(height+2*pt >= kh and width+2*pl >= kw,
                             'Conv kernel exceeds padded input')
                    oh, ow = (height+2*pt-kh)//sh+1, (width+2*pl-kw)//sw+1
                _require(m == oh*ow and k == kh*kw*channels, 'Conv M/K geometry mismatch')
                b_stride, c_stride = (k+7)//8*8, n*(1 if requant else 4)
                shape = [oh, ow, n]
            else:
                a_stride, b_stride, c_stride = geometry, kernel, spatial
                shape = [m, n]
            # Snapshot logical inputs and weights before writes. This mirrors
            # supported separate tensor allocations, not arbitrary in-place GEMM.
            weights = [read_values(b+channel*b_stride, k) for channel in range(n)]
            outputs = []
            for row in range(m):
                if opcode == 2:
                    y, x = divmod(row, ow)
                    inputs = []
                    for ky in range(kh):
                        yy = y*sh-pt+ky
                        for kx in range(kw):
                            xx = x*sw-pl+kx
                            if 0 <= yy < height and 0 <= xx < width:
                                inputs.extend(read_values(a+(yy*width+xx)*channels, channels))
                            else:
                                inputs.extend([input_zp if requant else 0]*channels)
                else:
                    inputs = read_values(a+row*a_stride, k)
                for channel in range(n):
                    raw = _signed(sum(value*weight for value, weight in zip(inputs, weights[channel])), 32)
                    biased = raw+biases[channel]  # RTL retains a signed 33-bit bias sum.
                    if requant:
                        product = _signed(biased*multipliers[channel], 64)
                        value = _signed(_round_shift(product, shifts[channel])+output_zp, 64)
                        if relu:
                            value = max(output_zp, value)
                        value = _saturate(value)
                    else:
                        value = _signed(biased, 32)
                    outputs.append(value)
            if fused:
                if opcode == 1:
                    height, width, channels, batch = [read32(param+offset) for offset in (16, 20, 24, 28)]
                    _require(batch == 1 and height*width*channels == n,
                             'Invalid fused FC reshape')
                    outputs = outputs[:n]  # Only the real batch-1 FC row is pooled.
                else:
                    height, width, channels = oh, ow, n
                outputs, shape = _max_pool(outputs, height, width, channels, pool_config)
                write_values(c, outputs)
            else:
                for row in range(m):
                    write_values(c+row*c_stride, outputs[row*n:(row+1)*n], requant)
        elif opcode == 3:
            _require(m > 0 and n > 0 and k > 0 and k % 4 == 0, 'Invalid MaxPool dimensions')
            outputs, shape = _max_pool(read_values(a, m*n*k), m, n, k, pool_config, geometry)
            write_values(c, outputs)
        elif opcode == 4:
            _require(m > 0 and n > 0 and k > 0 and k % 4 == 0, 'Invalid GAP dimensions')
            _require(m*n <= 16777215, 'GAP sum would exceed hardware capacity')
            outputs = []
            for channel in range(k):
                total = _signed(sum(read8(a+pixel*k+channel) for pixel in range(m*n)), 32)
                outputs.append(_saturate(_round_divide(total, m*n)))
            shape = [1, 1, k]
            write_values(c, outputs)
        else:
            _require(m > 0 and m % 4 == 0 and n == 0 and k == 0, 'Invalid Add dimensions')
            za, zb, zc = [read32(param+offset, True) for offset in (0, 4, 8)]
            ma, mb, shift = [read32(param+offset) for offset in (12, 16, 20)]
            _require(all(-128 <= zp <= 127 for zp in (za, zb, zc)) and shift <= 62 and
                     ma < 2**31 and mb < 2**31,
                     'Invalid Add zero points/shift')
            inputs_a, inputs_b = read_values(a, m), read_values(b, m)
            outputs = []
            for avalue, bvalue in zip(inputs_a, inputs_b):
                total = _signed((avalue-za)*ma+(bvalue-zb)*mb, 64)
                value = _signed(_round_shift(total, shift)+zc, 64)
                if flags & 1:
                    value = max(zc, value)
                outputs.append(_saturate(value))
            shape = [m]
            write_values(c, outputs)
        traces.append(dict(index=index, opcode=opcode, output_address=c,
                           shape=shape, values=outputs))
    return memory, traces
