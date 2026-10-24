#!/usr/bin/env python3
"""Extract, validate and classify structured reviewer output (stdlib only).

CLI:
  review_json.py classify FILE   print VALID|CLEAN|WEAK|ERROR|NOTJSON
                                 exit 0 (VALID/CLEAN), 5 WEAK, 6 ERROR, 8 NOTJSON
  review_json.py extract FILE    print the normalised review JSON (exit 0),
                                 else a message on stderr and exit 65
  review_json.py aggregate --root ROOT VOICE=FILE [VOICE=FILE...]
                                 print Markdown: one status line per voice, then a table
                                 of deterministic finding clusters (exit 0; exit 64 on usage)
"""
import json
import math
import os
import posixpath
import re
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "review-output.schema.json"
EXIT_CODES = {"VALID": 0, "CLEAN": 0, "WEAK": 5, "ERROR": 6, "NOTJSON": 8}
FENCE = re.compile(r"\A```(?:json)?[ \t]*\r?\n(.*?)\r?\n?```\Z", re.DOTALL | re.IGNORECASE)
SEVERITY_RANK = {"critical": 3, "high": 2, "medium": 1, "low": 0}
LINE_MARGIN = 3
WIDE_SPAN = 40  # a finding wider than this many lines is never merged


class ReviewError(Exception):
    """kind is "error" (reviewer/CLI failure) or "notjson" (no review object)."""

    def __init__(self, kind, message=""):
        super().__init__(message or kind)
        self.kind = kind


def _schema():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def _is_review_like(obj):
    return isinstance(obj, dict) and any(k in obj for k in _schema()["properties"])


def _parse_text(text):
    """Parse a model-produced string (optionally one ```json fence) into a review dict."""
    s = text.strip()
    m = FENCE.match(s)
    if m:
        s = m.group(1).strip()
    try:
        obj = json.loads(s)
    except ValueError:
        raise ReviewError("notjson", "text is not a JSON object")
    if not _is_review_like(obj):
        raise ReviewError("notjson", "JSON is not a review object")
    return obj


def load_review(path):
    """Return the review dict from a Claude/agy envelope, fenced text or direct JSON."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise ReviewError("notjson", f"cannot read {path}: {exc}")
    try:
        obj = json.loads(raw.strip())
    except ValueError:
        return _parse_text(raw)  # fenced JSON (agy final response) or prose
    if not isinstance(obj, dict):
        raise ReviewError("notjson", "top-level JSON is not an object")

    if "is_error" in obj or obj.get("type") == "result":  # Claude envelope
        if obj.get("is_error") is True:
            raise ReviewError("error", "claude reported is_error")
        if isinstance(obj.get("structured_output"), dict):
            return obj["structured_output"]
        if isinstance(obj.get("result"), str):
            return _parse_text(obj["result"])
        raise ReviewError("error", "claude envelope has neither structured_output nor result")

    if "status" in obj and not _is_review_like(obj):  # agy envelope
        if obj["status"] != "SUCCESS":
            raise ReviewError("error", f"agy status {obj['status']!r}")
        if isinstance(obj.get("structured_output"), dict):
            return obj["structured_output"]
        resp = obj.get("response")
        if not isinstance(resp, str) or not resp.strip():
            raise ReviewError("error", "agy SUCCESS without a response")
        return _parse_text(resp)

    if not _is_review_like(obj):
        raise ReviewError("notjson", "JSON is not a review object")
    return obj


_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
}


def _check(value, schema, where, errors):
    t = schema.get("type")
    if t and not _TYPES[t](value):
        errors.append(f"{where}: expected {t}, got {type(value).__name__}")
        return
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} not in {schema['enum']}")
    if t == "string" and len(value) < schema.get("minLength", 0):
        errors.append(f"{where}: string shorter than {schema['minLength']}")
    if t in ("integer", "number"):
        if not math.isfinite(value):  # json.loads accepts NaN/Infinity
            errors.append(f"{where}: {value} is not a finite number")
            return
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{where}: {value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{where}: {value} > maximum {schema['maximum']}")
    if t == "object":
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: missing required field {key!r}")
        for key, sub in value.items():
            if key in props:
                _check(sub, props[key], f"{where}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{where}: unexpected field {key!r}")
    if t == "array" and "items" in schema:
        for i, item in enumerate(value):
            _check(item, schema["items"], f"{where}[{i}]", errors)


def validate(review):
    """Schema violations as messages (empty list = valid), plus non-empty `checked`."""
    errors = []
    _check(review, _schema(), "review", errors)
    if isinstance(review, dict) and review.get("checked") == []:
        errors.append("review.checked: must not be empty")
    return errors


def classify(review):
    if validate(review):
        return "WEAK"
    if review["findings"]:
        return "VALID"
    return "CLEAN" if review["verdict"] == "approve" else "WEAK"


def normalize_path(path, root):
    """Repo-relative POSIX path: strips the root prefix and any leading ./"""
    p = path.replace("\\", "/")
    r = root.replace("\\", "/").rstrip("/")
    if r and p.startswith(r + "/"):
        p = p[len(r) + 1:]
    p = posixpath.normpath(p)
    return p[2:] if p.startswith("./") else p


def cluster(reviews, root):
    """Group findings of DIFFERENT voices that point at the same spot.

    Anchor-based, never transitive: a finding joins a cluster only if its line
    range overlaps the cluster's anchor (its first finding's range) with
    LINE_MARGIN lines of slack on each side, and only if that voice is not in the
    cluster yet (same-voice findings never merge). A finding spanning more than
    WIDE_SPAN lines is never merged. Of several candidates the nearest anchor wins.
    Sorted by severity, voice count, file, line. Proximity is not identity: the
    orchestrator still splits clusters that hold more than one defect (SKILL.md §5).
    """
    items = []
    for voice, review in reviews.items():
        for fd in review["findings"]:
            lo, hi = sorted((fd["line_start"], fd["line_end"]))
            items.append((normalize_path(fd["file"], root), lo, hi, voice, fd))
    items.sort(key=lambda it: (it[0], it[1], it[2], it[3], it[4]["title"]))
    clusters = []
    for file, lo, hi, voice, fd in items:
        wide = hi - lo + 1 > WIDE_SPAN
        best, best_gap = None, None
        if not wide:
            for c in clusters:
                if c["file"] != file or c["wide"] or voice in c["voices"]:
                    continue
                a_lo, a_hi = c["anchor"]
                gap = max(0, lo - a_hi, a_lo - hi)
                if gap <= 2 * LINE_MARGIN and (best_gap is None or gap < best_gap):
                    best, best_gap = c, gap
        if best is None:
            clusters.append({"file": file, "line_start": lo, "line_end": hi, "anchor": (lo, hi),
                             "wide": wide, "severity": fd["severity"], "voices": {voice},
                             "confidence": fd["confidence"], "titles": [fd["title"]]})
            continue
        best["line_start"] = min(best["line_start"], lo)
        best["line_end"] = max(best["line_end"], hi)
        if SEVERITY_RANK[fd["severity"]] > SEVERITY_RANK[best["severity"]]:
            best["severity"] = fd["severity"]
        best["confidence"] = max(best["confidence"], fd["confidence"])
        best["voices"].add(voice)
        if fd["title"] not in best["titles"]:
            best["titles"].append(fd["title"])
    for c in clusters:
        c["voices"] = sorted(c["voices"])
        del c["anchor"], c["wide"]
    clusters.sort(key=lambda c: (-SEVERITY_RANK[c["severity"]], -len(c["voices"]), c["file"], c["line_start"]))
    return clusters


def _cell(text):
    return " ".join(str(text).split()).replace("|", "\\|")


def _aggregate(root, specs):
    """Markdown report for (voice, file) pairs; a voice that is not VALID/CLEAN is MANGLER."""
    lines, usable = [], {}
    for voice, path in specs:
        if not os.path.exists(path):
            status = "MANGLER (MISSING)"
        else:
            try:
                review = load_review(path)
            except ReviewError as exc:
                status = "MANGLER (%s)" % ("ERROR" if exc.kind == "error" else "NOTJSON")
            else:
                word = classify(review)
                if word in ("VALID", "CLEAN"):
                    status, usable[voice] = word, review
                else:
                    status = f"MANGLER ({word})"
        lines.append(f"- {voice}: {status}")
    lines += ["", "| # | Severity | Location | Voices | Conf | Titles |", "|---|---|---|---|---|---|"]
    for n, c in enumerate(cluster(usable, root), 1):
        loc = f"{c['file']}:{c['line_start']}-{c['line_end']}"
        lines.append(f"| {n} | {c['severity']} | {_cell(loc)} | {', '.join(c['voices'])} "
                     f"| {c['confidence']:.2f} | {_cell('; '.join(c['titles']))} |")
    return "\n".join(lines) + "\n"


def _aggregate_cli(args):
    usage = "usage: review_json.py aggregate --root ROOT VOICE=FILE [VOICE=FILE...]"
    if len(args) < 3 or args[0] != "--root":
        print(usage, file=sys.stderr)
        return 64
    specs = []
    for arg in args[2:]:
        voice, sep, path = arg.partition("=")
        if not sep or not voice or not path:
            print(usage, file=sys.stderr)
            return 64
        specs.append((voice, path))
    sys.stdout.write(_aggregate(args[1], specs))
    return 0


def _cli(argv):
    if len(argv) > 1 and argv[1] == "aggregate":
        return _aggregate_cli(argv[2:])
    if len(argv) != 3 or argv[1] not in ("classify", "extract"):
        print("usage: review_json.py classify|extract FILE | aggregate --root ROOT VOICE=FILE...", file=sys.stderr)
        return 64
    cmd, path = argv[1], argv[2]
    try:
        review = load_review(path)
    except ReviewError as exc:
        if cmd == "extract":
            print(f"review_json: {exc.kind}: {exc}", file=sys.stderr)
            return 65
        print("ERROR" if exc.kind == "error" else "NOTJSON")
        print(f"review_json: {exc}", file=sys.stderr)
        return EXIT_CODES["ERROR" if exc.kind == "error" else "NOTJSON"]
    if cmd == "extract":
        json.dump(review, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    word = classify(review)
    if word == "WEAK":
        for msg in validate(review) or ["verdict needs-attention but no findings"]:
            print(f"review_json: {msg}", file=sys.stderr)
    print(word)
    return EXIT_CODES[word]


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
