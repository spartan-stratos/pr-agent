"""Fingerprint a pr-agent suggestion by its existing/improved code snippets."""
from __future__ import annotations

import hashlib
import re
from typing import Optional


_STRING_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')
_NUMERIC = re.compile(r"\b\d+(?:\.\d+)?\b")
_WHITESPACE_RUN = re.compile(r"[ \t]+")


def normalize(snippet: str) -> str:
    """Canonicalize a code snippet so cosmetic differences fingerprint-match."""
    if not snippet:
        return ""

    out: list[str] = []
    for line in snippet.splitlines():
        line = line.strip()
        if not line:
            continue
        line = _STRING_LITERAL.sub('"S"', line)
        line = _NUMERIC.sub("N", line)
        line = _WHITESPACE_RUN.sub(" ", line)
        out.append(line)
    return "\n".join(out)


def fingerprint(existing_code: Optional[str], improved_code: Optional[str]) -> str:
    """Return a 16-hex-char content hash of normalized (existing -> improved)."""
    a = normalize(existing_code or "")
    b = normalize(improved_code or "")
    payload = f"{a}\n→\n{b}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]
