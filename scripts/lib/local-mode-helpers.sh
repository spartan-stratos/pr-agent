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

# count_unreviewed_files <markdown_text>
# Parses PR-Agent's "Review coverage" footer (files dropped by the token
# budget) and prints how many files it names. 0 when the footer is absent.
count_unreviewed_files() {
    local markdown="$1" not_reviewed=0 more
    if printf '%s\n' "$markdown" | grep -q "Review coverage:"; then
        not_reviewed="$(printf '%s\n' "$markdown" | grep -c '^- `')"
        more="$(printf '%s\n' "$markdown" | sed -n 's/^\.\.\. and \([0-9][0-9]*\) more$/\1/p' | head -1)"
        [ -n "$more" ] && not_reviewed=$(( not_reviewed + more ))
    fi
    printf '%s\n' "$not_reviewed"
}

# compute_review_coverage <markdown_text> <total_files>
# Compares count_unreviewed_files() against the real diff file count and
# warns on stderr when coverage is low. Warn-only: always returns 0.
# total_files=0/empty means "unknown" - no output, avoiding both a bogus
# 0/0 line and a division by zero.
compute_review_coverage() {
    local markdown="$1"
    local total="$2"
    local min_coverage="${PRAGENT_MIN_COVERAGE:-70}"

    if [ -z "$total" ] || ! [ "$total" -eq "$total" ] 2>/dev/null || [ "$total" -eq 0 ]; then
        return 0
    fi

    local not_reviewed
    not_reviewed="$(count_unreviewed_files "$markdown")"

    local reviewed=$(( total - not_reviewed ))
    [ "$reviewed" -lt 0 ] && reviewed=0
    local pct=$(( reviewed * 100 / total ))

    echo "coverage: reviewed=${reviewed}/${total} (${pct}%)" >&2
    if [ "$pct" -lt "$min_coverage" ]; then
        echo "WARNING: low review coverage - split the diff or review per module" >&2
    fi
    return 0
}

# group_files_by_module [depth] [min_group_size] [max_groups]
# Reads a newline-separated file list on stdin, prints "group<TAB>file" lines.
# Pure function: no git, no model, deterministic. Groups by the first `depth`
# directory components (default 3; fewer levels use what's there; a top-level
# file groups as "root"), folds groups under `min_group_size` (default 3) into
# "misc", then caps total groups at `max_groups` (default 6) by folding the
# smallest remaining groups into "misc" (ties broken alphabetically).
group_files_by_module() {
    local depth="${1:-3}" min_group_size="${2:-3}" max_groups="${3:-6}"
    awk -v depth="$depth" -v min_size="$min_group_size" -v max_groups="$max_groups" '
    $0 != "" {
        n = ++total
        files[n] = $0
        dircount = split($0, parts, "/") - 1
        if (dircount <= 0) {
            key = "root"
        } else {
            take = (dircount < depth) ? dircount : depth
            key = parts[1]
            for (i = 2; i <= take; i++) key = key "/" parts[i]
        }
        group[n] = key
    }
    END {
        for (i = 1; i <= total; i++) natural_count[group[i]]++
        for (k in natural_count) if (natural_count[k] < min_size) small[k] = 1
        for (i = 1; i <= total; i++) if (group[i] in small) group[i] = "misc"

        for (;;) {
            delete count2
            for (i = 1; i <= total; i++) count2[group[i]]++
            ndistinct = 0
            for (k in count2) ndistinct++
            if (ndistinct <= max_groups) break

            smallest_k = ""
            smallest_c = 0
            for (k in count2) {
                if (k == "misc") continue
                if (smallest_k == "" || count2[k] < smallest_c || (count2[k] == smallest_c && k < smallest_k)) {
                    smallest_c = count2[k]
                    smallest_k = k
                }
            }
            if (smallest_k == "") break  # only misc left; nothing left to merge
            for (i = 1; i <= total; i++) if (group[i] == smallest_k) group[i] = "misc"
        }

        for (i = 1; i <= total; i++) print group[i] "\t" files[i]
    }
    '
}

# quote_regex_literal <string>
# Escapes basic-regex/extended-regex metacharacters so a literal directory
# prefix can be embedded verbatim inside a larger regex (e.g. a per-group
# negative-lookahead ignore pattern).
quote_regex_literal() {
    printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# build_group_ignore_regex
# Reads newline-separated file paths (one group's files) on stdin, prints one
# regex on stdout. Alternation of the exact paths, not a directory prefix -
# filter_ignored() runs re.match() (not fullmatch), so a shallow prefix would
# also keep a nested group's files and inflate per-group coverage sums.
build_group_ignore_regex() {
    local file quoted alt=""
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        quoted="$(quote_regex_literal "$file")"
        if [ -z "$alt" ]; then alt="$quoted"; else alt="$alt|$quoted"; fi
    done
    printf '^(?!(?:%s)$).*' "$alt"
}

# make_review_base_ref <short-sha>
# Generates a unique temp ref name by appending the current process ID to avoid
# collisions when multiple review-local runs target the same base commit.
# Prints "review-base-<short-sha>-<pid>".
make_review_base_ref() {
    local short_sha="$1"
    printf 'review-base-%s-%d' "$short_sha" "$$"
}

# prune_stale_review_base_refs
# Removes abandoned review-base-* refs from prior runs whose PID no longer exists,
# and legacy refs without a -<pid> suffix. Never deletes a ref whose PID is alive.
# Silently does nothing if no such refs exist. Returns 0 always.
prune_stale_review_base_refs() {
    local ref pid
    git for-each-ref 'refs/heads/review-base-*' --format='%(refname:short)' |
    while IFS= read -r ref; do
        # Extract the trailing segment after the last hyphen.
        pid="${ref##*-}"
        # A valid modern ref has form review-base-<sha>-<digits>. If the trailing
        # segment is NOT all digits, or the ref doesn't match the expected pattern,
        # it's a legacy ref without a pid suffix - delete it.
        if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! [[ "$ref" =~ ^review-base-.+-[0-9]+$ ]]; then
            # Legacy ref with no pid suffix or unexpected format.
            git branch -D "$ref" >/dev/null 2>&1 || true
        elif ! kill -0 "$pid" 2>/dev/null; then
            # PID extracted, matches pattern, but the process is not alive.
            git branch -D "$ref" >/dev/null 2>&1 || true
        fi
    done
    return 0
}
