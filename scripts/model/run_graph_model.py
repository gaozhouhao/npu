#!/usr/bin/env python3
"""Run serialized full graphs against an independent integer reference and RTL.

The model package is reused byte for byte. ``--source-ref`` snapshots only RTL
from a Git revision; the current testbench/support sources are always used.
Reports measure integer compatibility, simulated cycles and external AXI bytes.
No dataset accuracy is measured by this runner.
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'compiler'))
OP_NAMES = {1: 'FullyConnected', 2: 'Conv', 3: 'MaxPool', 4: 'GlobalAveragePool', 5: 'Add'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')


def write_hex(path, data):
    """Little endian words; only the final storage word is padded with zeros."""
    data = bytes(data)
    data += b'\0'*(-len(data) % 4)
    with Path(path).open('w') as handle:
        for offset in range(0, len(data), 4):
            handle.write('%08x\n' % struct.unpack_from('<I', data, offset)[0])


def read_dump(path):
    result = bytearray()
    with Path(path).open() as handle:
        for index, line in enumerate(handle):
            word = line.strip()
            if not word:
                continue
            require(re.fullmatch(r'[0-9a-fA-F]{8}', word) is not None,
                    'Invalid or unknown DDR word at line %d in %s' % (index+1, path))
            result.extend(struct.pack('<I', int(word, 16)))
    return result


def descriptor_mac_counts(descriptors):
    """Dense logical MACs and valid-input MACs, excluding Conv padding/tile tails.

    Counts depend only on geometry, never on numerical input/weight zeros.
    The valid Conv coordinates separate into independent height/width sums.
    """
    require(len(descriptors) > 0 and len(descriptors) % 64 == 0,
            'MAC accounting requires complete descriptors')
    counts = []
    for offset in range(0, len(descriptors), 64):
        words = struct.unpack_from('<16I', descriptors, offset)
        opcode, flags = words[0] & 255, words[0] >> 8
        m, n, k = words[1:4]
        require(opcode in OP_NAMES, 'Unsupported opcode in MAC accounting')
        nominal = m*n*k if opcode in (1, 2) else 0
        useful = nominal
        if opcode == 2:
            geometry, kernel, spatial = words[10:13]
            height, width = geometry & 65535, geometry >> 16
            channels, kh, kw = kernel & 65535, kernel >> 16 & 255, kernel >> 24
            sh, sw, pt, pl = [spatial >> (8*index) & 255 for index in range(4)]
            require(min(height, width, channels, kh, kw, sh, sw, n) > 0,
                    'Invalid Conv MAC geometry')
            if flags & 16:
                oh, ow = (height+sh-1)//sh, (width+sw-1)//sw
            else:
                oh, ow = (height+2*pt-kh)//sh+1, (width+2*pl-kw)//sw+1
            require(oh > 0 and ow > 0 and m == oh*ow and k == channels*kh*kw,
                    'Conv MAC geometry differs from logical M/K')
            valid_height = sum(max(0, min(height, y*sh-pt+kh)-max(0, y*sh-pt))
                               for y in range(oh))
            valid_width = sum(max(0, min(width, x*sw-pl+kw)-max(0, x*sw-pl))
                              for x in range(ow))
            useful = valid_height*valid_width*channels*n
        counts.append(dict(nominal_macs=nominal, useful_macs=useful))
    return counts


def load_package(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / 'manifest.json').read_text())
    image = (directory / 'ddr.bin').read_bytes()
    descriptors = (directory / 'descriptors.bin').read_bytes()
    require(manifest.get('schema_version') == 1, 'Unsupported package schema')
    require(len(image) == manifest['image_bytes'] and len(image) % 4 == 0,
            'DDR image size differs from manifest or is not word aligned')
    require(sha256(image) == manifest.get('ddr_sha256'), 'DDR image SHA256 differs from manifest')
    count = manifest['descriptor_count']
    require(type(count) is int and 0 < count < 65536 and len(descriptors) == count*64,
            'Descriptor count differs from manifest')
    base = manifest['descriptor_base']
    require(type(base) is int and 0 <= base <= len(image)-len(descriptors),
            'Descriptor table exceeds the DDR image')
    require(image[base:base+len(descriptors)] == descriptors,
            'Embedded DDR descriptors differ from descriptors.bin')
    nodes = manifest['graph']['nodes']
    require(len(nodes) == count, 'Graph node count differs from descriptor count')
    for index, graph_node in enumerate(nodes):
        words = struct.unpack_from('<16I', descriptors, index*64)
        opcode, flags = words[0] & 255, words[0] >> 8
        require(OP_NAMES.get(opcode) == graph_node['op'], 'Graph/descriptor opcode mismatch')
        require(not flags & 128 and (opcode not in (1, 2) or flags & 2),
                'Graph runner requires unfused INT8 output commands')
        region = manifest['regions'][graph_node['output']]
        address = words[8] | words[9] << 32
        require(address == region['address'] and
                0 <= address <= len(image)-region['logical_bytes'],
                'Graph output region differs from descriptor or exceeds DDR')
    hashes = dict((name, file_hash(directory / name))
                  for name in ('manifest.json', 'ddr.bin', 'descriptors.bin'))
    return manifest, image, descriptors, hashes


def prepare(package, output):
    from reference_numpy import execute
    package, output = Path(package).resolve(), Path(output).resolve()
    require(not any(character.isspace() for character in str(output)),
            'Layer-check output paths must not contain whitespace')
    manifest, image, descriptors, hashes = load_package(package)
    mac_counts = descriptor_mac_counts(descriptors)
    output.mkdir(parents=True, exist_ok=True)
    layers_dir = output / 'layers'
    layers_dir.mkdir(exist_ok=True)
    write_json(output / 'reference.json', dict(status='RUNNING', package_sha256=hashes))
    write_hex(output / 'input.hex', image)
    layers, started = [], time.monotonic()

    def record(trace):
        index = trace['index']
        require(index == len(layers), 'Reference returned out-of-order layer')
        graph_node = manifest['graph']['nodes'][index]
        region = manifest['regions'][graph_node['output']]
        values = trace['values']
        require(trace['opcode'] == struct.unpack_from('<I', descriptors, index*64)[0] & 255 and
                trace['output_address'] == region['address'] and
                len(values) == region['logical_bytes'], 'Reference trace differs from graph boundary')
        require(all(-128 <= value <= 127 for value in values), 'Reference produced non-INT8 output')
        payload = bytearray(value & 255 for value in values)
        path = layers_dir / ('%03d.hex' % index)
        write_hex(path, payload)
        layers.append(dict(index=index, opcode=trace['opcode'], operation=graph_node['op'],
                           tensor=graph_node['output'], shape=graph_node['shape'],
                           reference_shape=trace['shape'], address=region['address'],
                           logical_bytes=len(payload), sha256=sha256(payload),
                           expected_hex=str(path), expected_hex_sha256=file_hash(path), **mac_counts[index]))
        print('REFERENCE layer=%d/%d op=%s bytes=%d' %
              (index+1, manifest['descriptor_count'], graph_node['op'], len(payload)), flush=True)

    expected, traces = execute(image, descriptors, trace_callback=record, retain_traces=False)
    require(not traces and len(layers) == manifest['descriptor_count'], 'Reference layer count differs')
    (output / 'expected.bin').write_bytes(expected)
    with (output / 'layers.txt').open('w') as handle:
        for layer in layers:
            handle.write('%d %d %x %d %s\n' % (layer['index'], layer['opcode'],
                         layer['address'], layer['logical_bytes'], layer['expected_hex']))
    reference = dict(status='PASS', schema_version=1, package_directory=str(package),
                     package_sha256=hashes, descriptor_count=manifest['descriptor_count'],
                     image_bytes=len(image), expected_sha256=sha256(expected), layers=layers,
                     nominal_macs=sum(layer['nominal_macs'] for layer in layers),
                     useful_macs=sum(layer['useful_macs'] for layer in layers),
                     reference_wall_seconds=time.monotonic()-started,
                     reference_source_sha256=file_hash(ROOT / 'compiler/reference_numpy.py'),
                     input_hex_sha256=file_hash(output / 'input.hex'),
                     layer_checks_sha256=file_hash(output / 'layers.txt'),
                     purpose=manifest.get('purpose', 'integer_compatibility'),
                     calibrated=manifest.get('calibrated', False), dataset_accuracy_measured=False,
                     model_sha256=manifest['graph'].get('model_sha256'))
    write_json(output / 'reference.json', reference)
    print('REFERENCE PASS: %d layers; %d DDR bytes; %.3f seconds' %
          (len(layers), len(image), reference['reference_wall_seconds']), flush=True)
    return reference


def load_reference(package, output):
    manifest, image, descriptors, hashes = load_package(package)
    output = Path(output).resolve()
    reference = json.loads((output / 'reference.json').read_text())
    require(reference.get('status') == 'PASS' and reference.get('package_sha256') == hashes,
            'Reference is incomplete or belongs to a different package; run prepare')
    require(reference['descriptor_count'] == manifest['descriptor_count'] and
            len(reference['layers']) == manifest['descriptor_count'], 'Reference count differs')
    require(file_hash(output / 'expected.bin') == reference['expected_sha256'],
            'Expected DDR image was modified after prepare')
    require(file_hash(output / 'input.hex') == reference['input_hex_sha256'] and
            file_hash(output / 'layers.txt') == reference['layer_checks_sha256'],
            'Prepared simulator input/check list was modified')
    for layer in reference['layers']:
        require(file_hash(layer['expected_hex']) == layer['expected_hex_sha256'],
                'Expected layer image was modified after prepare')
    # Old immutable golden metadata used dense MACs as "useful". Recompute
    # reporting fields from the verified serialized geometry, in memory only.
    counts = descriptor_mac_counts(descriptors)
    for index, (layer, metrics) in enumerate(zip(reference['layers'], counts)):
        require(layer['index'] == index, 'Reference layer indices are not sequential')
        layer.update(metrics)
    for metric in ('nominal_macs', 'useful_macs'):
        reference[metric] = sum(layer[metric] for layer in reference['layers'])
    return manifest, reference


def snapshot_sources(directory, source_ref=None):
    directory = Path(directory)
    source = directory / 'source'
    source.mkdir(parents=True, exist_ok=True)

    def git(*args):
        return subprocess.check_output(['git']+list(args), cwd=str(ROOT))

    commit = git('rev-parse', '--verify', source_ref+'^{commit}').decode().strip() if source_ref else None
    listing = git('show', commit+':sim/filelists/rtl.f') if commit else (ROOT / 'sim/filelists/rtl.f').read_bytes()
    names = [line.strip() for line in listing.decode().splitlines() if line.strip() and not line.lstrip().startswith('#')]
    rtl_paths, hashes = [], {'sim/filelists/rtl.f': sha256(listing)}
    for name in names:
        require(name.startswith('rtl/') and '..' not in Path(name).parts,
                'Unsupported RTL file-list entry: '+name)
        data = git('show', commit+':'+name) if commit else (ROOT / name).read_bytes()
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[name] = sha256(data)
        rtl_paths.append(str(target))
    (source / 'rtl.f').write_bytes(listing)
    tb_name = 'sim/tb/system/graph_model_npu_tb.sv'
    shared_names = [tb_name]+[str(path.relative_to(ROOT))
                            for path in sorted((ROOT / 'sim/tb/support').glob('*.sv'))]
    shared_paths = []
    for name in shared_names:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        data = (ROOT / name).read_bytes()
        target.write_bytes(data)
        hashes[name] = sha256(data)
        shared_paths.append(str(target))
    return rtl_paths, shared_paths[0], shared_paths[1:], dict(
        source_ref=source_ref or 'workingtree', resolved_commit=commit, source_sha256=hashes,
        source_set_sha256=sha256(json.dumps(hashes, sort_keys=True).encode()),
        runner_sha256=file_hash(Path(__file__)), makefile_sha256=file_hash(ROOT / 'Makefile'))


def run_rtl(package, output, label='current', source_ref=None,
            read_latency=20, write_latency=0, max_cycles=4000000000):
    require(re.fullmatch(r'[A-Za-z0-9_-]+', label) is not None, 'Invalid run label')
    require(read_latency >= 0 and write_latency >= 0 and max_cycles > 0,
            'Latencies must be nonnegative and maximum cycles positive')
    output = Path(output).resolve()
    manifest, reference = load_reference(package, output)
    directory = output / (label+'-rtl')
    directory.mkdir(parents=True, exist_ok=True)
    write_json(output / (label+'-report.json'), dict(status='RUNNING'))
    for name in ('simulation.log', 'ddr.hex'):
        path = directory / name
        if path.exists():
            path.unlink()
    rtl, tb, support, metadata = snapshot_sources(directory, source_ref)
    max_bytes = max(layer['logical_bytes'] for layer in reference['layers'])
    logits = manifest['regions'][manifest['output']]
    plusargs = ['+DDR_HEX='+str(output / 'input.hex'), '+IMAGE_WORDS=%d' % (manifest['image_bytes']//4),
                '+DESC_BASE=%x' % manifest['descriptor_base'],
                '+DESC_COUNT=%d' % manifest['descriptor_count'],
                '+LOGITS_BASE=%x' % logits['address'], '+LOGITS_COUNT=%d' % logits['logical_bytes'],
                '+MAX_CYCLES=%d' % max_cycles, '+DDR_RD_LATENCY=%d' % read_latency,
                '+DDR_WR_LATENCY=%d' % write_latency, '+LAYER_CHECKS='+str(output / 'layers.txt'),
                '+DDR_DUMP='+str(directory / 'ddr.hex')]
    command = ['make', '--no-print-directory', 'test', 'TEST=graph_model_npu_tb',
               'DEFINES=NPU_PERF_ENABLE', 'RUN_DIR='+str(directory),
               'RTL_SRCS='+' '.join(rtl), 'TB_SRC='+tb, 'SUPPORT_SRCS='+' '.join(support),
               'PARAMS=MEM_WORDS=%d MAX_LAYER_WORDS=%d' % (manifest['image_bytes']//4, (max_bytes+3)//4),
               'RUN_ARGS='+' '.join(plusargs)]
    metadata.update(status='RUNNING', command=command, read_latency_cycles=read_latency,
                    write_latency_cycles=write_latency, max_cycles=max_cycles,
                    package_sha256=reference['package_sha256'],
                    reference_sha256=file_hash(output / 'reference.json'))
    write_json(directory / 'source.json', metadata)
    started = time.monotonic()
    print('RTL RUN: %s; %d layers; read latency %d; write latency %d' %
          (label, manifest['descriptor_count'], read_latency, write_latency), flush=True)
    with (directory / 'build-run.log').open('w') as handle:
        result = subprocess.run(command, cwd=str(ROOT), stdout=handle, stderr=subprocess.STDOUT)
    metadata.update(status='FINISHED' if result.returncode == 0 else 'FAILED',
                    returncode=result.returncode, simulation_wall_seconds=time.monotonic()-started)
    write_json(directory / 'source.json', metadata)
    require(result.returncode == 0, 'RTL build/run failed; see '+str(directory / 'build-run.log'))
    return metadata


def parse_perf(log, reference, read_latency=20, write_latency=0):
    text = Path(log).read_text()
    require(not re.search(r'(^Fatal:|^Error[: -]|^FAIL|TEST.?FAIL|LAYER_CHECK FAIL|\$fatal)', text, re.M),
            'Simulator error in '+str(log))
    require(re.findall(r'^DDR_READ_LATENCY_CYCLES,(\d+)$', text, re.M) == [str(read_latency)],
            'DDR read latency mismatch')
    require(re.findall(r'^DDR_WRITE_LATENCY_CYCLES,(\d+)$', text, re.M) == [str(write_latency)],
            'DDR write latency mismatch')
    finishes = re.findall(r'^MODEL_NPU FINISHED: (.+)$', text, re.M)
    require(len(finishes) == 1, 'Missing/duplicate completed inference')
    def numeric_fields(pairs):
        result = dict((key, int(value)) for key, value in pairs)
        require(len(result) == len(pairs), 'Duplicate field in simulator record')
        return result

    finish = numeric_fields(re.findall(r'(\w+)=(\d+)', finishes[0]))
    require('PERF_COUNTER_CHECK,PASS' in text, 'AXI counter check missing')
    layers, checks, total = {}, {}, None
    for line in text.splitlines():
        if line.startswith('LAYER_CHECK PASS '):
            check = numeric_fields(re.findall(r'(\w+)=(\d+)', line))
            index = check['index']
            require(index not in checks, 'Duplicate layer check')
            checks[index] = check
        elif line.startswith(('PERF_LAYER,', 'PERF_TOTAL,')):
            name, *fields = line.split(',')
            record = numeric_fields([field.split('=', 1) for field in fields])
            require(all(value >= 0 for value in record.values()), 'Negative performance counter')
            if name == 'PERF_LAYER':
                require(record['index'] not in layers, 'Duplicate layer performance record')
                layers[record['index']] = record
            else:
                require(total is None, 'Duplicate total performance record')
                total = record
    count = reference['descriptor_count']
    require(set(layers) == set(range(count)), 'Incomplete layer performance records')
    require(set(checks) == set(range(count)), 'Incomplete per-layer correctness checks')
    require(total is not None and total['cycles'] > 0, 'Missing total performance counters')
    require(finish.get('layers') == count and finish.get('descriptors') == count,
            'Completed descriptor/layer count differs from package')
    require(finish.get('cycles') == total['cycles'] and
            finish.get('logits_count') == reference['layers'][-1]['logical_bytes'],
            'Completed cycle/logit count differs from monitor/package')
    require(total['read_beats'] == finish.get('read_beats') and
            total['write_beats'] == finish.get('write_beats') and
            total['written_bytes'] == finish.get('written_bytes'),
            'Testbench/monitor AXI beat counts differ')
    require(sum(layer['write_beats'] for layer in layers.values()) == total['write_beats'],
            'Writes outside completed layer records')
    require(sum(layer['read_beats'] for layer in layers.values()) <= total['read_beats'] and
            sum(layer['cycles'] for layer in layers.values()) <= total['cycles'],
            'Layer counters exceed total counters')
    rows = []
    for expected in reference['layers']:
        index = expected['index']
        actual, checked = layers[index], checks[index]
        require(actual['opcode'] == expected['opcode'] and checked.get('opcode') == expected['opcode'] and
                checked.get('checked_bytes') == expected['logical_bytes'], 'Layer opcode/checked bytes differ')
        require(0 <= actual['written_bytes'] <= actual['write_beats']*4,
                'Layer write-strobe bytes exceed accepted beats')
        row = dict(expected)
        row.update(cycles=actual['cycles'], executor_cycles=actual['executor'], pool_cycles=actual['pool'],
                   read_transactions=actual['ar'], write_transactions=actual['aw'],
                   read_bytes=actual['read_beats']*8, write_bytes=actual['written_bytes'])
        rows.append(row)
    require(sum(row['write_bytes'] for row in rows) == total['written_bytes'],
            'Per-layer write-strobe byte counts differ from total')
    summary = dict(total_cycles=total['cycles'], testbench_cycles=finish['cycles'],
                   executor_cycles=total['executor'], pool_cycles=total['pool'],
                   read_transactions=total['ar'], write_transactions=total['aw'],
                   read_beats=total['read_beats'], write_beats=total['write_beats'],
                   read_bytes=total['read_beats']*8, write_bytes=total['written_bytes'],
                   nominal_macs=reference['nominal_macs'],
                   useful_macs=reference['useful_macs'],
                   effective_useful_mac_utilization=reference['useful_macs']/(16.0*total['cycles']),
                   cycles_outside_layers=total['cycles']-sum(row['cycles'] for row in rows))
    summary['external_bytes'] = summary['read_bytes']+summary['write_bytes']
    if 'top1' in finish:
        summary['top1'] = finish['top1']
    return summary, rows


def check(package, output, label='current', read_latency=20, write_latency=0):
    output = Path(output).resolve()
    require(re.fullmatch(r'[A-Za-z0-9_-]+', label) is not None, 'Invalid run label')
    write_json(output / (label+'-report.json'), dict(status='CHECKING'))
    manifest, reference = load_reference(package, output)
    directory = output / (label+'-rtl')
    metadata = json.loads((directory / 'source.json').read_text())
    require(metadata.get('status') == 'FINISHED' and metadata.get('returncode') == 0,
            'RTL run has not finished successfully')
    require(metadata['package_sha256'] == reference['package_sha256'] and
            metadata['reference_sha256'] == file_hash(output / 'reference.json'),
            'RTL run belongs to a different package/reference')
    require(metadata['read_latency_cycles'] == read_latency and
            metadata['write_latency_cycles'] == write_latency, 'Run/check latency arguments differ')
    summary, rows = parse_perf(directory / 'simulation.log', reference, read_latency, write_latency)
    actual = read_dump(directory / 'ddr.hex')
    expected = (output / 'expected.bin').read_bytes()
    require(len(actual) == len(expected) == manifest['image_bytes'], 'Final DDR dump size differs')
    if actual != expected:
        first = next(index for index, (a, b) in enumerate(zip(actual, expected)) if a != b)
        raise ValueError('Final DDR differs at byte %d: %d != %d' % (first, actual[first], expected[first]))
    report = dict(status='PASS', summary=summary, layers=rows, source=metadata,
                  checker_sha256=file_hash(Path(__file__)),
                  package_sha256=reference['package_sha256'], model_sha256=reference.get('model_sha256'),
                  full_ddr_sha256=sha256(actual), checked_full_ddr_bytes=len(actual),
                  checked_layers=len(rows), simulation_log_sha256=file_hash(directory / 'simulation.log'),
                  purpose=manifest.get('purpose', 'integer_compatibility'),
                  calibrated=manifest.get('calibrated', False), dataset_accuracy_measured=False,
                  accuracy_not_measured=True,
                  interpretation='Integer RTL compatibility and simulated performance; dataset accuracy not measured')
    write_json(output / (label+'-report.json'), report)
    fields = ['index', 'operation', 'tensor', 'logical_bytes', 'nominal_macs', 'useful_macs', 'cycles',
              'executor_cycles', 'pool_cycles', 'read_bytes', 'write_bytes']
    for path in (output / (label+'-per_layer.csv'), output / 'per_layer.csv'):
        with path.open('w', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, extrasaction='ignore')
            writer.writeheader()
            writer.writerows(rows)
    print('MODEL PASS: %d layers; %d cycles; %d read bytes; %d write bytes; useful MAC utilization %.6f' %
          (len(rows), summary['total_cycles'], summary['read_bytes'], summary['write_bytes'],
           summary['effective_useful_mac_utilization']), flush=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run', 'check', 'all'])
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--label', default='current')
    parser.add_argument('--source-ref', help='Git revision supplying only the RTL snapshot')
    parser.add_argument('--read-latency', type=int, default=20)
    parser.add_argument('--write-latency', type=int, default=0)
    parser.add_argument('--max-cycles', type=int, default=4000000000)
    args = parser.parse_args(argv)
    require(re.fullmatch(r'[A-Za-z0-9_-]+', args.label) is not None, 'Invalid run label')
    require(args.read_latency >= 0 and args.write_latency >= 0 and args.max_cycles > 0,
            'Latencies must be nonnegative and maximum cycles positive')
    if args.action in ('prepare', 'all'):
        prepare(args.package, args.out)
    if args.action in ('run', 'all'):
        run_rtl(args.package, args.out, args.label, args.source_ref,
                args.read_latency, args.write_latency, args.max_cycles)
    if args.action in ('check', 'all'):
        check(args.package, args.out, args.label, args.read_latency, args.write_latency)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit('Graph model failed: '+str(error))
