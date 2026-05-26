#!/usr/bin/env bash
set -euo pipefail

PATTERNS_ROOT="${PRAGENT_PATTERNS_ROOT:-$HOME/.claude-library/rules/patterns}"

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <stack1> [<stack2> ...]" >&2
    exit 2
fi

[ -d "$PATTERNS_ROOT" ] || exit 0

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

INPUT_LC="$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')"
SELECTED=" "

add_selected() {
    case "$SELECTED" in
        *" $1 "*) ;;
        *) SELECTED="${SELECTED}$1 " ;;
    esac
}

scan_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local file triggers trigger_line trigger
    for file in "$dir"/*.md; do
        [ -f "$file" ] || continue
        trigger_line="$(grep -im1 '^triggers:' "$file" 2>/dev/null || true)"
        [ -n "$trigger_line" ] || continue
        triggers="${trigger_line#*:}"
        for trigger in $triggers; do
            trigger="$(printf '%s' "$trigger" | tr '[:upper:]' '[:lower:]')"
            [ -n "$trigger" ] || continue
            case "$INPUT_LC" in
                *"$trigger"*)
                    add_selected "$file"
                    break
                    ;;
            esac
        done
    done
}

for stack in "$@"; do
    [ -n "$stack" ] || continue
    scan_dir "$PATTERNS_ROOT/$stack"
    scan_dir "$PATTERNS_ROOT/_all"
done

for file in $SELECTED; do
    printf '%s\n' "$file"
done
