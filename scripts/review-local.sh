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
