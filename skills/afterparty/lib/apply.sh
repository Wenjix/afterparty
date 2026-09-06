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
. "$DIR/state.sh"
. "$DIR/journal.sh"
. "$DIR/vetoes.sh"

# The reason a person typed under "## Why". plan promises this is recorded, so
# it has to actually reach the journal rather than dying with the file.
plan_reason() {
  # The plan ships an instructional placeholder under "## Why". Journaling it
  # would file the template as though it were a person's stated reason, on a
  # run where nobody typed anything and nothing happened.
  awk '/^## Why/ { on = 1; next }
       on && /^## / { exit }
       on && /^>/ {
         sub(/^>[[:space:]]*/, "")
         if ($0 == "" || $0 ~ /^\(free text/) next
         print
       }' "$1" \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

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

N_OK=0 N_DRIFT=0 N_GONE=0 N_HELD=0 N_FAILED=0 N_SURVIVED=0 N_VETOED=0
declare_targets=""
wt_targets=""

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
    local best="" maxcpu=0 pid cpu dir cand mixed=0
    while IFS=$'\t' read -r pid cpu; do
      awk -v c="$cpu" -v m="$maxcpu" 'BEGIN { exit !(c + 0 > m + 0) }' && maxcpu="$cpu"
      dir="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$T/cwd")"
      # A member we cannot place is not a member we can vouch for. Skipping it
      # would let a stale leader carry the whole group through the gate while
      # an unattributable sibling sits in a workspace someone is using.
      if [ -z "$dir" ]; then
        mixed=1
        continue
      fi
      cand="$(ws_owner_of "$dir" < "$T/ws" 2>/dev/null)" || cand=""
      # Every member is resolved, not just the first. A group can gain a child
      # in a live workspace after planning while its leader -- and therefore
      # its fingerprint -- stays exactly the same. Killing on the strength of
      # the stale member would take the active work with it.
      if [ -z "$cand" ]; then
        # A cwd that resolves to NO indexed workspace is unknown ownership, not
        # absent ownership. Folding it into the empty-best case let the next
        # member's workspace win and the unplaceable one be forgotten, so the
        # verdict depended on ps row order: identical worlds, opposite
        # decisions. Missing evidence is withheld, never assumed benign.
        mixed=1
      elif [ -z "$best" ]; then
        best="$cand"
      elif [ "$cand" != "$best" ]; then
        mixed=1
      fi
    done
    if [ "$mixed" -eq 1 ]; then
      printf -- 'mixed\t%s' "$maxcpu"
    elif [ -n "$best" ]; then
      printf '%s\t%s' "$(awk -F'\t' -v w="$best" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($2,w) { print $1; exit }' "$T/ws")" "$maxcpu"
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
      # Any checked line arms the next attribute line. Keying this on a pgid
      # having been parsed would drop every worktree item silently, since a
      # worktree line carries a path and no pgid -- the item would be counted
      # nowhere and the receipt would look clean.
      pending_pgid="$(printf '%s\n' "$line" | sed -n 's/.*pgid \([0-9][0-9]*\).*/\1/p')"
      [ -n "$pending_pgid" ] || pending_pgid="-"
      continue
      ;;
  esac
  [ -n "$pending_pgid" ] || continue
  case "$line" in
    # A worktree item is recognised by its type token, not by shape. The path
    # is read from 'path:' to end of line, which is the one parse that survives
    # a path containing spaces -- every other field is a fixed-width token.
    *"type: worktree"*)
      want_fp="$(printf '%s\n' "$line" | sed -n 's/.*fingerprint: \([0-9a-f][0-9a-f]*\).*/\1/p')"
      wtpath="$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]path: //p')"
      pending_pgid=""
      [ -n "$want_fp" ] && [ -n "$wtpath" ] || continue
      wt_targets="${wt_targets}${want_fp}:${wtpath}"$'\n'
      N_OK=$((N_OK + 1))
      continue
      ;;
    *fingerprint:*)
      want_fp="$(printf '%s\n' "$line" | sed -n 's/.*fingerprint: \([0-9a-f][0-9a-f]*\).*/\1/p')"
      category="$(printf '%s\n' "$line" | sed -n 's/.*category: \([a-z][a-z]*\).*/\1/p')"
      pg="$pending_pgid"
      pending_pgid=""
      [ "$pg" = "-" ] && continue
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
      if [ "$touched" = "mixed" ]; then
        s_skip "  pgid $pg — held, now spans more than one workspace"
        s_dim  "      it gained a member elsewhere since the plan was written"
        N_HELD=$((N_HELD + 1))
        continue
      fi
      [ "$touched" = "-" ] && touched=""
      verdict="$(elig_verdict "$touched" "${cpu:-0}" "$NOW")"
      if [ "$verdict" != "eligible" ]; then
        s_skip "  pgid $pg — held, no longer eligible ($verdict)"
        s_dim  "      approved when it was idle; that is not true any more"
        N_HELD=$((N_HELD + 1))
        continue
      fi
      # The delegation loop below handles exactly these. A plan naming anything
      # else was counted as applied and then never delegated: the item silently
      # did not happen and the receipt said it did. A hand-edited plan is
      # untrusted input, so this is validated rather than assumed.
      case "$category" in
        tests|dev|browser) : ;;
        *)
          s_skip "  pgid $pg — refused, '$category' is not a category apply can execute"
          N_FAILED=$((N_FAILED + 1))
          continue
          ;;
      esac
      declare_targets="${declare_targets}${category}:${pg}:${have_fp} "
      N_OK=$((N_OK + 1))
      ;;
    *) pending_pgid="" ;;
  esac
done < "$PLAN"

# The reason is recorded before any work, because "I reviewed this and approved
# nothing, here is why" is worth keeping and the run may exit early. But it is
# recorded as plan.reason/recorded, NOT as plan.apply/succeeded: claiming
# success before attempting anything is exactly the false receipt the project
# rule exists to prevent. The outcome is journaled after the work, below.
# Every exit path writes exactly one outcome receipt, including the path where
# nothing was approved: "I ran and applied nothing, and here is the breakdown"
# is a legitimate receipt, and its absence is what let a no-op look like a
# clean success from the outside.
journal_outcome() {
  local status=succeeded
  [ "$N_OK" -gt 0 ] || status=no-op
  # A survivor is not the same as a failure. audit declining to kill a
  # protected group is a CORRECT outcome; the work simply was not confirmed.
  # Filing that as "failed" made the receipt misdescribe a working refusal.
  { [ "$N_SURVIVED" -gt 0 ] || [ "$N_VETOED" -gt 0 ]; } && status=incomplete
  [ "$N_FAILED" -gt 0 ] && status=failed
  journal_action plan.apply "plan:$(basename "$PLAN")" "$status" \
    "applied=$N_OK refused=$N_DRIFT gone=$N_GONE held=$N_HELD vetoed=$N_VETOED survived=$N_SURVIVED failed=$N_FAILED"
}

REASON="$(plan_reason "$PLAN")"
if [ -n "$REASON" ]; then
  journal_action plan.reason "plan:$(basename "$PLAN")" recorded "$REASON"
fi

if [ "$N_OK" -eq 0 ]; then
  s_dim "  nothing approved is still what the plan described"
  journal_outcome
  printf '0 applied · %s refused (drift) · %s gone · %s held · 0 survived · 0 failed\n' "$N_DRIFT" "$N_GONE" "$N_HELD"
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
  expects=""
  for t in $declare_targets; do
    case "$t" in
      "$cat":*) pgx="${t#*:}"; expects="${expects:+$expects,}${pgx%%:*}:${t##*:}" ;;
    esac
  done
  s_would "  delegating: audit --kill $cat --pgid $list"
  if ! "$AUDIT" --kill "$cat" --pgid "$list" --expect "$expects"; then
    s_skip "  delegation failed for $cat (pgid $list)"
    N_FAILED=$((N_FAILED + 1))
  fi
  # Receipts are postcondition-based. audit returns 0 when it SKIPS a protected
  # group, so a successful call proves nothing was refused -- only that nothing
  # errored. Confirm each group is actually gone before calling it applied.
  OLD_IFS="$IFS"; IFS=','
  for pgx in $list; do
    IFS="$OLD_IFS"
    if fp_for_pgid "$pgx" >/dev/null 2>&1; then
      s_skip "  pgid $pgx — survived; audit declined to kill it"
      N_SURVIVED=$((N_SURVIVED + 1))
      N_OK=$((N_OK - 1))
    fi
    IFS=','
  done
  IFS="$OLD_IFS"
done

# --- worktrees -------------------------------------------------------------
#
# apply does not reimplement removal policy either: it re-runs the vetoes and
# hands the work to `git worktree remove`, WITHOUT --force. git refuses a dirty
# or locked worktree on its own, and that refusal is a second layer under the
# veto rather than something to argue past.
wt_repo() {
  local listing
  listing="$(git -C "$1" worktree list --porcelain 2>/dev/null)" || return 1
  # The first "worktree <path>" block is always the main worktree. Taken with
  # parameter expansion rather than `| head -1`: closing the pipe early would
  # SIGPIPE git under the pipefail this script runs with.
  printf '%s' "${listing%%$'\n'*}" | sed -n 's/^worktree //p'
}

while IFS= read -r t; do
  [ -n "$t" ] || continue
  want_fp="${t%%:*}"
  wtpath="${t#*:}"
  if ! have_fp="$(fp_for_worktree "$wtpath" 2>/dev/null)" || [ -z "$have_fp" ]; then
    if [ -e "$wtpath" ] || [ -L "$wtpath" ]; then
      s_skip "  $wtpath — refused, identity-unavailable (cannot verify the worktree)"
      N_FAILED=$((N_FAILED + 1))
    else
      s_skip "  $wtpath — gone, refused (no longer a worktree)"
      N_GONE=$((N_GONE + 1))
    fi
    N_OK=$((N_OK - 1))
    continue
  fi
  if [ "$have_fp" != "$want_fp" ]; then
    s_skip "  $wtpath — refused, fingerprint moved ($want_fp -> $have_fp)"
    s_dim  "      it was committed to, dirtied or replaced since the plan; re-plan"
    N_DRIFT=$((N_DRIFT + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  repo="$(wt_repo "$wtpath")" || repo=""
  if [ -z "$repo" ]; then
    s_skip "  $wtpath — refused, cannot locate the owning repository"
    N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  # Refresh after process cleanup and for each target. The earlier map can be
  # stale by now; a failed refresh must not become an empty, safe-looking map.
  ws_pid_cwd --strict > "$T/wt-cwd" 2>/dev/null || rm -f "$T/wt-cwd"
  # A ticked box gets the item considered; structural checks still apply.
  reason="$(veto_for worktree "$wtpath" "$repo" "$T/wt-cwd")"
  if [ -n "$reason" ]; then
    s_skip "  $wtpath — refused by the $reason veto, approval does not override it"
    N_VETOED=$((N_VETOED + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  # lsof and filesystem scans can take time. A replacement during those
  # checks is still a different target, even if it passes every veto itself.
  if ! have_fp="$(fp_for_worktree "$wtpath" 2>/dev/null)" || [ -z "$have_fp" ]; then
    s_skip "  $wtpath — refused, identity-unavailable at the removal boundary"
    N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  if [ "$have_fp" != "$want_fp" ]; then
    s_skip "  $wtpath — refused, identity changed during safety checks; re-plan"
    N_DRIFT=$((N_DRIFT + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  s_would "  removing worktree: $wtpath"
  rm_err="$(git -C "$repo" worktree remove -- "$wtpath" 2>&1)" || rm_err="${rm_err:-removal failed}"
  # Postcondition, not return code: git can report success while leaving the
  # directory behind if a file inside it is held open.
  if [ -e "$wtpath" ]; then
    s_skip "  $wtpath — survived removal: ${rm_err:-still present}"
    journal_action worktree.remove "$wtpath" failed "${rm_err:-target still exists}"
    N_SURVIVED=$((N_SURVIVED + 1)); N_OK=$((N_OK - 1))
    continue
  fi
  journal_action worktree.remove "$wtpath" succeeded "repo=$repo"
done <<WT_EOF
$wt_targets
WT_EOF

journal_outcome
printf '%s applied · %s refused (drift) · %s gone · %s held · %s vetoed · %s survived · %s failed\n' \
  "$N_OK" "$N_DRIFT" "$N_GONE" "$N_HELD" "$N_VETOED" "$N_SURVIVED" "$N_FAILED"
# Receipts are postcondition-based: a delegation that failed did not do the
# work, so the exit status must say so.
# A run where every approved group SURVIVED did no work, and a caller cannot
# tell that from "cleaned up" if both exit 0. Survivors are counted as a
# failure of the run, matching the postcondition rule: the receipt describes
# what was confirmed, and nothing was.
if [ "$N_FAILED" -ne 0 ] || [ "$N_SURVIVED" -ne 0 ] || [ "$N_VETOED" -ne 0 ]; then
  exit 1
fi
