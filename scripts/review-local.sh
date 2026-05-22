#!/usr/bin/env bash
# Runs PR-Agent review/improve through the local Claude Code CLI handler (Max subscription, no API key).
set -euo pipefail

PR_URL="${1:-}"
CMD="${2:-review}"
PREVIEW_FLAG="${3:-}"
MODEL="${MODEL:-claude_cli/sonnet}"

if [ -z "$PR_URL" ]; then
    echo "Usage: $0 <pr-url> [review|improve] [--preview]" >&2
    exit 1
fi

if [ "$CMD" != "review" ] && [ "$CMD" != "improve" ]; then
    echo "Usage: $0 <pr-url> [review|improve] [--preview]" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
    echo "Missing $PY. Create the venv with: python3 -m venv .venv && .venv/bin/pip install -e ." >&2
    exit 1
fi

export GITHUB__USER_TOKEN="$(gh auth token)"
export CONFIG__GIT_PROVIDER=github
export CONFIG__MODEL="$MODEL"
export CONFIG__FALLBACK_MODELS="[\"$MODEL\"]"

# Comment-style guidance (life-graph KB 04d5aebb): constructive, prioritized, explicit, concise.
REVIEW_STYLE="Prioritize must-fix and should-fix changes; include at most one or two nice-to-have items. State explicitly what to change and how, with concrete example code. Use plain, unambiguous wording; no vague, implicit, or loaded terms. Be explicit and transparent, but concise; do not flood with words."

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
CONV=""

if [ -f "$HOME/.config/pr-agent/conventions.md" ]; then
    CONV+=$'## Personal conventions\n'
    CONV+="$(cat "$HOME/.config/pr-agent/conventions.md")"
    CONV+=$'\n'
    PERSONAL_CONVENTIONS_LOADED=yes
fi

if [ "${PRAGENT_REPO_CONVENTIONS:-1}" != "0" ] && [ -n "$OWNER" ] && [ -n "$REPO" ]; then
    REPO_AGENTS_CONTENT="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/AGENTS.md" 2>/dev/null || true)"
    if [ -n "$REPO_AGENTS_CONTENT" ]; then
        CONV+="## $REPO AGENTS.md"$'\n'
        CONV+="$(printf '%s' "$REPO_AGENTS_CONTENT" | head -c 6000)"
        CONV+=$'\n'
        REPO_AGENTS_LOADED=yes
    fi

    if [ "${PRAGENT_INCLUDE_CLAUDE_MD:-0}" = "1" ]; then
        REPO_CLAUDE_CONTENT="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/CLAUDE.md" 2>/dev/null || true)"
        if [ -n "$REPO_CLAUDE_CONTENT" ]; then
            CONV+="## $REPO CLAUDE.md"$'\n'
            CONV+="$(printf '%s' "$REPO_CLAUDE_CONTENT" | head -c 6000)"
            CONV+=$'\n'
            CLAUDE_MD_LOADED=yes
        fi
    fi
fi

CONV="$(printf '%s' "$CONV" | head -c 9000)"

EXTRA_INSTRUCTIONS="$REVIEW_STYLE"
if [ -n "$CONV" ]; then
    EXTRA_INSTRUCTIONS+=$'\nEnforce these project conventions where the diff touches them; cite the specific rule when you flag a violation:\n'
    EXTRA_INSTRUCTIONS+="$CONV"
fi

export PR_REVIEWER__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
export PR_CODE_SUGGESTIONS__EXTRA_INSTRUCTIONS="$EXTRA_INSTRUCTIONS"
echo "conventions: personal=$PERSONAL_CONVENTIONS_LOADED repo-AGENTS=$REPO_AGENTS_LOADED claude-md=$CLAUDE_MD_LOADED" >&2

if [ "$CMD" = "improve" ]; then
    export PR_CODE_SUGGESTIONS__COMMITABLE_CODE_SUGGESTIONS=true
fi

if [ "$PREVIEW_FLAG" = "--preview" ]; then
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
    settings.set("CONFIG.GIT_PROVIDER", "github")
    settings.set("CONFIG.MODEL", os.environ["CONFIG__MODEL"])

    if cmd == "review":
        tool = PRReviewer(pr_url, ai_handler=get_ai_handler())
        await tool.run()
        print(settings.get("data", {}).get("artifact"))
    elif cmd == "improve":
        tool = PRCodeSuggestions(pr_url, ai_handler=get_ai_handler())
        await tool.run()
        print(json.dumps(settings.get("data", {}), indent=2, default=str))
    else:
        raise SystemExit(f"Unsupported command: {cmd}")


asyncio.run(main())
PY
else
    export CONFIG__PUBLISH_OUTPUT=true
    exec "$PY" -m pr_agent.cli --pr_url "$PR_URL" "$CMD"
fi
