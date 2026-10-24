#!/usr/bin/env python3
"""Emit a deterministic manifest; fail if any scoped file cannot be read."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)


def snapshot(root):
    root = Path(root).resolve(strict=True)
    if not root.is_dir():
        raise ValueError('project root must be a directory')
    try:
        git(root, 'rev-parse', '--show-toplevel')
    except subprocess.CalledProcessError:
        names = [str(p.relative_to(root)) for p in root.rglob('*')
                 if '.git' not in p.relative_to(root).parts and (not p.is_dir() or p.is_symlink())]
        state = None
    else:
        names = [os.fsdecode(n) for n in git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '.').split(b'\0') if n]
        try:
            head = git(root, 'rev-parse', '--verify', 'HEAD').decode().strip()
        except subprocess.CalledProcessError:
            head = None
        state = {'head': head, 'index': git(root, 'ls-files', '--stage', '-z', '--', '.').hex(),
                 'status': git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.').hex()}
    files = {}
    for name in sorted(set(names)):
        path = root / name
        try:
            info = path.lstat()
        except FileNotFoundError:
            files[name] = {'missing': True}
            continue
        record = {'mode': stat.S_IMODE(info.st_mode)}
        if stat.S_ISLNK(info.st_mode):
            record['symlink'] = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            after = path.stat()
            if (info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise RuntimeError(f'file changed while hashing: {name}')
            record['sha256'] = digest.hexdigest()
        elif stat.S_ISDIR(info.st_mode):
            # Git submodules must not silently appear unchanged when dirty.
            record['submodule'] = snapshot(path)
        else:
            raise ValueError(f'unsupported file type: {name}')
        files[name] = record
    return {'git': state, 'files': files}


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: snapshot.py PROJECT_ROOT')
        print(json.dumps(snapshot(sys.argv[1]), sort_keys=True, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(f'snapshot failed: {exc}')
