#!/usr/bin/env python3
"""Emit a budgeted digest of a review-pattern file, keeping its ACTIONABLE sections.

review-local.sh used to cut each pattern at the first N bytes. That is the wrong N bytes: measured
2026-10-10 across the pattern KB, 12 of 27 files exceed the cut, and the sections that fall past it
are `## Do NOT flag`, `## DO flag` and `## How to recognize in a diff` - the entire half that tells
a reviewer what to raise and what to suppress. The preamble explaining the mechanism survived; the
instructions did not.

So the cut is section-aware instead. The rule statement and a bounded preamble always survive, then
the actionable sections in priority order, then the rest, with provenance (`## Evidence`) last
because it is the part a model needs least.

Usage: pattern-digest.py <file> [cap-chars]
Writes the digest to stdout. On any unexpected failure it falls back to a head cut, so a malformed
pattern degrades to the old behaviour rather than vanishing from the review.
"""
import re
import sys

# Matched case-insensitively against the heading text. Order is the PRIORITY ORDER within the
# actionable tier, not merely a membership test: a long `## Rules` section must not starve
# `## DO flag`, which is what happens when position in the file decides.
HIGH = (
    r"do\s*n[o']?t\s+flag",
    r"do\s+flag",
    r"before\s+approving",
    r"discriminator",
    r"how\s+to\s+recogni[sz]e",
    r"^rules?$",
    r"^the\s+rule$",
)
LOW = (r"^evidence$", r"^companion", r"^further\s+reading$", r"^references?$", r"^see\s+also$")


def rank(heading: str) -> tuple:
    """(tier, sub-rank) - lower sorts first. Tier 0 is actionable, 1 is explanatory, 2 is
    provenance, which a model needs least."""
    text = heading.lstrip("#").strip().strip("`").lower()
    for i, pat in enumerate(HIGH):
        if re.search(pat, text):
            return (0, i)
    for pat in LOW:
        if re.search(pat, text):
            return (2, 0)
    return (1, 0)


def digest(body: str, cap: int) -> str:
    # Drop the resolver's own metadata: it steers selection, never the review.
    lines = body.splitlines()
    while lines and re.match(r"(?i)^(triggers|repos):", lines[0]):
        lines.pop(0)
    while lines and not lines[0].strip():
        lines.pop(0)

    # Split on level-2 headings. Anything before the first one is the preamble (H1 + lead text).
    chunks, cur = [], []
    for line in lines:
        if line.startswith("## "):
            chunks.append(cur)
            cur = [line]
        else:
            cur.append(line)
    chunks.append(cur)
    preamble = "\n".join(chunks[0]).strip()
    sections = ["\n".join(c).strip() for c in chunks[1:] if "\n".join(c).strip()]

    if len(body) <= cap and not preamble.startswith("triggers:"):
        out = ("\n\n".join([preamble, *sections])).strip()
        if len(out) <= cap:
            return out

    # Reserve room for the omitted-sections note, so adding it cannot push the digest past the cap
    # that the caller budgeted for.
    budget = max(400, cap - 64)
    # The rule statement must survive, so the preamble gets a bounded share and never the whole cap.
    pre_cap = max(400, budget // 4)
    kept = [preamble if len(preamble) <= pre_cap else _cut(preamble, pre_cap)]
    used = len(kept[0])

    ranked = sorted(range(len(sections)), key=lambda i: rank(sections[i].splitlines()[0]) + (i,))
    # Within the actionable tier every section gets a fair share, so one long section cannot
    # consume the budget and leave the others out. Lower tiers then take whatever is left over.
    n_high = sum(1 for i in ranked if rank(sections[i].splitlines()[0])[0] == 0)
    dropped = 0
    for i in ranked:
        sec = sections[i]
        room = budget - used - 2
        if rank(sec.splitlines()[0])[0] == 0 and n_high > 0:
            room = min(room, max(400, (budget - used - 2) // n_high))
            n_high -= 1
        if room < 200:
            dropped += 1
            continue
        kept.append(sec if len(sec) <= room else _cut(sec, room))
        used += min(len(sec), room) + 2
    out = "\n\n".join(kept)
    if dropped:
        out += f"\n\n(+{dropped} further section(s) omitted for length)"
    # Final clamp: the caller budgeted `cap`, so never hand back more than that.
    return _cut(out, cap) if len(out) > cap else out


def _cut(text: str, room: int) -> str:
    """Truncate at a line boundary so a sentence is never halved mid-word."""
    if len(text) <= room:
        return text
    head = text[: max(0, room - 4)]
    nl = head.rfind("\n")
    if nl > room // 2:
        head = head[:nl]
    return head.rstrip() + "\n..."


def main() -> int:
    if not 2 <= len(sys.argv) <= 3:
        print("usage: pattern-digest.py <file> [cap-chars]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    cap = int(sys.argv[2]) if len(sys.argv) == 3 else 3000
    with open(path, encoding="utf-8", errors="replace") as fh:
        body = fh.read()
    try:
        sys.stdout.write(digest(body, cap))
    except Exception as exc:  # degrade to the old head cut rather than drop the pattern
        print(f"pattern-digest: {path}: {exc}", file=sys.stderr)
        sys.stdout.write(body[:cap])
    return 0


if __name__ == "__main__":
    sys.exit(main())
