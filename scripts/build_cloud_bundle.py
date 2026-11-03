#!/usr/bin/env python3
"""Allowlisted source bundle: no environment files, records, caches or Git metadata."""
import argparse
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def build(output: Path, root: Path = ROOT) -> list[str]:
    app = root / 'backend/app'
    paths = [p for p in sorted(app.rglob('*')) if p.is_file() and not p.is_symlink()
             and '__pycache__' not in p.parts
             and p.suffix in {'.py', '.html', '.js', '.css', '.svg', '.png', '.jpg', '.jpeg', '.webp', '.ico', '.wav'}
             and not any(part.startswith('.') for part in p.relative_to(app).parts)]
    paths += [root / 'backend/requirements-lock.txt', root / 'deploy/gcp/install.sh']
    names = []
    with tarfile.open(output, 'w:gz') as archive:
        for path in paths:
            name = path.relative_to(root).as_posix()
            archive.add(path, arcname=name, recursive=False)
            names.append(name)
    return names


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    names = build(args.output)
    print(f'Bundled {len(names)} source files. No local database or environment file included.')
