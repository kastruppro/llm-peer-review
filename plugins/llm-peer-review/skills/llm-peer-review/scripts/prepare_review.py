#!/usr/bin/env python3
"""Resolve the review scope, write the diff and render the reviewer prompt.

stdlib only. Every git call uses an argument list (never a shell).
Exit codes: 0 ok, 2 invalid input / no default branch, 3 nothing to review.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

PLACEHOLDER_FOCUS = "No extra focus provided."
UNTRACKED_HEADER = "# Untracked files (read them directly):"
FULL_SCOPE_SENTENCE = (
    "Review every tracked or non-ignored untracked source file under the current "
    "project directory (in a non-Git directory, review source files except .git "
    "internals) for concrete correctness bugs, race conditions, lock-ordering "
    "problems, security issues, non-atomic file operations, crashes, and "
    "invariant violations."
)
SCOPES = ("auto", "working-tree", "branch", "full")
PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"


# Repo config must not run code (core.fsmonitor runs on `git status`) and user
# config must not rewrite target.diff (diff.external, textconv, color.diff=always).
GIT_SAFE = ("-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null")
DIFF_SAFE = ("--no-ext-diff", "--no-color", "--no-textconv")


def _git(root, *args, check=True):
    # LC_ALL=C keeps git's messages stable ("not a git repository").
    return subprocess.run(
        ["git", *GIT_SAFE, "-C", root, *args], capture_output=True, text=True,
        errors="surrogateescape", check=check, env=dict(os.environ, LC_ALL="C"),
    )


def _is_git_repo(root):
    """True inside a work tree, False only for "not a git repository".

    Any other git failure (dubious ownership, broken repo, ...) raises ValueError
    so we never silently fall back to a full-tree review.
    """
    r = _git(root, "rev-parse", "--is-inside-work-tree", check=False)
    if r.returncode == 0:
        return r.stdout.strip() == "true"
    if "not a git repository" in r.stderr:
        return False
    raise ValueError("git fejlede: %s" % (r.stderr.strip() or "exit %d" % r.returncode))


def _ref_exists(root, ref):
    return _git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False).returncode == 0


def _has_head(root):
    return _ref_exists(root, "HEAD")


def _diff(root, *args):
    return _git(root, "diff", *DIFF_SAFE, "--relative", *args).stdout


def _is_dirty(root):
    # Pathspec "." keeps the check to --root, the same subtree the diff covers.
    return bool(_git(root, "status", "--porcelain", "--untracked-files=all", "--", ".").stdout.strip())


def _split_z(text):
    return [n for n in text.split("\0") if n]


def default_branch(root):
    sym = _git(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False)
    if sym.returncode == 0:
        name = sym.stdout.strip()
        if name.startswith("origin/"):
            name = name[len("origin/"):]
        if name:
            return name
    for cand in ("main", "master", "trunk"):
        if _git(root, "show-ref", "--verify", "--quiet", "refs/heads/" + cand, check=False).returncode == 0:
            return cand
        if _git(root, "show-ref", "--verify", "--quiet", "refs/remotes/origin/" + cand, check=False).returncode == 0:
            return "origin/" + cand
    raise ValueError("Kan ikke finde default branch; brug --base <ref> eller --scope full")


def _usable_ref(root, name):
    """Prefer the local branch; fall back to origin/<name> when only the remote exists."""
    if _ref_exists(root, name):
        return name
    if not name.startswith("origin/") and _ref_exists(root, "origin/" + name):
        return "origin/" + name
    return name


def resolve_target(root, scope, base):
    if scope not in SCOPES:
        raise ValueError("Ukendt scope %r; brug auto, working-tree, branch eller full" % scope)
    if base and scope in ("working-tree", "full"):
        raise ValueError("--base kan ikke kombineres med --scope %s; brug --scope branch eller auto" % scope)
    if not _is_git_repo(root):
        if scope in ("auto", "full"):
            return {"mode": "full", "label": "full tree (no git repository)", "base_ref": None}
        raise ValueError("%s kræver et Git-repo; brug --scope full eller --scope auto" % scope)
    if scope == "full":
        return {"mode": "full", "label": "full tree", "base_ref": None}
    if base:
        if not _ref_exists(root, base):
            raise ValueError("Ukendt base-ref %r" % base)
        return {"mode": "branch", "label": "branch diff against %s" % base, "base_ref": base}
    if scope == "working-tree":
        return {"mode": "working-tree", "label": "working tree diff", "base_ref": None}
    if scope == "auto" and _is_dirty(root):
        return {"mode": "working-tree", "label": "working tree diff", "base_ref": None}
    ref = _usable_ref(root, default_branch(root))
    if not _ref_exists(root, ref):
        raise ValueError("Default branch %r findes ikke som ref; brug --base <ref> eller --scope full" % ref)
    return {"mode": "branch", "label": "branch diff against %s" % ref, "base_ref": ref}


def write_diff(root, target, path):
    mode = target["mode"]
    files = []
    if mode == "working-tree":
        if _has_head(root):
            diff = _diff(root, "HEAD")
            names = _split_z(_diff(root, "--name-only", "-z", "HEAD"))
        else:
            diff = _diff(root, "--cached") + _diff(root)
            names = _split_z(_diff(root, "--name-only", "-z", "--cached")
                             + "\0" + _diff(root, "--name-only", "-z"))
        untracked = _split_z(_git(root, "ls-files", "-z", "--others", "--exclude-standard", "--", ".").stdout)
        body = diff
        if body and not body.endswith("\n"):
            body += "\n"
        body += "\n" + UNTRACKED_HEADER + "\n" + "".join(u + "\n" for u in untracked)
        for n in names + untracked:
            if n not in files:
                files.append(n)
    elif mode == "branch":
        spec = "%s...HEAD" % target["base_ref"]
        try:
            body = _diff(root, spec)
            names = _split_z(_diff(root, "--name-only", "-z", spec))
        except subprocess.CalledProcessError as e:
            raise ValueError("git diff %s fejlede: %s" % (spec, (e.stderr or "").strip()))
        files = list(dict.fromkeys(names))
    else:
        raise ValueError("write_diff kræver en diff-mode, ikke %r" % mode)
    with open(path, "w", errors="surrogateescape") as fh:
        fh.write(body)
    return files


def _display_name(name):
    # Keep one file per line; never let a name break out of the fenced block.
    return "".join("?" if (ord(c) < 32 or c == "\x7f") else c for c in name)


def _target_block(target, files, diff_path):
    lines = ["```text", "mode: %s" % target["mode"]]
    if target["mode"] == "full":
        lines.append(FULL_SCOPE_SENTENCE)
    else:
        if target.get("base_ref"):
            lines.append("base: %s" % target["base_ref"])
        lines.append("diff file (absolute path): %s" % _display_name(str(diff_path)))
        lines.append("changed files:")
        lines.extend("- " + _display_name(f) for f in files)
    lines.append("```")
    return "\n".join(lines)


def render_prompt(template, target, files, diff_path, focus):
    focus = focus if focus and focus.strip() else PLACEHOLDER_FOCUS
    # A focus line starting with a fence would be captured by gemini-review.sh's
    # first-fence extraction instead of the target block; indent such lines.
    focus = "\n".join(" " + l if l.startswith("```") else l for l in focus.split("\n"))
    block = _target_block(target, files, diff_path)
    # Single pass over distinct placeholders; values are never re-scanned.
    out, i = [], 0
    marks = {"{{TARGET_LABEL}}": target["label"], "{{TARGET_BLOCK}}": block, "{{USER_FOCUS}}": focus}
    while i < len(template):
        for key, val in marks.items():
            if template.startswith(key, i):
                out.append(val)
                i += len(key)
                break
        else:
            out.append(template[i])
            i += 1
    return "".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scope", default="auto", choices=SCOPES)
    ap.add_argument("--base")
    ap.add_argument("--adversarial", action="store_true")
    ap.add_argument("--focus", default="")
    a = ap.parse_args(argv)
    try:
        root = os.path.realpath(a.root)
        if not os.path.isdir(root):
            raise ValueError("--root er ikke en mappe: %s" % a.root)
        out = os.path.realpath(a.out)
        os.makedirs(out, mode=0o700, exist_ok=True)
        target = resolve_target(root, a.scope, a.base)
        files, diff_path = [], None
        if target["mode"] == "full":
            try:
                os.remove(os.path.join(out, "target.diff"))  # no stale diff from an earlier run
            except FileNotFoundError:
                pass
        else:
            diff_path = os.path.join(out, "target.diff")
            files = write_diff(root, target, diff_path)
            if not files:
                os.remove(diff_path)
                print("Intet at reviewe i %s; brug --scope full eller --base <ref>" % target["label"],
                      file=sys.stderr)
                return 3
        name = "adversarial-review.md" if a.adversarial else "review.md"
        template = (PROMPTS_DIR / name).read_text()
        prompt = render_prompt(template, target, files, diff_path, a.focus)
        with open(os.path.join(out, "prompt.md"), "w") as fh:
            fh.write(prompt)
        with open(os.path.join(out, "target.json"), "w") as fh:
            json.dump(dict(target, root=root, files=files, diff_path=diff_path,
                           adversarial=a.adversarial), fh, indent=2)
            fh.write("\n")
        print(target["label"])
        return 0
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as e:
        print("git fejlede: %s" % ((e.stderr or "").strip() or "exit %d" % e.returncode), file=sys.stderr)
        return 2
    except OSError as e:
        print("Kunne ikke køre git eller skrive output: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
