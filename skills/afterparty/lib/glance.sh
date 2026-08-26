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

# Capability model copied from audit-processes.sh, which already gets this
# right. A scanner that could not run means UNKNOWN, never "nothing found".
# Without it glance printed an empty table and exited 0 for a machine it never
# inspected — the most dangerous possible answer for the surface you read
# first after switching context, because "quiet" is what tells you it is safe
# to stop looking.
GLANCE_INCOMPLETE=0
LSOF_STATUS=ok LSOF_REASON=""
PS_STATUS=ok  PS_REASON=""
WS_STATUS=ok  WS_REASON=""
# Present-but-failing counts as unavailable. lsof can exist and still refuse
# (permissions, a hardened kernel, a container without /proc), and treating a
# failed scan as "found nothing" is the same confident-all-clear this whole
# capability block exists to prevent. It also makes the condition testable:
# `command -v` alone cannot be simulated by a PATH shim, since a shim IS found.
if ! command -v lsof >/dev/null 2>&1; then
  LSOF_STATUS=unavailable
  LSOF_REASON="lsof is not installed; processes cannot be attributed to a workspace"
  GLANCE_INCOMPLETE=1
elif ! lsof -a -d cwd -Fpn >/dev/null 2>&1; then
  LSOF_STATUS=unavailable
  LSOF_REASON="lsof could not read process working directories; attribution is incomplete"
  GLANCE_INCOMPLETE=1
fi
if ! ps -Ao pid,pgid,%cpu,command >/dev/null 2>&1; then
  PS_STATUS=unavailable
  PS_REASON="ps cannot provide the detailed process table"
  GLANCE_INCOMPLETE=1
fi
if [ ! -d "${AFTERPARTY_TRANSCRIPT_ROOT:-$WS_TRANSCRIPT_ROOT}" ]; then
  WS_STATUS=unavailable
  WS_REASON="no agent transcripts found; last-touched times are unknown"
  GLANCE_INCOMPLETE=1
fi

# ---- workspaces that have an agent transcript -------------------------------
ws_index > "$T/ws" 2>/dev/null || true

# ---- pid -> cwd, one call ---------------------------------------------------
ws_pid_cwd > "$T/cwd" 2>/dev/null || : > "$T/cwd"

# ---- listeners --------------------------------------------------------------
: > "$T/listen"
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$2 ~ /^[0-9]+$/ {
    n = $NF; if (n == "(LISTEN)") n = $(NF - 1)
    sub(/.*:/, "", n)
    if (n ~ /^[0-9]+$/) print $2 "\t" n
  }' | sort -u > "$T/listen"
fi

# ---- processes --------------------------------------------------------------
: > "$T/ps"
ps -Ao pid,pgid,%cpu,command 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {
  cpu = $3; pid = $1
  $1 = ""; $2 = ""; $3 = ""
  sub(/^[ \t]+/, "")
  print pid "\t" cpu "\t" $0
}' > "$T/ps" || true

# ---- join and aggregate -----------------------------------------------------
# Tagged concatenation keeps this to one portable awk (no gawk ARGIND).
{
  sed 's/^/W\t/' "$T/ws"
  sed 's/^/C\t/' "$T/cwd"
  sed 's/^/L\t/' "$T/listen"
  sed 's/^/P\t/' "$T/ps"
} | awk -F'\t' -v now="$NOW" '
  $1 == "W" { wsts[$3] = $2; next }
  $1 == "C" { cwd[$2] = $3; next }
  $1 == "L" { port[$2] = ($2 in port ? port[$2] " " $3 : $3); next }
  $1 == "P" {
    pid = $2; cpu = $3 + 0; dir = cwd[pid]
    if (dir == "") next
    # longest workspace path that prefixes this cwd wins, so a process in
    # repo/packages/web belongs to repo, not to some shorter ancestor.
    best = ""
    for (w in wsts) {
      if (dir == w || index(dir, w "/") == 1) {
        if (length(w) > length(best)) best = w
      }
    }
    if (best == "") next
    procs[best]++
    if (cpu > maxcpu[best]) maxcpu[best] = cpu
    if (pid in port) ports[best] = (best in ports ? ports[best] " " port[pid] : port[pid])
  }
  END {
    for (w in procs)
      printf "%d\t%s\t%d\t%.1f\t%s\n", wsts[w], w, procs[w], maxcpu[w], (w in ports ? ports[w] : "-")
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
IDLE_WS="$(awk -F'\t' -v now="$NOW" -v cut="$IDLE_SECS" '(now - $1) > cut {n++} END {print n + 0}' "$T/rows")"
IDLE_PROCS="$(awk -F'\t' -v now="$NOW" -v cut="$IDLE_SECS" '(now - $1) > cut {n += $3} END {print n + 0}' "$T/rows")"

# ---- render -----------------------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  for cap in "listeners:$LSOF_STATUS:$LSOF_REASON" "processes:$PS_STATUS:$PS_REASON" "transcripts:$WS_STATUS:$WS_REASON"; do
    printf '{%s,%s,%s,%s,%s}\n' '"schema_version":1' '"section":"capability"' \
      "$(json_kv name "${cap%%:*}")" \
      "$(json_kv status "$(printf '%s' "$cap" | cut -d: -f2)")" \
      "$(json_kv reason "$(printf '%s' "$cap" | cut -d: -f3-)")"
  done
  while IFS=$'\t' read -r ts path procs cpu ports; do
    [ -n "$path" ] || continue
    printf '{%s,%s,%s,%s,%s,%s,%s}\n' \
      '"schema_version":1' '"section":"workspace"' \
      "$(json_kv path "$path")" \
      "$(json_kvn last_touched "$ts")" \
      "$(json_kvn idle_seconds "$((NOW - ts))")" \
      "$(json_kvn procs "$procs")" \
      "$(json_kv cpu_max "$cpu")"
  done < "$T/rows"
  exit 0
fi

if [ "$ONELINE" -eq 1 ]; then
  if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
    printf 'afterparty  cannot see the machine — scan incomplete\n'
    exit 0
  fi
  if [ "$TOTAL_WS" -eq 0 ]; then
    printf 'afterparty  nothing running\n'
  elif [ "$IDLE_WS" -gt 0 ]; then
    printf 'afterparty  %s · %s idle >%sh · %s procs\n' \
      "$(s_n "$TOTAL_WS" workspace workspaces)" "$IDLE_WS" "$WS_IDLE_HOURS" "$TOTAL_PROCS"
  else
    printf 'afterparty  %s · all touched recently · %s procs\n' \
      "$(s_n "$TOTAL_WS" workspace workspaces)" "$TOTAL_PROCS"
  fi
  exit 0
fi

s_banner "afterparty — welcome back" "let's see what is still running"
if [ "$TOTAL_WS" -eq 0 ]; then
  if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
    s_warn "scan incomplete — nothing could be attributed, and that is not the same as nothing running"
    [ "$LSOF_STATUS" = ok ] || s_dim "  $LSOF_REASON"
    [ "$PS_STATUS"   = ok ] || s_dim "  $PS_REASON"
    [ "$WS_STATUS"   = ok ] || s_dim "  $WS_REASON"
  else
    s_dim "  (nothing attributed to a workspace)"
  fi
  exit 0
fi

printf '%s\n' "afterparty glance — $(s_n "$TOTAL_WS" 'workspace holding' 'workspaces holding') $(s_n "$TOTAL_PROCS" process processes)"
echo
s_dim "  WORKSPACE                    LAST TOUCHED   PROCS     CPU  PORTS"
HERE="$(pwd -P 2>/dev/null || pwd)"
while IFS=$'\t' read -r ts path procs cpu ports; do
  [ -n "$path" ] || continue
  age=$((NOW - ts))
  name="$(ws_label "$path")"
  case "$HERE" in "$path"|"$path"/*) name="$name ·here" ;; esac
  printf '  %-28.28s %-14s %5s  %s  %s\n' \
    "$name" "$(ws_human_age "$age")" "$procs" \
    "$(s_sevcell "${cpu%%.*}" 50 80 "$(printf '%6s' "$cpu")")" "$ports"
done < "$T/rows"

echo
if [ "$IDLE_WS" -gt 0 ]; then
  s_dim "  $(s_n "$IDLE_WS" workspace workspaces) idle over ${WS_IDLE_HOURS}h holding $(s_n "$IDLE_PROCS" process processes)"
fi
s_dim "  glance only reports — use 'afterparty audit' to review what can be cleaned"
if [ "$GLANCE_INCOMPLETE" -eq 1 ]; then
  echo
  s_warn "scan incomplete — this is NOT a clean bill of health"
  [ "$LSOF_STATUS" = ok ] || s_dim "  $LSOF_REASON"
  [ "$PS_STATUS"   = ok ] || s_dim "  $PS_REASON"
  [ "$WS_STATUS"   = ok ] || s_dim "  $WS_REASON"
fi
