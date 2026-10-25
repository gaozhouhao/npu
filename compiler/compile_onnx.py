#!/usr/bin/env python
"""Plan ONNX, compile calibrated INT8, or explicitly benchmark integer execution."""
from __future__ import print_function

import argparse
import json
import os
import sys

from target import hardware_defaults
from graph_compiler import (binary, product, plan_graph, compile_graph,
                            quantization_template, benchmark_quantization, write_package)
from onnx_frontend import load_graph


def benchmark_input(shape, seed=1):
    """Reproducible nonzero INT8 bytes; no NumPy or image data required."""
    state = seed & 0xffffffff
    values = bytearray()
    for unused in range(product(shape)):
        state = (1664525*state+1013904223) & 0xffffffff
        values.append((state >> 24) or 1)
    return binary(values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'compile'])
    parser.add_argument('--model', required=True)
    parser.add_argument('--output-tensor', help='Optional ONNX logits boundary')
    parser.add_argument('--out', required=True)
    parser.add_argument('--quantization', help='Calibrated activation profile JSON')
    parser.add_argument('--input-bin', help='Signed INT8 input, tightly packed HWC')
    parser.add_argument('--benchmark-only', action='store_true',
                        help='Use uncalibrated fixed scales for integer performance; accuracy not measured')
    parser.add_argument('--benchmark-scale', type=float, default=0.0625,
                        help='Fixed activation scale for an automatically generated benchmark profile')
    parser.add_argument('--input-seed', type=int, default=1,
                        help='Seed for synthetic benchmark input when --input-bin is absent')
    parser.add_argument('--config', help='Target configuration (defaults read from RTL)')
    parser.add_argument('--ddr-capacity', type=int, default=64*1024*1024)
    parser.add_argument('--dataflow', choices=['a', 'b', 'auto'], default='auto')
    args = parser.parse_args()
    if args.action != 'compile' and args.benchmark_only:
        parser.error('--benchmark-only applies to compile')
    cfg = hardware_defaults()
    cfg.update(ddr_capacity_bytes=args.ddr_capacity, ddr_base=0,
               activation_layout='HWC', alignment_bytes=8)
    if args.config:
        with open(args.config) as handle:
            supplied = json.load(handle)
        for key, value in hardware_defaults().items():
            if key in supplied and supplied[key] != value:
                parser.error('Target '+key+' must match the RTL defaults')
        cfg.update(supplied)
    graph = load_graph(args.model, output=args.output_tensor)
    if args.action == 'prepare':
        plan = plan_graph(graph, cfg, args.dataflow)
        write_package(args.out, plan)
        with open(os.path.join(args.out, 'quantization.template.json'), 'w') as handle:
            json.dump(quantization_template(graph), handle, indent=2, sort_keys=True)
            handle.write('\n')
        print('PREPARED %d commands; DDR %d bytes; calibration required' %
              (plan['descriptor_count'], plan['image_bytes']))
    else:
        if not args.quantization and not args.benchmark_only:
            parser.error('compile requires --quantization from real calibration')
        if args.quantization:
            with open(args.quantization) as handle:
                profile = json.load(handle)
        else:
            profile = benchmark_quantization(graph, args.benchmark_scale)
        input_data = None
        if args.input_bin:
            with open(args.input_bin, 'rb') as handle:
                input_data = handle.read()
        elif args.benchmark_only:
            input_data = benchmark_input(graph['input']['shape'], args.input_seed)
        plan, image, descriptors = compile_graph(graph, cfg, profile, input_data, args.dataflow,
                                                 benchmark_only=args.benchmark_only)
        if args.benchmark_only:
            plan['benchmark_input'] = (dict(source='file', path=os.path.abspath(args.input_bin))
                                       if args.input_bin else
                                       dict(source='synthetic', generator='lcg32-high8-nonzero',
                                            seed=args.input_seed))
        write_package(args.out, plan, image, descriptors)
        if args.benchmark_only:
            with open(os.path.join(args.out, 'quantization.benchmark.json'), 'w') as handle:
                json.dump(profile, handle, indent=2, sort_keys=True)
                handle.write('\n')
            with open(os.path.join(args.out, 'input.bin'), 'wb') as handle:
                handle.write(input_data)
            print('BENCHMARK COMPILED %d commands; DDR %d bytes; uncalibrated; accuracy not measured' %
                  (plan['descriptor_count'], plan['image_bytes']))
        else:
            print('COMPILED %d commands; DDR %d bytes; accuracy/RTL validation pending' %
                  (plan['descriptor_count'], plan['image_bytes']))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, IOError) as error:
        print('Compile error: '+str(error), file=sys.stderr)
        sys.exit(1)
