#!/usr/bin/env bash
# recall-harness.sh - measures how OFTEN review-local.sh's review/improve
# passes find a known, planted defect, across N repeated real model calls
# per fixture. A single run proves nothing (see scripts/tests/recall-fixtures.tsv
# for the baseline this was built to measure: 2/6 on `review`, 0/6 on
# `improve`). This is an instrument only - it must never alter the wrapper,
# a prompt, or a default; see .agent/recall-harness-state.md do_not_touch.
#
# ITERATIONS RUN STRICTLY SEQUENTIALLY, NEVER IN PARALLEL. review-local.sh
# materialises a temp base ref named `review-base-<short-sha>` (deterministic
# for a given base) in the repo's shared git common dir - visible to every
# worktree of that repo - and deletes it in an EXIT trap. Two concurrent
# invocations against the same repo+base would have the first to finish
# delete the ref the second is still diffing against.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_TSV="$SCRIPT_DIR/tests/recall-fixtures.tsv"

N=10
FIXTURE_FILTER=()

usage() {
    echo "Usage: $0 [-n N] [-f FIXTURE_NAME]..." >&2
    exit 1
}

while getopts "n:f:" opt; do
    case "$opt" in
        n) N="$OPTARG" ;;
        f) FIXTURE_FILTER+=("$OPTARG") ;;
        *) usage ;;
    esac
done

fixture_wanted() {
    local name="$1" f
    [ "${#FIXTURE_FILTER[@]}" -eq 0 ] && return 0
    for f in "${FIXTURE_FILTER[@]}"; do
        [ "$f" = "$name" ] && return 0
    done
    return 1
}

# Never checked out in the fixture repo's own working tree - that repo is
# someone's live checkout, possibly on another branch, and the wrapper
# refuses a dirty tree. A fresh worktree in a temp dir is clean by
# construction and disposable via trap, on success or failure alike.
CURRENT_REPO=""
CURRENT_WORKTREE_PARENT=""
CURRENT_WORKTREE_DIR=""

cleanup_current_worktree() {
    if [ -n "$CURRENT_WORKTREE_DIR" ] && [ -n "$CURRENT_REPO" ]; then
        git -C "$CURRENT_REPO" worktree remove --force "$CURRENT_WORKTREE_DIR" >/dev/null 2>&1 || true
    fi
    if [ -n "$CURRENT_WORKTREE_PARENT" ] && [ -d "$CURRENT_WORKTREE_PARENT" ]; then
        rm -rf "$CURRENT_WORKTREE_PARENT"
    fi
    CURRENT_REPO=""
    CURRENT_WORKTREE_PARENT=""
    CURRENT_WORKTREE_DIR=""
}
trap cleanup_current_worktree EXIT

# Prints the effective value the wrapper will actually use for an env-var
# knob, marked "(default)" when unset here and the default was read from
# its source; "unknown" rather than a guessed number when the source
# doesn't parse - a wrong documented default is worse than an absent one.
knob_from_shell_default() {
    local var="$1" file="$2" d
    if [ -n "${!var:-}" ]; then
        echo "${var}=${!var}"
        return
    fi
    d="$(grep -oE "${var}:-[0-9]+" "$file" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)"
    if [ -n "$d" ]; then
        echo "${var}=${d}(default)"
    else
        echo "${var}=unknown"
    fi
}

knob_temperature() {
    if [ -n "${CONFIG__TEMPERATURE:-}" ]; then
        echo "CONFIG__TEMPERATURE=${CONFIG__TEMPERATURE}"
        return
    fi
    local d
    d="$(grep -oE '^temperature[[:space:]]*=[[:space:]]*[0-9.]+' "$ROOT/pr_agent/settings/configuration.toml" 2>/dev/null | head -1 | grep -oE '[0-9.]+$' || true)"
    if [ -n "$d" ]; then
        echo "CONFIG__TEMPERATURE=${d}(default)"
    else
        echo "CONFIG__TEMPERATURE=unknown"
    fi
}

echo "knobs: $(knob_from_shell_default PRAGENT_CONV_CAP "$ROOT/scripts/review-local.sh") $(knob_temperature) $(knob_from_shell_default PRAGENT_SPLIT_THRESHOLD "$ROOT/scripts/review-local.sh") $(knob_from_shell_default PRAGENT_REVIEW_UNION_K "$ROOT/scripts/review-local.sh")"

TOTAL_FOUND=0
TOTAL_ATTEMPTED=0
TOTAL_ERRORS=0

# Scored PER SECTION (split on "## review pass " headings; a file with none is
# one section, which is what keeps K=1 scoring untouched) then OR'd together.
# A file-wide check was tried first and is wrong: a K-pass union usually has at
# least one miss-phrase section even when another genuinely found the defect, so
# it demands all K sub-passes hit at once - inverting a union into an
# all-K-must-hit test. Do not "simplify" this back.
review_hit() {
    local out_file="$1" expect="$2"
    local sections_dir sec_file hit=1

    if grep -q '^## review pass ' "$out_file"; then
        sections_dir="$(mktemp -d)"
        awk -v dir="$sections_dir" 'BEGIN{n=0} /^## review pass /{n++} {print > (dir "/sec-" n)}' "$out_file"
        for sec_file in "$sections_dir"/sec-*; do
            [ -f "$sec_file" ] || continue
            if grep -qEi "$expect" "$sec_file" && ! grep -q "No major issues detected" "$sec_file"; then
                hit=0
                break
            fi
        done
        rm -rf "$sections_dir"
    else
        if grep -qEi "$expect" "$out_file" && ! grep -q "No major issues detected" "$out_file"; then
            hit=0
        fi
    fi
    return "$hit"
}

# improve hit = the JSON parses AND some code_suggestions element has a
# field matching expect_regex. python3, not grep, so a hit means a real
# suggestion and not an incidental match inside unrelated JSON.
improve_hit() {
    local out_file="$1" expect="$2"
    python3 - "$out_file" "$expect" <<'PYEOF'
import json, re, sys
path, pattern = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
rx = re.compile(pattern, re.IGNORECASE)
for s in data.get("code_suggestions") or []:
    if not isinstance(s, dict):
        continue
    for v in s.values():
        if isinstance(v, str) and rx.search(v):
            sys.exit(0)
sys.exit(1)
PYEOF
}

run_pass() {
    local fixture="$1" worktree="$2" base="$3" pass="$4" expect="$5" n="$6"
    local found=0 errors=0 i out_file err_file rc start end elapsed last_err
    local times=() last_sections=0

    for i in $(seq 1 "$n"); do
        echo "fixture $fixture pass $pass iter $i/$n" >&2
        out_file="$(mktemp)"
        err_file="$(mktemp)"
        rc=0
        start="$(_now)"
        ( cd "$worktree" && "$ROOT/scripts/review-local.sh" --local "$base" "$pass" ) \
            >"$out_file" 2>>"$err_file" || rc=$?
        end="$(_now)"
        elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.0f", e-s}')"
        times+=("$elapsed")

        # Ground truth for whether union actually ran, from the LAST iteration's
        # output - 0 means either K=1 (no headings expected) or the env var
        # never reached the wrapper (headings expected but absent).
        last_sections="$(grep -c '^## review pass ' "$out_file" 2>/dev/null || true)"

        if [ "$rc" -ne 0 ]; then
            # An error means the measurement did not happen, not that recall
            # missed - it is excluded from the rate's denominator below, not
            # tallied as a miss. Tail of stderr makes a systematic failure
            # (rate limit, truncated response) diagnosable, not just counted.
            last_err="$(tail -n 2 "$err_file" 2>/dev/null | tr '\n' ' ')"
            echo "fixture $fixture pass $pass iter $i/$n: wrapper exited $rc (excluded from rate); stderr: ${last_err:-<empty>}" >&2
            errors=$((errors + 1))
        else
            local hit=0
            if [ "$pass" = "review" ]; then
                review_hit "$out_file" "$expect" && hit=1
            else
                improve_hit "$out_file" "$expect" && hit=1
            fi
            found=$((found + hit))
        fi
        rm -f "$out_file" "$err_file"
    done

    local median max
    median="$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$0} END{if(NR%2==1) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}')"
    max="$(printf '%s\n' "${times[@]}" | sort -n | tail -1)"

    local attempted=$((n - errors))
    local rate="n/a"
    [ "$attempted" -gt 0 ] && rate=$((found * 100 / attempted))
    echo "recall fixture=$fixture pass=$pass n=$n attempted=$attempted found=$found errors=$errors rate=$rate wall_median=$median wall_max=$max sections_observed=$last_sections"

    TOTAL_FOUND=$((TOTAL_FOUND + found))
    TOTAL_ATTEMPTED=$((TOTAL_ATTEMPTED + attempted))
    TOTAL_ERRORS=$((TOTAL_ERRORS + errors))
}

_now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }

skip_fixture() {
    local fixture="$1" passes="$2" reason="$3"
    local pass_list pass
    IFS=',' read -ra pass_list <<< "$passes"
    for pass in "${pass_list[@]}"; do
        echo "recall fixture=$fixture pass=$pass SKIPPED reason=$reason"
    done
}

while IFS=$'\t' read -r name repo_path ref base passes expect_regex || [ -n "${name:-}" ]; do
    case "$name" in
        ''|'#'*) continue ;;
    esac
    fixture_wanted "$name" || continue

    if [ ! -d "$repo_path/.git" ] && ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
        skip_fixture "$name" "$passes" "repo_path not a git repo: $repo_path"
        continue
    fi
    if ! git -C "$repo_path" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
        skip_fixture "$name" "$passes" "ref not found: $ref"
        continue
    fi
    if ! git -C "$repo_path" rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
        skip_fixture "$name" "$passes" "base not found: $base"
        continue
    fi

    CURRENT_WORKTREE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/recall-harness.XXXXXX")"
    CURRENT_WORKTREE_DIR="$CURRENT_WORKTREE_PARENT/wt"
    CURRENT_REPO="$repo_path"
    if ! git -C "$repo_path" worktree add --detach --quiet "$CURRENT_WORKTREE_DIR" "$ref" >/dev/null 2>&1; then
        skip_fixture "$name" "$passes" "worktree creation failed for ref: $ref"
        cleanup_current_worktree
        continue
    fi
    # A fresh worktree is clean by construction; if it is not, something is
    # wrong with the ref itself (e.g. untracked artifacts baked into it) and
    # the wrapper would refuse it on every iteration - skip rather than burn
    # N model calls on a fixture that cannot produce a real measurement.
    if [ -n "$(git -C "$CURRENT_WORKTREE_DIR" status --porcelain)" ]; then
        skip_fixture "$name" "$passes" "fresh worktree not clean for ref: $ref"
        cleanup_current_worktree
        continue
    fi

    IFS=',' read -ra pass_list <<< "$passes"
    for p in "${pass_list[@]}"; do
        run_pass "$name" "$CURRENT_WORKTREE_DIR" "$base" "$p" "$expect_regex" "$N"
    done

    cleanup_current_worktree
done < "$FIXTURES_TSV"

echo "recall: ${TOTAL_FOUND}/${TOTAL_ATTEMPTED} (errors=${TOTAL_ERRORS})"
