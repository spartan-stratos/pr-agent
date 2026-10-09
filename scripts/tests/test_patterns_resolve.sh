#!/usr/bin/env bash
# test_patterns_resolve.sh - selection tests for scripts/patterns-resolve.sh.
#
# WHY this exists: pattern selection fails SILENTLY. A trigger that decomposes into junk tokens, or
# a `repos:` scope that never matches, produces a review that is merely worse - no error, and the
# `patterns=N` summary counts selections rather than survivors. Measured 2026-10-09 over 200
# service-dietfit commits: the median diff selected ~10 of 16 patterns, roughly 30k characters
# against review-local.sh's 14000-char cap, so the stack rules appended after them were discarded
# on every single review.
#
# Fixtures are literal diff fragments, not repo history, so the test runs offline and does not
# depend on any clone being present.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVE="$ROOT/scripts/patterns-resolve.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PRAGENT_PATTERNS_ROOT="$TMP/patterns"
mkdir -p "$PRAGENT_PATTERNS_ROOT/backend-micronaut" "$PRAGENT_PATTERNS_ROOT/_all"

cat > "$PRAGENT_PATTERNS_ROOT/backend-micronaut/scoped-alpha.md" <<'EOF'
triggers: db.replica replicaurl
repos: service-alpha
body
EOF
cat > "$PRAGENT_PATTERNS_ROOT/backend-micronaut/scoped-beta.md" <<'EOF'
triggers: db.replica
repos: service-beta other-beta
body
EOF
cat > "$PRAGENT_PATTERNS_ROOT/_all/global.md" <<'EOF'
triggers: responseformatmode
body
EOF
cat > "$PRAGENT_PATTERNS_ROOT/backend-micronaut/phrase.md" <<'EOF'
triggers: if (assignment.state ==
body
EOF
cat > "$PRAGENT_PATTERNS_ROOT/backend-micronaut/allstop.md" <<'EOF'
triggers: sealed class Result
body
EOF

PASS=0; FAIL=0
run() { # run <repo> <diff-text>
    PRAGENT_PATTERN_REPO="$1" bash "$RESOLVE" backend-micronaut 2>/dev/null <<<"$2" | sed 's#.*/##'
}
expect() { # expect <label> <want-regex|-> <got>
    local label="$1" want="$2" got="$3"
    if [ "$want" = "-" ]; then
        if [ -z "$got" ]; then echo "PASS: $label"; PASS=$((PASS+1)); return; fi
    elif printf '%s\n' "$got" | grep -q "$want"; then
        echo "PASS: $label"; PASS=$((PASS+1)); return
    fi
    echo "FAIL: $label (want '$want', got '${got//$'\n'/,}')"; FAIL=$((FAIL+1))
}
refute() { # refute <label> <unwanted-regex> <got>
    local label="$1" bad="$2" got="$3"
    if printf '%s\n' "$got" | grep -q "$bad"; then
        echo "FAIL: $label (unwanted '$bad' present)"; FAIL=$((FAIL+1))
    else
        echo "PASS: $label"; PASS=$((PASS+1))
    fi
}

REPLICA_DIFF='--- a/x/Repo.kt
+++ b/x/Repo.kt
+  override fun byUserId(id: UUID) = transaction(db.replica) { x }'

got="$(run service-alpha "$REPLICA_DIFF")"
expect "repos: matches -> selected" 'scoped-alpha' "$got"
refute "repos: non-matching scope excluded" 'scoped-beta' "$got"

got="$(run "spartan-stratos/service-alpha" "$REPLICA_DIFF")"
expect "repos: matches owner/repo form" 'scoped-alpha' "$got"

got="$(run "SPARTAN/Service-Alpha" "$REPLICA_DIFF")"
expect "repos: match is case-insensitive" 'scoped-alpha' "$got"

got="$(run other-beta "$REPLICA_DIFF")"
expect "repos: second token on the line matches" 'scoped-beta' "$got"

got="$(run service-gamma "$REPLICA_DIFF")"
expect "unrelated repo selects nothing scoped" "-" "$got"

got="$(run "" "$REPLICA_DIFF")"
expect "unknown repo never guesses a scoped pattern" "-" "$got"

got="$(PRAGENT_PATTERN_REPO="" bash "$RESOLVE" backend-micronaut _all 2>/dev/null <<<'+ responseFormatMode = NONE' | sed 's#.*/##')"
expect "a pattern with no repos: line stays global" 'global' "$got"

# A multi-word trigger phrase decomposes into whitespace-separated tokens. `if` is a stopword and
# `==` is under the 3-alnum floor, so only the punctuated `(assignment.state` can select, as a
# substring. This is the documented behaviour, not an accident - the test pins it so a future
# "support phrases" change has to be deliberate rather than silent.
got="$(run service-alpha '+ if (assignment.state == DONE) {')"
expect "phrase trigger selects on its one surviving token" 'phrase' "$got"
got="$(run service-alpha '+ if (x) { return }')"
expect "the stopword and the short token do not select" "-" "$got"

# Every token a stopword -> the file can never be selected. This is a pattern-authoring bug the
# test makes visible, since nothing else reports it.
got="$(run service-alpha '+ sealed class Result()')"
expect "an all-stopword triggers line selects nothing" "-" "$got"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
