#!/usr/bin/env bash
# Mirror a repo's .claude/rules/**/*.md into a local centralized rules space, so
# PR-Agent reviews can inject the repo's REAL domain conventions (not the generic
# Spartan .claude/CLAUDE.md catalog). Re-index is skipped when the rule blobs are unchanged.
#
# Usage: index-repo-rules.sh <owner> <repo>
#   exit 0 : indexed (or already up to date)
#   exit 3 : repo has no .claude/rules/*.md
#   exit 1 : transient fetch error
#   exit 2 : usage error
#
# Env:
#   PRAGENT_RULES_MIRROR   mirror root (default ~/.claude-library/rules/repos)
#   PRAGENT_RULES_REFRESH  =1 to re-index even when unchanged
set -euo pipefail

OWNER="${1:-}"; REPO="${2:-}"
if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "usage: $0 <owner> <repo>" >&2
    exit 2
fi

MIRROR_ROOT="${PRAGENT_RULES_MIRROR:-$HOME/.claude-library/rules/repos}"
DEST="$MIRROR_ROOT/${OWNER}__${REPO}"
SHAFILE="$DEST/.index-sha"

set +e
TREE="$(gh api "repos/$OWNER/$REPO/git/trees/HEAD?recursive=1" 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    if printf '%s' "$TREE" | grep -q '"status": *"404"\|"message": *"Not Found"'; then
        echo "index-repo-rules: $OWNER/$REPO not found / no default branch" >&2
        exit 3
    fi
    echo "index-repo-rules: transient fetch error for $OWNER/$REPO" >&2
    exit 1
fi

# (sha, path) for every .claude/rules/**/*.md blob.
ENTRIES="$(printf '%s' "$TREE" | jq -r \
    '.tree[] | select(.type=="blob") | select(.path|startswith(".claude/rules/") and endswith(".md")) | "\(.sha) \(.path)"')"
if [ -z "$ENTRIES" ]; then
    echo "index-repo-rules: no .claude/rules/*.md in $OWNER/$REPO" >&2
    exit 3
fi

# Digest of blob SHAs — stable unless the rule files themselves change.
INDEX_SHA="$(printf '%s' "$ENTRIES" | shasum -a 256 | cut -d' ' -f1)"
if [ "${PRAGENT_RULES_REFRESH:-0}" != "1" ] && [ -f "$SHAFILE" ] && [ "$(cat "$SHAFILE")" = "$INDEX_SHA" ]; then
    echo "up-to-date ${INDEX_SHA:0:8} ($(printf '%s\n' "$ENTRIES" | wc -l | tr -d ' ') files)"
    exit 0
fi

# Fresh mirror: drop the old tree so deleted rules don't linger.
rm -rf "$DEST"; mkdir -p "$DEST"
count=0
while IFS=' ' read -r _sha path; do
    [ -z "$path" ] && continue
    rel="${path#.claude/rules/}"
    set +e
    body="$(gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER/$REPO/contents/$path" 2>/dev/null)"
    frc=$?
    set -e
    if [ "$frc" -ne 0 ] || [ -z "$body" ]; then
        echo "index-repo-rules: failed to fetch $path (aborting, mirror left incomplete)" >&2
        exit 1
    fi
    mkdir -p "$DEST/$(dirname "$rel")"
    printf '%s' "$body" > "$DEST/$rel"
    count=$((count + 1))
done <<< "$ENTRIES"

printf '%s' "$INDEX_SHA" > "$SHAFILE"
echo "indexed ${INDEX_SHA:0:8} ($count files) -> $DEST"
exit 0
