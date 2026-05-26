#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "usage: $0 <file-list-stdin>" >&2
    exit 2
fi

STACKS=" "

add_stack() {
    case "$STACKS" in
        *" $1 "*) ;;
        *) STACKS="${STACKS}$1 " ;;
    esac
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
        *.kt)
            add_stack backend-micronaut
            add_stack shared-backend
            ;;
        *.sql)
            add_stack database
            ;;
        *.tf|*.hcl|*.tfvars)
            add_stack infrastructure
            ;;
        *.tsx|*.ts|*.jsx|*.js|*.css|*.scss)
            add_stack frontend-react
            ;;
    esac
    case "$f" in
        *docker-compose*|.github/workflows/*)
            add_stack infrastructure
            ;;
    esac
done

add_stack core
printf '%s\n' "${STACKS#" "}" | sed 's/[[:space:]]*$//'
