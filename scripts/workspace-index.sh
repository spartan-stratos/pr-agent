#!/usr/bin/env bash
# Diff-driven workspace code-context retrieval for local self-review.
#
# WHY: PR-Agent's built-in `allow_dynamic_context` only extends each hunk to its
# enclosing function/class (intra-file). It never shows how a changed symbol is
# USED elsewhere in the repo - the "blast radius" a repo-aware reviewer needs to
# catch signature/contract breaks (the value CodeRabbit/Greptile-style tools add).
# This is retrieval, NOT a persistent index: given the diff, it greps the on-disk
# working tree for call-sites of the symbols this diff defines/changes, and emits
# a compact markdown slab the review injects as extra context.
#
# Local mode only: needs the working tree on disk. GitHub mode is API-bound and
# out of scope here (the review already fetches curated/cache rules for that path).
#
# Usage: workspace-index.sh <base-ref> [repo-root]
#   stdout : markdown context slab (empty if nothing worth injecting)
#   stderr : one-line summary "workspace-index: S symbols, C call-sites"
#
# Env:
#   PRAGENT_WORKSPACE_INDEX_BUDGET   max chars of output      (default 3500)
#   PRAGENT_WORKSPACE_MAX_SYMBOLS    symbols to trace         (default 10)
#   PRAGENT_WORKSPACE_SITES_PER_SYM  call-sites per symbol    (default 4)
set -euo pipefail

BASE="${1:-}"
ROOT="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -z "$BASE" ] && { echo "usage: $0 <base-ref> [repo-root]" >&2; exit 2; }

BUDGET="${PRAGENT_WORKSPACE_INDEX_BUDGET:-3500}"
MAX_SYMBOLS="${PRAGENT_WORKSPACE_MAX_SYMBOLS:-10}"
SITES_PER_SYM="${PRAGENT_WORKSPACE_SITES_PER_SYM:-4}"

cd "$ROOT" 2>/dev/null || { echo "workspace-index: bad root $ROOT" >&2; exit 2; }

# Source extensions we can meaningfully trace by identifier.
SRC_RE='\.(kt|kts|java|ts|tsx|js|jsx|mjs|cjs|vue|svelte|go|py|rb|rs|scala|swift|c|h|cpp|hpp|cs|php|sh|bash|zsh)$'

# Changed source files vs BASE (three-dot: changes on our side only).
# Portable read loop (works under bash 3.2 - no mapfile).
CHANGED=()
while IFS= read -r f; do
    [ -n "$f" ] && CHANGED+=("$f")
done < <(git diff --name-only "$BASE"...HEAD 2>/dev/null | grep -iE "$SRC_RE" || true)
[ "${#CHANGED[@]}" -eq 0 ] && { echo "workspace-index: no traceable source files changed" >&2; exit 0; }

# Declaration patterns across the languages this monorepo touches. Each captures
# the declared identifier as \1. Applied to ADDED lines only (the defs this diff
# introduces or rewrites) so we trace their blast radius.
declare_names() {
    local added
    added="$(grep -E '^\+' | grep -vE '^\+\+\+' | sed -E 's/^\+//')"
    # Keyword-prefixed declarations (kt/ts/js/py/go/...); name is the last token.
    printf '%s\n' "$added" | grep -oE \
        -e '(fun|val|var|object|interface|class|enum class|data class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
        -e '(function|const|let|class|interface|type|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
        -e '(def|func)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      | awk '{print $NF}'
    # POSIX/bash function definitions: `name() {` (the brace distinguishes a def
    # from a bare call site). Strip the `()` decoration to leave the name.
    printf '%s\n' "$added" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' \
      | sed -E 's/[[:space:]]*\(\).*$//'
}

# Identifiers not worth tracing (too common / keywords / trivially short).
STOP=' get set run main test data type name value index handler config result error props state item items list map key val var def fun the and for new this self true false null void init build parse class interface enum object function const let import export return public private await async '

# Collect changed-definition symbols from the diff.
SYMS="$(git diff "$BASE"...HEAD -- "${CHANGED[@]}" 2>/dev/null | declare_names \
        | awk 'length($0) >= 4' \
        | while IFS= read -r s; do
            lc=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
            case "$STOP" in *" $lc "*) continue ;; esac
            printf '%s\n' "$s"
          done \
        | sort -u || true)"

[ -z "$SYMS" ] && { echo "workspace-index: no traceable symbols in diff" >&2; exit 0; }

# Build an exclude-pathspec so we don't re-report call-sites inside the changed
# files themselves (those are already in the diff the reviewer sees).
EXCLUDES=()
for f in "${CHANGED[@]}"; do EXCLUDES+=(":(exclude)$f"); done

OUT=""
sym_count=0
site_total=0
for sym in $SYMS; do
    [ "$sym_count" -ge "$MAX_SYMBOLS" ] && break
    # Whole-word, case-sensitive, tracked source files only, minus the changed files.
    hits="$(git grep -nwI -- "$sym" -- '*.kt' '*.kts' '*.java' '*.ts' '*.tsx' '*.js' '*.jsx' \
              '*.mjs' '*.cjs' '*.vue' '*.svelte' '*.go' '*.py' '*.rb' '*.rs' '*.scala' \
              '*.swift' '*.c' '*.h' '*.cpp' '*.hpp' '*.cs' '*.php' '*.sh' '*.bash' '*.zsh' \
              "${EXCLUDES[@]}" 2>/dev/null \
            | head -n "$SITES_PER_SYM" || true)"
    [ -z "$hits" ] && continue
    sym_count=$((sym_count + 1))
    n=$(printf '%s\n' "$hits" | grep -c . || true)
    site_total=$((site_total + n))
    OUT+="- \`$sym\` used in:"$'\n'
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # trim leading whitespace on the matched code for compactness
        OUT+="  $line"$'\n'
    done <<< "$hits"
done

if [ "$sym_count" -eq 0 ]; then
    echo "workspace-index: changed symbols have no external call-sites" >&2
    exit 0
fi

HEADER="Workspace call-sites of symbols this diff changes (blast radius - review whether these callers still hold given the change):"
SLAB="$HEADER"$'\n'"$OUT"
SLAB="${SLAB:0:$BUDGET}"

printf '%s' "$SLAB"
echo "workspace-index: $sym_count symbols, $site_total call-sites" >&2
