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

# Repo identity for the `repos:` scope line, as `<owner>/<repo>` or just `<repo>`. Empty means
# "unknown", and an unknown repo gets the GLOBAL patterns only - a repo-scoped pattern is never
# guessed into a review.
PATTERN_REPO_LC="$(printf '%s' "${PRAGENT_PATTERN_REPO:-}" | tr '[:upper:]' '[:lower:]')"

INPUT_LC="$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')"

# Overrideable so a stack whose diffs genuinely hinge on one of these can re-enable it.
STOPWORDS="${PRAGENT_PATTERN_STOPWORDS:-class object interface fun val var data sealed enum return if else for while when try catch throw import package public private internal true false null string int long boolean list map set get add new this that with from into and not error test tests result state guard type name value item items code line file files build}"
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

        # `repos: <token> [<token> ...]` restricts a pattern to the repos it was written from.
        #
        # WHY this exists: triggers are OR-matched single tokens, so a pattern written for one
        # repo and triggered on words like `default`, `manager`, `delete` or `@Singleton` fires on
        # EVERY Kotlin repo. Measured 2026-10-09 over 200 service-dietfit commits: the median diff
        # selected ~10 of 16 patterns, roughly 30k characters against review-local.sh's 14000-char
        # conventions cap. CONV is truncated head-keep, so the stack rules appended last were
        # silently discarded on every review, and the summary line still reported `patterns=10`
        # because it counts what was SELECTED, not what survived. Narrowing the triggers alone
        # would have cost those patterns their recall on their OWN repo; scoping keeps both.
        #
        # A substring match is deliberate so `service-dietfit` matches `spartan-stratos/service-dietfit`.
        repos_line="$(grep -im1 '^repos:' "$file" 2>/dev/null || true)"
        if [ -n "$repos_line" ]; then
            repo_ok=0
            if [ -n "$PATTERN_REPO_LC" ]; then
                for want in ${repos_line#*:}; do
                    want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
                    [ -n "$want" ] || continue
                    case "$PATTERN_REPO_LC" in
                        *"$want"*) repo_ok=1; break ;;
                    esac
                done
            fi
            [ "$repo_ok" -eq 1 ] || continue
        fi

        triggers="${trigger_line#*:}"
        for trigger in $triggers; do
            trigger="$(printf '%s' "$trigger" | tr '[:upper:]' '[:lower:]')"
            [ -n "$trigger" ] || continue

            # A trigger needs at least 3 alphanumeric characters. The triggers line is
            # whitespace-separated, so a multi-WORD trigger phrase silently decomposes into its
            # words - "if (assignment.state ==" becomes the tokens "if", "(assignment.state" and
            # "==", and "if"/"==" then match essentially every diff. Those junk tokens pulled
            # unrelated patterns into every review and ate the conventions budget, which is capped,
            # so real rules got truncated out. Nothing reported an error; the reviews just quietly
            # got worse.
            alnum="$(printf '%s' "$trigger" | tr -cd '[:alnum:]')"
            [ "${#alnum}" -ge 3 ] || continue

            # Generic code words carry no selection signal. They appear here only as debris from
            # the same phrase-splitting problem: "sealed class Result" contributes the token
            # "class", which matches every Kotlin diff ever written and attached a bulk-write
            # pattern to a logging change. Specific tokens (camelCase names, anything with
            # punctuation, domain nouns like Manager or Repository) are deliberately NOT here.
            case " $STOPWORDS " in
                *" $trigger "*) continue ;;
            esac

            if printf '%s' "$trigger" | grep -qE '^[a-z0-9_]+$'; then
                # Bare word: match on word boundaries, never as a substring. "cas" was matching
                # inside "case", which is how a bulk-write pattern attached itself to a logging diff.
                if printf '%s' "$INPUT_LC" | grep -qw -- "$trigger"; then
                    add_selected "$file"
                    break
                fi
            else
                # Carries punctuation (@Factory, Either<ClientException, .right()) - substring is
                # correct here, and the punctuation already makes it specific.
                case "$INPUT_LC" in
                    *"$trigger"*)
                        add_selected "$file"
                        break
                        ;;
                esac
            fi
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
