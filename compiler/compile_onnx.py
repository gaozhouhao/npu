#!/usr/bin/env python
"""Normalize/plan ONNX, or compile with an explicit calibrated INT8 profile."""
from __future__ import print_function

import argparse
import json
import os
import sys

from target import hardware_defaults
from graph_compiler import plan_graph, compile_graph, quantization_template, write_package
from onnx_frontend import load_graph


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'compile'])
    parser.add_argument('--model', required=True)
    parser.add_argument('--output-tensor', help='Optional ONNX logits boundary')
    parser.add_argument('--out', required=True)
    parser.add_argument('--quantization', help='Calibrated activation profile JSON')
    parser.add_argument('--input-bin', help='Signed INT8 input, tightly packed HWC')
    parser.add_argument('--config', help='Target configuration (defaults read from RTL)')
    parser.add_argument('--ddr-capacity', type=int, default=64*1024*1024)
    parser.add_argument('--dataflow', choices=['a', 'b', 'auto'], default='auto')
    args = parser.parse_args()
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
        if not args.quantization:
            parser.error('compile requires --quantization from real calibration')
        with open(args.quantization) as handle:
            profile = json.load(handle)
        input_data = None
        if args.input_bin:
            with open(args.input_bin, 'rb') as handle:
                input_data = handle.read()
        plan, image, descriptors = compile_graph(graph, cfg, profile, input_data, args.dataflow)
        write_package(args.out, plan, image, descriptors)
        print('COMPILED %d commands; DDR %d bytes; accuracy/RTL validation pending' %
              (plan['descriptor_count'], plan['image_bytes']))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, IOError) as error:
        print('Compile error: '+str(error), file=sys.stderr)
        sys.exit(1)
