#!/usr/bin/env python3
"""Materialize the pinned iOS-only Mihomo patches for Go's overlay filesystem."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / 'vendor' / 'mihomo'
OUTPUT = ROOT / 'build' / 'mihomo-overlay-prepared'
BASELINE = '024245dc72bc92f48237f865119afe0cd53ac9e6'


def git(*args):
    return subprocess.check_output(['git', '-C', str(SOURCE), *args], text=True).strip()


def main():
    if git('rev-parse', 'HEAD') != BASELINE or git('status', '--porcelain'):
        raise SystemExit('The Mihomo overlay requires the clean recorded baseline.')
    patches = sorted((ROOT / 'patches').glob('*.patch'))
    if not patches:
        raise SystemExit('The mobile Mihomo patches are missing.')
    paths = set()
    for patch in patches:
        for line in patch.read_text().splitlines():
            if not line.startswith('+++ b/'):
                continue
            path = PurePosixPath(line.removeprefix('+++ b/'))
            if path.is_absolute() or '..' in path.parts:
                raise SystemExit('Invalid path in mobile patch.')
            paths.add(str(path))
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    for path in sorted(paths):
        target = OUTPUT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if (SOURCE / path).exists():
            shutil.copyfile(SOURCE / path, target)
    for patch in patches:
        result = subprocess.run(['patch', '-p1', '-s', '-i', str(patch)], cwd=OUTPUT,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
    replacements = {str(SOURCE / path): str(OUTPUT / path) for path in sorted(paths)}
    manifest = OUTPUT / 'overlay.json'
    manifest.write_text(json.dumps({'Replace': replacements}, indent=2) + '\n')
    (OUTPUT / 'patches.sha256').write_text(''.join(
        f'{hashlib.sha256(patch.read_bytes()).hexdigest()}  {patch.name}\n' for patch in patches
    ))
    print(manifest)


if __name__ == '__main__':
    main()
