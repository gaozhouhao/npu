#!/usr/bin/env python
"""Check a legacy ResNet8 RTL DDR dump against independent NPU arithmetic.

This consumes the unmodified TFLite compiler's deployment artifacts. It checks
all physical layer outputs and the entire emitted DDR image, including input,
weights, parameters and descriptors. It does not model TFLite kernel rounding
and does not measure dataset accuracy.
"""
from __future__ import print_function
import argparse
import hashlib
import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'compiler'))
from reference_int8 import execute


def read_bytes(path):
    with open(path, 'rb') as handle:
        return handle.read()


def check(model_dir, rtl_dump, rtl_log=None, model=None):
    with open(os.path.join(model_dir, 'manifest.json')) as handle:
        manifest = json.load(handle)
    image = read_bytes(os.path.join(model_dir, 'ddr.bin'))
    descriptors = read_bytes(os.path.join(model_dir, 'descriptors.bin'))
    if len(descriptors) != manifest['descriptor_count']*64:
        raise ValueError('Descriptor count does not match manifest')
    offset = manifest['descriptor_addr']
    if image[offset:offset+len(descriptors)] != descriptors:
        raise ValueError('DDR descriptor copy does not match descriptors.bin')
    if rtl_log:
        with open(rtl_log) as handle:
            log = handle.read()
        if 'RESNET8 NPU FINISHED:' not in log:
            raise ValueError('RTL did not complete the ResNet8 command chain')
        if 'Fatal:' in log or 'Error-' in log:
            raise ValueError('RTL log contains a simulator error')
    print('Executing independent reference for %d descriptors...' % manifest['descriptor_count'])
    expected, traces = execute(image, descriptors)
    actual = bytearray()
    with open(rtl_dump) as handle:
        for line in handle:
            line = line.strip()
            if line:
                actual.extend(struct.pack('<I', int(line, 16)))
    if len(actual) < len(expected):
        raise ValueError('RTL dump is shorter than compiled DDR image')
    layers = []
    for trace in traces:
        count = len(trace['values'])
        address = trace['output_address']
        expected_bytes = bytearray(value & 255 for value in trace['values'])
        mismatches = sum(a != b for a, b in zip(actual[address:address+count], expected_bytes))
        layer = dict(index=trace['index'], opcode=trace['opcode'], shape=trace['shape'],
                     output_address=address, checked_bytes=count, mismatches=mismatches)
        layers.append(layer)
        print('layer %02d opcode=%d shape=%s bytes=%d mismatches=%d' % (
            layer['index'], layer['opcode'], layer['shape'], count, mismatches))
    mismatches = [i for i, (a, b) in enumerate(zip(actual, expected)) if a != b]
    if mismatches:
        first = mismatches[0]
        raise ValueError('DDR mismatch at 0x%x: RTL=%02x reference=%02x (%d bytes differ)' % (
            first, actual[first], expected[first], len(mismatches)))
    start = manifest['logits_addr']
    count = manifest.get('logits_logical_bytes', manifest['logits_shape'][-1])
    logits = [value-256 if value >= 128 else value for value in actual[start:start+count]]
    report = dict(status='PASS', descriptor_count=len(traces), layers=layers,
                  checked_ddr_bytes=len(expected), ddr_mismatches=0, logits=logits,
                  top1=max(range(len(logits)), key=lambda i: logits[i]),
                  arithmetic='NPU signed INT8; independent serialized-descriptor reference',
                  tflite_bit_exact=False, dataset_accuracy_measured=False)
    if model:
        report['model_sha256'] = hashlib.sha256(read_bytes(model)).hexdigest()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', required=True)
    parser.add_argument('--rtl-dump', required=True)
    parser.add_argument('--rtl-log')
    parser.add_argument('--model')
    parser.add_argument('--report')
    args = parser.parse_args()
    result = check(args.model_dir, args.rtl_dump, args.rtl_log, args.model)
    if args.report:
        with open(args.report, 'w') as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write('\n')
    print('PASS: all %d layers and %d DDR bytes match; top1=%d' % (
        result['descriptor_count'], result['checked_ddr_bytes'], result['top1']))
