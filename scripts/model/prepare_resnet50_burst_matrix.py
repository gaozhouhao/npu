#!/usr/bin/env python3
"""Prepare matched Burst serial / double-buffer historical NPU sources.

Both variants use the validated legacy00 functional CNN source and the exact
fd4a041 Conv Burst loader. Only the historical scheduler, its port/completion
bridge and A/B bank counts differ. These are declared mixed-source variants,
not untouched historical whole-NPU releases. Production RTL is never edited.
"""

import argparse
import difflib
import json
import shutil
import sys
from pathlib import Path

import prepare_resnet50_serial_baseline as serial
from prepare_resnet50_rollback import digest, git_bytes, require

ROOT = Path(__file__).resolve().parents[2]
BURST_COMMIT = 'fd4a041265034c466b9aa3056786dbe863684f4e'
BURST_PATH = 'rtl/dma/conv_patch_loader.sv'
BURST_SHA256 = '30cbcdaed1b0ba4f254abf1ddcf9c1be1c4f42ec6bdd1c5be4d4630340865b74'
GUARD_PATH = 'rtl/verification/burst_prefetch_guard.sv'
GUARD_SHA256 = '42aaf8bf35c620fed4b214afadccd089cbb45527ae9558f57ede0a5d2feaf273'
VARIANTS = ('burst_serial', 'burst_double')
SCHEDULE_PATHS = ('rtl/core/tile_scheduler.sv', 'rtl/core/gemm_executor.sv',
                  'rtl/core/npu_top.sv')


def assemble(repo, base_metadata, guard_file=serial.RECIPES / 'burst_prefetch_guard.sv'):
    """Validate all inputs and assemble both complete source sets in memory."""
    repo, base_metadata = Path(repo).resolve(), Path(base_metadata).resolve()
    raw_base = base_metadata.read_bytes()
    base = json.loads(raw_base)
    # The existing preparer verifies the complete legacy00 snapshot, pinned
    # historical scheduler/executor, common verification files and exact bridge.
    serial_files, serial_provenance = serial.assemble(repo, base_metadata)
    serial_sources = {name[len('source/'):]: data for name, data in serial_files.items()
                      if name.startswith('source/')}
    original = {}
    for name, expected in base['source_sha256'].items():
        physical = 'rtl.f' if name == 'sim/filelists/rtl.f' else name
        data = serial.inside_bytes(base_metadata.parent / 'source', physical)
        require(digest(data) == expected, 'Base changed during assembly: ' + name)
        original[physical] = data
    require(base_metadata.read_bytes() == raw_base, 'Base metadata changed during assembly')
    burst = git_bytes(repo, BURST_COMMIT, BURST_PATH)
    require(digest(burst) == BURST_SHA256, 'Pinned historical Burst loader SHA256 differs')
    require(b'parameter int unsigned MAX_REQUEST_BEATS = 64,' in burst,
            'Historical Burst request limit differs')
    guard = Path(guard_file).read_bytes()
    require(digest(guard) == GUARD_SHA256, 'Burst observation guard SHA256 differs')
    files, sources_by_variant, summaries = {}, {}, {}
    for variant in VARIANTS:
        is_serial = variant == 'burst_serial'
        sources = dict(serial_sources if is_serial else original)
        sources[BURST_PATH] = burst
        banks = 1 if is_serial else 2
        sources[GUARD_PATH] = ('`define BURST_PREFETCH_EXPECT_BANKS %d\n' % banks).encode() + guard
        require(GUARD_PATH not in sources['rtl.f'].decode().splitlines(),
                'Burst observation guard already in base listing')
        sources['rtl.f'] += (GUARD_PATH + '\n').encode()
        source_hashes = {name: digest(data) for name, data in sources.items()
                         if name.endswith('.sv')}
        source_hashes['sim/filelists/rtl.f'] = digest(sources['rtl.f'])
        source_set = digest(json.dumps(source_hashes, sort_keys=True).encode())
        schedule_ref = serial.SERIAL_COMMIT if is_serial else serial.CNN_COMMIT
        parameters = dict(A_BUFFER_COUNT=banks, B_BUFFER_COUNT=banks,
            internal_operand_bits=32, external_read_bits=64,
            overlapping_operand_prefetch=not is_serial,
            conv_burst=True, conv_max_request_beats=64,
            A_reuse=False, B_stationary=False, multi_k_A_reuse=False,
            PSUM_slots=False, native64_internal_operands=False,
            conv_cache=False, conv_read_lookahead=False,
            decoupled_C_writeback=False)
        changes = []
        for name, data in sorted(sources.items()):
            old = original.get(name)
            if old == data:
                continue
            patch = ''.join(difflib.unified_diff(
                (old or b'').decode().splitlines(keepends=True),
                data.decode().splitlines(keepends=True),
                fromfile='legacy00/' + name if old is not None else '/dev/null',
                tofile=variant + '/' + name)).encode()
            patch_name = 'change-%02d.patch' % (len(changes) + 1)
            files[variant + '/' + patch_name] = patch
            changes.append(dict(path=name, original_sha256=digest(old) if old is not None else None,
                result_sha256=digest(data), diff_path=patch_name, diff_sha256=digest(patch)))
        metadata = {key: base[key] for key in ('runner_sha256', 'makefile_sha256',
                    'rollback_runner_sha256', 'common_external_read_bits',
                    'legacy_internal_operand_bits')}
        metadata.update(source_ref=BURST_COMMIT, resolved_commit=BURST_COMMIT,
            variant=variant, status='PREPARED', functional_compatibility=True,
            mixed_source=True, source_sha256=source_hashes, source_set_sha256=source_set,
            schedule_source_ref=schedule_ref, cnn_functional_source_ref=serial.CNN_COMMIT,
            burst_loader_source_ref=BURST_COMMIT, measurement_parameters=parameters,
            verification_modules=([serial.GUARD_PATH] if is_serial else []) + [GUARD_PATH],
            verification_module_classification='observation_only',
            compatibility_note='Declared mixed-source Burst comparison: validated legacy00 '
                'functional Conv/GEMM/internal32 source and common external AXI64 shell; exact '
                'fd4a041 Conv Burst loader; ' + ('exact 1dc serial scheduler plus port/completion '
                'bridge and one physical bank per operand.' if is_serial else
                'unchanged legacy00 double-buffer scheduler/executor and two physical banks '
                'per operand.') + ' Not an untouched historical whole NPU.')
        if is_serial:
            metadata.update(verification_module=serial.GUARD_PATH)
        provenance = dict(schema_version=1, status='PREPARED', mixed_source=True,
            untouched_original_whole_npu=False,
            preparation_script_sha256=digest(Path(__file__).read_bytes()),
            serial_preparation_script_sha256=digest(Path(serial.__file__).read_bytes()),
            serial_preparation_provenance=serial_provenance if is_serial else None,
            base_metadata_path=str(base_metadata), base_metadata_sha256=digest(raw_base),
            schedule_source_ref=schedule_ref, cnn_functional_source_ref=serial.CNN_COMMIT,
            burst_loader_source_ref=BURST_COMMIT, burst_loader_sha256=BURST_SHA256,
            observation_guard_template_sha256=GUARD_SHA256,
            observation_guard_source_sha256=digest(sources[GUARD_PATH]),
            source_set_sha256=source_set, measurement_parameters=parameters,
            changes_from_validated_legacy00=changes,
            unchanged_from_validated_legacy00=[name for name in sorted(source_hashes)
                if source_hashes[name] == base['source_sha256'].get(name)],
            functional_compatibility_boundary='Retain identical per-channel quantization, '
                'Add/Pool/GAP routing, SAME decode, logical output tails and external AXI64 '
                'normalization. Import only conv_patch_loader.sv from fd4a041, not its '
                'executor or scheduler, so the earlier 82d10c8 A-reuse change is excluded.')
        for name, data in sources.items():
            files[variant + '/source/' + name] = data
        files[variant + '/source.json'] = serial.json_bytes(metadata)
        files[variant + '/provenance.json'] = serial.json_bytes(provenance)
        summaries[variant] = dict(source_set_sha256=source_set,
            schedule_source_ref=schedule_ref, measurement_parameters=parameters)
        sources_by_variant[variant] = sources
    a, b = (sources_by_variant[name] for name in VARIANTS)
    actual_differences = sorted(name for name in set(a) | set(b) if a.get(name) != b.get(name))
    allowed_differences = sorted(SCHEDULE_PATHS + ('rtl.f', serial.GUARD_PATH, GUARD_PATH))
    require(actual_differences == allowed_differences,
            'Unexpected A/B difference beyond scheduler, bridge, bank count and observation guard')
    require(a[BURST_PATH] == b[BURST_PATH] == burst, 'A/B Burst loader bytes differ')
    # Pin B's original double-buffer control; A's serial checks are pinned by
    # serial.assemble. Both get identical old loader/read-path/core/quant bytes.
    for name in SCHEDULE_PATHS:
        require(b[name] == original[name], 'Double-buffer control changed: ' + name)
    comparison = dict(schema_version=1, status='PREPARED', mixed_source=True,
        preparation_script_sha256=digest(Path(__file__).read_bytes()),
        burst_loader_source_ref=BURST_COMMIT, burst_loader_sha256=BURST_SHA256,
        observation_guard_template_sha256=GUARD_SHA256,
        base_metadata_sha256=digest(raw_base),
        actual_variant_difference_paths=actual_differences, variants=summaries,
        conclusion='Sources prepared only; no performance or correctness result claimed.')
    files['matrix-provenance.json'] = serial.json_bytes(comparison)
    return files, comparison


def prepare(repo, base_metadata, output, guard_file=serial.RECIPES / 'burst_prefetch_guard.sv'):
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
        serial.write_outputs(output, files)
    except BaseException:
        shutil.rmtree(str(output))
        raise
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path,
                        help='Fresh directory containing burst_serial/ and burst_double/')
    parser.add_argument('--base-metadata', required=True, type=Path,
                        help='Validated legacy00 frozen source.json and adjacent read-only source/')
    parser.add_argument('--repo', type=Path, default=ROOT)
    args = parser.parse_args()
    result = prepare(args.repo, args.base_metadata, args.out)
    print('BURST MATRIX SOURCES PREPARED: ' + str(args.out.resolve()))
    for variant in VARIANTS:
        print(variant + ': ' + result['variants'][variant]['source_set_sha256'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit('BURST MATRIX PREPARATION FAILED: ' + str(error))
