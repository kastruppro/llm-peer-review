#!/usr/bin/env python3
"""Choose an installed Codex CLI; only invokes --version, never a review/API."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys


class ResolutionError(Exception):
    pass


def version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ResolutionError(f"Invalid stable CLI version: {value!r}")
    return tuple(int(part) for part in value.split("."))


def candidates(path_value: str, app_roots: list[Path],
               install_dirs: list[Path] | None = None) -> list[Path]:
    # Ignore relative PATH entries: a reviewed project must not supply the CLI.
    bin_dirs = [Path(part) for part in path_value.split(os.pathsep)
                if part and Path(part).is_absolute()]
    if install_dirs is None:
        install_dirs = [Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
                        Path.home() / ".local/bin"]
    bin_dirs.extend(directory for directory in install_dirs if directory.is_absolute())
    paths = [directory / "codex" for directory in bin_dirs]
    # npm's launcher needs node on PATH. Its installed native executable also
    # works in an app/launchd shell with only /usr/bin:/bin; probe it normally.
    for launcher in list(paths):
        try:
            resolved = launcher.resolve()
            package = resolved.parent.parent
            if (resolved.name != "codex.js" or resolved.parent.name != "bin"
                    or package.name != "codex" or package.parent.name != "@openai"):
                continue
            for pattern in ("node_modules/@openai/codex-*/vendor/*/bin/codex",
                            "vendor/*/bin/codex"):
                paths.extend(sorted(package.glob(pattern)))
        except (OSError, RuntimeError):
            continue
    for root in app_roots:
        for name in ("ChatGPT.app", "Codex.app"):
            paths.append(root / name / "Contents/Resources/codex")
    return paths


def select(paths: list[Path], minimum: tuple[int, int, int]) -> tuple[Path, str]:
    available = []
    rejected = []
    seen = set()
    for candidate in paths:
        candidate = candidate.expanduser().absolute()
        try:
            identity = candidate.resolve()
            if identity in seen:
                continue
            seen.add(identity)
            if not candidate.is_file() or not os.access(candidate, os.X_OK):
                continue
            result = subprocess.run(
                [str(candidate), "--version"], capture_output=True, text=True,
                timeout=5, check=False,
            )
            match = re.fullmatch(r"codex-cli (\d+\.\d+\.\d+)(?:\+[\w.-]+)?", result.stdout.strip())
            if result.returncode or not match:
                rejected.append(f"{candidate}: failed/unrecognized stable version")
                continue
            number = version(match.group(1))
            if number < minimum:
                rejected.append(f"{candidate}: {match.group(1)} is too old")
                continue
            available.append((number, candidate, match.group(1)))
        except (OSError, RuntimeError, UnicodeError, subprocess.TimeoutExpired) as exc:
            rejected.append(f"{candidate}: version probe failed ({type(exc).__name__})")
    if not available:
        floor = ".".join(map(str, minimum))
        detail = "; ".join(rejected) or "no executable candidates found"
        raise ResolutionError(f"No compatible stable Codex CLI (tested floor {floor}): {detail}")
    # Numeric ordering, preserving candidate order for identical versions.
    _, executable, found_version = max(available, key=lambda item: item[0])
    return executable, found_version


def main() -> int:
    try:
        registry = json.loads(Path(__file__).with_name("models.json").read_text())
        model = registry["codex"]["model"]
        minimum = version(registry["codex"]["min_cli_version"])
        override = os.environ.get("PEERREVIEW_CODEX_BIN")
        if override:
            explicit = Path(override).expanduser()
            if not explicit.is_absolute():
                raise ResolutionError("PEERREVIEW_CODEX_BIN must be an absolute executable path")
            paths = [explicit]  # Explicit selections must pass; never silently substitute.
        else:
            paths = candidates(os.environ.get("PATH", ""), [Path.home() / "Applications", Path("/Applications")])
        executable, found_version = select(paths, minimum)
        print(f"llm-peer-review: Codex {found_version} for {model}: {executable}", file=sys.stderr)
        print(executable)
        return 0
    except (ResolutionError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"llm-peer-review: {exc}. Set PEERREVIEW_CODEX_BIN to a compatible installed CLI; do not change the requested model.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
