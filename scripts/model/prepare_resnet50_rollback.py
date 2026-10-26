#!/usr/bin/env python3
"""Restore pinned historical RTL and exact functional ResNet-50 compatibility.

The destination must not exist. Historical schedulers and operand readers are
restored from Git, while every functional change is declared in rollback_compat.
This prepares sources only; benchmark_resnet50_rollback.py runs and checks them.
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
RECIPE_DIR = Path(__file__).resolve().with_name('rollback_compat')
VARIANTS = ('legacy00', 'legacy46')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def relative_path(value):
    path = PurePosixPath(value)
    require(isinstance(value, str) and value and not path.is_absolute() and
            all(part not in ('', '.', '..') for part in value.split('/')),
            'Unsafe recipe path: %r' % value)
    return path


def recipe_bytes(directory, name):
    relative_path(name)
    directory = Path(directory).resolve()
    path = (directory / name).resolve()
    require(directory in path.parents, 'Recipe path escapes its directory')
    return path.read_bytes()


def git_bytes(repo, commit, path):
    require(re.fullmatch('[0-9a-f]{40}', commit) is not None,
            'Git source must be a pinned full commit SHA')
    relative_path(path)
    try:
        return subprocess.check_output(['git', 'show', commit+':'+path],
                                       cwd=str(repo), stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        raise ValueError('Missing pinned Git source %s:%s; fetch repository history first: %s' %
                         (commit, path, error.stderr.decode(errors='replace').strip()))


def apply_patch(original, patch, path):
    """Apply one exact unified diff, rejecting offsets, fuzzy contexts and tails."""
    lines = original.decode('utf-8').splitlines(keepends=True)
    delta = patch.decode('utf-8').splitlines(keepends=True)
    require(delta[:2] == ['--- a/'+path+'\n', '+++ b/'+path+'\n'],
            'Patch file headers differ from target: '+path)
    result, cursor, index, hunks = [], 0, 2, 0
    while index < len(delta):
        header = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n',
                              delta[index])
        require(header is not None, 'Invalid unified patch hunk: '+path)
        old_start, old_count, new_start, new_count = header.groups()
        old_start, new_start = int(old_start), int(new_start)
        old_count = int(old_count) if old_count is not None else 1
        new_count = int(new_count) if new_count is not None else 1
        start = old_start-1 if old_count else old_start
        require(cursor <= start <= len(lines), 'Patch offset/order differs: '+path)
        result.extend(lines[cursor:start])
        cursor = start
        expected_new = new_start-1 if new_count else new_start
        require(len(result) == expected_new, 'Patch new-file offset differs: '+path)
        index += 1
        removed = added = 0
        while index < len(delta) and not delta[index].startswith('@@ '):
            line = delta[index]
            require(line and line[0] in ' +-','Unsupported unified patch line: '+path)
            if line[0] in ' -':
                require(cursor < len(lines) and lines[cursor] == line[1:],
                        'Patch original context differs: '+path)
                cursor += 1
                removed += 1
            if line[0] in ' +':
                result.append(line[1:])
                added += 1
            index += 1
        require(removed == old_count and added == new_count,
                'Patch hunk line counts differ: '+path)
        hunks += 1
    require(hunks > 0, 'Patch contains no hunks: '+path)
    result.extend(lines[cursor:])
    return ''.join(result).encode('utf-8')


def assemble(repo, recipe_dir, variants):
    """Validate every original, diff and final hash before creating any output."""
    outputs, manifests, recipe_hashes = {}, {}, {}
    for variant in variants:
        require(variant in VARIANTS, 'Unknown rollback variant: '+variant)
        raw = recipe_bytes(recipe_dir, variant+'.json')
        recipe_hashes[variant+'.json'] = digest(raw)
        recipe = json.loads(raw)
        require(recipe['schema_version'] == 1 and recipe['variant'] == variant,
                'Recipe schema or variant differs')
        common_raw = recipe_bytes(recipe_dir, recipe['common_recipe'])
        require(digest(common_raw) == recipe['common_recipe_sha256'],
                'Shared compatibility recipe SHA256 differs')
        recipe_hashes[recipe['common_recipe']] = digest(common_raw)
        common = json.loads(common_raw)
        compiled = {}
        for item in recipe['files']:
            path = item['path']
            relative_path(path)
            require(path.startswith('rtl/') and path.endswith('.sv'),
                    'Recipe contains a non-RTL source')
            require(path not in compiled, 'Duplicate historical source: '+path)
            data = git_bytes(repo, item['source_ref'], path)
            require(digest(data) == item['original_sha256'],
                    'Original Git SHA256 differs: '+path)
            if 'patch' in item:
                delta = recipe_bytes(recipe_dir, item['patch'])
                require(digest(delta) == item['patch_sha256'],
                        'Compatibility patch SHA256 differs: '+path)
                recipe_hashes[item['patch']] = digest(delta)
                data = apply_patch(data, delta, path)
            require(digest(data) == item['compiled_sha256'],
                    'Compiled historical source SHA256 differs: '+path)
            outputs[variant+'/source/'+path] = data
            compiled[path] = digest(data)
        for item in common['files']:
            path = str(relative_path(item['output_path']))
            require(path.startswith('compat/') and path.endswith('.sv'),
                    'Shared compatibility output path differs')
            data = git_bytes(repo, common['source_ref'], item['original_path'])
            require(digest(data) == item['original_sha256'],
                    'Shared operator Git SHA256 differs: '+path)
            source = data.decode('utf-8')
            for old, rename in item['renames'].items():
                require(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', old) is not None,
                        'Invalid lexical module identifier')
                pattern = r'\b'+re.escape(old)+r'\b'
                require(len(re.findall(pattern, source)) == rename['replacement_count'],
                        'Shared operator rename count differs: '+path)
                source = re.sub(pattern, rename['renamed_to'], source)
            data = source.encode('utf-8')
            require(digest(data) == item['compat_sha256'],
                    'Shared operator compiled SHA256 differs: '+path)
            require(path not in outputs or outputs[path] == data,
                    'Variants disagree on a shared operator: '+path)
            outputs[path] = data
            compiled[path] = digest(data)
        require(compiled == recipe['compiled_rtl_sha256'],
                'Compiled RTL file set or SHA256 differs')
        require(digest(json.dumps(compiled, sort_keys=True).encode()) ==
                recipe['compiled_rtl_set_sha256'], 'Compiled RTL set checksum differs')
        manifests[variant] = recipe
        outputs[variant+'/source/compatibility.json'] = raw
        outputs['compat/sources.json'] = common_raw
    manifest = dict(schema_version=1, purpose='historical_integer_performance_comparison',
                    no_host_operator_execution=True,
                    preparation_script_sha256=digest(Path(__file__).read_bytes()),
                    recipe_sha256=recipe_hashes, variants=manifests,
                    output_sha256={name:digest(data) for name,data in sorted(outputs.items())})
    outputs['preparation.json'] = (json.dumps(manifest, indent=2, sort_keys=True)+'\n').encode()
    return outputs, manifest


def prepare(repo, output, variants=VARIANTS, recipe_dir=RECIPE_DIR):
    repo, output = Path(repo).resolve(), Path(output).absolute()
    require(not output.exists() and not output.is_symlink(),
            'Destination already exists; choose a fresh output directory: '+str(output))
    outputs, manifest = assemble(repo, recipe_dir, variants)
    # Exclusive creation protects existing snapshots even if another task creates
    # the destination while Git sources and compatibility recipes are validated.
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(exist_ok=False)
    try:
        for name,data in outputs.items():
            target = output/str(relative_path(name))
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as handle:
                handle.write(data)
    except BaseException:
        shutil.rmtree(str(output))
        raise
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path,
                        help='Fresh destination; existing directories are rejected')
    parser.add_argument('--repo', type=Path, default=ROOT,
                        help='Git checkout containing the pinned historical commits')
    parser.add_argument('--variant', choices=('both',)+VARIANTS, default='both')
    args = parser.parse_args()
    variants = VARIANTS if args.variant == 'both' else (args.variant,)
    manifest = prepare(args.repo, args.out, variants)
    print('ROLLBACK SOURCES PREPARED: '+str(args.out.resolve()))
    for name, recipe in manifest['variants'].items():
        print('%s: %s; %d original RTL files; %s' %
              (name, recipe['historical_source_commit'], len(recipe['files']),
               recipe['compiled_rtl_set_sha256']))


if __name__ == '__main__':
    main()
