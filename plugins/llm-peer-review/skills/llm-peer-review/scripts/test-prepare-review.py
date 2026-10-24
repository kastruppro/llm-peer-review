#!/usr/bin/env python3
"""Offline tests for prepare_review.py (scope resolution, diff, prompt rendering)."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SK = HERE.parent
SCRIPT = HERE / "prepare_review.py"
spec = importlib.util.spec_from_file_location("pr", SCRIPT)
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)

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


def write(root, name, text):
    p = Path(root) / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.root = self.tmp / "my project"
        self.root.mkdir()
        self.out = self.tmp / "out"

    def init_repo(self, branch="main"):
        git(self.root, "init", "-q", "-b", branch)
        write(self.root, "a.py", "print(1)\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "init")

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--root", str(self.root), "--out", str(self.out), *args],
            capture_output=True, text=True, env=GIT_ENV,
        )


class ScopeTests(Base):
    def test_auto_dirty_is_working_tree(self):
        self.init_repo()
        write(self.root, "a.py", "print(2)\n")
        write(self.root, "new.py", "x = 1\n")
        t = pr.resolve_target(str(self.root), "auto", None)
        self.assertEqual(t["mode"], "working-tree")
        diff = self.tmp / "d.diff"
        files = pr.write_diff(str(self.root), t, str(diff))
        self.assertIn("new.py", files)
        self.assertIn("a.py", files)
        text = diff.read_text()
        self.assertIn("# Untracked files (read them directly):", text)
        self.assertIn("new.py", text)
        self.assertIn("-print(1)", text)

    def test_auto_clean_feature_branch(self):
        self.init_repo()
        git(self.root, "checkout", "-q", "-b", "feat")
        write(self.root, "b.py", "y = 2\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "feat")
        t = pr.resolve_target(str(self.root), "auto", None)
        self.assertEqual(t["mode"], "branch")
        self.assertEqual(t["base_ref"], "main")
        files = pr.write_diff(str(self.root), t, str(self.tmp / "d.diff"))
        self.assertEqual(files, ["b.py"])

    def test_auto_clean_on_main_exits_3(self):
        self.init_repo()
        r = self.cli()
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("--scope full", r.stderr)
        self.assertIn("Intet at reviewe i", r.stderr)

    def test_explicit_base(self):
        self.init_repo()
        write(self.root, "b.py", "y = 2\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "second")
        r = self.cli("--base", "HEAD~1")
        self.assertEqual(r.returncode, 0, r.stderr)
        t = json.loads((self.out / "target.json").read_text())
        self.assertEqual(t["mode"], "branch")
        self.assertEqual(t["base_ref"], "HEAD~1")
        self.assertIn("b.py", (self.out / "target.diff").read_text())

    def test_bad_base_is_error(self):
        self.init_repo()
        r = self.cli("--base", "no-such-ref")
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_no_default_branch(self):
        self.init_repo(branch="dev")
        r = self.cli()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("--base", r.stderr)

    def test_default_branch_origin_head(self):
        self.init_repo(branch="dev")
        git(self.root, "update-ref", "refs/remotes/origin/trunk2", "HEAD")
        git(self.root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk2")
        self.assertEqual(pr.default_branch(str(self.root)), "trunk2")

    def test_default_branch_master(self):
        self.init_repo(branch="master")
        self.assertEqual(pr.default_branch(str(self.root)), "master")

    def test_non_git_auto_is_full(self):
        t = pr.resolve_target(str(self.root), "auto", None)
        self.assertEqual(t["mode"], "full")
        self.assertIsNone(t["base_ref"])
        r = self.cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.out / "target.diff").exists())
        self.assertTrue((self.out / "prompt.md").exists())

    def test_non_git_working_tree_is_error(self):
        r = self.cli("--scope", "working-tree")
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_non_git_branch_is_error(self):
        r = self.cli("--scope", "branch")
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_full_removes_stale_diff(self):
        self.init_repo()
        write(self.root, "a.py", "print(2)\n")
        self.assertEqual(self.cli().returncode, 0)
        self.assertTrue((self.out / "target.diff").exists())
        self.assertEqual(self.cli("--scope", "full").returncode, 0)
        self.assertFalse((self.out / "target.diff").exists())

    def test_full_in_git_repo_even_when_clean(self):
        self.init_repo()
        r = self.cli("--scope", "full")
        self.assertEqual(r.returncode, 0, r.stderr)
        t = json.loads((self.out / "target.json").read_text())
        self.assertEqual(t["mode"], "full")

    def test_unborn_head_working_tree(self):
        git(self.root, "init", "-q", "-b", "main")
        write(self.root, "a.py", "print(1)\n")
        write(self.root, "staged.py", "z = 1\n")
        git(self.root, "add", "staged.py")
        t = pr.resolve_target(str(self.root), "auto", None)
        self.assertEqual(t["mode"], "working-tree")
        diff = self.tmp / "d.diff"
        files = pr.write_diff(str(self.root), t, str(diff))
        self.assertEqual(sorted(files), ["a.py", "staged.py"])
        self.assertIn("+z = 1", diff.read_text())

    def test_out_dir_resolved_absolute_and_private(self):
        self.init_repo()
        write(self.root, "a.py", "print(2)\n")
        rel = Path(os.path.relpath(self.out, os.getcwd()))
        r = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--root", str(self.root), "--out", str(rel)],
            capture_output=True, text=True, env=GIT_ENV,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o700)
        self.assertIn(str(self.out / "target.diff"), (self.out / "prompt.md").read_text())


class PromptTests(Base):
    def dirty_repo(self):
        self.init_repo()
        write(self.root, "a.py", "print(2)\n")

    def test_focus_is_verbatim(self):
        self.dirty_repo()
        existed = Path("/tmp/pwn").exists()
        focus = '"; touch /tmp/pwn; echo "$(id)"'
        r = self.cli("--focus", focus)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(focus, (self.out / "prompt.md").read_text())
        if not existed:
            self.assertFalse(Path("/tmp/pwn").exists())

    def test_empty_focus_default(self):
        self.dirty_repo()
        self.assertEqual(self.cli().returncode, 0)
        self.assertIn("No extra focus provided.", (self.out / "prompt.md").read_text())

    def test_no_placeholders_left(self):
        self.dirty_repo()
        for extra in ([], ["--adversarial"]):
            r = self.cli(*extra)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn("{{", (self.out / "prompt.md").read_text())

    def test_target_block_is_fenced(self):
        self.dirty_repo()
        self.assertEqual(self.cli().returncode, 0)
        text = (self.out / "prompt.md").read_text()
        self.assertIn("```text", text)
        self.assertIn(str(self.out / "target.diff"), text)
        self.assertIn("- a.py", text)

    def test_exactly_one_fenced_block(self):
        self.dirty_repo()
        for extra in ([], ["--adversarial"], ["--focus", "hello"]):
            self.assertEqual(self.cli(*extra).returncode, 0)
            lines = (self.out / "prompt.md").read_text().splitlines()
            self.assertEqual(len([l for l in lines if l.startswith("```")]), 2, extra)
        r = self.cli("--scope", "full")
        lines = (self.out / "prompt.md").read_text().splitlines()
        self.assertEqual(len([l for l in lines if l.startswith("```")]), 2)

    def test_template_files_have_no_fences_or_model_names(self):
        for name in ("review.md", "adversarial-review.md"):
            text = (SK / "prompts" / name).read_text()
            self.assertNotIn("```", text, name)
            for banned in ("codex", "claude", "gemini", "gpt", "opus", "sonnet", "agy"):
                self.assertNotIn(banned, text.lower(), name)
            self.assertIn("do not modify, create, delete, format, stage or commit files", text.lower())
            self.assertIn("{{TARGET_BLOCK}}", text)

    def test_adversarial_uses_adversarial_template(self):
        self.dirty_repo()
        self.assertEqual(self.cli("--adversarial").returncode, 0)
        self.assertIn("adversarial", (self.out / "prompt.md").read_text())

    def test_full_mode_block_has_scope_sentence_not_diff(self):
        r = self.cli()  # non-git -> full
        self.assertEqual(r.returncode, 0, r.stderr)
        text = (self.out / "prompt.md").read_text()
        self.assertIn("Review every tracked or non-ignored untracked source file", text)
        self.assertNotIn("target.diff", text)

    def test_filename_with_backtick_prefix_cannot_open_fence(self):
        self.init_repo()
        write(self.root, "```evil.py", "x = 1\n")
        self.assertEqual(self.cli().returncode, 0)
        lines = (self.out / "prompt.md").read_text().splitlines()
        self.assertEqual(len([l for l in lines if l.startswith("```")]), 2)

    def test_render_prompt_unit(self):
        tpl = "{{TARGET_LABEL}}|{{USER_FOCUS}}|{{TARGET_BLOCK}}"
        t = {"mode": "full", "label": "L", "base_ref": None}
        out = pr.render_prompt(tpl, t, [], None, "")
        self.assertTrue(out.startswith("L|No extra focus provided.|```text"))


if __name__ == "__main__":
    unittest.main()
