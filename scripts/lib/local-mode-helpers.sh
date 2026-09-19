#!/usr/bin/env bash
# Pure helper functions for review-local.sh's --local mode, kept sourceable so
# scripts/tests/test_review_local_coverage.sh can exercise them without a model.

# find_repo_convention_file <toplevel>
# First hit wins: AGENTS.md, CLAUDE.md, .claude/CLAUDE.md. Prints the relative
# path and returns 0 on a hit; prints nothing and returns 1 otherwise.
find_repo_convention_file() {
    local toplevel="$1"
    local rel
    for rel in AGENTS.md CLAUDE.md .claude/CLAUDE.md; do
        if [ -f "$toplevel/$rel" ]; then
            printf '%s\n' "$rel"
            return 0
        fi
    done
    return 1
}

# compute_review_coverage <markdown_text> <total_files>
# Parses PR-Agent's "Review coverage" footer (files dropped by the token budget)
# against the real diff file count and warns on stderr when coverage is low.
# Warn-only: always returns 0. total_files=0/empty means "unknown" - no output,
# since that avoids both a bogus 0/0 line and a division by zero.
compute_review_coverage() {
    local markdown="$1"
    local total="$2"
    local min_coverage="${PRAGENT_MIN_COVERAGE:-70}"

    if [ -z "$total" ] || ! [ "$total" -eq "$total" ] 2>/dev/null || [ "$total" -eq 0 ]; then
        return 0
    fi

    local not_reviewed=0
    if printf '%s\n' "$markdown" | grep -q "Review coverage:"; then
        not_reviewed="$(printf '%s\n' "$markdown" | grep -c '^- `')"
        local more
        more="$(printf '%s\n' "$markdown" | sed -n 's/^\.\.\. and \([0-9][0-9]*\) more$/\1/p' | head -1)"
        [ -n "$more" ] && not_reviewed=$(( not_reviewed + more ))
    fi

    local reviewed=$(( total - not_reviewed ))
    [ "$reviewed" -lt 0 ] && reviewed=0
    local pct=$(( reviewed * 100 / total ))

    echo "coverage: reviewed=${reviewed}/${total} (${pct}%)" >&2
    if [ "$pct" -lt "$min_coverage" ]; then
        echo "WARNING: low review coverage - split the diff or review per module" >&2
    fi
    return 0
}
