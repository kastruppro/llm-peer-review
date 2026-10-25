#!/usr/bin/env python3
"""Offline tests for snapshot.py (read-only manifest incl. .git internals)."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "snapshot.py"
spec = importlib.util.spec_from_file_location("snap", SCRIPT)
snap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snap)

GIT_ENV = dict(
    os.environ,
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_SYSTEM="/dev/null",
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@example.invalid",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@example.invalid",
)
os.environ.update({k: GIT_ENV[k] for k in GIT_ENV if k.startswith("GIT_")})


def git(root, *args):
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, env=GIT_ENV)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.root = self.tmp / "my project"
        self.root.mkdir()
        git(self.root, "init", "-q", "-b", "main")
        (self.root / "a.py").write_text("print(1)\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "init")

    def cli(self, root=None):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(root or self.root)],
                              capture_output=True, text=True, env=GIT_ENV)

    def test_unchanged_repo_gives_identical_manifest(self):
        self.assertEqual(snap.snapshot(self.root), snap.snapshot(self.root))

    def test_new_hook_changes_manifest(self):
        before = snap.snapshot(self.root)
        hook = self.root / ".git" / "hooks" / "post-checkout"
        hook.write_text("#!/bin/sh\necho pwned\n")
        hook.chmod(0o755)
        self.assertNotEqual(before, snap.snapshot(self.root))

    def test_fsmonitor_in_config_changes_manifest(self):
        before = snap.snapshot(self.root)
        git(self.root, "config", "core.fsmonitor", "/bin/true")
        self.assertNotEqual(before, snap.snapshot(self.root))

    def test_info_and_refs_change_manifest(self):
        before = snap.snapshot(self.root)
        (self.root / ".git" / "info" / "exclude").write_text("*.secret\n")
        mid = snap.snapshot(self.root)
        self.assertNotEqual(before, mid)
        git(self.root, "branch", "side")
        self.assertNotEqual(mid, snap.snapshot(self.root))
        git(self.root, "pack-refs", "--all")
        packed = snap.snapshot(self.root)
        sha = subprocess.run(["git", "-C", str(self.root), "rev-parse", "HEAD"], capture_output=True,
                             text=True, check=True).stdout.strip()
        with open(self.root / ".git" / "packed-refs", "a") as fh:
            fh.write("%s refs/tags/planted\n" % sha)
        self.assertNotEqual(packed, snap.snapshot(self.root))

    def test_fetch_style_ref_updates_do_not_change_manifest(self):
        # A `git fetch` by the user or an IDE during the review is not a reviewer write.
        before = snap.snapshot(self.root)
        git(self.root, "update-ref", "refs/remotes/origin/main", "HEAD")
        (self.root / ".git" / "FETCH_HEAD").write_text("deadbeef\t\tbranch 'main'\n")
        self.assertEqual(before, snap.snapshot(self.root))
        git(self.root, "pack-refs", "--all")  # remote ref now lives in packed-refs
        packed = snap.snapshot(self.root)
        git(self.root, "update-ref", "-d", "refs/remotes/origin/main")  # like fetch --prune
        self.assertEqual(packed, snap.snapshot(self.root))

    def test_head_change_changes_manifest(self):
        git(self.root, "branch", "side")
        before = snap.snapshot(self.root)
        git(self.root, "symbolic-ref", "HEAD", "refs/heads/side")
        self.assertNotEqual(before, snap.snapshot(self.root))

    def test_planted_fsmonitor_is_not_executed(self):
        marker = self.tmp / "FSMONITOR_RAN"
        script = self.tmp / "fsmon.sh"
        script.write_text("#!/bin/sh\ntouch '%s'\n" % marker)
        script.chmod(0o755)
        git(self.root, "config", "core.fsmonitor", str(script))
        (self.root / "a.py").write_text("print(2)\n")  # dirty, so status has work to do
        r = self.cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(marker.exists(), "snapshot.py executed core.fsmonitor")

    def test_linked_worktree_covers_common_dir(self):
        wt = self.tmp / "wt"
        git(self.root, "worktree", "add", "-q", str(wt), "-b", "feature")
        self.assertTrue((wt / ".git").is_file())  # a .git FILE pointing at the common dir
        before = snap.snapshot(wt)
        (self.root / ".git" / "hooks" / "pre-commit").write_text("#!/bin/sh\nexit 0\n")
        mid = snap.snapshot(wt)
        self.assertNotEqual(before, mid)
        cfg = self.root / ".git" / "config"
        cfg.write_text(cfg.read_text() + "[core]\n\tfsmonitor = /bin/true\n")
        self.assertNotEqual(mid, snap.snapshot(wt))

    def test_subdir_root_still_hashes_repo_internals(self):
        (self.root / "sub").mkdir()
        (self.root / "sub" / "b.py").write_text("x = 1\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "sub")
        before = snap.snapshot(self.root / "sub")
        (self.root / ".git" / "hooks" / "pre-push").write_text("#!/bin/sh\n")
        self.assertNotEqual(before, snap.snapshot(self.root / "sub"))

    def test_tracked_file_change_still_detected(self):
        before = snap.snapshot(self.root)
        (self.root / "a.py").write_text("print(3)\n")
        self.assertNotEqual(before, snap.snapshot(self.root))

    def test_non_git_directory_has_no_git_state(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        (plain / "x.txt").write_text("x\n")
        m = snap.snapshot(plain)
        self.assertIsNone(m["git"])
        self.assertIn("x.txt", m["files"])


if __name__ == "__main__":
    unittest.main()
