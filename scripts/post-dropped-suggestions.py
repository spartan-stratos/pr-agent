#!/usr/bin/env python3
"""Recover PR-Agent suggestions that couldn't be attached inline and post them as a
single consolidated PR comment, so they aren't silently dropped.

PR-Agent logs an ERROR line per dropped suggestion:
    Failed to publish invalid comment as a single line comment: {<python-dict-repr>}
This happens when a suggestion targets a line outside the PR's diff hunks (common on
move/refactor PRs). We parse those dicts from the captured stderr and post them via `gh`.

Usage: post-dropped-suggestions.py <pr_url> <stderr_log_path>
Exit 0 always (best-effort; never breaks the review run).
"""
import ast
import re
import subprocess
import sys

MARKER = "Failed to publish invalid comment as a single line comment: "
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def parse_dropped(log_text: str) -> list[dict]:
    out, seen = [], set()
    for line in log_text.splitlines():
        line = ANSI.sub("", line)
        idx = line.find(MARKER)
        if idx == -1:
            continue
        blob = line[idx + len(MARKER):].strip()
        try:
            d = ast.literal_eval(blob)  # the logged value is a python dict literal
        except (ValueError, SyntaxError):
            continue
        if not isinstance(d, dict) or "body" not in d:
            continue
        key = (d.get("path"), d.get("line"), d.get("body"))
        if key in seen:
            continue
        seen.add(key)
        out.append(d)
    return out


def render(items: list[dict]) -> str:
    lines = [
        "## PR-Agent suggestions that couldn't be attached inline",
        "",
        "These reference lines **outside this PR's diff hunks** (common on move/refactor PRs), "
        "so GitHub rejected them as inline comments. Posting them here so they aren't lost:",
        "",
    ]
    for d in items:
        path = (d.get("path") or "").strip()
        line = d.get("line") or d.get("relevant_lines_start") or "?"
        body = (d.get("body") or "").strip().replace("\n", " ")
        lines.append(f"- **`{path}`:{line}** — {body}")
    return "\n".join(lines) + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        return 0
    pr_url, log_path = sys.argv[1], sys.argv[2]
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            log_text = f.read()
    except OSError:
        return 0
    items = parse_dropped(log_text)
    if not items:
        return 0
    body = render(items)
    try:
        subprocess.run(
            ["gh", "pr", "comment", pr_url, "--body-file", "-"],
            input=body, text=True, check=True,
        )
        print(f"post-dropped-suggestions: posted {len(items)} dropped suggestion(s) as a PR comment", file=sys.stderr)
    except Exception as e:  # noqa: BLE001 - best-effort, never fail the review
        print(f"post-dropped-suggestions: failed to post fallback comment: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
