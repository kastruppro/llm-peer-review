#!/usr/bin/env python3
"""Offline tests for review_json.py (extract / validate / classify); no model calls."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"
spec = importlib.util.spec_from_file_location("rj", HERE / "review_json.py")
rj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rj)

FINDING = {
    "severity": "high",
    "title": "Off-by-one in loop",
    "body": "The loop skips the last element.",
    "file": "src/a.py",
    "line_start": 3,
    "line_end": 4,
    "confidence": 0.9,
    "recommendation": "Use <= instead of <.",
}
CLEAN = {
    "verdict": "approve",
    "summary": "No issues found.",
    "findings": [],
    "checked": ["src/a.py", "src/b.py"],
    "next_steps": [],
}
CLEAN_JSON_ESCAPED = json.dumps(json.dumps(CLEAN))[1:-1]


class ReviewJsonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="review-json-test-")
        self.addCleanup(self.tmp.cleanup)
        self.n = 0

    def write(self, text):
        self.n += 1
        p = Path(self.tmp.name) / f"f{self.n}.txt"
        p.write_text(text)
        return str(p)

    def kind(self, text):
        with self.assertRaises(rj.ReviewError) as e:
            rj.load_review(self.write(text))
        return e.exception.kind

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", str(HERE / "review_json.py"), *args],
                              capture_output=True, text=True)

    def test_real_fixtures_are_valid(self):
        for name in ("claude-envelope.json", "codex-last.json", "agy-envelope.json"):
            self.assertEqual(rj.classify(rj.load_review(str(FIX / name))), "VALID", name)

    def test_fenced_json_response(self):  # Review Focus 3
        p = self.write('{"status":"SUCCESS","response":"```json\\n' + CLEAN_JSON_ESCAPED + '\\n```"}')
        self.assertEqual(rj.classify(rj.load_review(p)), "CLEAN")

    def test_bare_fence_and_fenced_file(self):
        fenced = "```\n" + json.dumps(CLEAN) + "\n```\n"
        self.assertEqual(rj.classify(rj.load_review(self.write(fenced))), "CLEAN")
        fenced = "```json\n" + json.dumps(CLEAN) + "\n```"
        self.assertEqual(rj.classify(rj.load_review(self.write(fenced))), "CLEAN")

    def test_direct_json_with_whitespace(self):
        self.assertEqual(rj.classify(rj.load_review(self.write("\n  " + json.dumps(CLEAN) + "\n\n"))), "CLEAN")

    def test_claude_result_string(self):
        env = {"type": "result", "is_error": False, "result": json.dumps(CLEAN)}
        self.assertEqual(rj.classify(rj.load_review(self.write(json.dumps(env)))), "CLEAN")

    def test_claude_tool_use_stop_reason_is_not_failure(self):
        env = {"type": "result", "is_error": False, "stop_reason": "tool_use", "structured_output": CLEAN}
        self.assertEqual(rj.classify(rj.load_review(self.write(json.dumps(env)))), "CLEAN")

    def test_agy_prefers_structured_output(self):
        env = {"status": "SUCCESS", "response": "not json at all", "structured_output": CLEAN}
        self.assertEqual(rj.load_review(self.write(json.dumps(env))), CLEAN)

    def test_agy_empty_response_is_error(self):
        for resp in ("", "  \n"):
            env = {"status": "SUCCESS", "response": resp}
            self.assertEqual(self.kind(json.dumps(env)), "error")

    def test_agy_non_success_is_error(self):
        env = {"status": "ERROR", "response": json.dumps(CLEAN)}
        self.assertEqual(self.kind(json.dumps(env)), "error")

    def test_clean_requires_checked(self):
        self.assertEqual(rj.classify({**CLEAN, "checked": []}), "WEAK")

    def test_findings_win_over_approve(self):
        self.assertEqual(rj.classify({**CLEAN, "findings": [FINDING]}), "VALID")

    def test_needs_attention_without_findings_is_weak(self):
        self.assertEqual(rj.classify({**CLEAN, "verdict": "needs-attention"}), "WEAK")

    def test_bad_severity_is_weak(self):
        self.assertEqual(rj.classify({**CLEAN, "findings": [{**FINDING, "severity": "P1"}]}), "WEAK")

    def test_validate_reports_types_required_and_extras(self):
        self.assertEqual(rj.validate(CLEAN), [])
        bad = {k: v for k, v in CLEAN.items() if k != "summary"}
        self.assertTrue(any("summary" in m for m in rj.validate(bad)))
        self.assertTrue(rj.validate({**CLEAN, "extra": 1}))
        self.assertTrue(rj.validate({**CLEAN, "findings": [{**FINDING, "line_start": True}]}))
        self.assertTrue(rj.validate({**CLEAN, "findings": [{**FINDING, "line_start": 0}]}))
        self.assertTrue(rj.validate({**CLEAN, "findings": [{**FINDING, "confidence": 1.5}]}))
        self.assertTrue(rj.validate({**CLEAN, "findings": ["x"]}))
        self.assertTrue(rj.validate({**CLEAN, "checked": "src/a.py"}))
        self.assertTrue(rj.validate([]))

    def test_claude_error_envelope(self):
        self.assertEqual(self.kind('{"is_error":true,"result":"x"}'), "error")

    def test_prose_is_notjson(self):
        self.assertEqual(self.kind("Here are my findings: src/a.py:3 bug"), "notjson")

    def test_other_notjson_shapes(self):
        self.assertEqual(self.kind(""), "notjson")
        self.assertEqual(self.kind("[1,2]"), "notjson")
        self.assertEqual(self.kind('{"error":"Unauthorized"}'), "notjson")
        self.assertEqual(self.kind("```json\nnot json\n```"), "notjson")
        self.assertEqual(self.kind("Intro\n```json\n" + json.dumps(CLEAN) + "\n```"), "notjson")
        env = {"type": "result", "is_error": False, "result": "prose, no json"}
        self.assertEqual(self.kind(json.dumps(env)), "notjson")

    def test_missing_file_is_notjson(self):
        with self.assertRaises(rj.ReviewError) as e:
            rj.load_review(str(Path(self.tmp.name) / "nope"))
        self.assertEqual(e.exception.kind, "notjson")

    def test_cli_exit_codes(self):
        cases = [
            (json.dumps({**CLEAN, "findings": [FINDING]}), "VALID", 0),
            (json.dumps(CLEAN), "CLEAN", 0),
            (json.dumps({**CLEAN, "checked": []}), "WEAK", 5),
            ('{"is_error":true,"result":"x"}', "ERROR", 6),
            ("Here are my findings: src/a.py:3 bug", "NOTJSON", 8),
        ]
        for text, word, rc in cases:
            r = self.run_cli("classify", self.write(text))
            self.assertEqual((r.stdout.strip(), r.returncode), (word, rc), text)
        ok = self.run_cli("extract", str(FIX / "agy-envelope.json"))
        self.assertEqual(ok.returncode, 0)
        self.assertEqual(rj.classify(json.loads(ok.stdout)), "VALID")
        self.assertIn("\n  ", ok.stdout)  # indent=2
        bad = self.run_cli("extract", self.write("Here are my findings: src/a.py:3 bug"))
        self.assertEqual(bad.returncode, 65)
        self.assertEqual(bad.stdout, "")
        self.assertTrue(bad.stderr.strip())

    def test_cli_usage_error(self):
        self.assertEqual(self.run_cli().returncode, 64)
        self.assertEqual(self.run_cli("bogus", "x").returncode, 64)


if __name__ == "__main__":
    unittest.main()
