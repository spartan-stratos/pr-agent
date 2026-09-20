#!/usr/bin/env bash
# Runs PR-Agent review/improve through the local Claude Code CLI handler (Max subscription, no API key).
set -euo pipefail

MODEL="${MODEL:-claude_cli/sonnet}"

# Local self-review mode: diff HEAD vs a target branch with PR-Agent's LocalGitProvider.
# No PR URL, no GitHub token, never posts - emits structured output to stdout.
LOCAL_MODE=0
PREVIEW_FLAG=""
PER_MODULE_FLAG=0
usage() {
    echo "Usage: $0 <pr-url> [review|improve] [--preview]" >&2
    echo "       $0 --local [target] [review|improve] [--per-module]   (HEAD vs target, no PR, no post)" >&2
    exit 1
}

# Strip --per-module from anywhere in argv before positional parsing (local mode
# only; github mode ignores the flag entirely - see the split-trigger check below).
ARGS=()
for _a in "$@"; do
    if [ "$_a" = "--per-module" ]; then
        PER_MODULE_FLAG=1
    else
        ARGS+=("$_a")
    fi
done
if [ "${#ARGS[@]}" -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

if [ "${1:-}" = "--local" ]; then
    LOCAL_MODE=1
    TARGET="${2:-}"
    CMD="${3:-review}"
else
    PR_URL="${1:-}"
    CMD="${2:-review}"
    PREVIEW_FLAG="${3:-}"
    [ -z "$PR_URL" ] && usage
fi

if [ "$CMD" != "review" ] && [ "$CMD" != "improve" ]; then
    usage
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"
# shellcheck source=lib/local-mode-helpers.sh disable=SC1091
source "$ROOT/scripts/lib/local-mode-helpers.sh"

if [ ! -x "$PY" ]; then
    echo "Missing $PY. Create the venv with: python3 -m venv .venv && .venv/bin/pip install -e ." >&2
    exit 1
fi

if [ "$LOCAL_MODE" = "1" ]; then
    # Resolve target: explicit arg, else origin/master, else origin/main, else local master/main.
    # Prefer the REMOTE-tracking ref over the local branch. In a multi-worktree setup the local
    # master is routinely stale (it is checked out in another worktree, so `git fetch` does not
    # move it), and diffing against it reviews commits the author never wrote - measured at 4
    # files instead of 1 on a reproduction, 3 of them a teammate's merged work. Nothing errors,
    # so the wrong review still records a marker and satisfies the PR gate.
    if [ -z "$TARGET" ]; then
        if git rev-parse --verify --quiet "origin/master^{commit}" >/dev/null; then TARGET=origin/master
        elif git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then TARGET=origin/main
        elif git show-ref --verify --quiet refs/heads/master; then TARGET=master
        elif git show-ref --verify --quiet refs/heads/main; then TARGET=main
        else echo "No target branch given and neither 'origin/master', 'origin/main', 'master' nor 'main' exists." >&2; exit 1; fi
    fi
    # Accept ANY resolvable commit-ish (origin/master, a SHA, a tag), not only refs/heads/*.
    # The old refs/heads-only check rejected `origin/master` outright, which is what forced the
    # caller onto the stale local branch in the first place.
    if ! git rev-parse --verify --quiet "${TARGET}^{commit}" >/dev/null; then
        echo "Branch '$TARGET' does not exist locally. Fetch it first (e.g. git fetch origin $TARGET:$TARGET)." >&2
        exit 1
    fi
    if [[ "$TARGET" == origin/* ]]; then
        _local_target="${TARGET#origin/}"
        if git show-ref --verify --quiet "refs/heads/$_local_target" \
           && [ "$(git rev-parse "$TARGET")" != "$(git rev-parse "$_local_target")" ]; then
            echo "note: using $TARGET instead of stale local $_local_target." >&2
        fi
    fi
    # LocalGitProvider reads file content from the working tree, so a file UNDER REVIEW whose
    # working copy differs from HEAD would be reviewed as something other than what HEAD says -
    # that is the real invariant. Scope the check to the reviewed files rather than the whole tree:
    # a stray unrelated file (routine when two sessions share a checkout, or when a long-running
    # edit sits in another subdir) cannot affect the diff, and failing on it disabled self-review
    # entirely - which silently downgrades every PR to Copilot-only review.
    # PRAGENT_STRICT_CLEAN_TREE=1 restores the old whole-tree behaviour.
    if [ "${PRAGENT_STRICT_CLEAN_TREE:-0}" = "1" ]; then
        if ! git diff --quiet || ! git diff --cached --quiet; then
            echo "Working tree is not clean. Commit or stash changes before self-review." >&2
            exit 1
        fi
    else
        _dirty_in_scope="$(comm -12 \
            <(git diff --name-only "$TARGET"...HEAD | sort -u) \
            <({ git diff --name-only; git diff --cached --name-only; } | sort -u))"
        if [ -n "$_dirty_in_scope" ]; then
            echo "These files are under review but have uncommitted changes - commit or stash them:" >&2
            printf '  %s\n' $_dirty_in_scope >&2
            exit 1
        fi
        _dirty_total="$({ git diff --name-only; git diff --cached --name-only; } | sort -u | grep -c . || true)"
        if [ "${_dirty_total:-0}" -gt 0 ]; then
            echo "note: $_dirty_total uncommitted file(s) outside the reviewed set - ignored." >&2
        fi
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo "The 'claude' CLI is not on PATH. Install/authenticate it before self-review." >&2
        exit 1
    fi
    export CONFIG__GIT_PROVIDER=local
    # LocalGitProvider reads pr_url as a target BRANCH NAME and looks it up in `repo.heads`
    # (local_git_provider.py:57), so a remote-tracking ref like `origin/master` raises
    # "Branch does not exist". Materialise a throwaway local ref pointing at the resolved
    # commit and hand THAT over - the review then runs against the correct base without the
    # provider ever seeing a remote ref. Removed on exit; never checked out, so it cannot
    # disturb the working tree or another worktree.
    PR_URL="$TARGET"
    case "$TARGET" in
      */*)
        TMP_BASE_REF="review-base-$(git rev-parse --short "${TARGET}^{commit}")"
        git branch -f "$TMP_BASE_REF" "${TARGET}^{commit}" >/dev/null 2>&1 || {
            echo "Could not create temp base ref for '$TARGET'." >&2; exit 1; }
        # shellcheck disable=SC2064  # expand TMP_BASE_REF now: it is stable for this run.
        trap "git branch -D '$TMP_BASE_REF' >/dev/null 2>&1 || true" EXIT INT HUP TERM
        PR_URL="$TMP_BASE_REF"
        TARGET="$TMP_BASE_REF"   # keep downstream diffs (clean-tree check, workspace-index) aligned
        ;;
    esac
else
    export GITHUB__USER_TOKEN="$(gh auth token)"
    export CONFIG__GIT_PROVIDER=github
fi
export CONFIG__MODEL="$MODEL"
export CONFIG__FALLBACK_MODELS="[\"$MODEL\"]"

# Disable upstream's native repo_context_files injection: this wrapper does its own
# richer, domain-aware conventions injection below (stacks/cache/patterns tiers keyed
# to the changed files). Leaving native on would double-inject AGENTS.md in github mode
# and log a "LocalGitProvider does not support repository file fetching" warning every
# local run. Override with PRAGENT_NATIVE_REPO_CONTEXT=1 to re-enable the native path.
[ "${PRAGENT_NATIVE_REPO_CONTEXT:-0}" = "1" ] || export CONFIG__REPO_CONTEXT_FILES="[]"

# Review prompt is externalized to scripts/lib/review-style.md (compressed for token budget).
# Override with PRAGENT_REVIEW_STYLE_FILE=/path/to/alt.md
REVIEW_STYLE_FILE="${PRAGENT_REVIEW_STYLE_FILE:-$ROOT/scripts/lib/review-style.md}"
if [ ! -f "$REVIEW_STYLE_FILE" ]; then
    echo "Missing review-style file: $REVIEW_STYLE_FILE" >&2
    exit 1
fi
REVIEW_STYLE="$(cat "$REVIEW_STYLE_FILE")"

# Self-reflection score threshold (PR-Agent scores every `improve` suggestion 0-10).
# 7 = "≥70% confidence", upstream's recommended high-band ceiling. Empirical: 8 was too
# strict - observed score-7 findings on PR #502 (UberDriverIdBackfillJob/Test) that were
# genuine defects with file:line evidence. Self-reflection scoring is also stochastic
# (varies ±1 between runs), so 7 catches real defects that a 1-point dip would otherwise
# silently drop.
# Override with PRAGENT_SCORE_THRESHOLD=N (8 for strict, 0 to disable).
export PR_CODE_SUGGESTIONS__SUGGESTIONS_SCORE_THRESHOLD="${PRAGENT_SCORE_THRESHOLD:-6}"

# Suppress the "No code suggestions found for the PR." placeholder comment.
# When the score filter drops everything, posting a placeholder is noise - the
# absence of comments already signals "no findings". Override with
# PRAGENT_PUBLISH_NO_SUGGESTIONS=true to restore upstream behavior.
export PR_CODE_SUGGESTIONS__PUBLISH_OUTPUT_NO_SUGGESTIONS="${PRAGENT_PUBLISH_NO_SUGGESTIONS:-false}"

# Suppress the "Generating PR code suggestions / Work in progress ..." progress
# placeholder. PR-Agent normally posts it before the model call and edits/
# removes it afterwards - but when every suggestion gets filtered out, the
# placeholder is either left as a confusing orphan or replaced by the "No
# suggestions" notice (also suppressed). Skipping it entirely avoids both.
# Override with PRAGENT_PUBLISH_PROGRESS=true.
export CONFIG__PUBLISH_OUTPUT_PROGRESS="${PRAGENT_PUBLISH_PROGRESS:-false}"

REPO_PATH=""
OWNER=""
REPO=""
if [[ "$PR_URL" == https://github.com/*/pull/* ]]; then
    REPO_PATH="${PR_URL#https://github.com/}"
    REPO_PATH="${REPO_PATH%%/pull/*}"
    OWNER="${REPO_PATH%%/*}"
    if [ "$OWNER" != "$REPO_PATH" ]; then
        REPO="${REPO_PATH#*/}"
    else
        OWNER=""
    fi
fi

PERSONAL_CONVENTIONS_LOADED=no
REPO_AGENTS_LOADED=no
CLAUDE_MD_LOADED=no
PATTERNS_LOADED=0
STACKS_DISPLAY=none
CONV=""

if [ -f "$HOME/.config/pr-agent/conventions.md" ]; then
    CONV+=$'## Personal conventions\n'
    CONV+="$(cat "$HOME/.config/pr-agent/conventions.md")"
    CONV+=$'\n'
    PERSONAL_CONVENTIONS_LOADED=yes
fi

if [ "$LOCAL_MODE" = "1" ]; then
    # Local mode: read on-disk rules (no GitHub API). First hit wins: AGENTS.md,
    # then CLAUDE.md, then .claude/CLAUDE.md (see find_repo_convention_file).
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ] && [ -n "$TOPLEVEL" ]; then
        if _repo_conv_rel="$(find_repo_convention_file "$TOPLEVEL")"; then
            CONV+="## repo $_repo_conv_rel"$'\n'
            CONV+="$(head -c 6000 "$TOPLEVEL/$_repo_conv_rel")"
            CONV+=$'\n'
            REPO_AGENTS_LOADED=file
        fi
    fi

    # .rules/-derived review checklist. The .rules/ dir often sits at a workspace level ABOVE the
    # git toplevel, so walk up from cwd (first hit wins). Single source of truth = .rules/; this file
    # is the review-facing index into it. Toggle off with PRAGENT_REVIEW_CHECKLIST=0.
    if [ "${PRAGENT_REVIEW_CHECKLIST:-1}" != "0" ] && [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ]; then
        _rc_dir="$PWD"
        while [ -n "$_rc_dir" ] && [ "$_rc_dir" != "/" ]; do
            if [ -f "$_rc_dir/.rules/REVIEW_CHECKLIST.md" ]; then
                CONV+="## review checklist (.rules/)"$'\n'
                CONV+="$(head -c 6000 "$_rc_dir/.rules/REVIEW_CHECKLIST.md")"
                CONV+=$'\n'
                REPO_AGENTS_LOADED="${REPO_AGENTS_LOADED}+rules"
                break
            fi
            _rc_dir="$(dirname "$_rc_dir")"
        done
    fi

    # Stacks + patterns tiers, same as the GitHub branch below but sourced from the LOCAL diff.
    #
    # These used to exist only in the PR branch, which meant /review-local - the pre-PR gate that
    # runs on every change - never loaded a single pattern file. The whole
    # ~/.claude-library/rules/patterns tree was dead code on the path it was written for, and the
    # symptom was a quiet "stacks=none patterns=0" on the summary line rather than any error.
    #
    # ORDER IS LOAD-BEARING. CONV is truncated head-keep to CONV_CAP, so whatever is appended last
    # is what gets cut. Patterns are trigger-matched against THIS diff; stack rules are generic and
    # apply to every file of a language. So patterns go first. Appending the stack tier first put
    # 31k of generic rules ahead of the cap and silently discarded every pattern - the summary line
    # still said "patterns=4", because it counts what was SELECTED, not what survived.
    STACKS_ROOT="${PRAGENT_STACKS_ROOT:-$HOME/.claude-library/rules/stacks}"
    if [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ]; then
        STACKS="$(git diff --name-only "${TARGET}...HEAD" 2>/dev/null \
                  | "$ROOT/scripts/stacks-resolve.sh" 2>/dev/null || echo "core")"
        STACKS_DISPLAY="$(printf '%s\n' "$STACKS" | tr ' ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')"
        [ -n "$STACKS_DISPLAY" ] || STACKS_DISPLAY="none"

        # Triggers match against changed-line CONTENT, not just paths, so feed the real diff.
        PATTERN_INPUT="$(git diff "${TARGET}...HEAD" 2>/dev/null || true)"
        if [ -n "$PATTERN_INPUT" ] && [ -n "$STACKS" ]; then
            while IFS= read -r pfile; do
                [ -z "$pfile" ] && continue
                [ ! -f "$pfile" ] && continue
                CHUNK="$(cat "$pfile" 2>/dev/null || true)"
                if [ -n "$CHUNK" ]; then
                    pname="$(basename "$pfile" .md)"
                    CONV+="## pattern: $pname"$'\n'"${CHUNK:0:${PRAGENT_PATTERN_CHARS:-3000}}"$'\n'
                    PATTERNS_LOADED=$((PATTERNS_LOADED + 1))
                fi
            done < <(printf '%s\n' "$PATTERN_INPUT" | "$ROOT/scripts/patterns-resolve.sh" $STACKS 2>/dev/null)
        fi

        # Stack rules fill whatever budget the patterns left, oldest-first per stack, and stop at
        # the cap rather than overrunning it and relying on the final truncation.
        STACK_BUDGET=$(( ${PRAGENT_CONV_CAP:-14000} - ${#CONV} ))
        for stack in $STACKS; do
            [ "$STACK_BUDGET" -gt 500 ] || break
            [ -d "$STACKS_ROOT/$stack" ] || continue
            for sfile in "$STACKS_ROOT/$stack"/*.md; do
                [ -f "$sfile" ] || continue
                [ "$STACK_BUDGET" -gt 500 ] || break
                take=$(( STACK_BUDGET < 2500 ? STACK_BUDGET : 2500 ))
                SCHUNK="$(head -c "$take" "$sfile")"
                CONV+="## stack $stack: $(basename "$sfile" .md)"$'\n'"$SCHUNK"$'\n'
                STACK_BUDGET=$(( STACK_BUDGET - ${#SCHUNK} ))
            done
        done
    fi
elif [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ] && [ -n "$OWNER" ] && [ -n "$REPO" ]; then
    STACKS_ROOT="${PRAGENT_STACKS_ROOT:-$HOME/.claude-library/rules/stacks}"
    REPO_CACHE_ROOT="${PRAGENT_REPO_CACHE_ROOT:-$HOME/.claude/cache/stacks-from}"
    REPO_CACHE="$REPO_CACHE_ROOT/${OWNER}__${REPO}"

    # Resolve which stacks apply by piping the PR's changed files into stacks-resolve.sh.
    STACKS="$(gh pr view "$PR_URL" --json files --jq '.files[].path' 2>/dev/null \
              | "$ROOT/scripts/stacks-resolve.sh" 2>/dev/null \
              || echo "core")"
    STACKS_DISPLAY="$(printf '%s\n' "$STACKS" | tr ' ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')"
    [ -n "$STACKS_DISPLAY" ] || STACKS_DISPLAY="none"

    # Auto-index this repo into the per-repo cache (best-effort, never fail the review).
    "$ROOT/scripts/auto-index-repo.sh" "$OWNER" "$REPO" >/dev/null 2>&1 || true

    for stack in $STACKS; do
        APPENDED_THIS_STACK=no
        # Tier 1: curated stack rules.
        if [ -d "$STACKS_ROOT/$stack" ]; then
            CHUNK="$(cat "$STACKS_ROOT/$stack"/*.md 2>/dev/null || true)"
            if [ -n "$CHUNK" ]; then
                CONV+="## $stack rules (curated)"$'\n'"${CHUNK:0:3000}"$'\n'
                REPO_AGENTS_LOADED=stacks
                APPENDED_THIS_STACK=yes
            fi
        fi
        # Tier 2: per-repo cache from auto-index, only when curated did not have it.
        if [ "$APPENDED_THIS_STACK" = "no" ] && [ -d "$REPO_CACHE/$stack" ]; then
            CHUNK="$(cat "$REPO_CACHE/$stack"/*.md 2>/dev/null || true)"
            if [ -n "$CHUNK" ]; then
                CONV+="## $stack rules (${OWNER}/${REPO} cache)"$'\n'"${CHUNK:0:3000}"$'\n'
                REPO_AGENTS_LOADED=cache
            fi
        fi
    done

    # Tier 3: nothing landed at all - fall back to root AGENTS.md fetch.
    if [ "$REPO_AGENTS_LOADED" = "no" ] && REPO_AGENTS_CONTENT="$("$ROOT/scripts/agent-rules.sh" "$OWNER" "$REPO" 2>/dev/null)" && [ -n "$REPO_AGENTS_CONTENT" ]; then
        CONV+="## $REPO AGENTS.md"$'\n'
        CONV+="${REPO_AGENTS_CONTENT:0:6000}"
        CONV+=$'\n'
        REPO_AGENTS_LOADED=api
    fi

    # Patterns layer (trigger-matched, opt-in per file). Stdin is the PR diff so triggers can match
    # against actual changed-line content, not just file paths.
    PATTERNS_LOADED=0
    PATTERN_INPUT="$(gh pr diff "$PR_URL" 2>/dev/null || true)"
    if [ -n "$PATTERN_INPUT" ] && [ -n "$STACKS" ]; then
        while IFS= read -r pfile; do
            [ -z "$pfile" ] && continue
            [ ! -f "$pfile" ] && continue
            CHUNK="$(cat "$pfile" 2>/dev/null || true)"
            if [ -n "$CHUNK" ]; then
                pname="$(basename "$pfile" .md)"
                CONV+="## pattern: $pname"$'\n'"${CHUNK:0:${PRAGENT_PATTERN_CHARS:-3000}}"$'\n'
                PATTERNS_LOADED=$((PATTERNS_LOADED + 1))
            fi
        done < <(printf '%s\n' "$PATTERN_INPUT" | "$ROOT/scripts/patterns-resolve.sh" $STACKS 2>/dev/null)
    fi
else
    STACKS_DISPLAY="none"
    PATTERNS_LOADED=0
fi

if [ "${PRAGENT_INCLUDE_CLAUDE_MD:-0}" = "1" ] && [ -n "$OWNER" ] && [ -n "$REPO" ]; then
    if REPO_CLAUDE_CONTENT="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/CLAUDE.md" 2>/dev/null)" && [ -n "$REPO_CLAUDE_CONTENT" ]; then
        CONV+="## $REPO CLAUDE.md"$'\n'
        CONV+="${REPO_CLAUDE_CONTENT:0:6000}"
        CONV+=$'\n'
        CLAUDE_MD_LOADED=yes
    fi
fi

# Orchestrator-side extension point: callers can append retrieved knowledge (e.g. life-graph)
# via this env var before the slab is truncated.
if [ -n "${PRAGENT_EXTRA_RULES_APPEND:-}" ]; then
    CONV+="## additional retrieved context"$'\n'
    CONV+="$PRAGENT_EXTRA_RULES_APPEND"$'\n'
fi

# Diff-driven workspace code-context (local mode only): pull call-sites of the symbols
# this diff changes so the reviewer sees blast radius beyond the diff. Appended AFTER the
# rules so the 9000-char cap prioritizes conventions; code-context fills the remainder.
# Best-effort: never fail the review. Disable with PRAGENT_WORKSPACE_INDEX=0.
WORKSPACE_CTX=none
if [ "$LOCAL_MODE" = "1" ] && [ "${PRAGENT_WORKSPACE_INDEX:-1}" != "0" ]; then
    WI_ERR="$(mktemp)"
    if WI_OUT="$("$ROOT/scripts/workspace-index.sh" "$TARGET" 2>"$WI_ERR")" && [ -n "$WI_OUT" ]; then
        CONV+="## workspace code context"$'\n'"$WI_OUT"$'\n'
        WORKSPACE_CTX="$(sed -n 's/^workspace-index: //p' "$WI_ERR" | head -1)"
        [ -n "$WORKSPACE_CTX" ] || WORKSPACE_CTX=injected
    else
        WORKSPACE_CTX="$(sed -n 's/^workspace-index: //p' "$WI_ERR" | head -1)"
        [ -n "$WORKSPACE_CTX" ] || WORKSPACE_CTX=none
    fi
    rm -f "$WI_ERR"
fi

# Truncation is head-keep, so anything appended late is silently dropped. That is how the entire
# patterns tier used to vanish while the summary line still reported it as loaded. Report the
# before/after size so a budget overrun is visible instead of being inferred from bad reviews.
CONV_CAP="${PRAGENT_CONV_CAP:-14000}"
[ -n "${PRAGENT_DUMP_CONV:-}" ] && printf '%s' "$CONV" > "${PRAGENT_DUMP_CONV}"
CONV_CHARS_PRE=${#CONV}
CONV="${CONV:0:$CONV_CAP}"
CONV_TRUNC=$(( CONV_CHARS_PRE - ${#CONV} ))

EXTRA_INSTRUCTIONS="$REVIEW_STYLE"
if [ -n "$CONV" ]; then
    EXTRA_INSTRUCTIONS+=$'\nEnforce these project conventions where the diff touches them; cite the specific rule when you flag a violation:\n'
    EXTRA_INSTRUCTIONS+="$CONV"
fi

export PR_REVIEWER__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
export PR_CODE_SUGGESTIONS__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
echo "conventions: personal=$PERSONAL_CONVENTIONS_LOADED stacks=$STACKS_DISPLAY patterns=$PATTERNS_LOADED conv-chars=$CONV_CHARS_PRE/$CONV_CAP dropped=$CONV_TRUNC repo-AGENTS=$REPO_AGENTS_LOADED claude-md=$CLAUDE_MD_LOADED workspace-ctx=$WORKSPACE_CTX score-threshold=$PR_CODE_SUGGESTIONS__SUGGESTIONS_SCORE_THRESHOLD" >&2

# Real diff file list/size, used for review-coverage accounting, the improve
# empty-suggestions note below, and (local mode) per-module splitting. Local
# mode only - TARGET is unset otherwise.
FILES_LIST=""
TOTAL_DIFF_FILES=0
if [ "$LOCAL_MODE" = "1" ]; then
    FILES_LIST="$(git diff --name-only "${TARGET}...HEAD" 2>/dev/null || true)"
    TOTAL_DIFF_FILES="$(printf '%s\n' "$FILES_LIST" | grep -c . || true)"
fi

# Committable suggestions only make sense when posting to a real PR (github mode).
# Local self-review wants the structured code_suggestions JSON instead.
if [ "$CMD" = "improve" ] && [ "$LOCAL_MODE" = "0" ]; then
    export PR_CODE_SUGGESTIONS__COMMITABLE_CODE_SUGGESTIONS=true
fi

# run_pragent_pass <pr_url> <cmd> <total_diff_files> <out_file>
# Runs one review/improve pass through the CLI-backed AI handler with
# CONFIG__GIT_PROVIDER/CONFIG__MODEL already exported; writes stdout to
# out_file and returns the python process's exit code. Shared by the
# single-pass and per-module-split paths below.
run_pragent_pass() {
    local pr_url="$1" cmd="$2" total_diff_files="$3" out_file="$4"
    local rc
    set +e
    "$PY" - "$pr_url" "$cmd" "$total_diff_files" <<'PY' > "$out_file"
import asyncio
import json
import os
import sys

from pr_agent.agent.pr_agent import get_ai_handler
from pr_agent.config_loader import get_settings
from pr_agent.tools.pr_code_suggestions import PRCodeSuggestions
from pr_agent.tools.pr_reviewer import PRReviewer


async def main() -> None:
    pr_url = sys.argv[1]
    cmd = sys.argv[2]
    total_diff_files = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 0

    settings = get_settings()
    settings.set("CONFIG.PUBLISH_OUTPUT", False)
    settings.set("CONFIG.GIT_PROVIDER", os.environ.get("CONFIG__GIT_PROVIDER", "github"))
    settings.set("CONFIG.MODEL", os.environ["CONFIG__MODEL"])

    if cmd == "review":
        tool = PRReviewer(pr_url, ai_handler=get_ai_handler())
        await tool.run()
        print(settings.get("data", {}).get("artifact"))
    elif cmd == "improve":
        tool = PRCodeSuggestions(pr_url, ai_handler=get_ai_handler())
        await tool.run()
        # With publish_output=False the tool clobbers settings.data to {"artifact": <md>};
        # the structured suggestions (with score/label per item) live on tool.data.
        raw_data = getattr(tool, "data", None)
        if not raw_data:
            print("WARNING: improve produced no data (model output lost or empty diff)",
                  file=sys.stderr)
        data = raw_data or {"code_suggestions": []}
        suggestions = data.get("code_suggestions") or []
        if not suggestions and total_diff_files > 20:
            print(f"note: 0 suggestions on a {total_diff_files}-file diff - "
                  "treat as unverified, not clean", file=sys.stderr)
        print(json.dumps(data, indent=2, default=str))
    else:
        raise SystemExit(f"Unsupported command: {cmd}")


asyncio.run(main())
PY
    rc=$?
    set -e
    return $rc
}

# run_split_review_or_improve
# Groups FILES_LIST via group_files_by_module, runs one run_pragent_pass per
# group sequentially (IGNORE__REGEX scoped to that group's exact files), then
# merges: review -> concatenated markdown under "## module: <g> (<n> files)"
# headings plus one combined "coverage:" line; improve -> one merged JSON
# object (code_suggestions arrays concatenated + deduped by
# relevant_file+one_sentence_summary). A failing group is named and the
# function returns non-zero; other groups still run.
run_split_review_or_improve() {
    local groups_tsv groups g files_g n_g pattern out_g rc_g
    local -a failed_groups=()
    groups_tsv="$(printf '%s\n' "$FILES_LIST" | grep -c . >/dev/null 2>&1; \
        printf '%s\n' "$FILES_LIST" | group_files_by_module 3 3 "${PRAGENT_SPLIT_MAX_GROUPS:-6}")"
    groups="$(printf '%s\n' "$groups_tsv" | cut -f1 | sort -u)"

    if [ "$CMD" = "review" ]; then
        local combined_md="" sum_reviewed=0 sum_total=0 not_reviewed_g reviewed_g pct
        while IFS= read -r g; do
            [ -z "$g" ] && continue
            files_g="$(printf '%s\n' "$groups_tsv" | awk -F'\t' -v g="$g" '$1==g{print $2}')"
            n_g="$(printf '%s\n' "$files_g" | grep -c .)"
            pattern="$(printf '%s\n' "$files_g" | build_group_ignore_regex)"
            export IGNORE__REGEX="['$pattern']"
            out_g="$(mktemp)"
            run_pragent_pass "$PR_URL" "$CMD" "$n_g" "$out_g"
            rc_g=$?
            [ "$rc_g" -ne 0 ] && failed_groups+=("$g")
            not_reviewed_g="$(count_unreviewed_files "$(cat "$out_g")")"
            reviewed_g=$(( n_g - not_reviewed_g ))
            [ "$reviewed_g" -lt 0 ] && reviewed_g=0
            sum_reviewed=$(( sum_reviewed + reviewed_g ))
            sum_total=$(( sum_total + n_g ))
            echo "module $g: reviewed=${reviewed_g}/${n_g}" >&2
            combined_md+="## module: $g ($n_g files)"$'\n\n'"$(cat "$out_g")"$'\n\n'
            rm -f "$out_g"
        done <<< "$groups"
        unset IGNORE__REGEX
        printf '%s' "$combined_md"
        pct=0
        [ "$sum_total" -gt 0 ] && pct=$(( sum_reviewed * 100 / sum_total ))
        echo "coverage: reviewed=${sum_reviewed}/${sum_total} (${pct}%)" >&2
        if [ "$sum_total" -gt 0 ] && [ "$pct" -lt "${PRAGENT_MIN_COVERAGE:-70}" ]; then
            echo "WARNING: low review coverage - split the diff or review per module" >&2
        fi
    else
        local -a group_out_files=()
        while IFS= read -r g; do
            [ -z "$g" ] && continue
            files_g="$(printf '%s\n' "$groups_tsv" | awk -F'\t' -v g="$g" '$1==g{print $2}')"
            n_g="$(printf '%s\n' "$files_g" | grep -c .)"
            pattern="$(printf '%s\n' "$files_g" | build_group_ignore_regex)"
            export IGNORE__REGEX="['$pattern']"
            out_g="$(mktemp)"
            run_pragent_pass "$PR_URL" "$CMD" "$n_g" "$out_g"
            rc_g=$?
            if [ "$rc_g" -ne 0 ] || ! "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$out_g" >/dev/null 2>&1; then
                failed_groups+=("$g")
                echo "module $g: FAILED (rc=$rc_g)" >&2
            else
                group_out_files+=("$out_g")
                echo "module $g: ok" >&2
            fi
        done <<< "$groups"
        unset IGNORE__REGEX
        if [ "${#group_out_files[@]}" -gt 0 ]; then
            jq -s '.[0] + {code_suggestions: ((map(.code_suggestions // []) | add // []) | unique_by([.relevant_file, .one_sentence_summary]))}' \
                "${group_out_files[@]}"
        else
            echo '{"code_suggestions": []}'
        fi
        for out_g in "${group_out_files[@]:-}"; do
            [ -n "$out_g" ] && rm -f "$out_g"
        done
    fi

    if [ "${#failed_groups[@]}" -gt 0 ]; then
        echo "ERROR: module(s) failed: ${failed_groups[*]}" >&2
        return 1
    fi
    return 0
}

# Per-module split trigger: explicit --per-module, or file count over
# PRAGENT_SPLIT_THRESHOLD (default 25; 0 disables auto-splitting). Local
# mode only - github mode must behave exactly as before.
SPLIT_MODE=0
PRAGENT_SPLIT_THRESHOLD="${PRAGENT_SPLIT_THRESHOLD:-25}"
if [ "$LOCAL_MODE" = "1" ]; then
    if [ "$PER_MODULE_FLAG" = "1" ]; then
        SPLIT_MODE=1
    elif [ "$PRAGENT_SPLIT_THRESHOLD" != "0" ] && [ "$TOTAL_DIFF_FILES" -gt "$PRAGENT_SPLIT_THRESHOLD" ]; then
        SPLIT_MODE=1
    fi
fi

# Local mode and --preview both produce structured stdout and never post.
if [ "$LOCAL_MODE" = "1" ] && [ "$SPLIT_MODE" = "1" ]; then
    export CONFIG__PUBLISH_OUTPUT=false
    run_split_review_or_improve
    exit $?
elif [ "$LOCAL_MODE" = "1" ] || [ "$PREVIEW_FLAG" = "--preview" ]; then
    export CONFIG__PUBLISH_OUTPUT=false
    OUT_FILE="$(mktemp)"
    run_pragent_pass "$PR_URL" "$CMD" "$TOTAL_DIFF_FILES" "$OUT_FILE"
    rc=$?
    cat "$OUT_FILE"
    if [ "$LOCAL_MODE" = "1" ] && [ "$CMD" = "review" ]; then
        compute_review_coverage "$(cat "$OUT_FILE")" "$TOTAL_DIFF_FILES"
    fi
    rm -f "$OUT_FILE"
    exit $rc
else
    export CONFIG__PUBLISH_OUTPUT=true
    if [ "$CMD" = "improve" ] && [ "$LOCAL_MODE" = "0" ]; then
        # Capture stderr so we can recover suggestions PR-Agent dropped when their target
        # line falls outside the diff hunks (move/refactor PRs) and post them as one comment.
        ERRLOG="$(mktemp)"
        set +e
        # loguru sink is stdout. Capture the raw run for recovery, but hide the alarming
        # "couldn't attach inline" ERROR/INFO lines from the console - those suggestions
        # target lines outside the diff (e.g. pure renames, which have no hunks at all) and
        # are re-posted as a single PR comment below, so they are not actually lost.
        "$PY" -m pr_agent.cli --pr_url "$PR_URL" "$CMD" 2>&1 \
            | tee "$ERRLOG" \
            | grep -av -e "Failed to publish invalid comment as a single line comment" \
                       -e "Initially failed to publish inline comments as committable"
        rc=${PIPESTATUS[0]}
        set -e
        "$PY" "$ROOT/scripts/post-dropped-suggestions.py" "$PR_URL" "$ERRLOG" || true
        "$ROOT/scripts/suppress.sh" post-improve --pr-url "$PR_URL" || true
        rm -f "$ERRLOG"
        exit $rc
    fi
    exec "$PY" -m pr_agent.cli --pr_url "$PR_URL" "$CMD"
fi
