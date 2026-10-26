#!/usr/bin/env python3
"""Controlled current-RTL cache/lookahead/prefetch ablation on frozen graphs.

Both variants retain native 64-bit operand reads. The baseline disables only
the declared read-path features in a build-directory snapshot of one pinned
RTL revision. Independent numerical goldens are copied without regeneration.
This experiment measures integer compatibility and simulated performance.
"""

import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys

import run_graph_model as graph_runner


ROOT = graph_runner.ROOT
sys.path.insert(0, str(ROOT / 'scripts/analysis'))
from compare_graph_benchmarks import compare as compare_graphs

PINNED_REF = 'f7419986f24fb7a2ba9902eb5e451e147d6b7abc'
RESNET50_SHA256 = '358c5906f4057cfff3506a63bcf7b502e69e566bdaa9ea598466fe002c3bd3fa'
CHANGED_FILES = ('rtl/npu_top.sv', 'rtl/dma/conv_patch_reader.sv',
                 'rtl/control/gemm_tile_scheduler.sv')
FEATURES = ('conv_cache', 'conv_segment_lookahead', 'b_stationary_prefetch', 'cp_idle_fast_acquire')
GOLDEN_FILES = ('reference.json', 'expected.bin', 'input.hex', 'layers.txt')
EXPERIMENT = 'current_rtl_readpath_feature_ablation'
require, file_hash, write_json, sha256 = (graph_runner.require, graph_runner.file_hash,
                                        graph_runner.write_json, graph_runner.sha256)


def canonical_hash(value):
    return sha256(json.dumps(value, sort_keys=True).encode())


def resolve_ref(source_ref):
    commit = subprocess.check_output(['git', 'rev-parse', '--verify', source_ref+'^{commit}'],
                                     cwd=str(ROOT)).decode().strip()
    require(commit == PINNED_REF, 'Read-path ablation requires the pinned common RTL revision')
    return commit


def prepare(package, reference, output):
    package, reference, output = [Path(path).resolve() for path in (package, reference, output)]
    require(output != reference and reference not in output.parents and output not in reference.parents and
            output != package and package not in output.parents and output not in package.parents,
            'Use an isolated output directory outside the original package/goldens')
    require(not any(character.isspace() for character in str(output)),
            'Simulator paths must not contain whitespace')
    manifest, original = graph_runner.load_reference(package, reference)
    require(manifest.get('purpose') == 'integer_performance' and manifest.get('calibrated') is False,
            'Read-path experiment requires an explicit uncalibrated integer-performance package')
    hashes = {name: file_hash(reference / name) for name in GOLDEN_FILES}
    for name in GOLDEN_FILES:
        if (output / name).exists():
            require(file_hash(output / name) == hashes[name],
                    'Existing output goldens differ; use a new output directory')
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / 'prepared.json', dict(status='RUNNING'))
    for name in GOLDEN_FILES:
        if not (output / name).exists():
            shutil.copyfile(str(reference / name), str(output / name))
    graph_runner.load_reference(package, output)
    require(all(file_hash(output / name) == hashes[name] for name in GOLDEN_FILES),
            'Copied golden bytes differ from the original reference')
    metadata = dict(status='PASS', schema_version=1, experiment=EXPERIMENT,
                    original_reference_directory=str(reference), package_directory=str(package),
                    reference_sha256=hashes['reference.json'], copied_file_sha256=hashes,
                    package_sha256=original['package_sha256'],
                    descriptor_count=original['descriptor_count'], image_bytes=original['image_bytes'],
                    expected_sha256=original['expected_sha256'], accuracy_not_measured=True,
                    native_operand_read_bits=64)
    write_json(output / 'prepared.json', metadata)
    print('ABLATION PREPARED: %d unchanged layer goldens; %d DDR bytes' %
          (metadata['descriptor_count'], metadata['image_bytes']), flush=True)
    return metadata


def load_prepared(package, reference, output):
    output, reference = Path(output).resolve(), Path(reference).resolve()
    manifest, expected = graph_runner.load_reference(package, output)
    metadata = json.loads((output / 'prepared.json').read_text())
    require(metadata.get('status') == 'PASS' and metadata.get('experiment') == EXPERIMENT,
            'Run prepare before the read-path experiment')
    require(metadata['original_reference_directory'] == str(reference) and
            metadata['package_directory'] == str(Path(package).resolve()) and
            metadata['package_sha256'] == expected['package_sha256'],
            'Prepared experiment belongs to a different package/reference')
    require(set(metadata['copied_file_sha256']) == set(GOLDEN_FILES),
            'Prepared golden-file provenance is incomplete')
    for name, digest in metadata['copied_file_sha256'].items():
        require(file_hash(output / name) == digest and file_hash(reference / name) == digest,
                'Original/copied reference changed after prepare: '+name)
    if manifest['graph'].get('model_sha256') == RESNET50_SHA256:
        require(manifest['descriptor_count'] == 72, 'Real ResNet50 must retain all 72 commands')
    return manifest, expected, metadata


def validate_variant_source(metadata, variant, snapshot_root=None):
    require(variant in ('baseline', 'optimized'), 'Unknown read-path variant')
    require(metadata.get('resolved_commit') == PINNED_REF, 'Variant uses a different original RTL revision')
    experiment = metadata.get('readpath_ablation', {})
    require(experiment.get('experiment') == EXPERIMENT and experiment.get('variant') == variant,
            'Missing/mismatched ablation provenance')
    require(experiment.get('native_operand_read_bits') == 64,
            'Both variants must retain native 64-bit operand reads')
    flags = experiment.get('features', {})
    enabled = variant == 'optimized'
    require(set(flags) == set(FEATURES) and
            all(type(flags[name]) is bool and flags[name] is enabled for name in FEATURES),
            'Variant read-path feature flags differ from the declared experiment')
    original, compiled = experiment.get('common_original_source_sha256', {}), metadata['source_sha256']
    require(original and set(original) == set(compiled), 'Original/compiled source sets differ')
    changed = {name for name in original if original[name] != compiled[name]}
    expected_changed = set(CHANGED_FILES) if variant == 'baseline' else set()
    require(changed == expected_changed and set(experiment.get('changed_files', [])) == expected_changed,
            'Compiled sources changed outside the declared three-file recipe')
    require(set(experiment.get('original_sha256', {})) == set(CHANGED_FILES) and
            set(experiment.get('compiled_sha256', {})) == set(CHANGED_FILES),
            'Recipe file provenance is incomplete')
    for name in CHANGED_FILES:
        require(experiment['original_sha256'][name] == original[name] and
                experiment['compiled_sha256'][name] == compiled[name],
                'Recipe hashes differ from actual snapshot hashes')
    patches = experiment.get('patches', [])
    require(len(patches) == len(expected_changed) and
            {patch['path'] for patch in patches} == expected_changed,
            'Recipe patch list is incomplete or unexpected')
    for patch in patches:
        name = patch['path']
        require(patch.get('unified_diff') and patch.get('sha256') == sha256(patch['unified_diff'].encode()) and
                patch['original_sha256'] == original[name] and patch['compiled_sha256'] == compiled[name],
                'Recipe patch bytes/hashes disagree')
    require(experiment.get('patches_sha256') == canonical_hash(patches), 'Recipe patch-set hash differs')
    require(experiment.get('wrapper_sha256') and experiment.get('helper_sha256'),
            'Wrapper/helper provenance missing')
    require(metadata['source_set_sha256'] == canonical_hash(compiled), 'Compiled source-set hash differs')
    if snapshot_root is not None:
        snapshot_root = Path(snapshot_root)
        for name, digest in compiled.items():
            path = snapshot_root / ('rtl.f' if name == 'sim/filelists/rtl.f' else name)
            require(file_hash(path) == digest, 'Snapshot was modified after compilation: '+name)
    return experiment


def run_variant(package, reference, output, variant, source_ref=PINNED_REF,
                read_latency=20, write_latency=0, max_cycles=4000000000):
    import readpath_variants
    require(variant in ('baseline', 'optimized'), 'Unknown read-path variant')
    load_prepared(package, reference, output)
    commit = resolve_ref(source_ref)
    original_snapshot = graph_runner.snapshot_sources

    def snapshot(directory, ignored_ref=None):
        rtl, tb, support, metadata = original_snapshot(directory, commit)
        original = copy.deepcopy(metadata['source_sha256'])
        root = Path(directory) / 'source'
        recipe = readpath_variants.apply_variant(root, variant)
        recipe = copy.deepcopy(recipe)
        for patch in recipe['patches']:
            patch['sha256'] = sha256(patch['unified_diff'].encode())
        recipe.update(experiment=EXPERIMENT, common_original_source_sha256=original,
                      wrapper_sha256=file_hash(Path(__file__)), patches_sha256=canonical_hash(recipe['patches']))
        compiled = {name: file_hash(root / ('rtl.f' if name == 'sim/filelists/rtl.f' else name))
                    for name in original}
        metadata.update(source_sha256=compiled, source_set_sha256=canonical_hash(compiled),
                        readpath_ablation=recipe)
        validate_variant_source(metadata, variant, root)
        return rtl, tb, support, metadata

    # The shared runner supplies compilation, bus timing, strict layer checks,
    # and final DDR handling. Restore the hook even when compilation fails.
    graph_runner.snapshot_sources = snapshot
    try:
        return graph_runner.run_rtl(package, output, variant, commit,
                                    read_latency, write_latency, max_cycles)
    finally:
        graph_runner.snapshot_sources = original_snapshot


def check_variant(package, reference, output, variant, read_latency=20, write_latency=0):
    import readpath_variants
    require(variant in ('baseline', 'optimized'), 'Unknown read-path variant')
    write_json(Path(output) / (variant+'-report.json'), dict(status='CHECKING'))
    load_prepared(package, reference, output)
    source = json.loads((Path(output) / (variant+'-rtl/source.json')).read_text())
    experiment = validate_variant_source(source, variant, Path(output) / (variant+'-rtl/source'))
    require(experiment['wrapper_sha256'] == file_hash(Path(__file__)) and
            experiment['helper_sha256'] == file_hash(Path(readpath_variants.__file__)),
            'Wrapper/helper changed after the experiment was launched')
    report = graph_runner.check(package, output, variant, read_latency, write_latency)
    report.update(experiment=EXPERIMENT, readpath_ablation=experiment,
                  ablation_checker_sha256=file_hash(Path(__file__)),
                  interpretation='Current-RTL cache/lookahead/prefetch ablation; native 64-bit reads shared; accuracy not measured')
    write_json(Path(output) / (variant+'-report.json'), report)
    return report


def compare_reports(baseline, optimized):
    result = compare_graphs(baseline, optimized)
    before = validate_variant_source(baseline['source'], 'baseline')
    after = validate_variant_source(optimized['source'], 'optimized')
    for report in (baseline, optimized):
        require(report.get('experiment') == EXPERIMENT and
                report.get('readpath_ablation') == report['source']['readpath_ablation'],
                'Report is missing verified ablation identity')
        require(report.get('accuracy_not_measured') is True and report.get('calibrated') is False,
                'Feature ablation does not establish calibrated classification accuracy')
        if report.get('model_sha256') == RESNET50_SHA256:
            require(report['checked_layers'] == 72, 'Real ResNet50 comparison must check all 72 commands')
    for key in ('common_original_source_sha256', 'wrapper_sha256', 'helper_sha256'):
        require(before[key] == after[key], 'Ablation provenance differs: '+key)
    require(baseline.get('ablation_checker_sha256') and
            baseline['ablation_checker_sha256'] == optimized.get('ablation_checker_sha256'),
            'Ablation report checkers differ')
    result.update(experiment=EXPERIMENT, common_rtl_commit=PINNED_REF,
                  native_operand_read_bits=64, native64_improvement_attributed=False,
                  baseline_features=before['features'], optimized_features=after['features'],
                  baseline_patch_sha256=before['patches_sha256'],
                  common_original_source_sha256=before['common_original_source_sha256'],
                  wrapper_sha256=before['wrapper_sha256'], helper_sha256=before['helper_sha256'],
                  ablation_checker_sha256=baseline['ablation_checker_sha256'],
                  interpretation='Current-RTL feature ablation of Conv cache, segment lookahead and B-prefetch/acquire; native 64-bit reads shared; accuracy not measured')
    return result


def compare(output):
    output = Path(output)
    write_json(output / 'comparison.json', dict(status='RUNNING'))
    result = compare_reports(json.loads((output / 'baseline-report.json').read_text()),
                             json.loads((output / 'optimized-report.json').read_text()))
    write_json(output / 'comparison.json', result)
    print('ABLATION COMPARE PASS: %d -> %d cycles; reduction %.6f%%' %
          (result['baseline_cycles'], result['current_cycles'], result['cycle_reduction_pct']), flush=True)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'run', 'check', 'compare'))
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--reference', type=Path, default=ROOT / 'build/resnet50-benchmark/check')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--source-ref', default=PINNED_REF)
    parser.add_argument('--variant', choices=('baseline', 'optimized'))
    parser.add_argument('--read-latency', type=int, default=20)
    parser.add_argument('--write-latency', type=int, default=0)
    parser.add_argument('--max-cycles', type=int, default=4000000000)
    args = parser.parse_args(argv)
    if args.action == 'prepare':
        prepare(args.package, args.reference, args.out)
    elif args.action == 'run':
        require(args.variant, 'run requires --variant')
        run_variant(args.package, args.reference, args.out, args.variant, args.source_ref,
                    args.read_latency, args.write_latency, args.max_cycles)
    elif args.action == 'check':
        require(args.variant, 'check requires --variant')
        check_variant(args.package, args.reference, args.out, args.variant,
                      args.read_latency, args.write_latency)
    else:
        load_prepared(args.package, args.reference, args.out)
        compare(args.out)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit('Read-path benchmark failed: '+str(error))
