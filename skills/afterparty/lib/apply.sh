#!/usr/bin/env bash
# apply.sh - execute the boxes a person checked in a plan, and nothing else.
#
# apply delegates process signals to audit-processes.sh and removes checked
# worktrees/artifacts through their own handlers. All checked metadata is
# validated before any action, then each target is rechecked independently.
# A later refusal does not roll back earlier completed actions.
#
# Process groups require fresh identity, attribution and two-signal eligibility;
# filesystem targets require fresh identity and their structural/occupancy
# vetoes. Worktree/artifact removal has no transcript-age or CPU gate.
# Changed fingerprints, held targets and failed checks return nonzero.
# Already absent targets and unchecked boxes are no-ops.
#
# Usage:
#   apply.sh [--json] <plan.md>
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/fingerprint.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"
. "$DIR/state.sh"
. "$DIR/journal.sh"
. "$DIR/vetoes.sh"
. "$DIR/plan-format.sh"
. "$DIR/apply-events.sh"

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

APPLY_JSON=0
if [ "${1:-}" = --json ]; then APPLY_JSON=1; shift; fi
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo 'Usage: afterparty apply [--json] <plan.md>'
  echo 'Afterparty checks each target again. It applies only checked choices.'
  echo 'A changed identity or a failed safety check prevents cleanup for that target.'
  echo '--json requires Python 3. It writes versioned cleanup receipts as JSON Lines.'
  exit 0
fi
if [ "$APPLY_JSON" -eq 1 ]; then exec 3>&1 1>&2; fi
reject_invocation() {
  echo "apply: $2" >&2
  if [ "$APPLY_JSON" -eq 1 ]; then ae_python early-reject "$1" "$2" >&3 || true; fi
  exit 2
}
PLAN="${1:-}"
if [ "$#" -ne 1 ]; then
  reject_invocation plan-required "needs a plan file (write one with 'afterparty plan')"
fi
if [ ! -f "$PLAN" ]; then
  reject_invocation plan-unavailable "no such plan: $PLAN"
fi
PLAN_NAME="$(basename "$PLAN")"

# Locate the audit entrypoint. A shim earlier on PATH wins, which is how the
# tests observe delegation without signalling anything real.
AUDIT="$(command -v audit-processes.sh 2>/dev/null || printf '%s' "$DIR/audit-processes.sh")"

N_OK=0 N_DRIFT=0 N_GONE=0 N_HELD=0 N_FAILED=0 N_SURVIVED=0 N_VETOED=0 N_RECORD_FAILED=0
record() {
  AE_RECEIPT=not-attempted
  if journal_action "$@"; then
    [ "${AFTERPARTY_JOURNAL:-1}" = 0 ] || AE_RECEIPT=recorded
  else
    AE_RECEIPT=failed
    N_RECORD_FAILED=$((N_RECORD_FAILED + 1))
  fi
}
declare_targets=""
wt_targets=""

NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"; [ -z "$AE_DIR" ] || rm -rf "$AE_DIR"' EXIT
if [ "$APPLY_JSON" -eq 1 ]; then
  ae_setup "$PLAN" || reject_invocation event-setup-unavailable 'structured output setup unavailable; no cleanup attempted'
  PLAN="$AE_DIR/plan.md"
fi
if ! plan_read_checked "$PLAN" > "$T/checked" 2> "$T/validation.err"; then
  cat "$T/validation.err" >&2
  ae_reject invalid-plan "$(cat "$T/validation.err")"
  exit 2
fi
ae_start "$T/checked"
WS_STATUS=ok
ws_index > "$T/ws" 2> "$T/ws.err" || { : > "$T/ws"; WS_STATUS=unavailable; }
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
      # in a live workspace after planning while the member anchoring its
      # fingerprint stays exactly the same. Killing on the strength of
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

# All checked rows were validated before live inspection or any mutation.
while IFS=$'\t' read -r type target want_fp category scope; do
  case "$type" in
    artifact)
      printf '%s\t%s\t%s\n' "$want_fp" "$scope" "$target" >> "$T/artifacts"
      N_OK=$((N_OK + 1))
      continue ;;
    worktree)
      wt_targets="${wt_targets}${want_fp}:${target}"$'\n'
      N_OK=$((N_OK + 1))
      continue ;;
    process-group)
      pg="$target"
      if ! have_fp="$(fp_for_pgid "$pg" 2>/dev/null)" || [ -z "$have_fp" ]; then
        fp_group_state "$pg"; state_rc=$?
        if [ "$state_rc" -eq 1 ]; then
          s_skip "  pgid $pg — gone (verified absent)"
          N_GONE=$((N_GONE + 1))
          apply_emit_target "$type" "$target" gone already-absent 'Group was verified absent before delegation.' 0 1 not-attempted
        else
          s_skip "  pgid $pg — refused, identity-unavailable"
          N_FAILED=$((N_FAILED + 1))
          apply_emit_target "$type" "$target" failed identity-unavailable 'Cannot verify the reviewed group identity.' 0 0 not-attempted
        fi
        continue
      fi
      if [ "$have_fp" != "$want_fp" ]; then
        s_skip "  pgid $pg — refused, fingerprint changed ($want_fp -> $have_fp)"
        s_dim  "      The process group changed since review. Create a new plan."
        N_DRIFT=$((N_DRIFT + 1))
        apply_emit_target "$type" "$target" drift identity-changed 'The process group changed since review.' 0 0 not-attempted
        continue
      fi
      # Re-check eligibility against the live world, not the plan's snapshot.
      if [ "$WS_STATUS" != ok ]; then
        s_skip "  pgid $pg — refused, activity-unavailable"
        [ ! -s "$T/ws.err" ] || s_dim "      $(head -n 1 "$T/ws.err")"
        N_FAILED=$((N_FAILED + 1))
        apply_emit_target "$type" "$target" failed activity-unavailable 'Recorded activity could not be inspected.' 0 0 not-attempted
        continue
      fi
      if ! ws_pid_cwd --strict > "$T/cwd" 2>/dev/null || ! facts="$(group_facts "$pg")"; then
        s_skip "  pgid $pg — refused, scan-incomplete"
        N_FAILED=$((N_FAILED + 1))
        apply_emit_target "$type" "$target" failed scan-incomplete 'Group attribution could not be completed.' 0 0 not-attempted
        continue
      fi
      touched="${facts%%	*}"; cpu="${facts##*	}"
      if [ "$touched" = "mixed" ]; then
        s_skip "  pgid $pg — held, workspace attribution is incomplete or mixed"
        s_dim  "      Afterparty cannot attribute all group members to one workspace."
        N_HELD=$((N_HELD + 1))
        apply_emit_target "$type" "$target" held mixed-workspaces 'Afterparty cannot attribute all group members to one workspace.' 0 0 not-attempted
        continue
      fi
      [ "$touched" = "-" ] && touched=""
      verdict="$(elig_verdict "$touched" "${cpu:-0}" "$NOW")"
      if [ "$verdict" != "eligible" ]; then
        s_skip "  pgid $pg — held, no longer eligible ($verdict)"
        s_dim  "      Current activity or CPU use no longer meets the cleanup conditions."
        N_HELD=$((N_HELD + 1))
        apply_emit_target "$type" "$target" held no-longer-eligible "Current eligibility: $verdict." 0 0 not-attempted
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
          apply_emit_target "$type" "$target" failed unsupported-category 'No executable process category matches the approval.' 0 0 not-attempted
          continue
          ;;
      esac
      declare_targets="${declare_targets}${category}:${pg}:${have_fp} "
      N_OK=$((N_OK + 1))
      ;;
  esac
done < "$T/checked"

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
  local status=succeeded detail
  [ "$N_OK" -gt 0 ] || status=no-op
  # A survivor is not the same as a failure. audit declining to kill a
  # protected group is a CORRECT outcome; the work simply was not confirmed.
  # Filing that as "failed" made the receipt misdescribe a working refusal.
  { [ "$N_SURVIVED" -gt 0 ] || [ "$N_VETOED" -gt 0 ] || [ "$N_DRIFT" -gt 0 ] || [ "$N_HELD" -gt 0 ]; } && status=incomplete
  [ "$N_FAILED" -gt 0 ] && status=failed
  detail="applied=$N_OK refused=$N_DRIFT gone=$N_GONE held=$N_HELD vetoed=$N_VETOED survived=$N_SURVIVED failed=$N_FAILED"
  if [ "$AE_ENABLED" -eq 1 ]; then
    [ "$((AE_INVOCATION_ERRORS + AE_JOURNAL_FAILURES + N_RECORD_FAILED))" -eq 0 ] || status=failed
    detail="$detail invocation_errors=$AE_INVOCATION_ERRORS journal_failures=$((N_RECORD_FAILED + AE_JOURNAL_FAILURES))"
  fi
  record plan.apply "plan:$PLAN_NAME" "$status" "$detail"
}

REASON="$(plan_reason "$PLAN")"
if [ -n "$REASON" ]; then
  record plan.reason "plan:$PLAN_NAME" recorded "$REASON"
fi

if [ "$N_OK" -eq 0 ]; then
  s_dim "  No checked target passed the current cleanup checks."
  journal_outcome
  printf '0 applied · %s refused (drift) · %s gone · %s held · 0 survived · %s failed · %s receipt failures\n' "$N_DRIFT" "$N_GONE" "$N_HELD" "$N_FAILED" "$N_RECORD_FAILED"
  final_rc=0
  [ "$((N_DRIFT + N_HELD + N_FAILED + N_RECORD_FAILED))" -eq 0 ] || final_rc=1
  apply_emit_summary "$final_rc"
  exit "$final_rc"
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
        # The first observed member anchors the fingerprint (pgid + start time
        # + command); it is not a hash of all members. Child churn alone need
        # not invalidate approval; audit rechecks protection before signals.
        if ! now_fp="$(fp_for_pgid "$pg" 2>/dev/null)" || [ "$now_fp" != "$expect" ]; then
          s_skip "  pgid $pg — dropped at the last check, identity changed"
          N_DRIFT=$((N_DRIFT + 1))
          N_OK=$((N_OK - 1))
          apply_emit_target process-group "$pg" drift identity-changed 'Group identity changed at the delegation boundary.' 0 0 not-attempted
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
  delegation_rc=0
  ae_child_prepare "$cat" "$list" "$expects"
  if [ "$AE_ENABLED" -eq 1 ]; then
    AFTERPARTY_APPLY_DIR="$AE_DIR" AFTERPARTY_APPLY_RUN_ID="$AE_RUN_ID" \
      "$AUDIT" --kill "$cat" --pgid "$list" --expect "$expects" || delegation_rc=$?
  else
    "$AUDIT" --kill "$cat" --pgid "$list" --expect "$expects" || delegation_rc=$?
  fi
  channel_failed=0
  if [ "$delegation_rc" -ne 0 ]; then
    s_skip "  delegation failed for $cat (pgid $list)"
    N_FAILED=$((N_FAILED + 1))
    AE_INVOCATION_ERRORS=$((AE_INVOCATION_ERRORS + 1))
  fi
  # Receipts are postcondition-based. audit returns 0 when it SKIPS a protected
  # group, so a successful call proves nothing was refused -- only that nothing
  # errored. Confirm each group is actually gone before calling it applied.
  OLD_IFS="$IFS"; IFS=','
  for pgx in $list; do
    IFS="$OLD_IFS"
    fp_group_state "$pgx"; state_rc=$?
    outcome=applied code=postcondition-confirmed attempted=unknown confirmed=0 receipt=unavailable
    if [ "$AE_ENABLED" -eq 1 ]; then
      if child_result="$(ae_python child-read "$AE_DIR" "$AE_RUN_ID" "$pgx")"; then
        IFS=$'\t' read -r outcome code attempted child_confirmed receipt <<< "$child_result"
        [ "$receipt" != failed ] || AE_JOURNAL_FAILURES=$((AE_JOURNAL_FAILURES + 1))
      else
        if [ "$channel_failed" -eq 0 ] && [ "$delegation_rc" -eq 0 ]; then AE_INVOCATION_ERRORS=$((AE_INVOCATION_ERRORS + 1)); fi
        channel_failed=1
        outcome=failed code=child-evidence-unavailable
      fi
    fi
    if [ "$state_rc" -eq 0 ]; then
      s_skip "  pgid $pgx — survived; cleanup was not completed"
      N_SURVIVED=$((N_SURVIVED + 1)); N_OK=$((N_OK - 1))
      case "$outcome" in applied|gone) outcome=survived code=group-survived ;; esac
    elif [ "$state_rc" -ne 1 ]; then
      s_skip "  pgid $pgx — completion unavailable; process inspection failed"
      N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
      outcome=failed code=postcondition-unavailable
    else
      confirmed=1
      case "$attempted" in 1) outcome=applied ;; 0) outcome=gone ;; esac
    fi
    apply_emit_target process-group "$pgx" "$outcome" "$code" "Delegated outcome: $code; parent absence check confirmed=$confirmed." \
      "$attempted" "$confirmed" "$receipt" "$delegation_rc"
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
      apply_emit_target worktree "$wtpath" failed identity-unavailable 'Cannot verify the reviewed worktree identity.' 0 0 not-attempted
    else
      s_skip "  $wtpath — gone, refused (no longer a worktree)"
      N_GONE=$((N_GONE + 1))
      apply_emit_target worktree "$wtpath" gone already-absent 'Worktree path was already absent.' 0 1 not-attempted
    fi
    N_OK=$((N_OK - 1))
    continue
  fi
  if [ "$have_fp" != "$want_fp" ]; then
    s_skip "  $wtpath — refused, fingerprint changed ($want_fp -> $have_fp)"
    s_dim  "      The worktree changed or was replaced since review. Create a new plan."
    N_DRIFT=$((N_DRIFT + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" drift identity-changed 'Worktree changed since review.' 0 0 not-attempted
    continue
  fi
  repo="$(wt_repo "$wtpath")" || repo=""
  if [ -z "$repo" ]; then
    s_skip "  $wtpath — refused, cannot locate the owning repository"
    N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" failed repository-unavailable 'Cannot locate the owning repository.' 0 0 not-attempted
    continue
  fi
  # Refresh after process cleanup and for each target. The earlier map can be
  # stale by now; a failed refresh must not become an empty, safe-looking map.
  ws_pid_cwd --strict > "$T/wt-cwd" 2>/dev/null || rm -f "$T/wt-cwd"
  # A ticked box gets the item considered; structural checks still apply.
  reason="$(veto_for worktree "$wtpath" "$repo" "$T/wt-cwd")"
  if [ -n "$reason" ]; then
    s_skip "  $wtpath — refused by the $reason veto. Approval does not override safety checks."
    N_VETOED=$((N_VETOED + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" vetoed "$reason" 'A fresh filesystem policy check refused removal.' 0 0 not-attempted
    continue
  fi
  # lsof and filesystem scans can take time. A replacement during those
  # checks is still a different target, even if it passes every veto itself.
  if ! have_fp="$(fp_for_worktree "$wtpath" 2>/dev/null)" || [ -z "$have_fp" ]; then
    s_skip "  $wtpath — refused, identity-unavailable immediately before removal"
    N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" failed identity-unavailable 'Afterparty could not check worktree identity immediately before removal.' 0 0 not-attempted
    continue
  fi
  if [ "$have_fp" != "$want_fp" ]; then
    s_skip "  $wtpath — refused, identity changed during safety checks; re-plan"
    N_DRIFT=$((N_DRIFT + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" drift identity-changed 'Worktree identity changed during safety checks.' 0 0 not-attempted
    continue
  fi
  s_would "  removing worktree: $wtpath"
  removal_rc=0
  rm_err="$(git -C "$repo" worktree remove -- "$wtpath" 2>&1)" || { removal_rc=$?; rm_err="${rm_err:-removal failed}"; }
  # Postcondition, not return code: git can report success while leaving the
  # directory behind if a file inside it is held open.
  if [ -e "$wtpath" ] || [ -L "$wtpath" ]; then
    s_skip "  $wtpath — survived removal: ${rm_err:-still present}"
    record worktree.remove "$wtpath" failed "${rm_err:-target still exists}"
    N_SURVIVED=$((N_SURVIVED + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" survived target-remains 'Worktree removal did not confirm path absence.' 1 0 "$AE_RECEIPT"
    continue
  fi
  if [ "$removal_rc" -ne 0 ]; then
    s_skip "  $wtpath — removal failed after path disappeared (exit $removal_rc): $rm_err"
    record worktree.remove "$wtpath" failed "exit_status=$removal_rc; target path confirmed absent; $rm_err"
    N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
    apply_emit_target worktree "$wtpath" failed removal-failed "Git worktree removal returned exit status $removal_rc after the path disappeared." 1 1 "$AE_RECEIPT"
    continue
  fi
  record worktree.remove "$wtpath" succeeded "repo=$repo"
  apply_emit_target worktree "$wtpath" applied postcondition-confirmed 'Worktree path was confirmed absent after removal.' 1 1 "$AE_RECEIPT"
done <<WT_EOF
$wt_targets
WT_EOF

# Artifact destruction uses the same checked identities and fresh hard vetoes.
if [ -f "$T/artifacts" ]; then
  while IFS=$'\t' read -r want_fp scope target; do
    reason=""
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      s_skip "  $target — gone (verified absent)"
      N_GONE=$((N_GONE + 1)); N_OK=$((N_OK - 1))
      apply_emit_target artifact "$target" gone already-absent 'Artifact path was already absent.' 0 1 not-attempted
      continue
    fi
    if ! veto_artifact_name "$target"; then reason=unsupported-artifact; fi
    if [ -z "$reason" ]; then reason="$(veto_for artifact "$target" "$scope")"; fi
    if [ -z "$reason" ]; then
      if ! ws_pid_cwd --strict > "$T/artifact-cwd" 2>/dev/null; then reason=occupancy-unavailable
      elif veto_is_occupied "$T/artifact-cwd" "$(veto_phys "$target")" "$target"; then reason=occupied; fi
    fi
    # Occupancy may be slow; refresh filesystem evidence after it completes.
    if [ -z "$reason" ]; then reason="$(veto_for artifact "$target" "$scope")"; fi
    if [ -n "$reason" ]; then
      s_skip "  $target — refused by the $reason veto"
      N_VETOED=$((N_VETOED + 1)); N_OK=$((N_OK - 1))
      apply_emit_target artifact "$target" vetoed "$reason" 'A fresh filesystem policy check refused deletion.' 0 0 not-attempted
      continue
    fi
    if ! have_fp="$(fp_for_artifact "$target")"; then
      s_skip "  $target — refused, identity-unavailable"
      N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
      apply_emit_target artifact "$target" failed identity-unavailable 'Cannot verify artifact identity.' 0 0 not-attempted
      continue
    fi
    if [ "$have_fp" != "$want_fp" ]; then
      s_skip "  $target — refused, fingerprint changed"
      N_DRIFT=$((N_DRIFT + 1)); N_OK=$((N_OK - 1))
      apply_emit_target artifact "$target" drift identity-changed 'Artifact changed since review.' 0 0 not-attempted
      continue
    fi
    s_would "  deleting artifact: $target"
    if rm -rf -- "$target" 2>/dev/null && [ ! -e "$target" ] && [ ! -L "$target" ]; then
      record artifact.clean "$target" succeeded "root=$scope"
      apply_emit_target artifact "$target" applied postcondition-confirmed 'Artifact path was confirmed absent after deletion.' 1 1 "$AE_RECEIPT"
    else
      s_skip "  $target — failed to delete (target remains or removal failed)"
      record artifact.clean "$target" failed "removal was not confirmed"
      N_FAILED=$((N_FAILED + 1)); N_OK=$((N_OK - 1))
      apply_emit_target artifact "$target" failed removal-unconfirmed 'Artifact deletion was not confirmed.' 1 0 "$AE_RECEIPT"
    fi
  done < "$T/artifacts"
fi

journal_outcome
printf '%s applied · %s refused (drift) · %s gone · %s held · %s vetoed · %s survived · %s failed · %s receipt failures\n' \
  "$N_OK" "$N_DRIFT" "$N_GONE" "$N_HELD" "$N_VETOED" "$N_SURVIVED" "$N_FAILED" "$N_RECORD_FAILED"
# Receipts are postcondition-based: a delegation that failed did not do the
# work, so the exit status must say so.
# A run where every approved group SURVIVED did no work, and a caller cannot
# tell that from "cleaned up" if both exit 0. Survivors are counted as a
# failure of the run, matching the postcondition rule: the receipt describes
# what was confirmed, and nothing was.
final_rc=0
if [ "$((N_FAILED + N_SURVIVED + N_VETOED + N_DRIFT + N_HELD + N_RECORD_FAILED + AE_INVOCATION_ERRORS + AE_JOURNAL_FAILURES))" -ne 0 ]; then final_rc=1; fi
apply_emit_summary "$final_rc"
exit "$final_rc"
