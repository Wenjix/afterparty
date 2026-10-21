#!/usr/bin/env bash
# Human-invoked review. It writes a checked plan, never executes cleanup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/state.sh"
ROOT="$PWD" OUTPUT="" ASCII=0
PLAN_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--output)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "review: $1 requires a value. Run afterparty review --help." >&2; exit 2; }
      if [ "$1" = --root ]; then ROOT="$2"; PLAN_ARGS+=(--root "$2"); else OUTPUT="$2"; fi
      shift 2 ;;
    --all|--artifacts-only|--caches-only) PLAN_ARGS+=("$1"); shift ;;
    --ascii) ASCII=1; shift ;;
    -h|--help)
      echo 'Usage: afterparty review [--root DIR] [--all] [--artifacts-only] [--caches-only] [--output FILE] [--ascii]'
      echo 'Mark targets. Review your choices. Save the plan. Run afterparty apply separately to execute the plan.'
      echo 'Space marks or unmarks. Enter continues. i inspects. d shows details. / filters. Esc goes back. r refreshes. q quits.'
      echo 'Review requires the Bubble Tea helper, Python 3, and a macOS/Linux terminal.'
      echo 'Review fits at 60 columns and 20 rows. Resize smaller panes to continue. In tmux, press prefix z to zoom.'
      echo 'Without a supported terminal, Afterparty prints an unchecked plan and exits with a nonzero status.'
      echo 'Afterparty does not overwrite files.'
      exit 0 ;;
    *) echo "review: Unknown option: $1. Run afterparty review --help." >&2; exit 2 ;;
  esac
done
if [ -n "$OUTPUT" ] && { [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; }; then
  echo "review: --output already exists: $OUTPUT. Choose another --output path, or move the existing file before you retry." >&2
  exit 2
fi
[ -d "$ROOT" ] || { echo "review: The scope is not a directory: $ROOT. Use --root with an existing directory." >&2; exit 2; }
fallback() {
  echo "review: $1. Afterparty did not save a plan. Review the unchecked plan manually." >&2
  AFTERPARTY_STYLE=never "$DIR/plan.sh" ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"}
  exit 1
}
if [ ! -t 0 ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ]; then fallback 'The interactive terminal is unavailable'; fi
command -v python3 >/dev/null 2>&1 || fallback 'Python 3 is unavailable'
python3 -c 'import termios, tty; termios.tcgetattr(0)' 2>/dev/null || fallback 'Terminal input is unavailable'
python3 -c 'import os, sys; s=os.get_terminal_size(1); sys.exit(not (s.columns > 0 and s.lines > 0 and os.ttyname(0)==os.ttyname(1)))' || fallback 'Terminal dimensions are unavailable, or the input and output terminals differ'
REVIEW_UI="$DIR/../bin/afterparty-review"
[ -x "$REVIEW_UI" ] || fallback "The Bubble Tea helper is unavailable. Run $DIR/../bin/build-review to build it"
REVIEW_DIR="$(state_review_dir "$ROOT")" || exit 1
umask 077
state_secure_dir "$REVIEW_DIR" || exit 1
s_review_theme
exec env PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 "$REVIEW_UI" \
  --state-dir "$REVIEW_DIR" --output "$OUTPUT" --ascii "$ASCII" -- ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"}
