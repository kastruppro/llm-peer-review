#!/usr/bin/env python3
"""Offline CLI selection regressions with executable fixtures; no model calls."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("resolver", Path(__file__).with_name("resolve-codex.py"))
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="codex-resolver-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.floor = (0, 164, 0)

    def cli(self, name, output="codex-cli 0.164.0", rc=0):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\n[ "$#" -eq 1 ] && [ "$1" = "--version" ] || exit 97\n'
                        + "printf '%s\\n' '" + output + "'\nexit " + str(rc) + "\n")
        path.chmod(0o700)
        return path

    def test_old_path_falls_back_to_app(self):
        old = self.cli("bin/codex", "codex-cli 0.146.0")
        app = self.cli("Applications/ChatGPT.app/Contents/Resources/codex")
        paths = resolver.candidates(str(old.parent), [self.root / "Applications"], [])
        self.assertEqual(resolver.select(paths, self.floor), (app, "0.164.0"))

    def test_newest_numeric_version_wins(self):
        old = self.cli("one/codex", "codex-cli 0.99.0")
        good = self.cli("two/codex")
        new = self.cli("three/codex", "codex-cli 0.165.1")
        self.assertEqual(resolver.select([old, good, new], self.floor)[0], new)

    def test_path_scan_finds_later_install(self):
        old = self.cli("one/codex", "codex-cli 0.146.0")
        new = self.cli("two/codex")
        paths = resolver.candidates(os.pathsep.join([str(old.parent), str(new.parent)]), [], [])
        self.assertEqual(resolver.select(paths, self.floor)[0], new)

    def test_only_old_fails(self):
        with self.assertRaisesRegex(resolver.ResolutionError, "too old"):
            resolver.select([self.cli("old", "codex-cli 0.146.0")], self.floor)

    def test_missing_fails(self):
        with self.assertRaisesRegex(resolver.ResolutionError, "no executable"):
            resolver.select([self.root / "missing"], self.floor)

    def test_spaces_in_path(self):
        cli = self.cli("My Apps/Codex.app/Contents/Resources/codex")
        self.assertEqual(resolver.select([cli], self.floor)[0], cli)

    def test_failed_and_prerelease_probes_do_not_win(self):
        bad = self.cli("bad", "codex-cli 9.0.0", 1)
        unknown = self.cli("unknown", "something 9.0.0")
        beta = self.cli("beta", "codex-cli 9.0.0-beta.1")
        good = self.cli("good")
        self.assertEqual(resolver.select([bad, unknown, beta, good], self.floor)[0], good)

    def test_hung_probe_is_bounded(self):
        cli = self.cli("hung")
        with patch.object(resolver.subprocess, "run", side_effect=subprocess.TimeoutExpired([str(cli)], 5)) as run:
            with self.assertRaisesRegex(resolver.ResolutionError, "TimeoutExpired"):
                resolver.select([cli], self.floor)
            self.assertEqual(run.call_args.kwargs["timeout"], 5)

    def test_symlinks_probed_once(self):
        cli = self.cli("real")
        alias = self.root / "alias"
        alias.symlink_to(cli)
        with patch.object(resolver.subprocess, "run", wraps=subprocess.run) as run:
            resolver.select([cli, alias], self.floor)
            self.assertEqual(run.call_count, 1)

    def test_relative_path_entries_ignored(self):
        self.assertEqual(resolver.candidates(":.:bin", [], []), [])

    def test_standard_install_found_outside_path(self):
        old = self.cli("old/bin/codex", "codex-cli 0.146.0")
        new = self.cli("standard/bin/codex", "codex-cli 0.165.0")
        paths = resolver.candidates(str(old.parent), [], [new.parent])
        self.assertEqual(resolver.select(paths, self.floor), (new, "0.165.0"))

    def test_npm_native_fallback_without_node_on_path(self):
        package = "prefix/lib/node_modules/@openai/codex/"
        wrapper = self.cli(package + "bin/codex.js", "", 127)
        native = self.cli(package + "node_modules/@openai/codex-darwin-arm64/"
                          "vendor/aarch64-apple-darwin/bin/codex", "codex-cli 0.165.0")
        launcher = self.root / "prefix/bin/codex"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to(wrapper)
        paths = resolver.candidates("/usr/bin:/bin", [], [launcher.parent])
        self.assertEqual(resolver.select(paths, self.floor), (native.resolve(), "0.165.0"))

    def test_old_native_fallback_still_rejected(self):
        package = "prefix/lib/node_modules/@openai/codex/"
        wrapper = self.cli(package + "bin/codex.js", "", 127)
        self.cli(package + "vendor/aarch64-apple-darwin/bin/codex", "codex-cli 0.146.0")
        launcher = self.root / "prefix/bin/codex"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to(wrapper)
        with self.assertRaisesRegex(resolver.ResolutionError, "too old"):
            resolver.select(resolver.candidates("", [], [launcher.parent]), self.floor)

    def test_explicit_old_override_does_not_fall_back(self):
        old = self.cli("explicit", "codex-cli 0.146.0")
        result = subprocess.run([sys.executable, str(Path(resolver.__file__))],
            env={**os.environ, "PEERREVIEW_CODEX_BIN": str(old)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("too old", result.stderr)

    def test_explicit_valid_override(self):
        cli = self.cli("explicit valid")
        result = subprocess.run([sys.executable, str(Path(resolver.__file__))],
            env={**os.environ, "PEERREVIEW_CODEX_BIN": str(cli)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(cli))


if __name__ == "__main__":
    unittest.main(verbosity=2)
