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

N_OK=0 N_DRIFT=0 N_GONE=0
declare_targets=""

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
      declare_targets="${declare_targets}${category}:${pg} "
      N_OK=$((N_OK + 1))
      ;;
    *) pending_pgid="" ;;
  esac
done < "$PLAN"

if [ "$N_OK" -eq 0 ]; then
  s_dim "  nothing approved is still what the plan described"
  printf '0 applied · %s refused (drift) · %s gone\n' "$N_DRIFT" "$N_GONE"
  exit 0
fi

# Group the approved pgids by category and delegate once per category, because
# --pgid narrows within a category.
for cat in tests dev browser; do
  list=""
  for t in $declare_targets; do
    case "$t" in "$cat":*) list="${list:+$list,}${t#*:}" ;; esac
  done
  [ -n "$list" ] || continue
  s_would "  delegating: audit --kill $cat --pgid $list"
  "$AUDIT" --kill "$cat" --pgid "$list" || true
done

printf '%s approved · %s refused (drift) · %s gone\n' "$N_OK" "$N_DRIFT" "$N_GONE"
