#!/usr/bin/env bash
# Fetch a repo's convention rules with a local TTL cache, so repeated reviews of the
# same repo don't re-hit the GitHub contents API. Caches both hits and 404 misses.
#
# Tries a list of candidate paths in order (first hit wins): AGENTS.md, then
# .claude/CLAUDE.md (Spartan layout — e.g. web-fleet keeps rules there, not at root).
#
# Usage: agent-rules.sh <owner> <repo>
#   stdout : rules content (only when present)
#   exit 0 : rules present (printed to stdout)
#   exit 3 : known-absent (none of the candidate paths exist)
#   exit 1 : transient fetch error (network/auth/rate-limit) — deliberately NOT cached
#   exit 2 : usage error
#
# Env:
#   PRAGENT_RULES_TTL      cache lifetime in seconds (default 86400 = 24h)
#   PRAGENT_RULES_CACHE    cache dir (default ~/.cache/pr-agent/agent-rules)
#   PRAGENT_RULES_REFRESH  =1 to bypass the cache and re-fetch
#   PRAGENT_RULES_PATHS    colon-separated candidate paths (default AGENTS.md:.claude/CLAUDE.md)
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
PATHFILE="$DIR/$KEY.path"   # records which candidate path the cached content came from

IFS=':' read -ra CANDIDATES <<< "${PRAGENT_RULES_PATHS:-AGENTS.md:.claude/CLAUDE.md}"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
fresh() { [ -f "$1" ] && [ "$(( $(date +%s) - $(mtime "$1") ))" -lt "$TTL" ]; }

if [ "${PRAGENT_RULES_REFRESH:-0}" != "1" ]; then
    if fresh "$HIT"; then cat "$HIT"; exit 0; fi
    if fresh "$MISS"; then exit 3; fi
fi

# Try each candidate path in order; first non-empty 200 wins. Distinguish a genuine
# 404 (absent) from a transient error (network/auth) — never cache a transient as a miss.
transient=0
for path in "${CANDIDATES[@]}"; do
    set +e
    CONTENT="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/$path" 2>/dev/null)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -n "$CONTENT" ]; then
        printf '%s' "$CONTENT" > "$HIT"; printf '%s' "$path" > "$PATHFILE"; rm -f "$MISS"
        cat "$HIT"; exit 0
    fi
    if ! printf '%s' "$CONTENT" | grep -q '"status": *"404"\|"message": *"Not Found"'; then
        transient=1   # a non-404 failure (e.g. 5xx, auth, rate-limit)
    fi
done

if [ "$transient" -eq 1 ]; then
    echo "agent-rules: transient fetch error for $OWNER/$REPO (not cached)" >&2
    exit 1
fi
: > "$MISS"; rm -f "$HIT" "$PATHFILE"
exit 3
