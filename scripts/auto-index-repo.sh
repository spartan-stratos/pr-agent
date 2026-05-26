#!/usr/bin/env bash
set -euo pipefail

OWNER="${1:-}"
REPO="${2:-}"
if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "usage: $0 <owner> <repo>" >&2
    exit 2
fi

CACHE_ROOT="${PRAGENT_REPO_CACHE_ROOT:-$HOME/.claude/cache/stacks-from}"
DEST="$CACHE_ROOT/${OWNER}__${REPO}"
SHAFILE="$DEST/.index-sha"
FETCHED_AT_FILE="$DEST/.fetched-at"
NOW="$(date +%s)"
TTL_SECONDS=86400

if [ "${PRAGENT_RULES_REFRESH:-0}" != "1" ] && [ -f "$FETCHED_AT_FILE" ]; then
    LAST_FETCHED="$(cat "$FETCHED_AT_FILE" 2>/dev/null || true)"
    if [[ "$LAST_FETCHED" =~ ^[0-9]+$ ]] && [ $((NOW - LAST_FETCHED)) -lt "$TTL_SECONDS" ]; then
        echo "up-to-date ttl"
        exit 0
    fi
fi

set +e
TREE="$(gh api "repos/$OWNER/$REPO/git/trees/HEAD?recursive=1" 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    if printf '%s' "$TREE" | grep -q '"status": *"404"\|"message": *"Not Found"'; then
        echo "auto-index-repo: $OWNER/$REPO not found / no default branch" >&2
        exit 3
    fi
    echo "auto-index-repo: transient fetch error for $OWNER/$REPO" >&2
    exit 1
fi

ENTRIES="$(printf '%s' "$TREE" | jq -r \
    '.tree[] | select(.type=="blob") | select(.path|startswith(".claude/rules/") and endswith(".md")) | "\(.sha) \(.path)"')"
if [ -z "$ENTRIES" ]; then
    echo "auto-index-repo: no .claude/rules/*.md in $OWNER/$REPO" >&2
    exit 3
fi

INDEX_SHA="$(printf '%s' "$ENTRIES" | shasum -a 256 | cut -d' ' -f1)"
if [ "${PRAGENT_RULES_REFRESH:-0}" != "1" ] && [ -f "$SHAFILE" ] && [ "$(cat "$SHAFILE")" = "$INDEX_SHA" ]; then
    mkdir -p "$DEST"
    printf '%s' "$NOW" > "$FETCHED_AT_FILE"
    echo "up-to-date ${INDEX_SHA:0:8} ($(printf '%s\n' "$ENTRIES" | wc -l | tr -d ' ') files)"
    exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"
count=0
while IFS=' ' read -r _sha path; do
    [ -z "$path" ] && continue
    rel="${path#.claude/rules/}"
    set +e
    body="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/$path" 2>/dev/null)"
    frc=$?
    set -e
    if [ "$frc" -ne 0 ] || [ -z "$body" ]; then
        echo "auto-index-repo: failed to fetch $path (aborting, cache left incomplete)" >&2
        exit 1
    fi
    mkdir -p "$DEST/$(dirname "$rel")"
    printf '%s' "$body" > "$DEST/$rel"
    count=$((count + 1))
done <<< "$ENTRIES"

printf '%s' "$INDEX_SHA" > "$SHAFILE"
printf '%s' "$NOW" > "$FETCHED_AT_FILE"
echo "indexed ${INDEX_SHA:0:8} ($count files) -> $DEST"
exit 0
