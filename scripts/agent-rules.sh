#!/usr/bin/env bash
# Fetch a repo's AGENTS.md with a local TTL cache, so repeated reviews of the same
# repo don't re-hit the GitHub contents API. Caches both hits and 404 misses.
#
# Usage: agent-rules.sh <owner> <repo>
#   stdout : AGENTS.md content (only when present)
#   exit 0 : rules present (printed to stdout)
#   exit 3 : known-absent (no AGENTS.md in the repo)
#   exit 1 : transient fetch error (network/auth/rate-limit) — deliberately NOT cached
#   exit 2 : usage error
#
# Env:
#   PRAGENT_RULES_TTL      cache lifetime in seconds (default 86400 = 24h)
#   PRAGENT_RULES_CACHE    cache dir (default ~/.cache/pr-agent/agent-rules)
#   PRAGENT_RULES_REFRESH  =1 to bypass the cache and re-fetch
set -euo pipefail

OWNER="${1:-}"; REPO="${2:-}"
if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "usage: $0 <owner> <repo>" >&2
    exit 2
fi

TTL="${PRAGENT_RULES_TTL:-86400}"
DIR="${PRAGENT_RULES_CACHE:-$HOME/.cache/pr-agent/agent-rules}"
mkdir -p "$DIR"
KEY="${OWNER}__${REPO}"
HIT="$DIR/$KEY.md"
MISS="$DIR/$KEY.missing"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
fresh() { [ -f "$1" ] && [ "$(( $(date +%s) - $(mtime "$1") ))" -lt "$TTL" ]; }

if [ "${PRAGENT_RULES_REFRESH:-0}" != "1" ]; then
    if fresh "$HIT"; then cat "$HIT"; exit 0; fi
    if fresh "$MISS"; then exit 3; fi
fi

set +e
CONTENT="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/AGENTS.md" 2>/dev/null)"
rc=$?
set -e

if [ "$rc" -eq 0 ] && [ -n "$CONTENT" ]; then
    printf '%s' "$CONTENT" > "$HIT"; rm -f "$MISS"
    cat "$HIT"; exit 0
fi

# Failure: distinguish a genuine 404 (absent → cache the miss) from a transient
# error (don't cache, so the next run retries). gh prints the error body to stdout.
if printf '%s' "$CONTENT" | grep -q '"status": *"404"\|"message": *"Not Found"'; then
    : > "$MISS"; rm -f "$HIT"
    exit 3
fi
echo "agent-rules: transient fetch error for $OWNER/$REPO (not cached)" >&2
exit 1
