"""Shared HWC INT8 graph backend (standard library, Python 2.7 and 3).

Frontends supply logical shapes and output-major weights. The target descriptor
ABI remains the same as the original SmallCNN and TFLite compiler entrypoints.
Deployment activation scales must come from calibration. An explicit benchmark
mode can use fixed scales to measure integer execution without accuracy claims.
"""
from __future__ import print_function

import copy
import hashlib
import json
import math
import os
import struct
import sys

from target import align, encode, validate_descriptor, require


def binary(data):
    return bytes(data) if sys.version_info[0] >= 3 else str(data)


def product(shape):
    value = 1
    for extent in shape:
        require(isinstance(extent, (int, type(2**32))) and extent > 0,
                'Tensor shape must contain positive integers')
        value *= extent
    return value


def round_away(value):
    require(not math.isnan(value) and not math.isinf(value), 'Nonfinite tensor value')
    return int(math.floor(value+0.5) if value >= 0 else math.ceil(value-0.5))


def fixed_point(ratios, bound):
    """A common shift, positive INT31 multipliers, safe signed INT64 rounding."""
    require(all(r > 0 and not math.isnan(r) and not math.isinf(r) for r in ratios),
            'Quantization scale ratios must be finite and positive')
    for shift in range(62, -1, -1):
        multipliers = [round_away(r*(1 << shift)) for r in ratios]
        half = (1 << (shift-1)) if shift else 0
        if (all(0 < m < 2**31 for m in multipliers) and
                bound*sum(multipliers)+half < 2**63):
            return multipliers, shift
    raise ValueError('Scale ratio has no safe fixed-point representation')


def optimize_graph(graph):
    """Fuse a sole-consumer ReLU, keeping calibration tensor names explicit."""
    nodes = copy.deepcopy(graph['nodes'])
    consumers = {}
    for node in nodes:
        for name in node['inputs']:
            consumers[name] = consumers.get(name, 0)+1
    consumers[graph['output']] = consumers.get(graph['output'], 0)+1
    producers, result = {}, []
    for node in nodes:
        if node['op'] == 'Relu':
            source = node['inputs'][0]
            producer = producers.get(source)
            require(producer is not None and consumers[source] == 1 and
                    producer['op'] in ('Conv', 'FullyConnected', 'Add'),
                    'ReLU needs a sole Conv/FC/Add producer: '+node['name'])
            require(producer['shape'] == node['shape'], 'ReLU shape mismatch')
            producer['relu'] = True
            producer.setdefault('fused_tensors', []).append(source)
            producer['output'] = node['output']
            producers[node['output']] = producer
        else:
            require(node['op'] in ('Conv', 'FullyConnected', 'Add', 'MaxPool',
                                   'GlobalAveragePool'), 'Unsupported graph operation: '+node['op'])
            result.append(node)
            producers[node['output']] = node
    optimized = dict(input=copy.deepcopy(graph['input']), nodes=result, output=graph['output'],
                     aliases=copy.deepcopy(graph.get('aliases', {})))
    for name in ('model_sha256', 'source', 'source_path'):
        if name in graph:
            optimized[name] = graph[name]
    return optimized


def quantization_template(graph):
    graph = optimize_graph(graph)
    tensors = {graph['input']['name']: dict(scale=None, zero_point=0)}
    for node in graph['nodes']:
        if node['op'] in ('MaxPool', 'GlobalAveragePool'):
            tensors[node['output']] = dict(shared_with=node['inputs'][0])
        else:
            tensors[node['output']] = dict(scale=None, zero_point=0)
    profile = dict(schema_version=1, calibrated=False,
                   calibration=dict(dataset=None, samples=0, method=None),
                   preprocessing=dict(description=None, input_layout='HWC',
                                      input_shape=graph['input']['shape']), tensors=tensors)
    if graph.get('model_sha256'):
        profile['model_sha256'] = graph['model_sha256']
    return profile


def benchmark_quantization(graph, activation_scale=0.0625):
    """Create fixed, uncalibrated scales ONLY for integer performance testing."""
    require(type(activation_scale) in (int, float) and activation_scale > 0 and
            not math.isnan(activation_scale) and not math.isinf(activation_scale),
            'Benchmark activation scale must be finite and positive')
    profile = quantization_template(graph)
    del profile['calibration']
    profile.update(purpose='integer_performance', accuracy_not_measured=True)
    profile['preprocessing']['description'] = (
        'Synthetic signed INT8 HWC values; fixed benchmark scales; no image calibration')
    for entry in profile['tensors'].values():
        if 'shared_with' not in entry:
            entry['scale'] = float(activation_scale)
    return profile


def resolve_quantization(graph, profile, benchmark_only=False):
    require(profile.get('schema_version') == 1, 'Unsupported quantization profile version')
    if graph.get('model_sha256'):
        require(profile.get('model_sha256') == graph['model_sha256'],
                'Quantization profile does not match this model SHA256')
    if benchmark_only:
        require(profile.get('purpose') == 'integer_performance' and
                profile.get('calibrated') is False and
                profile.get('accuracy_not_measured') is True,
                'Benchmark mode requires an explicit uncalibrated integer_performance profile')
        require('calibration' not in profile,
                'Benchmark profiles must not claim calibration metadata')
    else:
        require(profile.get('purpose') != 'integer_performance',
                'Integer performance profiles require explicit benchmark_only=True')
        calibration = profile.get('calibration', {})
        require(profile.get('calibrated') is True and calibration.get('samples', 0) > 0 and
                calibration.get('dataset') and calibration.get('method'),
                'Real calibration metadata is required; fill the quantization template first')
    preprocessing = profile.get('preprocessing', {})
    require(preprocessing.get('description'), 'Record input preprocessing used for calibration')
    require(preprocessing.get('input_layout') == 'HWC' and
            preprocessing.get('input_shape') == graph['input']['shape'],
            'Quantized input layout/shape must match the HWC graph input')
    entries, resolved = profile.get('tensors', {}), {}

    def resolve(name, visiting):
        if name in resolved:
            return resolved[name]
        require(name in entries, 'Missing activation quantization: '+name)
        require(name not in visiting, 'Cyclic quantization aliases: '+name)
        entry = entries[name]
        if 'shared_with' in entry:
            result = resolve(entry['shared_with'], visiting+[name])
        else:
            scale, zp = entry.get('scale'), entry.get('zero_point')
            require(type(scale) in (int, float) and scale > 0 and
                    not math.isnan(scale) and not math.isinf(scale),
                    'Missing or invalid activation scale: '+name)
            require(type(zp) is int and -128 <= zp <= 127,
                    'Activation zero point must be signed INT8: '+name)
            result = dict(scale=float(scale), zero_point=zp)
        resolved[name] = result
        return result

    resolve(graph['input']['name'], [])
    for node in graph['nodes']:
        for name in node['inputs']+[node['output']]:
            resolve(name, [])
        if node['op'] in ('MaxPool', 'GlobalAveragePool'):
            require(resolved[node['inputs'][0]] == resolved[node['output']],
                    node['op']+' must preserve scale and zero point')
    return resolved


def select_dataflow(m, n, k, cfg, preference='auto'):
    require(preference in ('auto', 'a', 'b'), 'Dataflow must be auto, a or b')
    mt = (m+cfg['pe_rows']-1)//cfg['pe_rows']
    nt = (n+cfg['pe_cols']-1)//cfg['pe_cols']
    kt = (k+cfg['k_tile_size']-1)//cfg['k_tile_size']
    if kt > 1:
        return 32 if nt > 1 else 0
    return 64 if mt > 1 and (preference == 'b' or preference == 'auto' and mt > nt) else 0


def _geometry(node, shapes):
    h, w, ci = shapes[node['inputs'][0]]
    oh, ow, co = node['shape']
    attrs = node.get('attrs', {})
    kh, kw = attrs['kernel']
    sh, sw = attrs.get('strides', [1, 1])
    pt, pl, pb, pr = attrs.get('pads', [0, 0, 0, 0])
    require(0 < h < 65536 and 0 < w < 65536 and 0 < ci < 65536 and
            0 < kh < 256 and 0 < kw < 256 and sh in (1, 2) and sw in (1, 2) and
            all(0 <= p < 256 for p in (pt, pl, pb, pr)), 'Conv geometry exceeds ABI')
    require(oh == (h+pt+pb-kh)//sh+1 and ow == (w+pl+pr-kw)//sw+1,
            'Conv output shape does not match padding')
    same = pt != pb or pl != pr
    if same:
        total_h, total_w = max(0, (oh-1)*sh+kh-h), max(0, (ow-1)*sw+kw-w)
        require(oh == (h+sh-1)//sh and ow == (w+sw-1)//sw and
                [pt, pl, pb, pr] == [total_h//2, total_w//2,
                                     total_h-total_h//2, total_w-total_w//2],
                'Asymmetric Conv padding must be SAME_UPPER')
    return oh*ow, co, kh*kw*ci, [h | w << 16, ci | kh << 16 | kw << 24,
                                sh | sw << 8 | pt << 16 | pl << 24], 16 if same else 0


def plan_graph(graph, cfg, dataflow='auto'):
    """Plan constants and activations; free values only AFTER their last command."""
    require(cfg.get('ddr_base', 0) == 0 and cfg.get('activation_layout', 'HWC') == 'HWC',
            'Graph backend requires zero-based DDR and HWC activations')
    require(all(type(cfg.get(key)) is int and cfg[key] > 0
                for key in ('pe_rows', 'pe_cols', 'k_tile_size', 'ddr_capacity_bytes')),
            'Target dimensions and DDR capacity must be positive integers')
    require(cfg['k_tile_size'] % 8 == 0, 'K tile offsets must be 64-bit aligned')
    allocation_alignment = cfg.get('alignment_bytes', 8)
    require(type(allocation_alignment) is int and allocation_alignment >= 8 and
            allocation_alignment & (allocation_alignment-1) == 0,
            'Allocation alignment must be a power of two >= 8')
    require(cfg.get('data_width', 8) == 8 and cfg.get('acc_width', 32) == 32,
            'Graph quantization backend requires INT8 operands and INT32 accumulators')
    graph = optimize_graph(graph)
    nodes = graph['nodes']
    require(0 < len(nodes) < 65536, 'Descriptor count must fit unsigned 16 bits')
    shapes = {graph['input']['name']: graph['input']['shape']}
    last = {graph['input']['name']: -1}
    for index, node in enumerate(nodes):
        require(node['output'] not in shapes, 'Duplicate tensor producer: '+node['output'])
        for name in node['inputs']:
            require(name in shapes, 'Graph is not topologically ordered: '+name)
            last[name] = index
        product(node['shape'])
        shapes[node['output']] = node['shape']
    require(graph['output'] in shapes, 'Unknown graph output')
    last[graph['output']] = len(nodes)
    descriptor_base = align(256, max(64, allocation_alignment))
    cursor = align(descriptor_base+64*len(nodes), max(64, allocation_alignment))
    constants, commands = {}, []
    from target import pack_pool_config, pack_pool_padding, pool_output_shape
    for node in nodes:
        op, out = node['op'], node['output']
        desc = dict(flags=0, a=0, b=0, c=0, param=0, words10_12=[0, 0, 0])
        if op in ('Conv', 'FullyConnected'):
            if op == 'Conv':
                m, n, k, geometry, same = _geometry(node, shapes)
                desc.update(opcode=2, words10_12=geometry, flags=same)
            else:
                require(len(node['shape']) == 1 and
                        product(shapes[node['inputs'][0]]) == node['weights']['shape'][1],
                        'FC needs one logical input vector')
                m, n, k = 1, node['shape'][0], node['weights']['shape'][1]
                desc.update(opcode=1, words10_12=[0, align(k, 8), align(n, 4)])
            require(node['weights']['shape'] == [n, k], 'Weight shape mismatch: '+node['name'])
            desc.update(m=m, n=n, k=k)
            desc['flags'] |= 11 | (4 if node.get('relu') else 0) | select_dataflow(m, n, k, cfg, dataflow)
            weight_size = n*align(k, 8)
            constants[out] = dict(weights=dict(address=cursor, bytes=weight_size))
            desc['b'] = cursor
            cursor = align(cursor+weight_size, allocation_alignment)
            param_size = 16+n*12
        elif op == 'Add':
            require(len(node['inputs']) == 2 and
                    all(shapes[x] == node['shape'] for x in node['inputs']),
                    'Residual ADD requires equal shapes')
            elements = product(node['shape'])
            require(elements % 4 == 0, 'Residual ADD requires groups of four bytes')
            desc.update(opcode=5, m=elements, n=0, k=0, flags=1 if node.get('relu') else 0)
            constants[out] = {}
            param_size = 24
        else:
            require(len(node['inputs']) == 1 and len(shapes[node['inputs'][0]]) == 3,
                    'Pooling requires HWC input')
            h, w, c = shapes[node['inputs'][0]]
            require(c % 4 == 0, 'Pooling requires complete four-channel groups')
            desc.update(opcode=3 if op == 'MaxPool' else 4, m=h, n=w, k=c)
            if op == 'MaxPool':
                attrs = node['attrs']
                kernel, stride = attrs['kernel'], attrs.get('strides', [1, 1])
                desc['pool_config'] = pack_pool_config(*(kernel+stride))
                desc['words10_12'][0] = pack_pool_padding(*attrs.get('pads', [0]*4))
                oh, ow = pool_output_shape(h, w, desc['pool_config'], desc['words10_12'][0])
                require(node['shape'] == [oh, ow, c], 'MaxPool output shape mismatch')
            else:
                require(node['shape'] in ([c], [1, 1, c]), 'Only spatial global average is supported')
            param_size = 0
        if param_size:
            constants[out]['params'] = dict(address=cursor, bytes=param_size)
            desc['param'] = cursor
            cursor = align(cursor+param_size, allocation_alignment)
        commands.append(desc)
    activation_base = align(cursor, max(64, allocation_alignment))
    regions, free, live = {}, [], {}

    def allocate(name, born):
        size = align(product(shapes[name]), allocation_alignment)
        address = None
        for index, (base, length) in enumerate(free):
            if length >= size:
                address = base
                free.pop(index)
                if length > size:
                    free.append((base+size, length-size))
                break
        if address is None:
            address = allocate.end
            allocate.end += size
        region = dict(address=address, bytes=size, logical_bytes=product(shapes[name]),
                      shape=shapes[name], born=born, last_use=last.get(name, born))
        live[name] = region
        regions[name] = region

    allocate.end = activation_base
    allocate(graph['input']['name'], -1)
    for index, (node, desc) in enumerate(zip(nodes, commands)):
        allocate(node['output'], index)
        desc['a'] = regions[node['inputs'][0]]['address']
        desc['c'] = regions[node['output']]['address']
        if node['op'] == 'Add':
            desc['b'] = regions[node['inputs'][1]]['address']
        validate_descriptor(desc, cfg)
        for name in list(live):
            if last.get(name, index) == index:
                region = live.pop(name)
                free.append((region['address'], region['bytes']))
        free.sort()
        merged = []
        for base, length in free:
            if merged and merged[-1][0]+merged[-1][1] == base:
                merged[-1] = (merged[-1][0], merged[-1][1]+length)
            else:
                merged.append((base, length))
        free[:] = merged
    image_bytes = align(allocate.end, 64)
    require(image_bytes <= cfg['ddr_capacity_bytes'],
            'DDR capacity exceeded: need %d bytes, configured %d' %
            (image_bytes, cfg['ddr_capacity_bytes']))
    return dict(schema_version=1, graph=graph, commands=commands, constants=constants,
                regions=regions, descriptor_base=descriptor_base, descriptor_count=len(commands),
                image_bytes=image_bytes, activation_base=activation_base,
                activation_arena_bytes=allocate.end-activation_base, target=copy.deepcopy(cfg),
                output=graph['output'], deployment_ready=False,
                validation='Graph/ABI/memory checks only; INT8 calibration and accuracy still required')


def compile_graph(source_graph, cfg, profile, input_data=None, dataflow='auto', benchmark_only=False):
    plan = plan_graph(source_graph, cfg, dataflow)
    graph = plan['graph']
    quant = resolve_quantization(graph, profile, benchmark_only=benchmark_only)
    image = bytearray(plan['image_bytes'])
    input_name = graph['input']['name']
    region = plan['regions'][input_name]
    image[region['address']:region['address']+region['bytes']] = bytearray(
        [quant[input_name]['zero_point'] & 255])*region['bytes']
    if input_data is not None:
        require(len(input_data) == region['logical_bytes'], 'Input must be logical signed INT8 HWC bytes')
        image[region['address']:region['address']+len(input_data)] = bytearray(input_data)
    weight_report = {}
    for node, desc in zip(graph['nodes'], plan['commands']):
        out = node['output']
        qo, qi = quant[out], quant[node['inputs'][0]]
        if node['op'] in ('Conv', 'FullyConnected'):
            weights = source_graph.load_weights(node)
            n, k = node['weights']['shape']
            require(len(weights) == n*k, 'Weight payload length mismatch')
            bias = source_graph.load_tensor(node['bias']['name']) if node.get('bias') else [0.0]*n
            require(len(bias) == n, 'Bias payload length mismatch')
            stride = align(k, 8)
            packed = bytearray(n*stride)
            params = bytearray(struct.pack('<4I', 0, 0, qi['zero_point'] & 0xffffffff,
                                           qo['zero_point'] & 0xffffffff))
            scales = []
            for channel in range(n):
                row = weights[channel*k:(channel+1)*k]
                maximum = max(abs(value) for value in row)
                require(not math.isnan(maximum) and not math.isinf(maximum), 'Nonfinite weight')
                scale = maximum/127.0 if maximum else 1.0
                accumulator_scale = qi['scale']*scale
                require(scale > 0 and accumulator_scale > 0 and
                        not math.isinf(accumulator_scale),
                        'Weight/accumulator scale underflow or overflow: '+node['name'])
                values = [max(-127, min(127, round_away(value/scale))) for value in row]
                bias_integer = round_away(bias[channel]/accumulator_scale)
                folded = bias_integer-qi['zero_point']*sum(values)
                require(-2**31 <= folded < 2**31 and 128*sum(abs(v) for v in values) < 2**31,
                        'INT32 accumulator/bias overflow: '+node['name'])
                multiplier, shift = fixed_point([accumulator_scale/qo['scale']], 2**32)
                params.extend(struct.pack('<iII', folded, multiplier[0], shift))
                packed[channel*stride:channel*stride+k] = bytearray(v & 255 for v in values)
                scales.append(scale)
            image[desc['b']:desc['b']+len(packed)] = packed
            image[desc['param']:desc['param']+len(params)] = params
            weight_report[out] = dict(scales=scales, layout='N_KH_KW_C' if node['op'] == 'Conv' else 'N_K',
                                      stride_bytes=stride, symmetric_zero_point=0)
        elif node['op'] == 'Add':
            qb = quant[node['inputs'][1]]
            multipliers, shift = fixed_point([qi['scale']/qo['scale'], qb['scale']/qo['scale']], 255)
            words = [qi['zero_point'], qb['zero_point'], qo['zero_point']]+multipliers+[shift]
            params = struct.pack('<6I', *(x & 0xffffffff for x in words))
            image[desc['param']:desc['param']+24] = bytearray(params)
    descriptors = b''.join(encode(d) for d in plan['commands'])
    image[plan['descriptor_base']:plan['descriptor_base']+len(descriptors)] = bytearray(descriptors)
    plan.update(quantization=quant, weight_quantization=weight_report,
                preprocessing=copy.deepcopy(profile['preprocessing']),
                input_provided=input_data is not None,
                calibrated=profile['calibrated'])
    if benchmark_only:
        plan.update(purpose='integer_performance', accuracy_not_measured=True,
                    validation='Uncalibrated integer performance package; accuracy not measured')
    else:
        plan.update(calibration=copy.deepcopy(profile['calibration']),
                    validation='Calibrated INT8 package; compare software/RTL outputs and model accuracy before deployment')
    return plan, binary(image), descriptors


def write_package(directory, plan, image=None, descriptors=None):
    if not os.path.isdir(directory):
        os.makedirs(directory)
    if image is not None:
        with open(os.path.join(directory, 'ddr.bin'), 'wb') as handle:
            handle.write(image)
        with open(os.path.join(directory, 'ddr.hex'), 'w') as handle:
            for pos in range(0, len(image), 4):
                handle.write('%08x\n' % struct.unpack_from('<I', image, pos)[0])
        with open(os.path.join(directory, 'descriptors.bin'), 'wb') as handle:
            handle.write(descriptors)
        plan['ddr_sha256'] = hashlib.sha256(image).hexdigest()
    with open(os.path.join(directory, 'manifest.json'), 'w') as handle:
        json.dump(plan, handle, indent=2, sort_keys=True)
        handle.write('\n')
