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


def f(file, line, severity="high", title=None, confidence=0.9, line_end=None):
    return {**FINDING, "file": file, "line_start": line, "line_end": line_end or line,
            "severity": severity, "title": title or f"{severity} at {file}:{line}",
            "confidence": confidence}


def rev(*findings):
    return {**CLEAN, "verdict": "needs-attention", "findings": list(findings)}


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

    def test_fence_language_tag_is_case_insensitive(self):
        fenced = "```JSON\n" + json.dumps(CLEAN) + "\n```"
        self.assertEqual(rj.classify(rj.load_review(self.write(fenced))), "CLEAN")

    def test_non_finite_confidence_is_weak(self):
        for bad in ("NaN", "Infinity", "-Infinity"):
            text = json.dumps({**CLEAN, "findings": [FINDING]}).replace('"confidence": 0.9', '"confidence": ' + bad)
            self.assertIn(bad, text)
            self.assertEqual(rj.classify(rj.load_review(self.write(text))), "WEAK", bad)

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

    def test_normalize_path(self):
        n = rj.normalize_path
        self.assertEqual(n("./src/a.py", "/R"), "src/a.py")
        self.assertEqual(n("/R/src/a.py", "/R"), "src/a.py")
        self.assertEqual(n("/R/src/a.py", "/R/"), "src/a.py")
        self.assertEqual(n("src\\a.py", "/R"), "src/a.py")
        self.assertEqual(n("/Rx/a.py", "/R"), "/Rx/a.py")  # prefix must end at a separator

    def test_path_variants_merge(self):  # Review Focus 4
        r = {"claude": rev(f("./src/a.py", 10)), "codex": rev(f("src/a.py", 12)),
             "gemini": rev(f("/R/src/a.py", 14))}
        [c] = rj.cluster(r, "/R")
        self.assertEqual(c["voices"], ["claude", "codex", "gemini"])
        self.assertEqual((c["file"], c["line_start"], c["line_end"]), ("src/a.py", 10, 14))

    def test_far_lines_do_not_merge(self):
        r = {"claude": rev(f("a.py", 10)), "codex": rev(f("a.py", 40))}
        self.assertEqual(len(rj.cluster(r, "/R")), 2)

    def test_three_line_margin_boundary(self):
        near = {"claude": rev(f("a.py", 10)), "codex": rev(f("a.py", 16))}   # 3+3 apart: merge
        far = {"claude": rev(f("a.py", 10)), "codex": rev(f("a.py", 17))}
        self.assertEqual(len(rj.cluster(near, "/R")), 1)
        self.assertEqual(len(rj.cluster(far, "/R")), 2)

    def test_different_files_do_not_merge(self):
        r = {"claude": rev(f("a.py", 10)), "codex": rev(f("b.py", 10))}
        self.assertEqual(len(rj.cluster(r, "/R")), 2)

    def test_cluster_takes_max_severity_confidence_and_unique_titles(self):
        r = {"claude": rev(f("a.py", 10, "low", "T1", 0.4), f("a.py", 11, "critical", "T2", 0.7)),
             "codex": rev(f("a.py", 12, "medium", "T1", 0.95))}
        [c] = rj.cluster(r, "/R")
        self.assertEqual((c["severity"], c["confidence"], c["voices"]), ("critical", 0.95, ["claude", "codex"]))
        self.assertEqual(sorted(c["titles"]), ["T1", "T2"])

    def test_chain_extends_cluster(self):
        r = {"claude": rev(f("a.py", 10), f("a.py", 16), f("a.py", 22))}
        [c] = rj.cluster(r, "/R")
        self.assertEqual((c["line_start"], c["line_end"]), (10, 22))

    def test_sort_severity_then_votes(self):
        r = {"claude": rev(f("a.py", 1, "high"), f("b.py", 1, "medium"), f("c.py", 1, "high"), f("d.py", 1, "low")),
             "codex": rev(f("b.py", 1, "medium"), f("c.py", 1, "high")),
             "gemini": rev(f("b.py", 1, "medium"))}
        got = [(c["file"], c["severity"], len(c["voices"])) for c in rj.cluster(r, "/R")]
        self.assertEqual(got, [("c.py", "high", 2), ("a.py", "high", 1), ("b.py", "medium", 3), ("d.py", "low", 1)])

    def aggregate(self, *pairs, root="/R"):
        return self.run_cli("aggregate", "--root", root, *[f"{v}={p}" for v, p in pairs])

    def test_aggregate_table_and_voice_lines(self):
        a = self.write(json.dumps(rev(f("./src/a.py", 10, title="Bug A"))))
        b = self.write(json.dumps(rev(f("/R/src/a.py", 11, title="Bug A | pipe"))))
        c = self.write(json.dumps(CLEAN))
        r = self.aggregate(("claude", a), ("codex", b), ("gemini", c))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("claude: VALID", r.stdout)
        self.assertIn("gemini: CLEAN", r.stdout)
        self.assertIn("| # | Severity | Location | Voices | Conf | Titles |", r.stdout)
        self.assertIn("| 1 | high | src/a.py:10-11 | claude, codex | 0.90 |", r.stdout)
        self.assertIn("Bug A \\| pipe", r.stdout)

    def test_aggregate_marks_missing_voice(self):
        a = self.write(json.dumps(rev(f("a.py", 1))))
        g = self.write("Here are my findings: src/a.py:3 bug")
        r = self.aggregate(("claude", a), ("gemini", g))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("gemini: MANGLER (NOTJSON)", r.stdout)
        weak = self.write(json.dumps({**CLEAN, "checked": []}))
        self.assertIn("gemini: MANGLER (WEAK)", self.aggregate(("claude", a), ("gemini", weak)).stdout)
        err = self.write('{"is_error":true,"result":"x"}')
        self.assertIn("gemini: MANGLER (ERROR)", self.aggregate(("claude", a), ("gemini", err)).stdout)

    def test_aggregate_missing_file_does_not_crash(self):
        a = self.write(json.dumps(rev(f("a.py", 1))))
        r = self.aggregate(("claude", a), ("codex", str(Path(self.tmp.name) / "nope")))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("codex: MANGLER (MISSING)", r.stdout)
        self.assertIn("a.py:1-1", r.stdout)

    def test_aggregate_weak_voice_findings_are_excluded(self):
        weak = self.write(json.dumps({**rev(f("a.py", 1)), "checked": []}))
        r = self.aggregate(("claude", weak))
        self.assertIn("claude: MANGLER (WEAK)", r.stdout)
        self.assertNotIn("a.py:1", r.stdout)

    def test_aggregate_usage_errors(self):
        self.assertEqual(self.run_cli("aggregate").returncode, 64)
        self.assertEqual(self.run_cli("aggregate", "claude=x").returncode, 64)  # no --root
        self.assertEqual(self.run_cli("aggregate", "--root", "/R", "noequals").returncode, 64)

    def test_cli_usage_error(self):
        self.assertEqual(self.run_cli().returncode, 64)
        self.assertEqual(self.run_cli("bogus", "x").returncode, 64)


if __name__ == "__main__":
    unittest.main()
