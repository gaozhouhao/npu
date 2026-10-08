"""Audited ABI for gaozhouhao/npu commit 87cc23c; no RTL generation."""
import hashlib
import json
import re
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def normalized_digest(path):
    return hashlib.sha256(Path(path).read_text(encoding='utf-8').encode()).hexdigest()


def load_target(path):
    cfg = json.loads(Path(path).read_text())
    lock = json.loads((HERE / 'rtl_contract.json').read_text())
    for name, expected in lock['files'].items():
        require(normalized_digest(REPO / name) == expected,
                f'RTL contract changed: {name}; review ABI and update audit before compiling.')
    text = (REPO / 'rtl/core/npu_top.sv').read_text()
    mappings = dict(pe_rows='ROWS', pe_cols='COLS', k_tile_size='K_TILE_SIZE',
                    a_buffer_count='A_BUFFER_COUNT', b_buffer_count='B_BUFFER_COUNT',
                    axi_data_width='MEM_WORD_WIDTH', data_width='DATA_WIDTH',
                    acc_width='ACC_WIDTH', tile_count_width='TILE_COUNT_WIDTH')
    for key, param in mappings.items():
        match = re.search(r'parameter int unsigned\s+' + param + r'\s*=\s*(\d+)', text)
        require(match is not None and cfg.get(key) == int(match[1]),
                f'{key}: config must match audited npu_top default {param}; overrides not audited.')
    require(cfg['pe_rows'] == cfg['pe_cols'],
            'scratchpad.sv swaps A/B lane-count parameters; rectangular arrays not supported by V0.')
    require(cfg['a_buffer_count'] == cfg['b_buffer_count'],
            'scratchpad.sv swaps A/B buffer-count parameters; asymmetric counts not supported.')
    require(cfg['activation_layout'] == 'HWC', 'conv_patch_loader requires HWC.')
    require(cfg['alignment_bytes'] >= 4 and cfg['alignment_bytes'] & (cfg['alignment_bytes']-1) == 0,
            'alignment_bytes must be a power of two >= 4.')
    require(cfg['ddr_base'] == 0, 'memory.cpp uses zero-based addresses; V0 requires ddr_base=0.')
    require(isinstance(cfg['ddr_capacity_bytes'], int) and cfg['ddr_capacity_bytes'] > 0,
            'DDR capacity must be positive; initialize C++ memory to at least this capacity.')
    require(cfg['k_tile_size'] % 4 == 0, 'K tile offsets must stay word aligned.')
    return cfg, lock


def align(n, a=4):
    return (n+a-1)//a*a


def encode(d):
    w = [d['opcode'] | (d['flags'] << 8), d['m'], d['n'], d['k']]
    for key in ('a', 'b', 'c'):
        value = d[key]
        require(0 <= value < 2**64, f'{key} base exceeds 64 bits')
        w.extend([value & 0xffffffff, value >> 32])
    w.extend(d['words10_12'])
    w.extend([d['param'] & 0xffffffff, d['param'] >> 32, 0])
    require(len(w) == 16 and all(0 <= x < 2**32 for x in w), 'Descriptor field exceeds 32 bits')
    return struct.pack('<16I', *w)


def decode(raw):
    require(len(raw) == 64, 'Descriptor must be exactly 64 bytes')
    w = struct.unpack('<16I', raw)
    require(w[15] == 0, 'Reserved descriptor word must be zero')
    return dict(opcode=w[0] & 255, flags=w[0] >> 8, m=w[1], n=w[2], k=w[3],
                a=w[4] | (w[5] << 32), b=w[6] | (w[7] << 32), c=w[8] | (w[9] << 32),
                words10_12=list(w[10:13]), param=w[13] | (w[14] << 32))


def validate_descriptor(d, cfg):
    """RTL admission checks plus stricter compiler memory-safety constraints."""
    op, flags = d['opcode'], d['flags']
    m,n,k = d['m'],d['n'],d['k']
    require(op in (1,2,3) and min(m,n,k)>0, 'Unsupported opcode or zero dimension')
    require(flags < 8 and not (flags & 4 and not flags & 2), 'Unsupported postprocess flags')
    require(all(d[key]%4 == 0 for key in ('a','b','c','param')), 'Unaligned descriptor base')
    require(flags & 3 or d['param']==0, 'Unused parameter base must be zero')
    if op==3:
        require(flags==0 and m>=2 and n>=2 and k%4==0 and d['b']==0 and d['param']==0
                and d['words10_12']==[0,0,0], 'Invalid pooling descriptor')
        return
    require(m%cfg['pe_rows']==0 and n%cfg['pe_cols']==0,
            'Partial M/N requires explicit allocation/padding; no DMA lane masking')
    if op==2:
        geometry,kernel,spatial=d['words10_12']
        h,w=geometry&65535,geometry>>16
        ci,kh,kw=kernel&65535,(kernel>>16)&255,kernel>>24
        sh,sw,pt,pl=(spatial>>(8*i)&255 for i in range(4))
        require(min(h,w,ci,kh,kw)>0 and sh in (1,2) and sw in (1,2), 'Invalid Conv geometry')
        require(h+2*pt>=kh and w+2*pl>=kw, 'Conv kernel exceeds padded input')
        require(m==((h+2*pt-kh)//sh+1)*((w+2*pl-kw)//sw+1) and k==kh*kw*ci,
                'Conv M/K does not match geometry')
    else:
        a,b,c=d['words10_12']
        require(all(x%4==0 for x in (a,b,c)), 'DMA strides must be byte counts aligned to 4')
        require(a>=align(k) and b>=align(k) and c>=n*(1 if flags&2 else 4),
                'Stride is smaller than physical row footprint')


class MemoryPlan:
    def __init__(self, cfg):
        self.cfg, self.regions, self.cursor = cfg, {}, cfg['ddr_base']

    def allocate(self, name, size, shape, dtype, layout, alignment=4, **extra):
        require(name not in self.regions and size > 0, f'Invalid allocation {name}')
        base = align(self.cursor, max(self.cfg['alignment_bytes'], alignment))
        require(base + size <= self.cfg['ddr_base'] + self.cfg['ddr_capacity_bytes'],
                f'DDR capacity exceeded by {name}: need {base+size} bytes')
        self.regions[name] = dict(address=base, bytes=size, shape=shape, dtype=dtype,
                                  layout=layout, **extra)
        self.cursor = base+size
        return base

    def validate_access(self, address, size, name):
        r = self.regions[name]
        require(r['address'] <= address and address+size <= r['address']+r['bytes'],
                f'DMA access escapes {name}: address={address}, bytes={size}')


MODEL_HEADER = struct.Struct('<8sIIQQQQ')
MODEL_MAGIC = b'NPUMV0\0\0'
