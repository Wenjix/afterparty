#!/usr/bin/env bash
# glance.sh - "what did I leave running?", answered on returning to the machine.
#
# Machine-wide, grouped by workspace, sorted so the workspaces nobody has
# touched sink to the bottom. Severity here is MAGNITUDE, not reversibility:
# this view exists to make you look up, and the plan is where consequence gets
# weighed. Read-only by construction -- there is deliberately no flag that acts.
#
# Attribution costs one lsof call for every process cwd rather than one per
# pid; per-pid would be ~500 forks on a normal machine.
#
# Usage:
#   glance.sh [--oneline] [--json]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/workspace.sh"
. "$DIR/json.sh"

ONELINE=0
AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --oneline) ONELINE=1; shift ;;
    --json)    AS_JSON=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "glance: unknown option: $1" >&2
       echo "glance reports; it never acts. Use 'audit --kill' or 'plan' to change anything." >&2
       exit 2 ;;
  esac
done

NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

# Each capability describes the scan whose data is actually rendered. Do not
# probe once and then trust a second, independently failing invocation.
GLANCE_INCOMPLETE=0
LSOF_STATUS=ok LSOF_REASON=""
CWD_STATUS=ok CWD_REASON=""
PS_STATUS=ok PS_REASON=""
WS_STATUS=ok WS_REASON=""
if ! ws_pid_cwd --strict > "$T/cwd" 2> "$T/cwd.err"; then
  : > "$T/cwd"
  CWD_STATUS=unavailable
  CWD_REASON="lsof could not completely read process working directories; attribution is incomplete"
  GLANCE_INCOMPLETE=1
fi
if ! ps -Ao pid,pgid,%cpu,command > "$T/ps.raw" 2> "$T/ps.err" \
  || [ -s "$T/ps.err" ] || [ ! -s "$T/ps.raw" ]; then
  PS_STATUS=unavailable
else
  awk '$1 == "PID" {next}
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ && NF >= 4 {
      pid=$1; cpu=$3; $1=""; $2=""; $3=""; sub(/^[ \t]+/, "")
      print pid "\t" cpu "\t" $0; next
    }
    {bad=1}
    END {if (bad) exit 1}' "$T/ps.raw" > "$T/ps" || PS_STATUS=unavailable
fi
if [ "$PS_STATUS" != ok ] || [ ! -s "$T/ps" ]; then
  PS_STATUS=unavailable
  : > "$T/ps"
  PS_REASON="ps cannot provide a complete detailed process table"
  GLANCE_INCOMPLETE=1
fi
ws_index > "$T/ws" 2> "$T/ws.err" || WS_STATUS=unavailable
if [ ! -s "$T/ws" ] || [ -s "$T/ws.err" ]; then
  WS_STATUS=unavailable
fi
if [ "$WS_STATUS" != ok ]; then
  WS_REASON="Claude transcript activity is unavailable; workspace activity is unknown"
  GLANCE_INCOMPLETE=1
fi
: > "$T/listen"
if ! command -v lsof >/dev/null 2>&1; then
  LSOF_STATUS=unavailable
else
  lsof -nP -iTCP -sTCP:LISTEN > "$T/listen.raw" 2> "$T/listen.err"
  listen_rc=$?
  # lsof's empty, diagnostic-free exit 1 means no matching listeners.
  if [ -s "$T/listen.err" ] || { [ "$listen_rc" -ne 0 ] && { [ "$listen_rc" -ne 1 ] || [ -s "$T/listen.raw" ]; }; }; then
    LSOF_STATUS=unavailable
  else
    if ! awk '$1 == "COMMAND" && $2 == "PID" {next}
      $2 ~ /^[0-9]+$/ && NF >= 9 {
        n=$NF; if (n == "(LISTEN)") n=$(NF-1)
        sub(/.*:/, "", n)
        if (n !~ /^[0-9]+$/) {bad=1; next}
        print $2 "\t" n; next
      }
      NF {bad=1}
      END {if (bad) exit 1}' "$T/listen.raw" | sort -u > "$T/listen"; then
      : > "$T/listen"
      LSOF_STATUS=unavailable
    fi
  fi
fi
if [ "$LSOF_STATUS" != ok ]; then
  LSOF_REASON="lsof could not completely inspect listeners"
  GLANCE_INCOMPLETE=1
fi

# ---- join and aggregate -----------------------------------------------------
# Tagged concatenation keeps this to one portable awk (no gawk ARGIND).
{
  sed 's/^/W\t/' "$T/ws"
  sed 's/^/C\t/' "$T/cwd"
  sed 's/^/L\t/' "$T/listen"
  sed 's/^/P\t/' "$T/ps"
} | awk -F'\t' -v now="$NOW" '
    # macOS awk (20200816) compares strings via locale collation, and reports
    # two DIFFERENT multibyte paths as equal: "/w/プロジェクト/web" == "/w/別
    # プロジェクト/web" evaluates TRUE, and so does the substr form. index() is
    # byte-exact, so equality is length-plus-index. Without this a process is
    # attributed to the WRONG workspace and two workspaces merge into one row —
    # on the surface a person approves kills from.
    function samepath(a, b) { return (length(a) == length(b) && index(a, b) == 1) }
  $1 == "W" { wsts[$3] = $2; next }
  $1 == "C" { cwd[$2] = $3; next }
  $1 == "L" { port[$2] = ($2 in port ? port[$2] " " $3 : $3); next }
  $1 == "P" {
    pid = $2; cpu = $3 + 0; dir = cwd[pid]
    if (dir == "") dir = "(unattributed)"
    # longest workspace path that prefixes this cwd wins, so a process in
    # repo/packages/web belongs to repo, not to some shorter ancestor.
    best = ""
    for (w in wsts) {
      if (samepath(dir, w) || index(dir, w "/") == 1) {
        if (length(w) > length(best)) best = w
      }
    }
    if (best == "") {
      best = dir
      if (!(best in wsts)) wsts[best] = "-"
      attribution[best] = (dir == "(unattributed)" ? "unattributed" : "cwd-only")
    } else if (!(best in attribution)) attribution[best] = "transcript-workspace"
    procs[best]++
    if (cpu > maxcpu[best]) maxcpu[best] = cpu
    if (pid in port) ports[best] = (best in ports ? ports[best] " " port[pid] : port[pid])
  }
  END {
    for (w in procs)
      printf "%s\t%s\t%d\t%.1f\t%s\t%s\n", wsts[w], w, procs[w], maxcpu[w], (w in ports ? ports[w] : "-"), attribution[w]
  }
' | sort -rn > "$T/rows"

# wc, not `grep -c ... || echo 0`: grep -c PRINTS 0 and EXITS 1 when nothing
# matches, so the fallback appended a second zero and TOTAL_WS became the
# two-line string "0\n0". Every [ -eq ] on it then errored, which made the
# entire empty-state branch unreachable — invisible until a machine with no
# lsof produced an empty row set.
TOTAL_WS="$(wc -l < "$T/rows" | tr -d '[:space:]')"
TOTAL_WS="${TOTAL_WS:-0}"
TOTAL_PROCS="$(awk -F'\t' '{n += $3} END {print n + 0}' "$T/rows")"
IDLE_SECS=$((WS_IDLE_HOURS * 3600))
IDLE_WS="$(awk -F'\t' -v now="$NOW" -v cut="$IDLE_SECS" '$1 != "-" && (now - $1) > cut {n++} END {print n + 0}' "$T/rows")"
IDLE_PROCS="$(awk -F'\t' -v now="$NOW" -v cut="$IDLE_SECS" '$1 != "-" && (now - $1) > cut {n += $3} END {print n + 0}' "$T/rows")"

# ---- render -----------------------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  for cap in "attribution:$CWD_STATUS:$CWD_REASON" "listeners:$LSOF_STATUS:$LSOF_REASON" "processes:$PS_STATUS:$PS_REASON" "transcripts:$WS_STATUS:$WS_REASON"; do
    printf '{%s,%s,%s,%s,%s}\n' '"schema_version":1' '"section":"capability"' \
      "$(json_kv name "${cap%%:*}")" \
      "$(json_kv status "$(printf '%s' "$cap" | cut -d: -f2)")" \
      "$(json_kv reason "$(printf '%s' "$cap" | cut -d: -f3-)")"
  done
  while IFS=$'\t' read -r ts path procs cpu ports attribution; do
    [ -n "$path" ] || continue
    idle=""
    [ "$ts" = "-" ] || idle="$((NOW - ts))"
    json_row "$(json_kv section workspace)" \
      "$(json_kvz path "$([ "$attribution" = unattributed ] || printf '%s' "$path")")" \
      "$(json_kv attribution "$attribution")" \
      "$(json_kvn last_touched "$ts")" "$(json_kvn idle_seconds "$idle")" \
      "$(json_kv activity_source claude-transcript)" \
      "$(json_kvn procs "$procs")" "$(json_kv cpu_max "$cpu")" \
      "$(json_kvz ports "$([ "$ports" = - ] || printf '%s' "$ports")")"
  done < "$T/rows"
  exit 0
fi

if [ "$ONELINE" -eq 1 ]; then
  if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
    printf 'afterparty  %s observed procs · scan incomplete (attribution or activity unknown)\n' "$TOTAL_PROCS"
    exit 0
  fi
  if [ "$TOTAL_WS" -eq 0 ]; then
    printf 'afterparty  no processes observed\n'
  elif [ "$IDLE_WS" -gt 0 ]; then
    printf 'afterparty  %s · %s without Claude transcript activity >%sh · %s procs\n' \
      "$(s_n "$TOTAL_WS" workspace workspaces)" "$IDLE_WS" "$WS_IDLE_HOURS" "$TOTAL_PROCS"
  else
    printf 'afterparty  %s · observed processes · %s procs\n' \
      "$(s_n "$TOTAL_WS" workspace workspaces)" "$TOTAL_PROCS"
  fi
  exit 0
fi

s_banner "afterparty — welcome back" "let's see what is still running"
if [ "$TOTAL_WS" -eq 0 ]; then
  if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
    s_warn "scan incomplete — nothing could be attributed, and that is not the same as nothing running"
    [ "$CWD_STATUS" = ok ] || s_dim "  $CWD_REASON"
    [ "$LSOF_STATUS" = ok ] || s_dim "  $LSOF_REASON"
    [ "$PS_STATUS"   = ok ] || s_dim "  $PS_REASON"
    [ "$WS_STATUS"   = ok ] || s_dim "  $WS_REASON"
  else
    s_dim "  (nothing attributed to a workspace)"
  fi
  exit 0
fi

printf '%s\n' "afterparty glance — $(s_n "$TOTAL_WS" 'process scope holding' 'process scopes holding') $(s_n "$TOTAL_PROCS" process processes)"
echo
s_dim "  WORKSPACE / PROCESS CWD       CLAUDE ACTIVITY PROCS     CPU  PORTS"
# Labels are computed across the rows being displayed, so each one is the
# shortest suffix unique in THIS table rather than a guess made row by row.
awk -F'\t' '{print $2}' "$T/rows" | ws_unique_labels > "$T/labels" 2>/dev/null || : > "$T/labels"
HERE="$(pwd -P 2>/dev/null || pwd)"
while IFS=$'\t' read -r ts path procs cpu ports attribution; do
  [ -n "$path" ] || continue
  age="unknown"
  [ "$ts" = "-" ] || age="$(ws_human_age "$((NOW - ts))")"
  name="$(awk -F'\t' -v p="$path" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($1,p) { print $2; exit }' "$T/labels")"
  [ -n "$name" ] || name="$(ws_label "$path")"
  case "$HERE" in "$path"|"$path"/*) name="$name ·here" ;; esac
  printf '  %-28s %-14s %5s  %s  %s\n' \
    "$name" "$age" "$procs" \
    "$(s_sevcell "${cpu%%.*}" 50 80 "$(printf '%6s' "$cpu")")" "$ports"
done < "$T/rows"

echo
if [ "$IDLE_WS" -gt 0 ]; then
  s_dim "  $(s_n "$IDLE_WS" workspace workspaces) without Claude transcript activity for over ${WS_IDLE_HOURS}h holding $(s_n "$IDLE_PROCS" process processes)"
fi
s_dim "  Unknown activity is not idle; cwd-only rows are not confirmed workspace ownership."
s_dim "  glance only reports — use 'afterparty audit' to review what can be cleaned"
if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
  echo
  s_warn "scan incomplete — this is NOT a clean bill of health"
  [ "$CWD_STATUS" = ok ] || s_dim "  $CWD_REASON"
    [ "$LSOF_STATUS" = ok ] || s_dim "  $LSOF_REASON"
  [ "$PS_STATUS"   = ok ] || s_dim "  $PS_REASON"
  [ "$WS_STATUS"   = ok ] || s_dim "  $WS_REASON"
fi
