#!/usr/bin/env bash
# Local PR-Agent polling watcher. Polls your GitHub notifications and, when your
# authenticated account is @-mentioned with a command in a PR comment
# (e.g. "@spartan-ducduong /improve"), runs it through the local Claude Code CLI
# handler (Max subscription, no API key). Ctrl-C to stop.
set -euo pipefail

MODEL="${MODEL:-claude_cli/sonnet}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
    echo "Missing $PY. Create the venv with: python3 -m venv .venv && .venv/bin/pip install -e ." >&2
    exit 1
fi

export GITHUB__USER_TOKEN="$(gh auth token)"
export GITHUB__DEPLOYMENT_TYPE=user
export CONFIG__GIT_PROVIDER=github
export CONFIG__MODEL="$MODEL"
export CONFIG__FALLBACK_MODELS="[\"$MODEL\"]"

# Same comment-style guidance as review-local.sh (life-graph KB 04d5aebb).
REVIEW_STYLE="Prioritize must-fix and should-fix changes; include at most one or two nice-to-have items. State explicitly what to change and how, with concrete example code. Use plain, unambiguous wording; no vague, implicit, or loaded terms. Be explicit and transparent, but concise; do not flood with words."
export PR_REVIEWER__EXTRA_INSTRUCTIONS="$REVIEW_STYLE"
export PR_CODE_SUGGESTIONS__EXTRA_INSTRUCTIONS="$REVIEW_STYLE"
export PR_CODE_SUGGESTIONS__COMMITABLE_CODE_SUGGESTIONS=true

echo "PR-Agent polling watcher running (Ctrl-C to stop)."
echo "Trigger: comment '@<your-username> /improve' (or /review, /describe) on any PR you can access."
exec "$PY" -m pr_agent.servers.github_polling
