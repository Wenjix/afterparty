#!/usr/bin/env bash
# Read-only inventory of generated output across explicitly selected projects.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/state.sh"
. "$DIR/style.sh"

usage() {
  cat <<'USAGE'
Usage: afterparty builds [--projects-root DIR ...] [--max-depth N] [--json|--plain] [--ascii]
Find build output, caches, and test reports across Git repositories and worktrees.
Repeat --projects-root to inspect more than one project directory.
Without --projects-root, inspect the current repository or directory.
--max-depth limits repository discovery (default 6, range 1 to 64).
The terminal view shows sizes and growth since the previous complete scan.
Press Enter to open cleanup review for the focused repository. This command deletes nothing.
--json prints one versioned report. --plain prints a readable report without the TUI.
Unknown sizes and incomplete scans remain visible. An incomplete scan exits 1.
USAGE
}

ROOT_ARGS=()
DEPTH=6 MODE=auto ASCII=0
while [ $# -gt 0 ]; do
  case "$1" in
    --projects-root)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo 'builds: --projects-root requires a directory.' >&2; exit 2; }
      ROOT_ARGS+=(--projects-root "$2"); shift 2 ;;
    --max-depth)
      [ $# -ge 2 ] || { echo 'builds: --max-depth requires a number from 1 to 64.' >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo 'builds: --max-depth requires a number from 1 to 64.' >&2; exit 2 ;; esac
      # A length limit also prevents shell arithmetic overflow on invalid input.
      if [ "${#2}" -gt 2 ] || [ "$2" -lt 1 ] || [ "$2" -gt 64 ]; then
        echo 'builds: --max-depth requires a number from 1 to 64.' >&2; exit 2
      fi
      DEPTH="$2"; shift 2 ;;
    --json|--plain)
      NEXT_MODE="${1#--}"
      if [ "$MODE" != auto ] && [ "$MODE" != "$NEXT_MODE" ]; then
        echo 'builds: --json and --plain cannot be used together.' >&2; exit 2
      fi
      MODE="$NEXT_MODE"; shift ;;
    --ascii) ASCII=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "builds: Unknown option: $1. Run afterparty builds --help." >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo 'builds: Python 3 is required to inspect build output.' >&2; exit 2; }
if [ "${#ROOT_ARGS[@]}" -eq 0 ]; then
  if ROOT="$(GIT_OPTIONAL_LOCKS=0 git rev-parse --show-toplevel 2>/dev/null && printf '.')"; then
    # Keep path newlines; remove only the sentinel and Git's line terminator.
    ROOT="${ROOT%.}"
    ROOT="${ROOT%$'\n'}"
  else
    ROOT="$PWD"
  fi
  ROOT_ARGS=(--projects-root "$ROOT")
fi
ROOT_ARGS+=(--max-depth "$DEPTH")
STATE_DIR="$(state_builds_dir)" || { echo 'builds: The private cache location is unavailable.' >&2; exit 2; }
umask 077
state_secure_dir "$STATE_DIR" || { echo 'builds: Afterparty could not create the private inventory directory.' >&2; exit 2; }

if [ "$MODE" = auto ]; then
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    MODE=plain
  elif [ "${TERM:-dumb}" = dumb ]; then
    echo 'builds: This terminal does not support the TUI. Afterparty will print the inventory.' >&2
    MODE=plain
  elif ! python3 -c 'import os, termios; termios.tcgetattr(0); s=os.get_terminal_size(1); assert s.columns > 0 and s.lines > 0 and os.ttyname(0) == os.ttyname(1)' 2>/dev/null; then
    echo 'builds: Terminal input is unavailable. Afterparty will print the inventory.' >&2
    MODE=plain
  elif [ ! -x "$DIR/../bin/afterparty-review" ]; then
    echo "builds: The terminal helper is unavailable. Run $DIR/../bin/build-review to build it. Afterparty will print the inventory." >&2
    MODE=plain
  else
    s_review_theme
    exec env PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 "$DIR/../bin/afterparty-review" \
      --inventory --state-dir "$STATE_DIR" --ascii "$ASCII" -- "${ROOT_ARGS[@]}"
  fi
fi
DISPLAY_ARGS=()
[ "$ASCII" -eq 0 ] || DISPLAY_ARGS+=(--ascii)
exec env PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/build_inventory.py" \
  --state-dir "$STATE_DIR" "--$MODE" ${DISPLAY_ARGS[@]+"${DISPLAY_ARGS[@]}"} "${ROOT_ARGS[@]}"
