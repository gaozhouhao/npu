"""Descriptor ABI and hardware defaults from the NPU top module."""
import hashlib
import io
import json
import os
import re
import struct
try:
    from pathlib import Path
except ImportError:
    class Path(object):
        """Small standard-library fallback for the Python 2 compiler entrypoint.

        Python 3 keeps pathlib.Path unchanged.  Only the path operations used
        by this shared ABI module are needed by the dependency-free compiler.
        """
        def __init__(self, path):
            self.path = str(path)

        def __str__(self):
            return self.path

        def __div__(self, child):
            return Path(os.path.join(self.path, str(child)))

        __truediv__ = __div__

        def resolve(self):
            return Path(os.path.realpath(self.path))

        @property
        def parent(self):
            return Path(os.path.dirname(self.path))

        def read_bytes(self):
            with open(self.path, 'rb') as handle:
                return handle.read()

        def read_text(self):
            with io.open(self.path, encoding='utf-8') as handle:
                return handle.read()

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def hardware_defaults():
    """Read architectural defaults from the single RTL configuration entrypoint."""
    text = (REPO / 'rtl/npu_top.sv').read_text()
    mappings = dict(pe_rows='ROWS', pe_cols='COLS', k_tile_size='K_TILE_SIZE',
                    a_buffer_count='A_BUFFER_COUNT', b_buffer_count='B_BUFFER_COUNT',
                    axi_data_width='MEM_WORD_WIDTH', data_width='DATA_WIDTH',
                    acc_width='ACC_WIDTH', tile_count_width='TILE_COUNT_WIDTH',
                    pool_line_words='POOL_LINE_WORDS')
    defaults = {}
    for key, param in mappings.items():
        match = re.search(r'parameter int unsigned\s+' + param + r'\s*=\s*(\d+)', text)
        require(match is not None, 'Missing npu_top parameter: {}'.format(param))
        defaults[key] = int(match.group(1))
    return defaults


def load_target(path):
    cfg = json.loads(Path(path).read_text())
    for key, default in hardware_defaults().items():
        cfg.setdefault(key, default)
        require(cfg[key] == default,
                '{}: config must match the npu_top default; overrides not audited.'.format(key))
    require(cfg['pe_rows'] == cfg['pe_cols'],
            'Compiler V0 is audited for the square default NPU configuration only.')
    require(cfg['a_buffer_count'] == cfg['b_buffer_count'],
            'Compiler V0 is audited for equal A/B buffer counts only.')
    require(cfg['activation_layout'] == 'HWC', 'conv_patch_reader requires HWC.')
    require(cfg['alignment_bytes'] >= 8 and cfg['alignment_bytes'] & (cfg['alignment_bytes']-1) == 0,
            'alignment_bytes must be a power of two >= 8 for operand DMA.')
    require(cfg['ddr_base'] == 0, 'memory.cpp uses zero-based addresses; V0 requires ddr_base=0.')
    require(isinstance(cfg['ddr_capacity_bytes'], (int, type(2**64))) and cfg['ddr_capacity_bytes'] > 0,
            'DDR capacity must be positive; initialize C++ memory to at least this capacity.')
    require(cfg['k_tile_size'] % 8 == 0, 'K tile offsets must stay 64-bit word aligned.')
    return cfg, dict(commit='working-tree')


def align(n, a=4):
    return (n+a-1)//a*a


def pack_pool_config(kernel_h=2, kernel_w=2, stride_h=2, stride_w=2):
    """Pack pooling geometry into descriptor word 15 (KH, KW, SH, SW)."""
    fields = (kernel_h, kernel_w, stride_h, stride_w)
    require(all(isinstance(x, int) and 1 <= x <= 255 for x in fields),
            'Pooling kernel and stride fields must be integers in 1..255')
    return sum(value << (8*i) for i, value in enumerate(fields))


def unpack_pool_config(pool_config=0):
    """Return KH, KW, SH, SW; zero preserves legacy 2x2, stride-2 pooling."""
    require(isinstance(pool_config, int) and 0 <= pool_config < 2**32,
            'Pooling configuration must fit unsigned 32 bits')
    if pool_config == 0:
        return 2, 2, 2, 2
    fields = tuple((pool_config >> (8*i)) & 255 for i in range(4))
    require(all(fields), 'Nonzero pooling configuration contains a zero kernel or stride')
    return fields


def pack_pool_padding(top=0, left=0, bottom=0, right=0):
    """Pack standalone MaxPool padding into word 10, low byte first: T,L,B,R."""
    fields = (top, left, bottom, right)
    require(all(isinstance(x, int) and 0 <= x <= 255 for x in fields),
            'Pooling padding fields must be integers in 0..255')
    return sum(value << (8*i) for i, value in enumerate(fields))


def unpack_pool_padding(pool_padding=0):
    """Return top, left, bottom, right; zero preserves unpadded pooling."""
    require(isinstance(pool_padding, int) and 0 <= pool_padding < 2**32,
            'Pooling padding must fit unsigned 32 bits')
    return tuple((pool_padding >> (8*i)) & 255 for i in range(4))


def pool_output_shape(height, width, pool_config=0, pool_padding=0):
    """Floor-mode MaxPool shape; each output window includes real input data."""
    kh, kw, sh, sw = unpack_pool_config(pool_config)
    pt, pl, pb, pr = unpack_pool_padding(pool_padding)
    require(all(isinstance(x, (int, type(2**64))) and 0 < x < 2**32 for x in (height, width)),
            'Pooling input height and width must be positive unsigned 32-bit values')
    require(pt < kh and pb < kh and pl < kw and pr < kw,
            'Pooling padding must be smaller than the corresponding kernel')
    padded_h, padded_w = height+pt+pb, width+pl+pr
    require(padded_h >= kh and padded_w >= kw,
            'Pooling kernel exceeds input height or width including padding')
    oh, ow = (padded_h-kh)//sh+1, (padded_w-kw)//sw+1
    require(oh < 2**32 and ow < 2**32, 'Pooling output shape exceeds unsigned 32 bits')
    return oh, ow


def pool_line_words(height, width, channels, pool_config=0, pool_padding=0):
    """Raw input-line words for VALID pooling; padded pooling stays offline."""
    require(pool_padding == 0, 'Fused pooling does not support padding')
    kh, _, _, _ = unpack_pool_config(pool_config)
    pool_output_shape(height, width, pool_config)
    require(channels > 0 and channels % 4 == 0, 'Pooling requires four-channel groups')
    return kh*width*(channels//4)


def pool_fusion_buffer_plan(height, width, channels, pe_cols=4, line_words=1024,
                            pool_config=0, pool_padding=0):
    """Choose full-channel storage or one output-channel tile at a time.

    Channel tiling changes the hardware traversal, not the descriptor or HWC
    output layout. A tile contains pe_cols channels; all of its spatial points
    finish before the line-buffer addresses are reused for the next tile.
    """
    require(isinstance(pe_cols, int) and pe_cols >= 4 and pe_cols % 4 == 0,
            'Fused pooling requires four-channel PE groups')
    require(isinstance(channels, int) and channels > 0 and channels % pe_cols == 0,
            'Fused pooling requires complete output-channel tiles')
    require(isinstance(line_words, int) and line_words > 0,
            'Pooling line buffer capacity must be positive')
    full_words = pool_line_words(height, width, channels, pool_config, pool_padding)
    minimum_words = pool_line_words(height, width, pe_cols, pool_config, pool_padding)
    channel_tiled = full_words > line_words and minimum_words <= line_words
    active_words = minimum_words if full_words > line_words else full_words
    return dict(fits=active_words <= line_words, channel_tiled=channel_tiled,
                full_words=full_words, minimum_words=minimum_words,
                active_words=active_words,
                channel_block_channels=pe_cols if full_words > line_words else channels)


def encode(d):
    w = [d['opcode'] | (d['flags'] << 8), d['m'], d['n'], d['k']]
    for key in ('a', 'b', 'c'):
        value = d[key]
        require(0 <= value < 2**64, '{} base exceeds 64 bits'.format(key))
        w.extend([value & 0xffffffff, value >> 32])
    w.extend(d['words10_12'])
    w.extend([d['param'] & 0xffffffff, d['param'] >> 32, d.get('pool_config', 0)])
    require(len(w) == 16 and all(0 <= x < 2**32 for x in w), 'Descriptor field exceeds 32 bits')
    return struct.pack('<16I', *w)


def decode(raw):
    require(len(raw) == 64, 'Descriptor must be exactly 64 bytes')
    w = struct.unpack('<16I', raw)
    result = dict(opcode=w[0] & 255, flags=w[0] >> 8, m=w[1], n=w[2], k=w[3],
                  a=w[4] | (w[5] << 32), b=w[6] | (w[7] << 32), c=w[8] | (w[9] << 32),
                  words10_12=list(w[10:13]), param=w[13] | (w[14] << 32))
    if w[15]:
        result['pool_config'] = w[15]
    return result


def validate_descriptor(d, cfg):
    """RTL admission checks plus stricter compiler memory-safety constraints."""
    op, flags = d['opcode'], d['flags']
    m,n,k = d['m'],d['n'],d['k']
    require(op in (1,2,3,4,5) and
            all(isinstance(x, (int, type(2**64))) and 0 <= x < 2**32
                for x in (m,n,k)) and m > 0 and (op == 5 or min(n,k) > 0),
            'Unsupported opcode or invalid unsigned 32-bit dimension')
    require(isinstance(flags, (int, type(2**64))) and 0 <= flags < 256,
            'Unsupported postprocess flags')
    require(all(isinstance(d[key], (int, type(2**64))) and 0 <= d[key] < 2**64
                for key in ('a','b','c','param')), 'Descriptor base exceeds unsigned 64 bits')
    require(len(d['words10_12']) == 3 and
            all(isinstance(x, (int, type(2**64))) and 0 <= x < 2**32
                for x in d['words10_12']), 'Invalid unsigned 32-bit stride or geometry')
    require(all(d[key]%4 == 0 for key in ('a','b','c','param')), 'Unaligned descriptor base')
    fused_pool = bool(flags & 128)
    pool_config = d.get('pool_config', 0)
    unpack_pool_config(pool_config)
    require(pool_config == 0 or op == 3 or fused_pool,
            'Pooling configuration requires MaxPool or fused Conv/FC MaxPool')
    if op==5:
        require(flags in (0,1) and m%4==0 and n==0 and k==0 and
                d['words10_12']==[0,0,0] and pool_config==0,
                'Invalid residual ADD descriptor')
        require(all(d[key]+m <= 2**64 for key in ('a','b','c')) and
                d['param']+24 <= 2**64, 'Residual ADD address span exceeds 64 bits')
        return
    if op==3 or op==4:
        require(flags==0 and k%4==0 and d['b']==0 and d['param']==0
                and d['words10_12'][1:]==[0,0],
                'Invalid pooling descriptor')
        if op==4:
            require(pool_config==0 and d['words10_12'][0]==0,
                    'Invalid global average pooling descriptor')
            require(m*n <= 16777215, 'Global average pooling pixel count exceeds hardware limit')
            output_bytes = k
        else:
            oh,ow = pool_output_shape(m, n, pool_config, d['words10_12'][0])
            output_bytes = oh*ow*k
        require(d['a']+m*n*k <= 2**64 and d['c']+output_bytes <= 2**64,
                'Pooling address span exceeds 64 bits')
        return
    require(not (flags & 4 and not flags & 2) and
            not (flags & 8 and not flags & 2) and
            not (flags & 16 and op != 2) and not (flags & 32 and flags & 64),
            'Unsupported postprocess or dataflow flags')
    require(not flags & 64 or k <= cfg.get('k_tile_size', 256),
            'B-stationary dataflow requires one K tile')
    require(flags & 3 or d['param']==0, 'Unused parameter base must be zero')
    tile_counts = ((m+cfg['pe_rows']-1)//cfg['pe_rows'],
                   (n+cfg['pe_cols']-1)//cfg['pe_cols'],
                   (k+cfg.get('k_tile_size', 256)-1)//cfg.get('k_tile_size', 256))
    require(all(count < 2**cfg.get('tile_count_width', 16) for count in tile_counts),
            'Tile counter overflow')
    # Hardware reads only valid M/N operand lanes and masks logical tails at
    # writeback. Each valid K row still reserves an 8-byte-aligned footprint.
    if op==2:
        geometry,kernel,spatial=d['words10_12']
        h,w=geometry&65535,geometry>>16
        ci,kh,kw=kernel&65535,(kernel>>16)&255,kernel>>24
        sh,sw,pt,pl=(spatial>>(8*i)&255 for i in range(4))
        require(min(h,w,ci,kh,kw)>0 and sh in (1,2) and sw in (1,2), 'Invalid Conv geometry')
        if flags & 16:
            # SAME changes output shape only; the descriptor still carries
            # the actual top/left padding used by conv_patch_reader.
            oh,ow = (h+sh-1)//sh, (w+sw-1)//sw
        else:
            require(h+2*pt>=kh and w+2*pl>=kw, 'Conv kernel exceeds padded input')
            oh,ow = (h+2*pt-kh)//sh+1, (w+2*pl-kw)//sw+1
        require(m==oh*ow and k==kh*kw*ci,
                'Conv M/K does not match geometry')
        require(align(k,8) < 2**32 and n*(1 if flags&2 else 4) < 2**32,
                'Conv operand or output stride exceeds unsigned 32 bits')
        if fused_pool:
            require(flags & 2, 'Fused pooling requires requantized INT8 Conv output')
            require(cfg['pe_cols'] >= 4 and cfg['pe_cols'] % 4 == 0 and n % 4 == 0,
                    'Fused pooling requires four-channel groups')
            require(n % cfg['pe_cols'] == 0,
                    'Fused pooling requires complete output-channel tiles')
            buffer_plan = pool_fusion_buffer_plan(
                oh, ow, n, cfg['pe_cols'], cfg.get('pool_line_words', 1024), pool_config)
            require(buffer_plan['fits'],
                    'Fused pooling line buffer capacity exceeded for one channel tile')
    else:
        a,b,c=d['words10_12']
        require(a%8==0 and b%8==0 and c%4==0,
                'A/B strides require 8-byte alignment; C stride requires 4-byte alignment')
        require(d['a']%8==0 and d['b']%8==0, 'A/B bases require 8-byte alignment')
        require((a==0 or a>=align(k,8)) and b>=align(k,8) and
                c>=align(n*(1 if flags&2 else 4),4),
                'Stride is smaller than physical row footprint')
        if fused_pool:
            require(flags & 2, 'Fused FC pooling requires requantized INT8 output')
            require(m == cfg['pe_rows'],
                    'Fused FC pooling requires one physical M tile and one logical sample')
            require(cfg['pe_cols'] >= 4 and cfg['pe_cols'] % 4 == 0,
                    'Fused FC pooling requires four-channel PE groups')
            require(n % cfg['pe_cols'] == 0,
                    'Fused FC pooling requires complete output-channel tiles')
            require(c == n, 'Fused FC pooling requires C stride equal to unpooled N')
            # H/W/C and logical batch live in the extended parameter header.
            # The FC-pool builder validates shape, full raw-input line-buffer capacity
            # and the smaller pooled C allocation before encoding this command.


class MemoryPlan:
    def __init__(self, cfg):
        self.cfg, self.regions, self.cursor = cfg, {}, cfg['ddr_base']

    def allocate(self, name, size, shape, dtype, layout, alignment=4, **extra):
        require(name not in self.regions and size > 0, 'Invalid allocation {}'.format(name))
        base = align(self.cursor, max(self.cfg['alignment_bytes'], alignment))
        require(base + size <= self.cfg['ddr_base'] + self.cfg['ddr_capacity_bytes'],
                'DDR capacity exceeded by {}: need {} bytes'.format(name, base+size))
        self.regions[name] = dict(address=base, bytes=size, shape=shape, dtype=dtype,
                                  layout=layout, **extra)
        self.cursor = base+size
        return base

    def validate_access(self, address, size, name):
        r = self.regions[name]
        require(r['address'] <= address and address+size <= r['address']+r['bytes'],
                'DMA access escapes {}: address={}, bytes={}'.format(name, address, size))


MODEL_HEADER = struct.Struct('<8sIIQQQQ')
MODEL_MAGIC = b'NPUMV0\0\0'
