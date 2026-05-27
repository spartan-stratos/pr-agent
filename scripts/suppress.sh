#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python"

cmd="${1:-}"; shift || true
case "$cmd" in
  list|reject|accept|purge|post-improve|stats)
    exec "$PY" "$ROOT/scripts/suppress_cli.py" "$cmd" "$@" ;;
  import)
    exec "$PY" "$ROOT/scripts/suppress_import.py" "$@" ;;
  ""|-h|--help)
    cat <<USAGE
Usage: $0 <command> [args]
  list [--repo OWNER/NAME] [--status STATUS] [--reviewer REVIEWER] [--limit N]
  stats [--repo OWNER/NAME]
  reject <id> [--reason "..."]
  accept <id>
  purge [--older-than DAYS]
  post-improve --pr-url URL
  import --pr-url URL
USAGE
    exit 0 ;;
  *)
    echo "Unknown command: $cmd" >&2; exit 2 ;;
esac
