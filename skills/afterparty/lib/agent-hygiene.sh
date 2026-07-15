#!/usr/bin/env bash
# agent-hygiene.sh - one script entrypoint for agent process tracking, audit,
# and cleanup. The skill should route here instead of reimplementing logic in
# prompt text.
#
# Usage:
#   agent-hygiene.sh list [--json]
#   agent-hygiene.sh audit [--kill <tests|dev|browser>] [--keep <pgid>] [--json] [--report]
#   agent-hygiene.sh add --pid 123 --kind dev --port 3000 --purpose "verify UI" -- pnpm dev website
#   agent-hygiene.sh stop [--kill]
#   agent-hygiene.sh prune
#   agent-hygiene.sh git [--clean] [--age <days>] [--root <dir>] [--json]
#   agent-hygiene.sh artifacts [clean-artifacts args...]
#   agent-hygiene.sh devclean [--deep] [--optimize] [--disk] [--apply]
#   agent-hygiene.sh doctor
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,15p' "$0"
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

case "$cmd" in
  list)
    exec "$DIR/process-ledger.sh" list "$@"
    ;;
  add)
    exec "$DIR/process-ledger.sh" add "$@"
    ;;
  stop)
    exec "$DIR/process-ledger.sh" stop "$@"
    ;;
  prune)
    exec "$DIR/process-ledger.sh" prune "$@"
    ;;
  audit)
    # Composite report: ledger, stray processes, git leftovers. --json flows
    # to every part (JSON Lines compose across scripts); --report tees the
    # human report to report.md — at the repo root only when the repo
    # gitignores it (litter guard), otherwise next to the ledger.
    REPORT=0 JSON_FLAG=""
    ARGS=()
    for a in "$@"; do
      case "$a" in
        --report) REPORT=1 ;;
        --json) JSON_FLAG="--json"; ARGS+=("$a") ;;
        *) ARGS+=("$a") ;;
      esac
    done
    if [ "$REPORT" -eq 1 ] && [ -n "$JSON_FLAG" ]; then
      echo "--report and --json are mutually exclusive" >&2
      exit 2
    fi
    run_audit() {
      "$DIR/process-ledger.sh" list ${JSON_FLAG:+"$JSON_FLAG"}
      "$DIR/audit-processes.sh" ${ARGS[@]+"${ARGS[@]}"}
      "$DIR/audit-git.sh" ${JSON_FLAG:+"$JSON_FLAG"}
    }
    if [ "$REPORT" -eq 1 ]; then
      if ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" \
        && git check-ignore -q "$ROOT_DIR/report.md" 2>/dev/null; then
        REPORT_FILE="$ROOT_DIR/report.md"
      else
        REPORT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/report.md"
        mkdir -p "$(dirname "$REPORT_FILE")"
      fi
      echo "note: writing audit report to $REPORT_FILE" >&2
      { echo "# afterparty audit — $(date -u +'%Y-%m-%dT%H:%M:%SZ')"; run_audit; } | tee "$REPORT_FILE"
    else
      run_audit
    fi
    ;;
  git)
    exec "$DIR/audit-git.sh" "$@"
    ;;
  artifacts)
    exec "$DIR/clean-artifacts.sh" "$@"
    ;;
  devclean)
    exec "$DIR/devclean.sh" "$@"
    ;;
  doctor)
    "$DIR/process-ledger.sh" list
    "$DIR/audit-processes.sh"
    "$DIR/audit-git.sh"
    "$DIR/clean-artifacts.sh"
    "$DIR/devclean.sh"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac
