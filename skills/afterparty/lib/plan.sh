#!/usr/bin/env bash
# plan.sh - write a proposal for what could be cleaned, one checkbox per
# process group, for a person to edit.
#
# A proposal, not a decision. Only items that pass the two-signal gate arrive
# checked; in-use, still-working, and no-signal items are listed unchecked with
# the reason stated, so the withholding is visible rather than silent. Every
# checked line carries a fingerprint, which is what lets apply refuse an item
# that moved between planning and applying.
#
# Usage:
#   plan.sh [--json]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"
. "$DIR/fingerprint.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "plan: unknown option: $1" >&2
       echo "plan proposes; 'apply' is what acts on it." >&2
       exit 2 ;;
  esac
done

NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

ws_index > "$T/ws" 2>/dev/null || : > "$T/ws"
ws_pid_cwd > "$T/cwd" 2>/dev/null || : > "$T/cwd"
ps -Ao pid,pgid,%cpu,command 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {
  print $1 "\t" $2 "\t" $3
}' > "$T/ps" || : > "$T/ps"

# Aggregate to the unit that actually gets killed: the process group.
{
  sed 's/^/W\t/' "$T/ws"
  sed 's/^/C\t/' "$T/cwd"
  sed 's/^/P\t/' "$T/ps"
} | awk -F'\t' '
  $1 == "W" { wsts[$3] = $2; next }
  $1 == "C" { cwd[$2] = $3; next }
  $1 == "P" {
    pid = $2; pg = $3; cpu = $4 + 0
    dir = cwd[pid]; if (dir == "") next
    best = ""
    for (w in wsts) if (dir == w || index(dir, w "/") == 1)
      if (length(w) > length(best)) best = w
    owner[pg] = (best != "" ? best : dir)
    known[pg] = (best != "" ? wsts[best] : "")
    procs[pg]++
    if (cpu > maxcpu[pg]) maxcpu[pg] = cpu
  }
  END {
    # "-" rather than "" for an unknown last-touched: tab is IFS-whitespace, so
    # bash read collapses consecutive tabs and an empty middle field shifts
    # every later column left. That is how a no-transcript workspace ended up
    # parsed as eligible. Same hazard test-review-fixes C6 pins for the ledger.
    for (pg in procs)
      printf "%s\t%s\t%s\t%d\t%.1f\n", pg, owner[pg],
             (known[pg] == "" ? "-" : known[pg]), procs[pg], maxcpu[pg]
  }
' | sort -n > "$T/groups"

printf '# afterparty plan — %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '# Check a box to approve it. apply refuses any item whose fingerprint moved,\n'
printf '# and re-checks eligibility, so a plan cannot outlive what it described.\n'
echo
echo '## Process groups'
echo

if [ ! -s "$T/groups" ]; then
  echo '(nothing attributed to a workspace)'
  exit 0
fi

while IFS=$'\t' read -r pg owner touched procs cpu; do
  [ -n "$pg" ] || continue
  [ "$touched" = "-" ] && touched=""
  # Scope: a group belongs in the plan only if it sits in a workspace. With no
  # transcript the fallback test is "is this a git repo" -- that catches a
  # hand-driven project, which genuinely has no staleness signal and is worth
  # showing as unknown, while excluding the system daemons that all root at "/".
  if [ -z "$touched" ] && ! git -C "$owner" rev-parse --show-toplevel >/dev/null 2>&1; then
    continue
  fi
  verdict="$(elig_verdict "$touched" "$cpu" "$NOW")"
  name="$(basename "$owner")"
  if [ -n "$touched" ]; then
    age="idle $(ws_human_age "$((NOW - touched))")"
  else
    age="no transcript"
  fi
  detail="$name · $(s_n "$procs" proc procs) · $age · cpu $cpu"
  if [ "$verdict" = "eligible" ]; then
    fp="$(fp_for_pgid "$pg" 2>/dev/null)" || fp=""
    if [ -n "$fp" ]; then
      printf -- '- [x] eligible  pgid %s  %s\n' "$pg" "$detail"
      printf -- '      fingerprint: %s\n' "$fp"
      continue
    fi
  fi
  printf -- '- [⊘] %-8s pgid %s  %s\n' "$verdict" "$pg" "$detail"
  case "$verdict" in
    in-use)  printf -- '      not offered: that workspace was touched recently\n' ;;
    working) printf -- '      not offered: quiet transcript but cpu %s — a long task, not an abandoned one\n' "$cpu" ;;
    unknown) printf -- '      not offered: no transcript, so there is no staleness signal to trust\n' ;;
    *)       printf -- '      not offered: the group vanished before it could be fingerprinted\n' ;;
  esac
done < "$T/groups"

echo
echo '## Why'
echo '> (free text; apply records this with the receipt)'
