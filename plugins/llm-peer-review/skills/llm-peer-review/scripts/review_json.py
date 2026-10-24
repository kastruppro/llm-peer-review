#!/usr/bin/env python3
"""Extract, validate and classify structured reviewer output (stdlib only).

CLI:
  review_json.py classify FILE   print VALID|CLEAN|WEAK|ERROR|NOTJSON
                                 exit 0 (VALID/CLEAN), 5 WEAK, 6 ERROR, 8 NOTJSON
  review_json.py extract FILE    print the normalised review JSON (exit 0),
                                 else a message on stderr and exit 65
"""
import json
import re
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "review-output.schema.json"
EXIT_CODES = {"VALID": 0, "CLEAN": 0, "WEAK": 5, "ERROR": 6, "NOTJSON": 8}
FENCE = re.compile(r"\A```(?:json)?[ \t]*\r?\n(.*?)\r?\n?```\Z", re.DOTALL)


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


def _cli(argv):
    if len(argv) != 3 or argv[1] not in ("classify", "extract"):
        print("usage: review_json.py classify|extract FILE", file=sys.stderr)
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
