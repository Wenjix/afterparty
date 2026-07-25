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
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"

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

# Print a human report for a category. Sets LAST_N to the row count so the
# caller can tally findings.
report() {
  local label="$1" re="$2" rows hc="" hr="" line pid ppid pgid cpu et
  rows=$(list_matches "$re" || true)
  LAST_N=0
  [ -n "$rows" ] && LAST_N=$(printf '%s\n' "$rows" | grep -c .)
  s_hdr "$label"
  if [ -z "$rows" ]; then
    s_dim "  (none)"
    return
  fi
  if [ "$STYLE_ON" -eq 1 ]; then hc="$C_DIM"; hr="$C_RESET"; fi
  printf '  %s%-7s %-7s %-7s %-6s %-10s %s%s\n' "$hc" PID PPID PGID %CPU ELAPSED COMMAND "$hr"
  if [ "$STYLE_ON" -eq 1 ]; then
    # Styled rows render in bash so %CPU can carry a severity tint and
    # ELAPSED reads as "1d 2h"; the plain awk path below stays byte-exact.
    echo "$rows" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      # shellcheck disable=SC2086
      set -- $line
      [ $# -ge 6 ] || continue
      pid="$1" ppid="$2" pgid="$3" cpu="$4" et="$5"
      shift 5
      printf '  %-7s %-7s %-7s %s %-10s %s\n' "$pid" "$ppid" "$pgid" \
        "$(s_sevcell "$cpu" 10 50 "$(printf '%-6s' "$cpu")")" \
        "$(s_etime "$et")" "${*:1:9}"
    done
  else
    echo "$rows" | while IFS= read -r line; do
      echo "$line" | awk '{printf "  %-7s %-7s %-7s %-6s %-10s ", $1,$2,$3,$4,$5; for(i=6;i<=NF && i<=14;i++) printf "%s ", $i; print ""}'
    done
  fi
}

report_localhost() {
  s_hdr "Localhost listeners (ports that may be active dev servers)"
  LAST_N=0
  if ! command -v lsof >/dev/null 2>&1; then
    s_dim "  lsof unavailable"
    return
  fi
  rows=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 && /127\.0\.0\.1|localhost|\[::1\]|\*:/' \
    | match_i "$LOCALHOST_RE" \
    | match_iv "$PROTECT_RE" || true)
  if [ -z "$rows" ]; then
    s_dim "  (none)"
    return
  fi
  LAST_N=$(printf '%s\n' "$rows" | grep -c .)
  s_dim "  COMMAND     PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME"
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

# SIGTERM then SIGKILL a process group. Returns 0 only if the SIGTERM was
# delivered, so callers can count actual kills rather than candidates.
kill_group() {
  local pg="$1" ok=1
  if kill -TERM -"$pg" 2>/dev/null; then
    ok=0
    s_kill "  SIGTERM -> pgid $pg"
  fi
  sleep 2
  if ps -Ao pgid= 2>/dev/null | tr -d ' ' | match_q "^${pg}$"; then
    kill -KILL -"$pg" 2>/dev/null && s_kill "  SIGKILL -> pgid $pg (straggler)"
  fi
  return "$ok"
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
    --keep|--keep-pgid) KEEP="${2:-}"; shift 2 ;;
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

# Finale cards (styled standalone runs only; the composite router owns the
# card when AFTERPARTY_TALLY is set).
print_procs_card() {
  local total=$((N_TESTS + N_DEV + N_BROWSER)) cats=""
  echo
  s_card_open
  if [ "$total" -gt 0 ]; then
    [ "$N_TESTS" -gt 0 ] && cats="tests"
    [ "$N_DEV" -gt 0 ] && cats="${cats:+$cats,}dev"
    [ "$N_BROWSER" -gt 0 ] && cats="${cats:+$cats,}browser"
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — processes${C_RESET}"
    [ "$N_TESTS" -gt 0 ] && s_card_line "   $(s_n "$N_TESTS" 'test runner still running laps' 'test runners still running laps')"
    [ "$N_DEV" -gt 0 ] && s_card_line "   $(s_n "$N_DEV" 'dev server still serving' 'dev servers still serving')"
    [ "$N_BROWSER" -gt 0 ] && s_card_line "   $(s_n "$N_BROWSER" 'automation browser nobody closed' 'automation browsers nobody closed')"
    [ "$N_LISTEN" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_LISTEN" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    s_card_line
    s_card_line "   closing time: ${C_CYAN}afterparty audit --kill $cats${C_RESET}"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — no stragglers, nobody hiding in the bathroom${C_RESET}"
    [ "$N_LISTEN" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_LISTEN" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
}

print_procs_receipt() {
  echo
  s_card_open
  s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty audit --kill $KILL_CATS${C_RESET}"
  if [ "$N_KILLED" -gt 0 ]; then
    s_card_line "   $(s_n "$N_KILLED" 'process group shown the door' 'process groups shown the door')"
  else
    s_card_line "   nothing to kick out — floor was already clear ✨"
  fi
  s_card_line
  s_card_line "   thanks for partying responsibly 🎉"
  s_card_close
}

if [ -z "$KILL_CATS" ]; then
  s_mode "$C_YEL" "DRY RUN" " — headcount only, nobody gets kicked out yet (use --kill <tests|dev|browser> to act)" \
    "DRY RUN — reporting stray processes (use --kill <tests|dev|browser> to act)"
  report_localhost;                                                N_LISTEN=$LAST_N
  report "Test / watch runners (usually safe to kill)" "$TESTS_RE";  N_TESTS=$LAST_N
  report "Dev servers (keep the one you are actively using)" "$DEV_RE"; N_DEV=$LAST_N
  report "Automation browsers (close via the browser tool first)" "$BROWSER_RE"; N_BROWSER=$LAST_N
  echo
  s_dim "Protected (never killed): $PROTECT_RE"
  tally_add procs.found "$((N_TESTS + N_DEV + N_BROWSER))"
  tally_add procs.listeners "$N_LISTEN"
  if cards_on; then print_procs_card; fi
  exit 0
fi

N_KILLED=0
IFS=','
for cat in $KILL_CATS; do
  re=$(category_re "$cat")
  if [ -z "$re" ]; then echo "unknown category: $cat (use tests|dev|browser)" >&2; exit 2; fi
  s_lead "$C_RED" "Killing category '$cat' — last call (keep: ${KEEP:-none})" \
    "Killing category '$cat' (keep: ${KEEP:-none})"
  pgs=$(pgids_for "$re" "$KEEP")
  if [ -z "$pgs" ]; then s_dim "  nothing to kill"; continue; fi
  # pgids_for emits one pgid per line; the surrounding loop runs under
  # IFS=',' so word-splitting would glue them into one token — read by line.
  while IFS= read -r pg; do
    [ -n "$pg" ] || continue
    # The listing filtered protected rows, but a protected process may share
    # this group — never signal the whole group in that case.
    if pgid_has_protected "$pg"; then
      s_skip "  protect pgid $pg: shares its group with a protected process"
      continue
    fi
    kill_group "$pg" && N_KILLED=$((N_KILLED + 1))
  done <<< "$pgs"
done
unset IFS
s_ok "done"
tally_add procs.killed "$N_KILLED"
if cards_on; then print_procs_receipt; fi
