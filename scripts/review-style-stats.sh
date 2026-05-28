#!/usr/bin/env bash
# Report char/word/approx-token count for the active review-style prompt.
# Use to compare prompt revisions before committing.
#
# Usage:
#   scripts/review-style-stats.sh                       # active prompt
#   scripts/review-style-stats.sh <file.md>             # arbitrary file
#   PRAGENT_REVIEW_STYLE_FILE=/tmp/alt.md scripts/review-style-stats.sh
#
# Token estimate uses ~4-chars/token rule of thumb.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:-${PRAGENT_REVIEW_STYLE_FILE:-$ROOT/scripts/lib/review-style.md}}"

if [ ! -f "$FILE" ]; then
    echo "Missing: $FILE" >&2
    exit 1
fi

content="$(cat "$FILE")"
chars=$(printf %s "$content" | wc -c | tr -d ' ')
words=$(printf %s "$content" | wc -w | tr -d ' ')
tokens=$(( (chars + 3) / 4 ))

printf "file:    %s\n" "$FILE"
printf "chars:   %d\n" "$chars"
printf "words:   %d\n" "$words"
printf "~tokens: %d (rule-of-thumb, ~4 chars/token)\n" "$tokens"
