#!/usr/bin/env bash
# Runs PR-Agent review/improve through the local Claude Code CLI handler (Max subscription, no API key).
set -euo pipefail

MODEL="${MODEL:-claude_cli/sonnet}"

# Local self-review mode: diff HEAD vs a target branch with PR-Agent's LocalGitProvider.
# No PR URL, no GitHub token, never posts — emits structured output to stdout.
LOCAL_MODE=0
PREVIEW_FLAG=""
usage() {
    echo "Usage: $0 <pr-url> [review|improve] [--preview]" >&2
    echo "       $0 --local [target] [review|improve]   (HEAD vs target, no PR, no post)" >&2
    exit 1
}

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

if [ ! -x "$PY" ]; then
    echo "Missing $PY. Create the venv with: python3 -m venv .venv && .venv/bin/pip install -e ." >&2
    exit 1
fi

if [ "$LOCAL_MODE" = "1" ]; then
    # Resolve target: explicit arg, else master, else main.
    if [ -z "$TARGET" ]; then
        if git show-ref --verify --quiet refs/heads/master; then TARGET=master
        elif git show-ref --verify --quiet refs/heads/main; then TARGET=main
        else echo "No target branch given and neither 'master' nor 'main' exists locally." >&2; exit 1; fi
    fi
    if ! git show-ref --verify --quiet "refs/heads/$TARGET"; then
        echo "Branch '$TARGET' does not exist locally. Fetch it first (e.g. git fetch origin $TARGET:$TARGET)." >&2
        exit 1
    fi
    # LocalGitProvider requires a clean working tree.
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Working tree is not clean. Commit or stash changes before self-review." >&2
        exit 1
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo "The 'claude' CLI is not on PATH. Install/authenticate it before self-review." >&2
        exit 1
    fi
    export CONFIG__GIT_PROVIDER=local
    PR_URL="$TARGET"   # LocalGitProvider reads the pr_url argument as the target branch name
else
    export GITHUB__USER_TOKEN="$(gh auth token)"
    export CONFIG__GIT_PROVIDER=github
fi
export CONFIG__MODEL="$MODEL"
export CONFIG__FALLBACK_MODELS="[\"$MODEL\"]"

# Comment-style guidance (life-graph KB 04d5aebb): constructive, prioritized, explicit, concise.
REVIEW_STYLE="Prioritize must-fix and should-fix changes; include at most one or two nice-to-have items. State explicitly what to change and how, with concrete example code. Use plain, unambiguous wording; no vague, implicit, or loaded terms. Be explicit and transparent, but concise; do not flood with words. When a suggestion asserts a specific library/framework API exists or behaves a certain way (e.g. an Exposed DSL overload, a Micronaut annotation, a Kotlin stdlib function, a React hook signature), include a reference URL to the official docs or source of the current version (e.g. JetBrains/Exposed wiki or GitHub source, Micronaut guide, kotlinlang.org). If you cannot find a current authoritative reference, phrase the claim as 'verify' rather than 'use' — do not invent APIs. Every finding about a TYPE, STATE, or TIMING property of the code must include AT LEAST ONE of: (a) a file:line citation from the diff or repo that proves the precondition (e.g. 'type allows null per api/foo.ts:42'); (b) a documentation URL for the library behaviour claimed; (c) the loaded rule path that the diff violates. If none of these is available, phrase the finding as a question ('Is X nullable here?') instead of an assertion, or omit it. Never make a definitive claim that is actually a guess — guesses are noise."

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
    # Local mode: read on-disk rules (no GitHub API). First hit wins: AGENTS.md, then .claude/CLAUDE.md.
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ] && [ -n "$TOPLEVEL" ]; then
        for rel in AGENTS.md .claude/CLAUDE.md; do
            if [ -f "$TOPLEVEL/$rel" ]; then
                CONV+="## repo $rel"$'\n'
                CONV+="$(head -c 6000 "$TOPLEVEL/$rel")"
                CONV+=$'\n'
                REPO_AGENTS_LOADED=file
                break
            fi
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

    # Tier 3: nothing landed at all — fall back to root AGENTS.md fetch.
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
                CONV+="## pattern: $pname"$'\n'"${CHUNK:0:2000}"$'\n'
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

CONV="${CONV:0:9000}"

EXTRA_INSTRUCTIONS="$REVIEW_STYLE"
if [ -n "$CONV" ]; then
    EXTRA_INSTRUCTIONS+=$'\nEnforce these project conventions where the diff touches them; cite the specific rule when you flag a violation:\n'
    EXTRA_INSTRUCTIONS+="$CONV"
fi

export PR_REVIEWER__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
export PR_CODE_SUGGESTIONS__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
echo "conventions: personal=$PERSONAL_CONVENTIONS_LOADED stacks=$STACKS_DISPLAY patterns=$PATTERNS_LOADED repo-AGENTS=$REPO_AGENTS_LOADED claude-md=$CLAUDE_MD_LOADED" >&2

# Committable suggestions only make sense when posting to a real PR (github mode).
# Local self-review wants the structured code_suggestions JSON instead.
if [ "$CMD" = "improve" ] && [ "$LOCAL_MODE" = "0" ]; then
    export PR_CODE_SUGGESTIONS__COMMITABLE_CODE_SUGGESTIONS=true
fi

# Local mode and --preview both produce structured stdout and never post.
if [ "$LOCAL_MODE" = "1" ] || [ "$PREVIEW_FLAG" = "--preview" ]; then
    export CONFIG__PUBLISH_OUTPUT=false
    exec "$PY" - "$PR_URL" "$CMD" <<'PY'
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
        print(json.dumps(getattr(tool, "data", None) or {"code_suggestions": []},
                         indent=2, default=str))
    else:
        raise SystemExit(f"Unsupported command: {cmd}")


asyncio.run(main())
PY
else
    export CONFIG__PUBLISH_OUTPUT=true
    if [ "$CMD" = "improve" ] && [ "$LOCAL_MODE" = "0" ]; then
        # Capture stderr so we can recover suggestions PR-Agent dropped when their target
        # line falls outside the diff hunks (move/refactor PRs) and post them as one comment.
        ERRLOG="$(mktemp)"
        set +e
        # loguru sink is stdout. Capture the raw run for recovery, but hide the alarming
        # "couldn't attach inline" ERROR/INFO lines from the console — those suggestions
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
