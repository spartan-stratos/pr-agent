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

# --- group_files_by_module ---

out="$(printf '%s\n' \
    a/b/c/F1.kt a/b/c/F2.kt a/b/c/F3.kt \
    d/e/f/F1.kt d/e/f/F2.kt d/e/f/F3.kt \
    | group_files_by_module | sort)"
expected="$(printf '%s\n' \
    'a/b/c	a/b/c/F1.kt' 'a/b/c	a/b/c/F2.kt' 'a/b/c	a/b/c/F3.kt' \
    'd/e/f	d/e/f/F1.kt' 'd/e/f	d/e/f/F2.kt' 'd/e/f	d/e/f/F3.kt' | sort)"
assert_eq "depth-3 grouping keeps 3-file groups separate" "$expected" "$out"

out="$(printf '%s\n' a/b/c/One.kt a/b/c/deeper/nested/Two.kt x/y/z/A.kt x/y/z/B.kt x/y/z/C.kt \
    | group_files_by_module | sort)"
expected="$(printf '%s\n' \
    'misc	a/b/c/One.kt' 'misc	a/b/c/deeper/nested/Two.kt' \
    'x/y/z	x/y/z/A.kt' 'x/y/z	x/y/z/B.kt' 'x/y/z	x/y/z/C.kt' | sort)"
assert_eq "a group under min_group_size (2 files) merges into misc" "$expected" "$out"

files=""
for g in a b c d e f g; do
    for i in 1 2 3; do
        files+="$g/mod/dir/F$i.kt"$'\n'
    done
done
out="$(printf '%s' "$files" | group_files_by_module | cut -f1 | sort -u)"
ndistinct="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "7 natural groups of 3 cap at max_groups=6" "6" "$ndistinct"
# misc itself starts empty, so folding the first tied-smallest group into it
# does not yet reduce the distinct-group count (7 -1 +1 == 7); a second fold
# is needed to reach the cap of 6 - so misc ends up holding 2 groups' files.
misc_count="$(printf '%s' "$files" | group_files_by_module | awk -F'\t' '$1=="misc"' | grep -c .)"
assert_eq "two tied-smallest groups fold into misc to reach the cap" "6" "$misc_count"

out="$(printf '%s\n' 'a/mod+ule/x/A.kt' 'a/mod+ule/x/B.kt' 'a/mod+ule/x/C.kt' | group_files_by_module | cut -f1 -d"$(printf '\t')" | sort -u)"
assert_eq "regex-metacharacter path segment groups correctly" "a/mod+ule/x" "$out"
quoted="$(quote_regex_literal 'a/mod+ule/x')"
assert_eq "quote_regex_literal escapes the metacharacter" 'a/mod\+ule/x' "$quoted"

out="$(printf '%s\n' 'only/one/file/Here.kt' | group_files_by_module)"
assert_eq "single-file input merges into misc (below min_group_size)" \
    "misc	only/one/file/Here.kt" "$out"

# --- build_group_ignore_regex ---

out="$(printf '%s\n' 'a/mod+ule/x/A.kt' 'a/b/c/B.kt' | build_group_ignore_regex)"
assert_eq "build_group_ignore_regex escapes and alternates group files" \
    '^(?!(?:a/mod\+ule/x/A\.kt|a/b/c/B\.kt)$).*' "$out"

# --- make_review_base_ref and prune_stale_review_base_refs ---

# Create a throwaway git repo for ref tests.
GITDIR="$(mktemp -d)"
trap 'rm -rf "$GITDIR"' EXIT
cd "$GITDIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add file.txt
git commit -q -m "initial"

# Test: two calls in different processes yield different ref names.
# Source the helpers in separate bash processes to get different PIDs.
ref1="$(bash -c "source '$ROOT/scripts/lib/local-mode-helpers.sh'; make_review_base_ref abc1234")"
ref2="$(bash -c "source '$ROOT/scripts/lib/local-mode-helpers.sh'; make_review_base_ref abc1234")"
if [ "$ref1" != "$ref2" ]; then
    echo "PASS: different processes yield different ref names"
else
    echo "FAIL: different processes should yield different ref names"
    echo "  ref1: $ref1"
    echo "  ref2: $ref2"
    fail=1
fi

# Test: prune_stale_review_base_refs deletes a legacy ref with no -<pid> suffix.
git branch -q review-base-legacy-only
prune_stale_review_base_refs
if git branch | grep -q "review-base-legacy-only"; then
    echo "FAIL: legacy ref without -<pid> suffix should be pruned"
    fail=1
else
    echo "PASS: legacy ref without -<pid> suffix is pruned"
fi

# Test: prune_stale_review_base_refs deletes a ref whose pid is not alive.
# Use a very high PID that is extremely unlikely to be running.
git branch -q review-base-deadpid-999999999
prune_stale_review_base_refs
if git branch | grep -q "review-base-deadpid-999999999"; then
    echo "FAIL: ref with dead PID should be pruned"
    fail=1
else
    echo "PASS: ref with dead PID is pruned"
fi

# Test: prune_stale_review_base_refs does NOT delete a ref whose pid is alive.
# Create a ref with the current process's PID.
current_pid=$$
git branch -q "review-base-alive-$current_pid"
prune_stale_review_base_refs
if git branch | grep -q "review-base-alive-$current_pid"; then
    echo "PASS: ref with live PID is not pruned"
else
    echo "FAIL: ref with live PID should not be pruned"
    fail=1
fi

# Test: an all-digits legacy ref (review-base-<alldigits>, no -pid suffix) is pruned.
# The sha must be a LIVE pid ($$), or the case cannot tell the implementations apart:
# a naive check falls through to kill -0, and a dead pid is pruned either way, so the
# test would pass against the very bug it exists to catch.
git branch -q "review-base-$$"
prune_stale_review_base_refs
if git branch | grep -q "review-base-$$\b"; then
    echo "FAIL: all-digits legacy ref should be pruned"
    fail=1
else
    echo "PASS: all-digits legacy ref is pruned"
fi

# reviewed_count: a failed pass (rc != 0) emits no coverage footer, so it must
# score 0 reviewed rather than "n files minus 0 unreviewed".
check_reviewed() {
    local label="$1" want="$2" got
    shift 2
    got="$(reviewed_count "$@" 2>&1)"
    if [ "$got" = "$want" ]; then
        echo "PASS: $label"
    else
        echo "FAIL: $label (want '$want', got '$got')"
        fail=1
    fi
}
cov_md=$'Review coverage: 2 of 5 files not reviewed\n- `a.py`\n- `b.py`\n'
check_reviewed "reviewed_count: rc=1 scores 0" 0 1 "" 5
check_reviewed "reviewed_count: rc=1 ignores a coverage footer too" 0 1 "$cov_md" 5
check_reviewed "reviewed_count: rc=0 no footer scores n" 5 0 "" 5
check_reviewed "reviewed_count: rc=0 footer subtracts listed files" 3 0 "$cov_md" 5
check_reviewed "reviewed_count: rc=0 floors at 0" 0 0 "$cov_md" 1

exit $fail
