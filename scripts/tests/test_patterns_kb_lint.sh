#!/usr/bin/env bash
# test_patterns_kb_lint.sh - authoring lint for the live pattern knowledge base.
#
# Three pattern-authoring mistakes report NOTHING at review time and just make reviews worse:
#   1. no `triggers:` line at all        -> patterns-resolve.sh skips the file entirely
#   2. every trigger token unselectable  -> same outcome, but it looks authored
#   3. a file far over the per-pattern char cut -> the tail is truncated mid-sentence
# Skips cleanly when the KB is not present on this machine.
set -uo pipefail

ROOT="${PRAGENT_PATTERNS_ROOT:-$HOME/.claude-library/rules/patterns}"
if [ ! -d "$ROOT" ]; then
    echo "SKIP: no pattern KB at $ROOT"
    exit 0
fi

CAP="${PRAGENT_PATTERN_CHARS:-3000}"
STOPWORDS="${PRAGENT_PATTERN_STOPWORDS:-class object interface fun val var data sealed enum return if else for while when try catch throw import package public private internal true false null string int long boolean list map set get add new this that with from into and not error test tests result state guard type name value item items code line file files build}"

PASS=0; FAIL=0
for f in "$ROOT"/*/*.md; do
    [ -f "$f" ] || continue
    rel="${f#"$ROOT"/}"

    tline="$(grep -im1 '^triggers:' "$f" || true)"
    if [ -z "$tline" ]; then
        echo "FAIL: $rel has no 'triggers:' line - the file is never selected"; FAIL=$((FAIL+1)); continue
    fi

    usable=0
    for t in ${tline#*:}; do
        t="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
        alnum="$(printf '%s' "$t" | tr -cd '[:alnum:]')"
        [ "${#alnum}" -ge 3 ] || continue
        case " $STOPWORDS " in *" $t "*) continue ;; esac
        usable=$((usable+1))
    done
    if [ "$usable" -eq 0 ]; then
        echo "FAIL: $rel has no selectable trigger (all tokens are stopwords or under 3 alnum chars)"
        FAIL=$((FAIL+1)); continue
    fi

    size="$(wc -c < "$f" | tr -d ' ')"
    if [ "$size" -gt $(( CAP + CAP / 2 )) ]; then
        echo "WARN: $rel is ${size}c; the per-pattern cut is ${CAP}c, so the tail never reaches the model"
    fi

    # A `repos:` line must carry at least one token, or the file is dead for every repo.
    rline="$(grep -im1 '^repos:' "$f" || true)"
    if [ -n "$rline" ] && [ -z "$(printf '%s' "${rline#*:}" | tr -d '[:space:]')" ]; then
        echo "FAIL: $rel has an empty 'repos:' line - selectable by no repo"; FAIL=$((FAIL+1)); continue
    fi

    PASS=$((PASS+1))
done

echo "---"
echo "$PASS patterns ok, $FAIL broken"
[ "$FAIL" -eq 0 ]
