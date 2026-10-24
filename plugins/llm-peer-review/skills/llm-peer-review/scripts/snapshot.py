#!/usr/bin/env python3
"""Emit a deterministic manifest; fail if any scoped file cannot be read."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


# Never let repo config run code while we look at it: a voice could plant
# core.fsmonitor (run by `git status`) or a hook between the two snapshots.
GIT_SAFE = ('-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null')
# Git control files that change what git (or a later commit/checkout) executes.
GIT_FILES = ('HEAD', 'config', 'config.worktree', 'packed-refs')
GIT_TREES = ('hooks', 'info', 'refs')


def git(root, *args):
    return subprocess.check_output(['git', *GIT_SAFE, '-C', str(root), *args], stderr=subprocess.DEVNULL)


def _record(path, name):
    """Mode plus sha256 (regular file) or link target (symlink); None if missing."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
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
        record['dir'] = True
    else:
        raise ValueError(f'unsupported file type: {name}')
    return record


def git_internals(root):
    """Hash HEAD, config, packed-refs, hooks/, info/ and refs/ of the git dir and
    (for linked worktrees, where .git is a file) the common dir."""
    dirs = {}
    for label, flag in (('gitdir', '--git-dir'), ('common', '--git-common-dir')):
        d = Path(os.fsdecode(git(root, 'rev-parse', flag).rstrip(b'\n')))
        if not d.is_absolute():
            d = root / d
        d = d.resolve()
        if d not in dirs.values():
            dirs[label] = d
    out = {}
    for label, d in dirs.items():
        for name in GIT_FILES:
            rec = _record(d / name, name)
            if rec is not None:
                out[f'{label}:{name}'] = rec
        for tree in GIT_TREES:
            top = d / tree
            if top.is_symlink() or not top.is_dir():
                rec = _record(top, tree)
                if rec is not None:
                    out[f'{label}:{tree}'] = rec
                continue
            for base, subdirs, names in os.walk(top):  # never follows symlinks
                subdirs.sort()
                for n in sorted(names + [s for s in subdirs if os.path.islink(os.path.join(base, s))]):
                    path = Path(base) / n
                    rel = path.relative_to(d).as_posix()
                    out[f'{label}:{rel}'] = _record(path, rel)
    return out


def _symbolic_head(root):
    try:
        return git(root, 'symbolic-ref', '-q', 'HEAD').decode().strip()
    except subprocess.CalledProcessError:
        return None  # detached HEAD


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
        # Hash the control files FIRST, before any git call that reads the work tree.
        internals = git_internals(root)
        state = {'head': head, 'internals': internals,
                 'symbolic_head': _symbolic_head(root),
                 'index': git(root, 'ls-files', '--stage', '-z', '--', '.').hex(),
                 'status': git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.').hex()}
    files = {}
    for name in sorted(set(names)):
        path = root / name
        record = _record(path, name)
        if record is None:
            files[name] = {'missing': True}
            continue
        if record.pop('dir', False):
            # Git submodules must not silently appear unchanged when dirty.
            record['submodule'] = snapshot(path)
        files[name] = record
    return {'git': state, 'files': files}


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: snapshot.py PROJECT_ROOT')
        print(json.dumps(snapshot(sys.argv[1]), sort_keys=True, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(f'snapshot failed: {exc}')
