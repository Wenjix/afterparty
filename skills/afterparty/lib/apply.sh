#!/usr/bin/env bash
# apply.sh - execute the boxes a person checked in a plan, and nothing else.
#
# apply does NOT kill anything itself. audit-processes.sh already carries the
# protect list, process-group semantics, postcondition receipts, and the
# journal; reimplementing any of that here would mean two kill disciplines
# drifting apart. apply's whole job is to decide WHICH groups are still
# legitimate targets and hand those to the existing gated path.
#
# Three ways an item is refused rather than acted on:
#   drift    the fingerprint moved -- a recycled pgid now holds a different
#            process, and killing it would destroy something never reviewed
#   gone     the group no longer exists
#   unchecked  the box was never ticked, or was withheld by the plan
#
# Usage:
#   apply.sh <plan.md>
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/fingerprint.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"

PLAN="${1:-}"
if [ -z "$PLAN" ]; then
  echo "apply: needs a plan file (write one with 'afterparty plan')" >&2
  exit 2
fi
if [ ! -f "$PLAN" ]; then
  echo "apply: no such plan: $PLAN" >&2
  exit 2
fi

# Locate the audit entrypoint. A shim earlier on PATH wins, which is how the
# tests observe delegation without signalling anything real.
AUDIT="$(command -v audit-processes.sh 2>/dev/null || printf '%s' "$DIR/audit-processes.sh")"

N_OK=0 N_DRIFT=0 N_GONE=0 N_HELD=0 N_FAILED=0
declare_targets=""

NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
ws_index   > "$T/ws"  2>/dev/null || : > "$T/ws"
ws_pid_cwd > "$T/cwd" 2>/dev/null || : > "$T/cwd"

# Facts for one group, sampled NOW: "<last_touched|-> <max_cpu>". A plan
# records what was true when it was written; approval must be checked against
# what is true when it runs, because a group can go from idle to active without
# any process changing -- the human simply came back.
group_facts() {
  local pg="$1"
  ps -Ao pid,pgid,%cpu 2>/dev/null | awk -v g="$pg" '$1 ~ /^[0-9]+$/ && $2 == g { print $1 "\t" $3 }' \
  | {
    local best="" maxcpu=0 pid cpu dir cand
    while IFS=$'\t' read -r pid cpu; do
      awk -v c="$cpu" -v m="$maxcpu" 'BEGIN { exit !(c + 0 > m + 0) }' && maxcpu="$cpu"
      dir="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$T/cwd")"
      [ -n "$dir" ] || continue
      cand="$(ws_owner_of "$dir" < "$T/ws" 2>/dev/null)" || cand=""
      [ -n "$cand" ] && [ -z "$best" ] && best="$cand"
    done
    if [ -n "$best" ]; then
      printf '%s\t%s' "$(awk -F'\t' -v w="$best" '$2 == w { print $1; exit }' "$T/ws")" "$maxcpu"
    else
      printf -- '-\t%s' "$maxcpu"
    fi
  }
}

# Parse: a checked line names a pgid, and the line under it carries the
# category and fingerprint. Anything not matching "- [x]" is ignored outright,
# so an unchecked or withheld item can never be acted on by accident.
pending_pgid=""
while IFS= read -r line; do
  case "$line" in
    '- [x]'*)
      pending_pgid="$(printf '%s\n' "$line" | sed -n 's/.*pgid \([0-9][0-9]*\).*/\1/p')"
      continue
      ;;
  esac
  [ -n "$pending_pgid" ] || continue
  case "$line" in
    *fingerprint:*)
      want_fp="$(printf '%s\n' "$line" | sed -n 's/.*fingerprint: \([0-9a-f][0-9a-f]*\).*/\1/p')"
      category="$(printf '%s\n' "$line" | sed -n 's/.*category: \([a-z][a-z]*\).*/\1/p')"
      pg="$pending_pgid"
      pending_pgid=""
      [ -n "$pg" ] && [ -n "$want_fp" ] && [ -n "$category" ] || continue

      if ! have_fp="$(fp_for_pgid "$pg" 2>/dev/null)" || [ -z "$have_fp" ]; then
        s_skip "  pgid $pg — gone, refused (the group no longer exists)"
        N_GONE=$((N_GONE + 1))
        continue
      fi
      if [ "$have_fp" != "$want_fp" ]; then
        s_skip "  pgid $pg — refused, fingerprint moved ($want_fp -> $have_fp)"
        s_dim  "      a different process holds this group now; re-plan"
        N_DRIFT=$((N_DRIFT + 1))
        continue
      fi
      # Re-check eligibility against the live world, not the plan's snapshot.
      facts="$(group_facts "$pg")"
      touched="${facts%%	*}"; cpu="${facts##*	}"
      [ "$touched" = "-" ] && touched=""
      verdict="$(elig_verdict "$touched" "${cpu:-0}" "$NOW")"
      if [ "$verdict" != "eligible" ]; then
        s_skip "  pgid $pg — held, no longer eligible ($verdict)"
        s_dim  "      approved when it was idle; that is not true any more"
        N_HELD=$((N_HELD + 1))
        continue
      fi
      declare_targets="${declare_targets}${category}:${pg}:${have_fp} "
      N_OK=$((N_OK + 1))
      ;;
    *) pending_pgid="" ;;
  esac
done < "$PLAN"

if [ "$N_OK" -eq 0 ]; then
  s_dim "  nothing approved is still what the plan described"
  printf '0 applied · %s refused (drift) · %s gone · %s held · 0 failed\n' "$N_DRIFT" "$N_GONE" "$N_HELD"
  exit 0
fi

# Group the approved pgids by category and delegate once per category, because
# --pgid narrows within a category.
for cat in tests dev browser; do
  list=""
  for t in $declare_targets; do
    case "$t" in
      "$cat":*)
        pg="${t#*:}"; pg="${pg%%:*}"
        expect="${t##*:}"
        # Re-verify identity immediately before signalling, not just at parse
        # time: the gap between the two is where a group could be recycled.
        # Leader identity (pgid + start time + command) is what detects
        # recycling; hashing every member instead would go stale on any child
        # spawn, and busy dev groups churn members every few seconds.
        if ! now_fp="$(fp_for_pgid "$pg" 2>/dev/null)" || [ "$now_fp" != "$expect" ]; then
          s_skip "  pgid $pg — dropped at the last check, identity changed"
          N_DRIFT=$((N_DRIFT + 1))
          N_OK=$((N_OK - 1))
          continue
        fi
        list="${list:+$list,}$pg"
        ;;
    esac
  done
  [ -n "$list" ] || continue
  s_would "  delegating: audit --kill $cat --pgid $list"
  if ! "$AUDIT" --kill "$cat" --pgid "$list"; then
    s_skip "  delegation failed for $cat (pgid $list)"
    N_FAILED=$((N_FAILED + 1))
  fi
done

printf '%s applied · %s refused (drift) · %s gone · %s held · %s failed\n' \
  "$N_OK" "$N_DRIFT" "$N_GONE" "$N_HELD" "$N_FAILED"
# Receipts are postcondition-based: a delegation that failed did not do the
# work, so the exit status must say so.
[ "$N_FAILED" -eq 0 ] || exit 1
