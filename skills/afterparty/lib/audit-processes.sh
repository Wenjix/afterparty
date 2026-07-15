#!/usr/bin/env bash
# audit-processes.sh — find (and optionally kill) stray agent-spawned processes
# that linger after a task and burn CPU/RAM: test/watch runners, dev servers, and
# automation browsers. Default is a DRY-RUN report. Killing requires --kill and a
# category. Kills happen by process GROUP (pgid) so the whole pnpm->node->worker tree
# dies together, and a hardcoded protect-list keeps IDEs/agent-runtimes/MCP servers
# safe.
#
# Usage:
#   audit-processes.sh                      # report all categories (dry run)
#   audit-processes.sh --kill tests         # kill runaway test/watch groups
#   audit-processes.sh --kill dev --keep 87239   # kill dev servers except pgid 87239
#   audit-processes.sh --kill browser       # kill automation Chrome (never MCP servers)
#   audit-processes.sh --kill tests,dev     # multiple categories
#   audit-processes.sh --json               # JSON Lines report (no --kill)
#
# Exit codes: 0 ok · 2 usage error.
set -uo pipefail

# --- constants ---------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROTECT_RE (never signal these) is shared with process-ledger.sh.
. "$DIR/protect.sh"
# JSON Lines helpers for --json output.
. "$DIR/json.sh"

# Category patterns (extended regex, matched against the full command string).
TESTS_RE='vitest|jest|mocha|jasmine|ava |pytest|pnpm test|npm test|yarn test|vitest run|pnpm exec vitest'
DEV_RE='next dev|next start|nodemon|astro dev|remix vite|vite($| )|webpack.*serve|turbo.*dev|pnpm dev|pnpm start|npm run dev|npm run start|yarn dev|bun.*dev|deno task.*dev|ng serve|rails server|flask run|fastapi dev|uvicorn|python -m http.server'
BROWSER_RE='(Google Chrome|Chromium|Chrome Helper|headless_shell).*(remote-debugging|ms-playwright|mcp-chrome|puppeteer)|playwright.*(chromium|firefox|webkit)'
LOCALHOST_RE='^(node|bun|deno|python|uvicorn|ruby|rails|go|cargo|java|next|vite|webpack|cloudflared)[[:space:]]|:3000|:3001|:3002|:5173|:5174|:8000|:8080|:8787'

SELF_PID=$$
SELF_PGID=$(ps -o pgid= -p "$SELF_PID" 2>/dev/null | tr -d ' ')

# --- helpers -----------------------------------------------------------------
# rg when available, grep -E otherwise, so a missing ripgrep degrades to grep
# instead of reporting every category as "(none)".
HAVE_RG=0
command -v rg >/dev/null 2>&1 && HAVE_RG=1
[ "$HAVE_RG" -eq 1 ] || echo "note: ripgrep (rg) not found; matching with grep -E" >&2
ps -Ao pid= >/dev/null 2>&1 \
  || echo "warning: this ps lacks -Ao support (Git Bash?); process reports will be empty — use macOS/Linux or WSL" >&2

match_i()  { if [ "$HAVE_RG" -eq 1 ]; then rg -i -- "$1"; else grep -Ei -- "$1"; fi; }
match_iv() { if [ "$HAVE_RG" -eq 1 ]; then rg -iv -- "$1"; else grep -Eiv -- "$1"; fi; }
match_v()  { if [ "$HAVE_RG" -eq 1 ]; then rg -v -- "$1"; else grep -Ev -- "$1"; fi; }
match_q()  { if [ "$HAVE_RG" -eq 1 ]; then rg -q -- "$1"; else grep -Eq -- "$1"; fi; }

# Print matching processes for a category, excluding protected and self.
list_matches() {
  local re="$1"
  ps -Ao pid,ppid,pgid,%cpu,etime,command 2>/dev/null \
    | match_i "$re" \
    | match_iv "$PROTECT_RE" \
    | match_v "audit-processes.sh" \
    | match_v 'rg -i --|grep -Ei --' \
    | awk -v self="$SELF_PGID" '$3 != self'
}

# Print a human report for a category.
report() {
  local label="$1" re="$2" rows
  rows=$(list_matches "$re" || true)
  printf '\n=== %s ===\n' "$label"
  if [ -z "$rows" ]; then
    echo "  (none)"
    return
  fi
  printf '  %-7s %-7s %-7s %-6s %-10s %s\n' PID PPID PGID %CPU ELAPSED COMMAND
  echo "$rows" | while IFS= read -r line; do
    echo "$line" | awk '{printf "  %-7s %-7s %-7s %-6s %-10s ", $1,$2,$3,$4,$5; for(i=6;i<=NF && i<=14;i++) printf "%s ", $i; print ""}'
  done
}

report_localhost() {
  printf '\n=== Localhost listeners (ports that may be active dev servers) ===\n'
  if ! command -v lsof >/dev/null 2>&1; then
    echo "  lsof unavailable"
    return
  fi
  rows=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 && /127\.0\.0\.1|localhost|\[::1\]|\*:/' \
    | match_i "$LOCALHOST_RE" \
    | match_iv "$PROTECT_RE" || true)
  if [ -z "$rows" ]; then
    echo "  (none)"
    return
  fi
  echo "  COMMAND     PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME"
  echo "$rows" | awk '{print "  " $0}'
}

# Distinct pgids for a category, minus any in the keep-list.
pgids_for() {
  local re="$1" keep="$2"
  list_matches "$re" | awk '{print $3}' | sort -u | while read -r pg; do
    [ -z "$pg" ] && continue
    case ",$keep," in *",$pg,"*) continue ;; esac
    echo "$pg"
  done
}

# SIGTERM then SIGKILL a process group.
kill_group() {
  local pg="$1"
  kill -TERM -"$pg" 2>/dev/null && echo "  SIGTERM -> pgid $pg"
  sleep 2
  if ps -Ao pgid= 2>/dev/null | tr -d ' ' | match_q "^${pg}$"; then
    kill -KILL -"$pg" 2>/dev/null && echo "  SIGKILL -> pgid $pg (straggler)"
  fi
}

category_re() {
  case "$1" in
    tests) echo "$TESTS_RE" ;;
    dev) echo "$DEV_RE" ;;
    browser) echo "$BROWSER_RE" ;;
    *) echo "" ;;
  esac
}

# One JSON Lines object per matching process for a category.
json_report() {
  local cat="$1" re="$2" line pid ppid pgid cpu etime
  list_matches "$re" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    set -- $line
    [ $# -ge 6 ] || continue
    pid="$1" ppid="$2" pgid="$3" cpu="$4" etime="$5"
    shift 5
    json_row "$(json_kv section processes)" "$(json_kv category "$cat")" \
      "$(json_kvn pid "$pid")" "$(json_kvn ppid "$ppid")" "$(json_kvn pgid "$pgid")" \
      "$(json_kv cpu "$cpu")" "$(json_kv elapsed "$etime")" "$(json_kv command "$*")"
  done
}

# One JSON Lines object per localhost listener (needs lsof).
json_report_localhost() {
  command -v lsof >/dev/null 2>&1 || return 0
  local line
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 && /127\.0\.0\.1|localhost|\[::1\]|\*:/' \
    | match_i "$LOCALHOST_RE" \
    | match_iv "$PROTECT_RE" \
    | while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        [ $# -ge 4 ] || continue
        json_row "$(json_kv section listeners)" "$(json_kv command "$1")" \
          "$(json_kvn pid "$2")" "$(json_kv user "$3")" "$(json_kv name "${!#}")"
      done
}

# --- main --------------------------------------------------------------------
KILL_CATS="" KEEP="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kill) KILL_CATS="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$JSON" -eq 1 ] && [ -n "$KILL_CATS" ]; then
  echo "--json is report-only (cannot combine with --kill)" >&2
  exit 2
fi

if [ "$JSON" -eq 1 ]; then
  json_report_localhost
  json_report tests "$TESTS_RE"
  json_report dev "$DEV_RE"
  json_report browser "$BROWSER_RE"
  exit 0
fi

if [ -z "$KILL_CATS" ]; then
  echo "DRY RUN — reporting stray processes (use --kill <tests|dev|browser> to act)"
  report_localhost
  report "Test / watch runners (usually safe to kill)" "$TESTS_RE"
  report "Dev servers (keep the one you are actively using)" "$DEV_RE"
  report "Automation browsers (close via the browser tool first)" "$BROWSER_RE"
  echo
  echo "Protected (never killed): $PROTECT_RE"
  exit 0
fi

IFS=','
for cat in $KILL_CATS; do
  re=$(category_re "$cat")
  if [ -z "$re" ]; then echo "unknown category: $cat (use tests|dev|browser)" >&2; exit 2; fi
  echo "Killing category '$cat' (keep: ${KEEP:-none})"
  pgs=$(pgids_for "$re" "$KEEP")
  if [ -z "$pgs" ]; then echo "  nothing to kill"; continue; fi
  for pg in $pgs; do kill_group "$pg"; done
done
unset IFS
echo "done"
