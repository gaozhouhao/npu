"""Compile the existing SmallCNN PTQ checkpoint to the current NPU ABI."""
import argparse
import importlib
import json
import struct
import sys
from pathlib import Path
from target import (HERE, REPO, require, digest, load_target, align, encode, decode,
                    MemoryPlan, MODEL_HEADER, MODEL_MAGIC, validate_descriptor,
                    unpack_pool_config, pool_output_shape, pool_line_words,
                    pool_fusion_buffer_plan)
from verify_model import execute, rtl_requant, verify_files


FUSE_MAXPOOL = 1 << 7


def fuse_conv_pool(descriptors, layers, cfg):
    """Fuse eligible adjacent Conv/MaxPool pairs without changing quantization.

    This pass preserves the original memory allocation and logical layer list.
    descriptor_layers records which logical results each hardware command makes;
    elided intermediates remain available as software golden values, not DDR outputs.
    """
    require(len(descriptors) == len(layers), 'Descriptor/layer list mismatch')
    emitted, descriptor_layers, fused, skipped = [], [], [], []

    def read_ranges(d):
        params = []
        if d['opcode'] in (1, 2) and d['flags'] & 3:
            # Fused FC extends the header with H/W/C and logical batch.
            # Bias follows the header;
            # per-channel records additionally carry multiplier and shift.
            parameter_bytes = 32 if d['opcode'] == 1 and d['flags'] & FUSE_MAXPOOL else 16
            if d['flags'] & 8:
                parameter_bytes += d['n']*12
            elif d['flags'] & 1:
                parameter_bytes += d['n']*4
            params = [(d['param'], parameter_bytes)]
        if d['opcode'] == 2:
            geometry, kernel, _ = d['words10_12']
            h, w, ci = geometry & 65535, geometry >> 16, kernel & 65535
            return [(d['a'], h*w*ci), (d['b'], d['n']*align(d['k'], 8))]+params
        if d['opcode'] == 3:
            return [(d['a'], d['m']*d['n']*d['k'])]
        if d['opcode'] == 1:
            a_stride, b_stride, _ = d['words10_12']
            return [(d['a'], (d['m']-1)*a_stride+align(d['k'], 8)),
                    (d['b'], (d['n']-1)*b_stride+align(d['k'], 8))]+params
        # Unrecognised readers prevent an unsafe graph rewrite.
        return [(0, 2**64)]

    i = 0
    while i < len(descriptors):
        conv = descriptors[i]
        reason = None
        candidate = (conv['opcode'] == 2 and i+1 < len(descriptors)
                     and descriptors[i+1]['opcode'] == 3)
        if candidate:
            pool = descriptors[i+1]
            geometry, kernel, spatial = conv['words10_12']
            h, w = geometry & 65535, geometry >> 16
            kh, kw = (kernel >> 16) & 255, kernel >> 24
            sh, sw, pt, pl = (spatial >> (8*j) & 255 for j in range(4))
            oh = (h+2*pt-kh)//sh+1 if sh else 0
            ow = (w+2*pl-kw)//sw+1 if sw else 0
            channels = conv['n']
            pool_config = pool.get('pool_config', 0)
            pool_padding = pool['words10_12'][0]
            try:
                pool_kh, pool_kw, _, _ = unpack_pool_config(pool_config)
                pooled_h, pooled_w = pool_output_shape(oh, ow, pool_config, pool_padding)
                geometry_error = None
            except ValueError as exc:
                geometry_error = str(exc)
            if not conv['flags'] & 2 or conv['flags'] & FUSE_MAXPOOL:
                reason = 'Conv must produce requantized INT8 and not already be fused'
            elif conv.get('pool_config', 0):
                reason = 'Unfused Conv must not contain a pooling configuration'
            elif pool_padding:
                reason = 'Padded MaxPool requires the standalone pooling path; fusion does not support padding'
            elif (pool['flags'] != 0 or pool['b'] != 0 or pool['param'] != 0 or
                  pool['words10_12'] != [0, 0, 0] or pool['a'] != conv['c'] or
                  (pool['m'], pool['n'], pool['k']) != (oh, ow, channels)):
                reason = 'MaxPool input does not exactly match the Conv output'
            elif geometry_error:
                reason = geometry_error
            elif (cfg['pe_cols'] < 4 or cfg['pe_cols'] % 4 or channels % 4 or
                  channels % cfg['pe_cols']):
                reason = 'Fused MaxPool requires complete groups of four INT8 channels'
            elif not pool_fusion_buffer_plan(
                    oh, ow, channels, cfg['pe_cols'], cfg.get('pool_line_words', 1024),
                    pool_config)['fits']:
                reason = 'Fused MaxPool line buffer capacity exceeded for one channel tile'
            else:
                output_start = pool['c']
                output_end = output_start+pooled_h*pooled_w*channels
                if any(base < output_end and output_start < base+size
                       for base, size in read_ranges(conv)):
                    reason = 'Pool output overlaps a live Conv input, weight, or parameter read'
            if reason is None:
                start, end = conv['c'], conv['c']+oh*ow*channels
                other_readers = [j for j, d in enumerate(descriptors)
                                 if j != i+1 and any(base < end and start < base+size
                                                    for base, size in read_ranges(d))]
                if other_readers:
                    reason = 'Conv output has another consumer or an overlapping read'
            if reason is None:
                buffer_plan = pool_fusion_buffer_plan(
                    oh, ow, channels, cfg['pe_cols'], cfg.get('pool_line_words', 1024),
                    pool_config)
                command = dict(conv, flags=conv['flags'] | FUSE_MAXPOOL, c=pool['c'])
                command['words10_12'] = list(conv['words10_12'])
                command.pop('pool_config', None)
                if pool_config:
                    command['pool_config'] = pool_config
                emitted.append(command)
                descriptor_layers.append([layers[i]['name'], layers[i+1]['name']])
                fused.append(dict(conv=layers[i]['name'], pool=layers[i+1]['name'],
                                  channel_tiled=buffer_plan['channel_tiled'],
                                  pool_full_line_words=buffer_plan['full_words'],
                                  pool_active_line_words=buffer_plan['active_words'],
                                  pool_channel_block_channels=buffer_plan['channel_block_channels'],
                                  intermediate_region=layers[i]['c_region'],
                                  output_region=layers[i+1]['c_region'],
                                  avoided_intermediate_write_bytes=oh*ow*channels,
                                  avoided_pool_input_read_bytes=pooled_h*pooled_w*pool_kh*pool_kw*channels,
                                  avoided_intermediate_bytes=(oh*ow +
                                      pooled_h*pooled_w*pool_kh*pool_kw)*channels))
                i += 2
                continue
            skipped.append(dict(conv=layers[i]['name'], pool=layers[i+1]['name'], reason=reason))
        emitted.append(dict(conv, words10_12=list(conv['words10_12'])))
        descriptor_layers.append([layers[i]['name']])
        i += 1
    return emitted, descriptor_layers, dict(fused_pairs=fused, skipped_pairs=skipped,
                                           fused_pair_count=len(fused),
                                           original_descriptor_count=len(descriptors),
                                           descriptor_count=len(emitted))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model-dir', type=Path, default=REPO.parent/'mnist_npu')
    parser.add_argument('--config', type=Path, default=HERE/'npu_config.json')
    parser.add_argument('--out', type=Path, default=REPO/'artifacts/npu')
    parser.add_argument('--full-test', action='store_true', help='Evaluate all 10000 images with existing PTQ reference')
    parser.add_argument('--fuse-conv-pool', action='store_true',
                        help='Fuse eligible Conv -> MaxPool pairs using their pooling geometry')
    args = parser.parse_args()
    cfg, target_metadata = load_target(args.config)
    source = args.model_dir.resolve()
    sys.path.insert(0, str(source))
    common = importlib.import_module('common')
    ptq = importlib.import_module('quantize_export')
    require(common.ROOT == source, 'Wrong common.py imported')
    np, torch = common.np, common.torch
    torch.set_num_threads(4)
    checkpoint = source/'artifacts/fp32_state_dict.pt'
    original_hash = digest(checkpoint)
    qdir = source/'artifacts/int8'
    qmeta = json.loads((qdir/'manifest.json').read_text())
    specs = qmeta['layers']
    fpmodel = common.load_model()
    weights = {}
    source_hashes = {str(p.relative_to(source)): digest(p) for p in
                     [checkpoint, source/'common.py', source/'quantize_export.py', qdir/'manifest.json']}
    for name, layer in [('conv1', fpmodel.conv1), ('conv2', fpmodel.conv2), ('fc', fpmodel.fc)]:
        spec = specs[name]
        sw = max(float(np.abs(layer.weight.detach().numpy()).max())/127, 1e-12)
        require(sw == spec['weight_scale'] and spec['zero_point'] == 0,
                f'{name}: saved scale differs from original symmetric quantizer')
        require(spec['accumulator_scale'] == spec['input_scale']*sw, 'Accumulator scale mismatch')
        for field, expected in [
            ('weight', np.clip(np.rint(layer.weight.detach().numpy().astype(np.float64)/sw), -127, 127).astype('i1')),
            ('bias', np.rint(layer.bias.detach().numpy().astype(np.float64)/(spec['input_scale']*sw)).astype('<i4')),
        ]:
            key = f'{name}.{field}'
            path = qdir/f'{key}.bin'
            meta = qmeta['tensors'][key]
            require(digest(path) == meta['sha256'], f'Saved PTQ hash mismatch: {key}')
            value = np.fromfile(path, dtype=meta['dtype']).reshape(meta['shape'])
            require(np.array_equal(value, expected), f'FP32 -> PTQ mismatch: {key}')
            weights[key] = value
            source_hashes[str(path.relative_to(source))] = digest(path)
    require(specs['conv1']['input_scale'] == 1/127 and
            specs['conv1']['output_scale'] == specs['conv2']['input_scale'] and
            specs['conv2']['output_scale'] == specs['fc']['input_scale'], 'Activation scale chain mismatch')
    for name in ('conv1', 'conv2'):
        s = specs[name]
        expected_mult = int(np.floor(s['accumulator_scale']/s['output_scale']*(1<<30)+0.5))
        require(s['shift'] == 30 and s['multiplier'] == expected_mult, 'Saved requant parameters changed')
        boundaries = np.array([-2**31+1, -1000, -3, -1, 0, 1, 3, 254, 255, 10000, 2**31-1], dtype=np.int64)
        require(np.array_equal(rtl_requant(np, boundaries, s['multiplier'], s['shift']),
                               ptq.requant_relu(boundaries, s['multiplier'], s['shift'])), 'Requant mismatch')
    require(np.array_equal(rtl_requant(np, np.array([-255,-7,-1,0,1,7,255]), 1, 1, False),
                           [-128,-4,-1,0,1,4,127]), 'Signed half-away rounding test failed')

    # Exact FC permutation: [out,c,y,x] -> [out,y,x,c].
    rows, cols, kt = cfg['pe_rows'], cfg['pe_cols'], cfg['k_tile_size']
    fm, fn = align(1, rows), align(10, cols)
    hw_weights = {}
    for name in ('conv1','conv2'):
        w = weights[name+'.weight'].transpose(0,2,3,1).copy()
        n, kh, kw, ci = w.shape
        packed = np.zeros((n, align(kh*kw*ci, 8)), dtype='i1')
        packed[:, :kh*kw*ci] = w.reshape(n, -1)
        require(np.array_equal(packed[:, :kh*kw*ci].reshape(w.shape).transpose(0,3,1,2),
                               weights[name+'.weight']), 'Conv OHWI conversion failed')
        hw_weights[name] = packed
    hw_weights['fc'] = np.zeros((fn, 784), dtype='i1')
    hw_weights['fc'][:10] = weights['fc.weight'].reshape(10,16,7,7).transpose(0,2,3,1).reshape(10,784)
    require(np.array_equal(hw_weights['fc'][:10].reshape(10,7,7,16).transpose(0,3,1,2).reshape(10,784),
                           weights['fc.weight']), 'FC inverse permutation failed')
    # Independent random, signed feature vectors catch flatten mistakes unrelated to MNIST values.
    feature = np.random.default_rng(2718).integers(-127,128,(3,16,7,7), dtype=np.int16)
    require(np.array_equal(feature.reshape(3,784).astype(np.int64) @ weights['fc.weight'].astype(np.int64).T,
            feature.transpose(0,2,3,1).reshape(3,784).astype(np.int64) @ hw_weights['fc'][:10].astype(np.int64).T),
            'Independent FC HWC permutation test failed')

    plan = MemoryPlan(cfg)
    for name in ('conv1','conv2','fc'):
        w = hw_weights[name]
        plan.allocate(name+'_weights', w.nbytes, list(w.shape), 'i1', 'B_transpose[N][aligned_K]',
                      logical_k=(9 if name=='conv1' else 72 if name=='conv2' else 784), row_stride_bytes=w.shape[1])
    bundles = {'weights': dict(address=0, bytes=plan.cursor)}
    param_payloads = {}
    param_start = align(plan.cursor, cfg['alignment_bytes'])
    for name in ('conv1','conv2','fc'):
        n = hw_weights[name].shape[0]
        bias = np.zeros(n, dtype='<i4')
        bias[:len(weights[name+'.bias'])] = weights[name+'.bias']
        # 16-byte header: multiplier, shift, reserved, reserved. Bias at +16.
        s = specs[name]
        param_payloads[name] = struct.pack('<4I', s.get('multiplier',0), s.get('shift',0), 0, 0)+bias.tobytes()
        plan.allocate(name+'_params', len(param_payloads[name]), [4+n], '<u4', 'header[4] + signed_bias[N]')
    bundles['params'] = dict(address=param_start, bytes=plan.cursor-param_start)
    plan.allocate('input', 784, [28,28,1], 'i1', 'HWC')
    plan.allocate('conv1_output', 28*28*8, [28,28,8], 'i1', 'HWC')
    plan.allocate('pool1_output', 14*14*8, [14,14,8], 'i1', 'HWC')
    plan.allocate('conv2_output', 14*14*16, [14,14,16], 'i1', 'HWC')
    plan.allocate('pool2_output_fc_input', fm*784, [fm,784], 'i1', 'row0=HWC[7,7,16]; remaining rows zero',
                  logical_output_shape=[7,7,16], logical_output_bytes=784, padding_bytes=(fm-1)*784)
    plan.allocate('fc_output', fm*fn*4, [fm,fn], '<i4', 'row-major; use row0 columns0..9', alignment=16)
    plan.allocate('commands', 320, [5,16], '<u4', '5 little-endian descriptors', alignment=64)
    r = plan.regions
    addr = lambda name: r[name]['address']
    descriptors = []
    layers = []
    for name, h, ci, co, ain, cout in [
        ('conv1',28,1,8,'input','conv1_output'), ('conv2',14,8,16,'pool1_output','conv2_output')]:
        m, k = h*h, 9*ci
        d = dict(opcode=2, flags=7, m=m, n=co, k=k, a=addr(ain), b=addr(name+'_weights'), c=addr(cout),
                 words10_12=[(h<<16)|h, (3<<24)|(3<<16)|ci, 0x01010101], param=addr(name+'_params'))
        descriptors.append(d)
        layers.append(dict(name=name, m=m,n=co,k=k,a_region=ain,b_region=name+'_weights',c_region=cout,
                           a_stride_bytes=None,b_stride_bytes=align(k,8),c_stride_bytes=co, padding='K row bytes only'))
        pool_name = 'pool1' if name=='conv1' else 'pool2'
        pool_out = 'pool1_output' if name=='conv1' else 'pool2_output_fc_input'
        descriptors.append(dict(opcode=3,flags=0,m=h,n=h,k=co,a=addr(cout),b=0,c=addr(pool_out),
                                words10_12=[0,0,0],param=0))
        layers.append(dict(name=pool_name, input_shape=[h,h,co], output_shape=[h//2,h//2,co],
                           a_region=cout,c_region=pool_out, output_bytes=h//2*(h//2)*co))
    descriptors.append(dict(opcode=1,flags=1,m=fm,n=fn,k=784,a=addr('pool2_output_fc_input'),
                            b=addr('fc_weights'),c=addr('fc_output'),words10_12=[784,784,fn*4],param=addr('fc_params')))
    layers.append(dict(name='fc',m=fm,n=fn,k=784,logical_m=1,logical_n=10,
                       a_region='pool2_output_fc_input',b_region='fc_weights',c_region='fc_output',
                       a_stride_bytes=784,b_stride_bytes=784,c_stride_bytes=fn*4,padding='zero A rows, B rows and extra bias channels'))
    # Validate every DMA row address and byte footprint, independently of scheduler state/timing.
    for layer in layers:
        if 'k' not in layer:
            plan.validate_access(addr(layer['c_region']), layer['output_bytes'], layer['c_region'])
            continue
        m,n,k = layer['m'],layer['n'],layer['k']
        counts = [(m+rows-1)//rows, (n+cols-1)//cols, (k+kt-1)//kt]
        require(all(0 < x < 2**cfg['tile_count_width'] for x in counts), 'Tile counter overflow')
        layer['tile_counts_m_n_k'] = counts
        layer['compute_tiles'] = int(np.prod(counts))
        layer['k_segments'] = [min(kt,k-start) for start in range(0,k,kt)]
        layer['weight_bytes'] = r[layer['b_region']]['bytes']
        layer['output_bytes'] = r[layer['c_region']]['bytes']
        for oc in range(n):
            for start in range(0,k,kt):
                base = addr(layer['b_region'])+oc*layer['b_stride_bytes']+start
                require(base%8 == 0, 'Unaligned B DMA read')
                plan.validate_access(base, align(min(kt,k-start),8), layer['b_region'])
        if layer['name']=='fc':
            for row in range(m):
                for start in range(0,k,kt):
                    base = addr(layer['a_region'])+row*784+start
                    require(base%8 == 0, 'Unaligned A DMA read')
                    plan.validate_access(base, align(min(kt,k-start),8), layer['a_region'])
        else:
            plan.validate_access(addr(layer['a_region']), int(np.prod(r[layer['a_region']]['shape'])), layer['a_region'])
        element_bytes = 4 if layer['name']=='fc' else 1
        for row in range(m):
            for col in range(0,n,cols):
                base = addr(layer['c_region'])+row*layer['c_stride_bytes']+col*element_bytes
                # The DMA masks tail bytes and splits aligned AXI bursts at
                # page boundaries; validate only the logical output region.
                size = min(cols, n-col)*element_bytes
                plan.validate_access(base,size,layer['c_region'])
    original_descriptors = descriptors
    descriptor_layers = [[layer['name']] for layer in layers]
    fusion_report = dict(enabled=args.fuse_conv_pool, fused_pairs=[], skipped_pairs=[],
                         fused_pair_count=0, original_descriptor_count=len(descriptors),
                         descriptor_count=len(descriptors))
    if args.fuse_conv_pool:
        descriptors, descriptor_layers, details = fuse_conv_pool(descriptors, layers, cfg)
        fusion_report.update(details)
    descriptor_count = len(descriptors)
    elided_regions = {pair['intermediate_region'] for pair in fusion_report['fused_pairs']}
    commands = b''.join(encode(d) for d in descriptors)
    for i,d in enumerate(descriptors):
        validate_descriptor(d,cfg)
        require(decode(commands[64*i:64*(i+1)])==d,'Descriptor decode roundtrip failed')
    template = bytearray(plan.cursor)
    for name in ('conv1','conv2','fc'):
        for suffix, data in [('weights',hw_weights[name].tobytes()),('params',param_payloads[name])]:
            base=addr(name+'_'+suffix)
            template[base:base+len(data)] = data
    template[addr('commands'):addr('commands')+len(commands)] = commands
    r['commands'].update(used_bytes=len(commands), descriptor_count=descriptor_count)
    mm = dict(ddr_base=0,ddr_capacity_bytes=cfg['ddr_capacity_bytes'],image_bytes=len(template),
              regions=r,bundles=bundles,desc_base=addr('commands'),desc_count=descriptor_count,
              descriptor_layers=descriptor_layers,
              elided_intermediate_regions=sorted(elided_regions))
    out = args.out.resolve()
    out.mkdir(parents=True,exist_ok=True)
    files = {}

    def emit(name, data, shape=None, dtype='|u1', layout='bytes', load_address=None):
        path=out/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(data)
        entry=dict(bytes=len(data),sha256=digest(path),dtype=dtype,byte_order='little',layout=layout)
        if shape is not None:
            entry['shape']=list(shape)
            require(np.fromfile(path,dtype=dtype).reshape(shape).tobytes()==data,f'BIN roundtrip: {name}')
        if load_address is not None:
            entry['load_address']=load_address
        files[name]=entry

    emit('commands.bin',commands,[descriptor_count,16],'<u4','descriptor words',addr('commands'))
    for bundle in ('weights','params'):
        b=bundles[bundle]
        emit(bundle+'.bin',bytes(template[b['address']:b['address']+b['bytes']]),[b['bytes']],
             layout='see memory_map regions',load_address=b['address'])
    header=MODEL_HEADER.pack(MODEL_MAGIC,1,MODEL_HEADER.size,0,len(template),addr('commands'),descriptor_count)
    emit('model.bin',header+template,layout='48-byte NPUMV0 header + zero-input DDR template; parse header before loading')
    test_x,test_y=common.dataset(False)
    qx=((test_x.astype(np.int32)*127+127)//255).astype('i1')
    images=[]
    for i in range(4):
        image_id=f'image_{i:04d}'
        x=qx[i].transpose(1,2,0).copy()
        image=bytearray(template)
        image[addr('input'):addr('input')+x.nbytes]=x.tobytes()
        emit(f'inputs/{image_id}.bin',x.tobytes(),x.shape,'i1','HWC',addr('input'))
        emit(f'ddr/{image_id}.bin',bytes(image),[len(image)],load_address=0)
        traces, final_mem=execute(np,bytes(image),commands,mm)
        reference=ptq.run_integer(qx[i:i+1],weights,specs,trace=True)
        for name in ('conv1','conv2'):
            for suffix, ref_suffix in [('.acc','.acc'),('', '.relu')]:
                expected=reference[name+ref_suffix][0].transpose(1,2,0)
                require(np.array_equal(traces[name+suffix],expected),f'{image_id} {name+suffix} differs from original PTQ')
        for name, ref_name in [('pool1','conv1.pool'),('pool2','conv2.pool')]:
            require(np.array_equal(traces[name],reference[ref_name][0].transpose(1,2,0)),f'{name} layout mismatch')
        require(np.array_equal(traces['fc.acc'][0,:10],reference['fc.acc'][0]),'FC INT32 differs from original PTQ')
        require(not np.any(traces['fc'][:,10:]),'Padded FC output channels must be zero')
        # Dummy A rows still receive real-channel bias: do not assert all dummy output rows are zero.
        require(np.array_equal(traces['fc'][1:,:10],np.broadcast_to(weights['fc.bias'],(fm-1,10))),
                'Padded FC rows must equal bias in real channels')
        for name,value in traces.items():
            dtype='<i4' if value.dtype.itemsize==4 else 'i1'
            value=value.astype(dtype)
            load_address=None
            output_region=dict(conv1='conv1_output',pool1='pool1_output',conv2='conv2_output',
                               pool2='pool2_output_fc_input',fc='fc_output').get(name)
            if output_region and output_region not in elided_regions:
                load_address=addr(output_region)
                require(final_mem[load_address:load_address+value.nbytes]==value.tobytes(),'C write layout mismatch')
            emit(f'golden/{image_id}/{name}.bin',value.tobytes(),value.shape,dtype,
                 'MN' if name.startswith('fc') else 'HWC',load_address)
        logits=traces['fc'][0,:10].astype('<i4')
        emit(f'golden/{image_id}/logits.bin',logits.tobytes(),[10],'<i4','classes 0..9')
        images.append(dict(image=image_id,label=int(test_y[i]),prediction=int(logits.argmax()),logits=logits.tolist()))
    accuracy=dict(source='saved PTQ manifest; not re-evaluated',accuracy=qmeta['accuracy'])
    if args.full_test:
        correct=0
        for start in range(0,len(qx),64):
            correct+=int((ptq.run_integer(qx[start:start+64],weights,specs)==test_y[start:start+64]).sum())
        require(correct==qmeta['correct'],'Full-test accuracy changed')
        accuracy=dict(source='re-evaluated unchanged integer PTQ on full test set',correct=correct,
                      samples=len(qx),accuracy=correct/len(qx),exported_ddr_interpreter_samples=4)
    require(digest(checkpoint)==original_hash,'FP32 checkpoint was modified')
    report=dict(rtl_commit=target_metadata['commit'],hardware_config=cfg,source_sha256=source_hashes,
                layers=layers,descriptors=descriptors,images=images,software_accuracy=accuracy,
                original_descriptors=original_descriptors,descriptor_layers=descriptor_layers,
                fusion=fusion_report,
                quantization_changed=False,rounding='RTL signed ties-away then ReLU equals original ReLU then positive ties-up',
                checks=['FP32/PTQ weights and bias exact','scale chain unchanged','BIN readback',
                        'Conv OIHW/OHWI equivalence','independent signed FC permutation',
                        'RTL requant boundary values','DDR address/stride/padding/4KiB writes',
                        'descriptor encode/decode','four DDR chains match original PTQ at every output'],
                rtl_execution_verified=False,all_descriptors_static_compatible=True,
                all_five_descriptors_static_compatible=descriptor_count == 5,
                rtl_limitations=['No M/N lane masking: compiler pads FC to 4x12 and allocates all output rows.',
                                 'This SmallCNN compiler targets square arrays and equal A/B bank counts.',
                                 'Native operand reads use 64-bit words and require 8-byte row alignment.'],
                required_rtl_changes_for_this_model=[],
                validation_limit='Generated data was checked by the software model; run make mnist-all for RTL validation.')
    for name,data in [('memory_map.json',mm),('compilation_report.json',report)]:
        emit(name,(json.dumps(data,indent=2,ensure_ascii=False)+'\n').encode('utf-8'),layout='JSON UTF-8')
    (out/'manifest.json').write_text(json.dumps(dict(format_version=1,files=files),indent=2)+'\n',encoding='utf-8')
    verified=verify_files(np,out)
    print(json.dumps(dict(output=str(out),image_bytes=len(template),desc_base=addr('commands'),
                          descriptor_count=descriptor_count,fusion=fusion_report,
                          verified=verified,accuracy=accuracy,rtl_execution_verified=False),indent=2))


if __name__=='__main__':
    try:
        main()
    except (ValueError, FileNotFoundError) as exc:
        raise SystemExit(f'Compilation failed: {exc}')
