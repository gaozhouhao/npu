#!/usr/bin/env python3
"""Run an existing SHA256-frozen graph RTL snapshot with the common VCS checker."""
import argparse
import copy
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/model'))
import run_graph_model as runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-metadata', type=Path, required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--read-latency', type=int, default=20)
    parser.add_argument('--write-latency', type=int, default=0)
    parser.add_argument('--max-cycles', type=int, default=200000000000)
    args = parser.parse_args()
    for name in ('source_metadata', 'package', 'reference', 'out'):
        setattr(args, name, getattr(args, name).resolve())
    runner.require(re.fullmatch(r'[A-Za-z0-9_-]+', args.label), 'Invalid run label')
    runner.require(not (args.out / (args.label+'-rtl')).exists(), 'Refusing existing run directory')
    manifest, reference = runner.load_reference(args.package, args.reference)
    original = json.loads(args.source_metadata.read_text())
    for key, path in (('runner_sha256', Path(runner.__file__)), ('makefile_sha256', ROOT / 'Makefile')):
        runner.require(original[key] == runner.file_hash(path), 'Shared runner or Makefile differs: '+key)
    args.out.mkdir(parents=True, exist_ok=True)
    for name in ('reference.json', 'expected.bin', 'input.hex', 'layers.txt'):
        source, target = args.reference / name, args.out / name
        runner.require(not target.exists() or target.read_bytes() == source.read_bytes(), 'Existing reference differs: '+name)
        if not target.exists():
            shutil.copyfile(str(source), str(target))

    def snapshot(directory, source_ref=None):
        source = Path(directory) / 'source'
        source.mkdir(parents=True, exist_ok=True)
        hashes, rtl, support = {}, [], []
        tb_name = 'sim/tb/system/graph_model_npu_tb.sv'
        for name, expected in original['source_sha256'].items():
            path = Path(name)
            runner.require(not path.is_absolute() and '..' not in path.parts, 'Unsafe frozen path')
            if name == 'sim/filelists/rtl.f':
                data = (args.source_metadata.parent / 'source/rtl.f').read_bytes()
                target = source / 'rtl.f'
            elif name.endswith('.sv'):
                data = (args.source_metadata.parent / 'source' / name).read_bytes()
                target = source / name
            else:
                raise ValueError('Unsupported frozen source entry: '+name)
            runner.require(runner.sha256(data) == expected, 'Frozen source hash differs: '+name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            hashes[name] = expected
            if name.endswith('.sv') and name != tb_name:
                (support if name.startswith('sim/') else rtl).append(str(target))
        runner.require(tb_name in hashes, 'Missing graph testbench')
        metadata = copy.deepcopy(original)
        metadata.update(source_sha256=hashes, source_set_sha256=runner.sha256(json.dumps(hashes, sort_keys=True).encode()),
                        frozen_source_metadata_origin=str(args.source_metadata),
                        frozen_source_metadata_sha256=runner.file_hash(args.source_metadata),
                        frozen_vcs_helper_sha256=runner.file_hash(Path(__file__)), simulator='VCS with common SystemVerilog graph testbench')
        return rtl, str(source / tb_name), support, metadata

    runner.snapshot_sources = snapshot
    runner.run_rtl(args.package, args.out, args.label, original['source_ref'], args.read_latency,
                   args.write_latency, args.max_cycles)
    runner.check(args.package, args.out, args.label, args.read_latency, args.write_latency)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit('FROZEN GRAPH FAILED: '+str(error))
