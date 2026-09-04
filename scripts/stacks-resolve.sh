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
        # A Gradle build file IS backend architecture: dependency scope and direction are where
        # module-layering violations actually land, and they never appear in a .kt diff.
        *.gradle|*.gradle.kts|settings.gradle|gradle/*.toml|*.versions.toml)
            add_stack backend-micronaut
            add_stack shared-backend
            ;;
        # logback.xml, application.yml and the like carry runtime behaviour that no Kotlin file
        # shows. A logging config that silently drops every appender is a backend defect.
        */resources/*.xml|*logback*.xml|*/resources/*.yml|*/resources/*.yaml|*application*.yml)
            add_stack backend-micronaut
            ;;
    esac
    case "$f" in
        *docker-compose*|.github/workflows/*|Dockerfile*|*/Dockerfile*|*.dockerfile)
            add_stack infrastructure
            ;;
        # Flyway migrations live under database-migration/sql/ and carry a numbering contract that
        # a plain *.sql match already covers, but the conf file governs schema wiping.
        *flyway.conf|*/database-migration/*)
            add_stack database
            ;;
    esac
done

add_stack core
printf '%s\n' "${STACKS#" "}" | sed 's/[[:space:]]*$//'
