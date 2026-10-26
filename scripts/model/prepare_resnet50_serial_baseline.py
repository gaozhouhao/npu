#!/usr/bin/env python3
"""Prepare the declared historical serial NPU baseline in a fresh directory.

Reuse a validated legacy00 frozen source.json, restore the exact 1dc serial
scheduler, bridge its original final-DDR-write handshake, and select one A/B
bank. This prepares sources only and never edits the supplied base snapshot.
The result includes later functional Conv/quantization compatibility; it is not
an untouched original 1dc whole NPU.
"""

import argparse
import difflib
import json
import shutil
import sys
from pathlib import Path

import prepare_resnet50_rollback as rollback
from prepare_resnet50_rollback import digest, git_bytes, relative_path, require

ROOT = Path(__file__).resolve().parents[2]
RECIPES = Path(__file__).resolve().with_name('rollback_compat')
SERIAL_COMMIT = '1dc5b2d5d1981f08a8c2cb6efeee73327d2846f4'
CNN_COMMIT = '00fd93c6f0deabf8c427fa34a6f6ac1d58e9ce47'
COMMON_COMMIT = 'af66f524875d78d443309a25754f049dbe4d4999'
ORIGINAL_SHA256 = {
    'rtl/core/tile_scheduler.sv': 'cbf12ac6a5d377cc5cf252ad544a26c00e6ab1fa0a2875902cc16a263f9177e3',
    'rtl/core/gemm_executor.sv': '28ecdedddfb51060c8e92ed48c11bc08d8cc26bc46b507b3e74ba656d72f36b1',
}
FINAL_SHA256 = {
    'rtl/core/gemm_executor.sv': '6cc7cd4b7ae5831123c282ae8b23d1ccc3fb186821da910efc387347141f4f13',
    'rtl/core/npu_top.sv': '0174dc3a3a4585ac409bf2875f664d8326cdc1fcdeb34cd1ce2ceff7b6fa0d53',
    'rtl/verification/serial_schedule_guard.sv': '9c962ffde10c1bb3aff130ccc88173399c13c5f7877193f9f457a249b0dae125',
}
FINAL_SOURCE_SET_SHA256 = '262af25da19469bccc2a6d72845eac58ceb30a2e9e4280566b672b437b2013e2'
COMMON_TESTBENCHES = (
    'sim/tb/support/axi_memory_model.sv',
    'sim/tb/support/npu_perf_v2_monitor.sv',
    'sim/tb/system/graph_model_npu_tb.sv',
)
GUARD_PATH = 'rtl/verification/serial_schedule_guard.sv'


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def replace_once(text, before, after):
    require(text.count(before) == 1,
            'Expected exactly one serial bridge context: ' + repr(before))
    return text.replace(before, after)


def inside_bytes(directory, name):
    relative_path(name)
    directory = Path(directory).resolve()
    path = (directory / name).resolve()
    require(directory in path.parents, 'Source path escapes base directory: ' + name)
    return path.read_bytes()


def bridge_executor(data):
    text = data.decode('utf-8')
    text = replace_once(text,
        '        .load_m_tile_idx    (load_m_tile_idx),\n'
        '        .load_n_tile_idx    (load_n_tile_idx),\n'
        '        .load_k_tile_idx    (load_k_tile_idx),\n'
        '        .load_k_size        (scheduler_load_k_size),',
        '        .m_tile_idx         (load_m_tile_idx),\n'
        '        .n_tile_idx         (load_n_tile_idx),\n'
        '        .k_tile_idx         (load_k_tile_idx),\n'
        '        .current_k_size     (scheduler_load_k_size),')
    text = replace_once(text,
        '        .matrix_done        (core_done),\n\n'
        '        .writeback_done     (c_write_done),',
        '        .matrix_done        ((core_done && !scheduler_writeback_en) || c_write_done),')
    text = replace_once(text,
        '        .compute_k_size     (scheduler_compute_k_size),\n'
        '        .compute_m_tile_idx (compute_m_tile_idx),\n'
        '        .compute_n_tile_idx (compute_n_tile_idx),\n\n', '')
    marker = ('    // ============================================================\n'
              '    // Address Generator\n'
              '    // ============================================================\n')
    aliases = ('    // The historical serial scheduler has one coordinate set. It stays\n'
               '    // stable until final C DDR writeback, matching the original 1dc executor.\n'
               '    assign compute_m_tile_idx = load_m_tile_idx;\n'
               '    assign compute_n_tile_idx = load_n_tile_idx;\n'
               '    assign scheduler_compute_k_size = scheduler_load_k_size;\n\n')
    return replace_once(text, marker, aliases + marker).encode()


def assemble(repo, base_metadata, guard_file=RECIPES / 'serial_schedule_guard.sv'):
    """Validate pinned historical originals, base bytes and all final bytes in memory."""
    repo, base_metadata = Path(repo).resolve(), Path(base_metadata).resolve()
    raw_metadata = base_metadata.read_bytes()
    base = json.loads(raw_metadata)
    require(base['source_ref'] == CNN_COMMIT and base['resolved_commit'] == CNN_COMMIT,
            'Base must identify the pinned legacy00 functional snapshot')
    require(base.get('variant') == 'legacy00' and base.get('functional_compatibility') is True,
            'Base must be the declared legacy00 compatibility variant')
    declared = base['source_sha256']
    require(digest(json.dumps(declared, sort_keys=True).encode()) == base['source_set_sha256'],
            'Base source-set SHA256 differs')
    recipe_raw = (RECIPES / 'legacy00.json').read_bytes()
    recipe = json.loads(recipe_raw)
    expected_rtl = recipe['compiled_rtl_sha256']
    require({name: value for name, value in declared.items()
             if name.endswith('.sv') and not name.startswith('sim/')} == expected_rtl,
            'Base RTL source set differs from the validated legacy00 recipe')
    expected_keys = set(expected_rtl) | set(COMMON_TESTBENCHES) | {'sim/filelists/rtl.f'}
    require(set(declared) == expected_keys, 'Unexpected base source file set')
    source = base_metadata.parent / 'source'
    original = {}
    for name, expected in sorted(declared.items()):
        physical = 'rtl.f' if name == 'sim/filelists/rtl.f' else name
        data = inside_bytes(source, physical)
        require(digest(data) == expected, 'Base frozen source SHA256 differs: ' + name)
        original[physical] = data
    for name in COMMON_TESTBENCHES:
        require(original[name] == git_bytes(repo, COMMON_COMMIT, name),
                'Common verification source differs from pinned Git source: ' + name)
    early = {}
    for name, expected in ORIGINAL_SHA256.items():
        data = git_bytes(repo, SERIAL_COMMIT, name)
        require(digest(data) == expected, 'Historical serial original SHA256 differs: ' + name)
        early[name] = data
    guard = Path(guard_file).read_bytes()
    require(digest(guard) == FINAL_SHA256[GUARD_PATH], 'Serial verification guard SHA256 differs')
    outputs = dict(original)
    changes = []

    def change(name, data, reason, origin):
        old = outputs[name]
        require(old != data, 'Serial change unexpectedly empty: ' + name)
        outputs[name] = data
        patch = ''.join(difflib.unified_diff(
            old.decode().splitlines(keepends=True), data.decode().splitlines(keepends=True),
            fromfile='legacy00/' + name, tofile='legacy-serial/' + name)).encode()
        patch_name = 'change-%d.patch' % (len(changes) + 1)
        changes.append(dict(path=name, original_sha256=digest(old), result_sha256=digest(data),
                            reason=reason, origin=origin, diff_path=patch_name,
                            diff_sha256=digest(patch)))
        return patch_name, patch

    patches = dict([change('rtl/core/tile_scheduler.sv', early['rtl/core/tile_scheduler.sv'],
                          'Exact historical serial load / compute / final DDR write scheduler.', SERIAL_COMMIT)])
    patch_name, patch = change('rtl/core/gemm_executor.sv',
        bridge_executor(original['rtl/core/gemm_executor.sv']),
        'Adapt scheduler ports only; restore original completion gating and shared load/compute coordinates.',
        '1dc serial handshake plus legacy00 functional executor')
    patches[patch_name] = patch
    text = original['rtl/core/npu_top.sv'].decode()
    text = replace_once(text, 'parameter int unsigned A_BUFFER_COUNT = 2,',
                        'parameter int unsigned A_BUFFER_COUNT = 1,')
    text = replace_once(text, 'parameter int unsigned B_BUFFER_COUNT = 2',
                        'parameter int unsigned B_BUFFER_COUNT = 1')
    patch_name, patch = change('rtl/core/npu_top.sv', text.encode(),
                              'Select pre-existing single physical operand-bank configuration.',
                              'measurement parameters A_BUFFER_COUNT=1, B_BUFFER_COUNT=1')
    patches[patch_name] = patch
    outputs[GUARD_PATH] = guard
    listing = original['rtl.f'].decode().splitlines()
    require(GUARD_PATH not in listing, 'Serial verification guard already in base listing')
    outputs['rtl.f'] = ('\n'.join(listing + [GUARD_PATH]) + '\n').encode()
    for name, expected in FINAL_SHA256.items():
        require(digest(outputs[name]) == expected, 'Final serial source SHA256 differs: ' + name)
    hashes = {name: digest(data) for name, data in outputs.items() if name.endswith('.sv')}
    hashes['sim/filelists/rtl.f'] = digest(outputs['rtl.f'])
    source_set = digest(json.dumps(hashes, sort_keys=True).encode())
    require(source_set == FINAL_SOURCE_SET_SHA256, 'Final serial source-set SHA256 differs')
    parameters = dict(A_BUFFER_COUNT=1, B_BUFFER_COUNT=1, internal_operand_bits=32,
                      external_read_bits=64, overlapping_operand_prefetch=False)
    metadata = {key: base[key] for key in ('runner_sha256', 'makefile_sha256',
                'rollback_runner_sha256', 'common_external_read_bits', 'legacy_internal_operand_bits')}
    metadata.update(source_ref=SERIAL_COMMIT, resolved_commit=SERIAL_COMMIT,
        variant='legacy_serial', status='PREPARED', functional_compatibility=True,
        source_sha256=hashes, source_set_sha256=source_set,
        schedule_source_ref=SERIAL_COMMIT, cnn_functional_source_ref=CNN_COMMIT,
        measurement_parameters=parameters, verification_module=GUARD_PATH,
        verification_module_classification='observation_only',
        compatibility_note='Mixed-source declared baseline: exact 1dc historical serial scheduler; '
            'validated legacy00 byte-at-a-time Conv/internal32 implementation and functional compatibility; '
            'common external AXI64 shell; one physical A bank and one B bank. '
            'Not an untouched original 1dc whole NPU.')
    unchanged = [name for name in sorted(hashes) if name.endswith('.sv') and
                 hashes[name] == declared.get(name)]
    provenance = dict(schema_version=1, status='PREPARED',
        preparation_script_sha256=digest(Path(__file__).read_bytes()),
        preparation_helper_sha256=digest(Path(rollback.__file__).read_bytes()),
        base_metadata_path=str(base_metadata), base_metadata_sha256=digest(raw_metadata),
        legacy00_recipe_sha256=digest(recipe_raw), microarchitecture_baseline=SERIAL_COMMIT,
        functional_cnn_base=CNN_COMMIT, untouched_original_whole_npu=False,
        original_serial_git_sha256={name: digest(data) for name, data in early.items()},
        source_set_sha256=source_set, measurement_parameters=parameters, changes=changes,
        unchanged_from_validated_legacy00_snapshot=unchanged,
        added_verification_files={GUARD_PATH: digest(guard)},
        functional_compatibility_boundary='Conv/per-channel quantization, Add/Pool/GAP descriptor routing, '
            'SAME decode, output-tail masking and common external AXI64 normalization retained. '
            'No A/B dataflow reuse, segment Burst assembler, PSUM slots, native64 internal operands, '
            'Conv cache/lookahead, or decoupled C writeback imported.',
        original_1dc_features_retained=['4x4 INT8 array', 'M/N/K tiling',
            'output-stationary K accumulation', 'serial load-compute-final-writeback scheduler'],
        verification_claims=['One physical bank per operand',
            'No operand-load request/acceptance while compute/final writeback is active',
            'One completed fresh A and B load per launched K tile',
            'Historical M/N/K traversal and first/last K controls'])
    files = {'source/' + name: data for name, data in outputs.items()}
    files.update(patches)
    files['source.json'] = json_bytes(metadata)
    files['provenance.json'] = json_bytes(provenance)
    return files, provenance


def write_outputs(output, files):
    for name, data in files.items():
        target = output / str(relative_path(name))
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as handle:
            handle.write(data)


def prepare(repo, base_metadata, output, guard_file=RECIPES / 'serial_schedule_guard.sv'):
    base_metadata = Path(base_metadata).resolve()
    requested = Path(output).absolute()
    require(not requested.exists() and not requested.is_symlink(),
            'Destination already exists; choose a fresh output directory: ' + str(requested))
    output = requested.resolve()
    require(not output.exists(), 'Resolved destination already exists: ' + str(output))
    require(base_metadata.parent not in output.parents,
            'Destination must be outside the base snapshot directory')
    files, provenance = assemble(repo, base_metadata, guard_file)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(exist_ok=False)
    try:
        write_outputs(output, files)
    except BaseException:
        shutil.rmtree(str(output))
        raise
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path,
                        help='Fresh destination containing source/, source.json and provenance.json')
    parser.add_argument('--base-metadata', required=True, type=Path,
                        help='Validated legacy00 frozen source.json; its adjacent source/ is read only')
    parser.add_argument('--repo', type=Path, default=ROOT,
                        help='Git checkout containing pinned 1dc, legacy00 and common-shell history')
    args = parser.parse_args()
    result = prepare(args.repo, args.base_metadata, args.out)
    print('SERIAL BASELINE SOURCES PREPARED: ' + str(args.out.resolve()))
    print('Source-set SHA256: ' + result['source_set_sha256'])
    print('A/B banks: 1/1; exact historical serial scheduler; declared functional backports')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit('SERIAL BASELINE PREPARATION FAILED: ' + str(error))
