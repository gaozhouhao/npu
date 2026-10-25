#!/usr/bin/env python3
"""Compare verified graph runs only when model and simulation conditions match."""

import argparse
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def compare(baseline, current):
    for report in (baseline, current):
        require(report.get('status') == 'PASS', 'Both full runs must pass verification')
        require(report.get('checked_layers', 0) == len(report.get('layers', [])) > 0,
                'A report has incomplete layer checks')
        require(report['summary']['total_cycles'] > 0, 'Cycle count must be positive')
    for key in ('package_sha256', 'model_sha256', 'checked_full_ddr_bytes',
                'checked_layers', 'full_ddr_sha256', 'purpose', 'calibrated', 'checker_sha256'):
        require(baseline[key] == current[key], 'Reports differ in '+key)
    for key in ('read_latency_cycles', 'write_latency_cycles', 'reference_sha256',
                'runner_sha256', 'makefile_sha256'):
        require(baseline['source'][key] == current['source'][key],
                'Different simulation/reference conditions: '+key)
    shared = []
    for report in (baseline, current):
        shared.append({path: value for path, value in report['source']['source_sha256'].items()
                       if path.startswith('sim/tb/')})
    require(shared[0] and shared[0] == shared[1], 'Testbench/support sources differ')
    layer_rows = []
    for before, after in zip(baseline['layers'], current['layers']):
        for key in ('index', 'opcode', 'operation', 'tensor', 'logical_bytes',
                    'nominal_macs', 'useful_macs', 'sha256'):
            require(before[key] == after[key], 'Layer identity/numerical result differs: '+key)
        require(before['cycles'] > 0 and after['cycles'] > 0, 'Layer cycle count must be positive')
        layer_rows.append(dict(index=before['index'], operation=before['operation'],
                               tensor=before['tensor'], baseline_cycles=before['cycles'],
                               current_cycles=after['cycles'],
                               cycles_saved=before['cycles']-after['cycles'],
                               read_bytes_saved=before['read_bytes']-after['read_bytes'],
                               write_bytes_saved=before['write_bytes']-after['write_bytes']))
    before, after = baseline['summary'], current['summary']
    require(before['useful_macs'] == after['useful_macs'], 'Logical MAC count differs')
    require(before['nominal_macs'] == after['nominal_macs'], 'Nominal MAC count differs')
    return dict(status='PASS', interpretation='Matched-model simulated performance; accuracy not measured',
                model_sha256=baseline['model_sha256'], checked_layers=baseline['checked_layers'],
                checked_full_ddr_bytes=baseline['checked_full_ddr_bytes'],
                baseline_commit=baseline['source'].get('resolved_commit'),
                current_commit=current['source'].get('resolved_commit'),
                read_latency_cycles=baseline['source']['read_latency_cycles'],
                write_latency_cycles=baseline['source']['write_latency_cycles'],
                baseline_cycles=before['total_cycles'], current_cycles=after['total_cycles'],
                cycles_saved=before['total_cycles']-after['total_cycles'],
                cycle_reduction_pct=100.0*(before['total_cycles']-after['total_cycles'])/before['total_cycles'],
                speedup=before['total_cycles']/float(after['total_cycles']),
                baseline_read_bytes=before['read_bytes'], current_read_bytes=after['read_bytes'],
                baseline_write_bytes=before['write_bytes'], current_write_bytes=after['write_bytes'],
                useful_macs=before['useful_macs'],
                nominal_macs=before['nominal_macs'],
                baseline_effective_useful_mac_utilization=before['effective_useful_mac_utilization'],
                current_effective_useful_mac_utilization=after['effective_useful_mac_utilization'],
                full_ddr_identical=True, dataset_accuracy_measured=False, layers=layer_rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--current', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dict(status='RUNNING'))+'\n')
    result = compare(json.loads(args.baseline.read_text()), json.loads(args.current.read_text()))
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print('COMPARE PASS: %d -> %d cycles; reduction %.6f%%; speedup %.6fx' %
          (result['baseline_cycles'], result['current_cycles'],
           result['cycle_reduction_pct'], result['speedup']))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit('Comparison failed: '+str(error))
