#!/usr/bin/env bash
# Plain-bash tests for scripts/lib/local-mode-helpers.sh. No model, no python,
# no network - pure functions only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/local-mode-helpers.sh disable=SC1091
source "$ROOT/scripts/lib/local-mode-helpers.sh"

fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        fail=1
    else
        echo "PASS: $desc"
    fi
}

# --- find_repo_convention_file ---

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/root-claude-md" "$WORKDIR/dotclaude" "$WORKDIR/agents-md" "$WORKDIR/none"
echo "x" > "$WORKDIR/root-claude-md/CLAUDE.md"
mkdir -p "$WORKDIR/dotclaude/.claude"
echo "x" > "$WORKDIR/dotclaude/.claude/CLAUDE.md"
echo "x" > "$WORKDIR/agents-md/AGENTS.md"
echo "x" > "$WORKDIR/agents-md/CLAUDE.md"

out="$(find_repo_convention_file "$WORKDIR/root-claude-md")"
assert_eq "root CLAUDE.md is found when AGENTS.md absent" "CLAUDE.md" "$out"

out="$(find_repo_convention_file "$WORKDIR/dotclaude")"
assert_eq ".claude/CLAUDE.md found when nothing else present" ".claude/CLAUDE.md" "$out"

out="$(find_repo_convention_file "$WORKDIR/agents-md")"
assert_eq "AGENTS.md wins over root CLAUDE.md" "AGENTS.md" "$out"

if find_repo_convention_file "$WORKDIR/none" > /dev/null; then
    echo "FAIL: no-convention dir should return 1"
    fail=1
else
    echo "PASS: no-convention dir returns 1"
fi

# --- compute_review_coverage ---

MD_WITH_GAP='body text

<hr>

⚠️ **Review coverage:** The following files were not included in this review because of the token budget:
- `a.kt`
- `b.kt`
- `c.kt`
... and 2 more'

out="$(compute_review_coverage "$MD_WITH_GAP" 10 2>&1 >/dev/null)"
assert_eq "coverage line counts bullets + and-N-more" \
    "coverage: reviewed=5/10 (50%)" "$(printf '%s\n' "$out" | sed -n '1p')"
assert_eq "low coverage warning printed under default 70% threshold" \
    "WARNING: low review coverage - split the diff or review per module" \
    "$(printf '%s\n' "$out" | sed -n '2p')"

MD_CLEAN='body text, no coverage footer'
out="$(compute_review_coverage "$MD_CLEAN" 10 2>&1 >/dev/null)"
assert_eq "full coverage line when no footer present" \
    "coverage: reviewed=10/10 (100%)" "$(printf '%s\n' "$out" | sed -n '1p')"
line_count="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "no warning line when coverage is full" "1" "$line_count"

out="$(compute_review_coverage "$MD_CLEAN" 0 2>&1 >/dev/null)"
assert_eq "total=0 (unknown) produces no output" "" "$out"

out="$(PRAGENT_MIN_COVERAGE=90 compute_review_coverage "$MD_CLEAN" 10 2>&1 >/dev/null)"
assert_eq "100% coverage never warns even with a raised threshold" \
    "1" "$(printf '%s\n' "$out" | grep -c .)"

exit $fail
