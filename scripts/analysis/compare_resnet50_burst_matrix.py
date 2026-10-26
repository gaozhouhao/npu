#!/usr/bin/env python3
"""Verify and compare matched Burst serial, double-bank and optimized RTL runs."""
import argparse
from collections import Counter
import hashlib
import json
from math import prod
from pathlib import Path
import re

from compare_graph_benchmarks import compare, require

BURST_REF = 'fd4a041265034c466b9aa3056786dbe863684f4e'
BURST_PATH = 'rtl/dma/conv_patch_loader.sv'
BURST_SHA = '30cbcdaed1b0ba4f254abf1ddcf9c1be1c4f42ec6bdd1c5be4d4630340865b74'
GUARD_PATH = 'rtl/verification/burst_prefetch_guard.sv'
GUARD_SHA = {1: '2296d456ea018a28a9ba285852dcfb53ef6d4a78b6f9aad46a3288bda221a86b',
             2: '6a53da4caf9edc15b5fa2ab3bda856f00205a7ccd290fbb2432729deeb091871'}
SERIAL_GUARD = 'rtl/verification/serial_schedule_guard.sv'
SERIAL_GUARD_SHA = '9c962ffde10c1bb3aff130ccc88173399c13c5f7877193f9f457a249b0dae125'
SOURCE_SET_SHA = (
    'f8f89395ae13beb77e814ea3c32f883d3c82507b391c34d754e0a2a7d7d890d2',
    'cd89ab3d55fff33b9d9dd7e15dc223f5b5b044f16c76578b6efb03ce70f071e8',
    '9fd61c8a980846de4be26614530949a6fa47d2e2e5937b0264372eb211d5bf43')
EXCLUDED_SIM_SOURCES = {'sim/tb/support/axi_memory_model.sv',
    'sim/tb/support/npu_perf_v2_monitor.sv', 'sim/tb/system/graph_model_npu_tb.sv'}
EXCLUDED_COMPAT_TESTS = {'compat/pool2d_configurable_tb.sv', 'compat/pool2d_global_avg_tb.sv'}
ALLOWED_DIFFERENCES = {'rtl/core/tile_scheduler.sv', 'rtl/core/gemm_executor.sv',
                       'rtl/core/npu_top.sv', GUARD_PATH, SERIAL_GUARD}
TOOL_KEYS = ('simulator', 'driver_mode', 'driver_source_sha256', 'verilator_binary_sha256',
             'verilator_wrapper_sha256', 'verilator_helper_sha256', 'compiler_binary_sha256',
             'compiler_wrapper_sha256', 'optimization_level', 'max_cycles')
OVERLAP_KEYS = ('overlap_cycles', 'a_start_overlap', 'b_start_overlap', 'read_overlap', 'sram_overlap')
CONV_KEYS = ('conv_requests', 'conv_words', 'conv_max_beats', 'conv_multibeat_requests', 'conv_received')
FRESH_KEYS = ('a_loads', 'b_loads', 'a_finished', 'b_finished', 'launched', 'completed')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def integer_fields(line, prefix):
    fields = line[len(prefix):].split(',')
    pairs = [field.split('=', 1) for field in fields]
    require(all(len(pair) == 2 and re.fullmatch(r'[0-9]+', pair[1]) for pair in pairs),
            'Malformed counter line: ' + line)
    require(len({pair[0] for pair in pairs}) == len(pairs), 'Duplicate counter field')
    return {key: int(value) for key, value in pairs}


def compile_options(source):
    command = source['command']
    result, skip = [], False
    for argument in command[1:]:
        if skip:
            skip = False
        elif argument == '--Mdir':
            skip = True
        elif not argument.endswith(('.sv', '.cpp')):
            result.append(argument)
    require('--assert' in result and '--cc' in result and '--exe' in result,
            'Expected assertion-enabled cycle-stepped C++ build')
    require(result[result.index('-CFLAGS') + 1] ==
            '-std=c++20 -O%d -pthread' % source['optimization_level'],
            'Compilation flags disagree with optimization metadata')
    return result


def matched_sources(serial, double, optimized):
    sources = [report['source'] for report in (serial, double, optimized)]
    for source in sources:
        require(source.get('status') == 'FINISHED' and source.get('returncode') == 0 and
                source.get('build_returncode') == 0 and source.get('complete_network') is True and
                source.get('prefix_layers') is None, 'Incomplete or failed simulator run')
        require(source['driver_mode'] == 'cpp', 'All three runs must use the C++ driver')
        for key in TOOL_KEYS:
            require(source.get(key) is not None and source[key] == sources[0][key],
                    'Different or missing toolchain/driver condition: ' + key)
        require(compile_options(source) == compile_options(sources[0]), 'Compilation options differ')
    for banks, report in ((1, serial), (2, double)):
        source = report['source']
        expected = dict(A_BUFFER_COUNT=banks, B_BUFFER_COUNT=banks, internal_operand_bits=32,
            external_read_bits=64, overlapping_operand_prefetch=(banks == 2), conv_burst=True,
            conv_max_request_beats=64, A_reuse=False, B_stationary=False, multi_k_A_reuse=False,
            PSUM_slots=False, native64_internal_operands=False, conv_cache=False,
            conv_read_lookahead=False, decoupled_C_writeback=False)
        require(source.get('measurement_parameters') == expected, 'A/B feature configuration differs')
        require(source.get('burst_loader_source_ref') == BURST_REF, 'Historical Burst source differs')
        compiled = source['compiled_source_sha256']
        require(compiled.get(BURST_PATH) == BURST_SHA, 'Pinned historical Burst loader is absent or changed')
        require(compiled.get(GUARD_PATH) == GUARD_SHA[banks], 'Runtime guard is absent or changed')
        require(all(name.endswith('.sv') and source['source_sha256'].get(name) == digest
                    for name, digest in compiled.items()), 'Compiled SV source hash metadata differs')
    require(serial['source']['compiled_source_sha256'].get(SERIAL_GUARD) == SERIAL_GUARD_SHA,
            'Serial scheduling guard absent or changed')
    a, b = (source['compiled_source_sha256'] for source in sources[:2])
    differences = sorted(name for name in set(a) | set(b) if a.get(name) != b.get(name))
    require(set(differences) == ALLOWED_DIFFERENCES,
            'Compiled A/B SV differences exceed scheduler, bridge, banks and observation modules')
    for index, source in enumerate(sources):
        declared = source['source_sha256']
        calculated = sha(json.dumps(declared, sort_keys=True).encode())
        require(calculated == source.get('source_set_sha256') == SOURCE_SET_SHA[index],
                'Pinned source-set hash differs or does not match the declared source hashes')
        excluded = EXCLUDED_SIM_SOURCES | (EXCLUDED_COMPAT_TESTS if index < 2 else set())
        require(set(source['excluded_verification_sources']) == excluded,
                'Unexpected compiled-source exclusions')
        expected_compiled = {name: digest for name, digest in declared.items()
                             if name.endswith('.sv') and name not in excluded}
        require(source['compiled_source_sha256'] == expected_compiled,
                'Compiled SV set differs from the pinned declared sources and explicit exclusions')
    return dict(common_burst_loader_ref=BURST_REF, common_burst_loader_sha256=BURST_SHA,
                allowed_compiled_sv_differences=differences,
                common_toolchain={key: sources[0][key] for key in TOOL_KEYS},
                common_compile_options=compile_options(sources[0]))


def check_log(report, path, banks=None):
    raw = Path(path).read_bytes()
    require(sha(raw) == report['simulation_log_sha256'], 'Simulation log hash differs: ' + str(path))
    lines = raw.decode().splitlines()
    source = report['source']
    arguments = [argument.split('=', 1) for argument in source['run_command'][1:]]
    require(all(len(pair) == 2 and pair[0].startswith('+') for pair in arguments) and
            len({pair[0] for pair in arguments}) == len(arguments), 'Malformed/duplicate run command arguments')
    arguments = {key[1:]: value for key, value in arguments}
    for argument, metadata, label in (('DDR_RD_LATENCY', 'read_latency_cycles', 'read'),
                                      ('DDR_WR_LATENCY', 'write_latency_cycles', 'write')):
        require(int(arguments[argument]) == source[metadata],
                'Run command/source %s latency differs' % label)
        header = 'DDR_%s_LATENCY_CYCLES,%d' % (label.upper(), source[metadata])
        require(sum(line.startswith('DDR_%s_LATENCY_CYCLES,' % label.upper()) for line in lines) == 1 and
                header in lines, 'Raw log/source %s latency differs' % label)
    require(int(arguments['DESC_COUNT']) == report['checked_layers'] and
            int(arguments['IMAGE_WORDS']) * 4 == report['checked_full_ddr_bytes'] and
            int(arguments['MAX_CYCLES']) == source['max_cycles'],
            'Run command layer count/DDR size/cycle limit differs from the report')
    config = [integer_fields(line, 'MODEL_CONFIG,') for line in lines if line.startswith('MODEL_CONFIG,')]
    require(len(config) == 1 and all(config[0][key] == int(arguments[argument]) for key, argument in
            (('image_words', 'IMAGE_WORDS'), ('descriptor_count', 'DESC_COUNT'),
             ('logits_count', 'LOGITS_COUNT'), ('max_cycles', 'MAX_CYCLES'))),
            'Raw log MODEL_CONFIG differs from the run command')
    require('PERF_COUNTER_CHECK,PASS' in lines and
            sum(line.startswith('MODEL_NPU FINISHED:') for line in lines) == 1,
            'Simulator did not finish verified performance counters')
    checks = [line for line in lines if line.startswith('LAYER_CHECK PASS ')]
    require(len(checks) == report['checked_layers'], 'Raw log layer checks are incomplete')
    perf = [integer_fields(line, 'PERF_LAYER,') for line in lines if line.startswith('PERF_LAYER,')]
    require(len(perf) == len(report['layers']), 'Raw log layer performance is incomplete')
    mapping = dict(index='index', opcode='opcode', cycles='cycles', ar='read_transactions',
                   aw='write_transactions', written_bytes='write_bytes')
    for row, layer in zip(perf, report['layers']):
        require(all(row[key] == layer[value] for key, value in mapping.items()),
                'Raw log/report layer counters differ')
        require(row['read_beats'] * 8 == layer['read_bytes'], 'External read beat accounting differs')
    totals = [integer_fields(line, 'PERF_TOTAL,') for line in lines if line.startswith('PERF_TOTAL,')]
    require(len(totals) == 1, 'Missing/duplicate total counters')
    total_mapping = dict(cycles='total_cycles', ar='read_transactions', read_beats='read_beats',
                         aw='write_transactions', write_beats='write_beats', written_bytes='write_bytes')
    require(all(totals[0][key] == report['summary'][value] for key, value in total_mapping.items()),
            'Raw log/report total counters differ')
    finished = next(line for line in lines if line.startswith('MODEL_NPU FINISHED:'))
    finished = integer_fields(','.join(finished[len('MODEL_NPU FINISHED:'):].split()), '')
    require(all(finished[key] == report['summary'][value] for key, value in
            (('cycles', 'total_cycles'), ('read_beats', 'read_beats'), ('write_beats', 'write_beats'),
             ('written_bytes', 'write_bytes'), ('top1', 'top1'))) and
            finished['descriptors'] == finished['layers'] == report['checked_layers'] and
            finished['logits_count'] == int(arguments['LOGITS_COUNT']),
            'Raw log MODEL_NPU FINISHED differs from the report/run command')
    result = dict(path=str(Path(path).resolve()), sha256=sha(raw))
    if banks is None:
        return result
    bank_line = 'BURST_PREFETCH_BANK_CHECK,PASS,a_banks=%d,b_banks=%d' % (banks, banks)
    require(lines.count(bank_line) == 1, 'Missing or wrong physical-bank runtime check')
    rows = [integer_fields(line, 'BURST_PREFETCH_CHECK,PASS,') for line in lines
            if line.startswith('BURST_PREFETCH_CHECK,PASS,')]
    compute = [layer for layer in report['layers'] if layer['operation'] in ('Conv', 'FullyConnected')]
    require(len(rows) == len(compute) > 0, 'Missing/duplicate Conv/FC runtime guard records')
    for index, (row, layer) in enumerate(zip(rows, compute)):
        shape = layer['shape']
        m, n = prod(shape[:-1]), shape[-1]
        require(m > 0 and n > 0 and layer['nominal_macs'] % (m * n) == 0,
                'Cannot derive GEMM dimensions from the checked layer')
        k = layer['nominal_macs'] // (m * n)
        tiles = ((m + 3) // 4) * ((n + 3) // 4) * ((k + 255) // 256)
        require([row[key] for key in ('command', 'conv', 'm', 'n', 'k', 'tiles')] ==
                [index, int(layer['operation'] == 'Conv'), m, n, k, tiles],
                'Runtime command dimensions/tile count differ from the checked model')
        require(all(row[key] == tiles for key in FRESH_KEYS), 'Missing fresh A/B load or compute tile')
        require(0 <= row['overlap_cycles'] <= row['core_busy_cycles'] <= layer['cycles'] and
                row['load_cycles'] <= layer['cycles'], 'Invalid load/compute overlap accounting')
        if banks == 1:
            require(all(row[key] == 0 for key in OVERLAP_KEYS), 'Serial run overlaps loading and compute')
        if layer['operation'] == 'Conv':
            require(row['conv_requests'] > 0 and 0 < row['conv_multibeat_requests'] <= row['conv_requests'] and
                    1 < row['conv_max_beats'] <= 64 and row['conv_words'] == row['conv_received'] and
                    row['conv_words'] >= row['conv_requests'] + row['conv_multibeat_requests'],
                    'Conv does not demonstrate accepted multiword requests and complete data returns')
        else:
            require(all(row[key] == 0 for key in CONV_KEYS), 'FC unexpectedly counted Conv requests')
    aggregate = {key: sum(row[key] for row in rows) for key in FRESH_KEYS + OVERLAP_KEYS +
                 ('tiles', 'load_cycles', 'core_busy_cycles', 'conv_requests', 'conv_words',
                  'conv_multibeat_requests', 'conv_received')}
    aggregate['conv_max_beats'] = max(row['conv_max_beats'] for row in rows)
    if banks == 2:
        require(aggregate['overlap_cycles'] > 0 and aggregate['read_overlap'] > 0 and
                aggregate['a_start_overlap'] + aggregate['b_start_overlap'] > 0,
                'Double-bank run did not demonstrate prefetch and actual read/compute overlap')
    result.update(compute_commands=len(rows), aggregate=aggregate, commands=rows,
                  conv_request_unit='Internal 32-bit words; these counts are not external AXI64 Burst counts')
    return result


def compare_matrix(reports, logs, expected_layers=72, expected_ddr_bytes=29404672):
    serial, double, optimized = reports
    comparisons = dict(serial_to_double=compare(serial, double),
                       double_to_optimized=compare(double, optimized),
                       serial_to_optimized=compare(serial, optimized))
    for report in reports:
        require(report['checked_layers'] == expected_layers and
                report['checked_full_ddr_bytes'] == expected_ddr_bytes,
                'Expected complete layer count/full DDR size has not passed')
    if expected_layers == 72:
        require(Counter(layer['operation'] for layer in serial['layers']) ==
                Counter(Conv=53, FullyConnected=1, Add=16, MaxPool=1, GlobalAveragePool=1),
                'The 72-layer report is not the expected ResNet-50 operator set')
    source_check = matched_sources(*reports)
    runtime = [check_log(report, path, banks) for report, path, banks in zip(reports, logs, (1, 2, None))]
    for key in ('read_transactions', 'read_beats', 'read_bytes', 'write_transactions', 'write_beats', 'write_bytes'):
        require(serial['summary'][key] == double['summary'][key], 'A/B total AXI traffic differs: ' + key)
    for a, b in zip(serial['layers'], double['layers']):
        for key in ('read_transactions', 'read_bytes', 'write_transactions', 'write_bytes'):
            require(a[key] == b[key], 'A/B per-layer traffic differs: ' + key)
    for a, b in zip(runtime[0]['commands'], runtime[1]['commands']):
        require(a['core_busy_cycles'] == b['core_busy_cycles'], 'A/B core computation cycles differ')
        require(all(a[key] == b[key] for key in CONV_KEYS), 'A/B Conv request pattern differs')
    return dict(status='PASS', interpretation='Matched-model simulated performance; dataset accuracy not measured',
                checked_layers=expected_layers, checked_full_ddr_bytes=expected_ddr_bytes,
                full_ddr_sha256=serial['full_ddr_sha256'], package_sha256=serial['package_sha256'],
                model_sha256=serial['model_sha256'], source_check=source_check,
                runtime_checks=dict(zip(('serial', 'double', 'optimized'), runtime)),
                comparisons=comparisons, dataset_accuracy_measured=False,
                attribution='A to B measures buffering/scheduling with the same Burst reader; B to C is the composite subsequent optimization gain. Percentages are not additive.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('serial', 'double', 'optimized'):
        parser.add_argument('--' + name + '-report', type=Path, required=True)
    parser.add_argument('--serial-log', type=Path, required=True)
    parser.add_argument('--double-log', type=Path, required=True)
    parser.add_argument('--optimized-log', type=Path)
    parser.add_argument('--expected-layers', type=int, default=72)
    parser.add_argument('--expected-ddr-bytes', type=int, default=29404672)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    paths = [getattr(args, name + '_report') for name in ('serial', 'double', 'optimized')]
    reports = [json.loads(path.read_text()) for path in paths]
    current_log = args.optimized_log or (Path(reports[2]['source']['run_command'][0]).parent.parent / 'simulation.log')
    logs = [args.serial_log, args.double_log, current_log]
    require(args.out.resolve() not in [path.resolve() for path in paths + logs], 'Output would overwrite evidence')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    try:
        result = compare_matrix(reports, logs, args.expected_layers, args.expected_ddr_bytes)
        result['groups'] = {name: dict(report_path=str(path.resolve()), report_sha256=sha(path.read_bytes()),
            summary=report['summary'], source=report['source']) for name, path, report in
            zip(('serial', 'double', 'optimized'), paths, reports)}
    except (ValueError, KeyError, OSError) as error:
        args.out.write_text(json.dumps(dict(status='FAIL', error=str(error)), indent=2) + '\n')
        raise
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print('BURST MATRIX PASS: %d -> %d -> %d cycles' % tuple(report['summary']['total_cycles'] for report in reports))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit('Burst matrix comparison failed: ' + str(error))
