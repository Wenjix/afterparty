# shellcheck shell=bash
# Optional structured apply output. Execution policy remains in the callers.
APPLY_EVENTS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE_ENABLED=0 AE_DIR="" AE_RUN_ID="" AE_INVOCATION_ERRORS=0 AE_JOURNAL_FAILURES=0
AE_RECEIPT=not-attempted AE_CHILD_SEEN=""

ae_python() { PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 python3 "$APPLY_EVENTS_LIB/apply_events.py" "$@"; }

ae_abort() {
  echo 'apply: event output unavailable. Afterparty could not produce a completion receipt. Check the action journal for earlier confirmed changes.' >&2
  exit 1
}

ae_setup() {
  local base
  command -v python3 >/dev/null 2>&1 || { echo 'apply: --json requires Python 3. Afterparty did not attempt cleanup.' >&2; return 1; }
  base="$(state_apply_dir "$PWD")" && state_secure_dir "$base" || return 1
  AE_DIR="$(umask 077; mktemp -d "$base/run.XXXXXX")" || return 1
  AE_RUN_ID="$(ae_python init "$AE_DIR" "$1")" || return 1
  AE_ENABLED=1
}

ae_start() { [ "$AE_ENABLED" -eq 0 ] || ae_python start "$AE_DIR" "$1" >&3 || ae_abort; }
ae_reject() { [ "$AE_ENABLED" -eq 0 ] || ae_python reject "$AE_DIR" "$@" >&3 || ae_abort; }

apply_emit_target() { # type target outcome reason detail attempted confirmed receipt [delegation-exit]
  [ "$AE_ENABLED" -eq 1 ] || return 0
  ae_python target "$AE_DIR" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}" >&3 || ae_abort
}

apply_emit_summary() { # exit status
  [ "$AE_ENABLED" -eq 1 ] || return 0
  ae_python summary "$AE_DIR" "$1" "$AE_INVOCATION_ERRORS" "$((N_RECORD_FAILED + AE_JOURNAL_FAILURES))" \
    "$N_OK" "$N_DRIFT" "$N_GONE" "$N_HELD" "$N_VETOED" "$N_SURVIVED" "$N_FAILED" >&3 || ae_abort
}

ae_child_prepare() { [ "$AE_ENABLED" -eq 0 ] || ae_python child-prepare "$AE_DIR" "$@" || ae_abort; }

ae_child_setup() {
  [ -n "${AFTERPARTY_APPLY_DIR:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 1
  ae_python child-check "$AFTERPARTY_APPLY_DIR" "${AFTERPARTY_APPLY_RUN_ID:-}" "$KILL_CATS" "$PGID_FILTER" "$EXPECT_MAP"
}

ae_process_decision() { AE_OUTCOME="$1" AE_REASON="$2" AE_DETAIL="$3"; }
ae_process_reset() {
  AE_OUTCOME=failed AE_REASON=inspection-unavailable AE_DETAIL='Afterparty could not inspect the processes.'
  AE_ATTEMPTED=0 AE_CONFIRMED=0 AE_RECEIPT=not-attempted
}

ae_child_emit() {
  [ -n "${AFTERPARTY_APPLY_DIR:-}" ] || return 0
  ae_python child-target "$AFTERPARTY_APPLY_DIR" "$AFTERPARTY_APPLY_RUN_ID" "$1" \
    "$AE_OUTCOME" "$AE_REASON" "$AE_DETAIL" "$AE_ATTEMPTED" "$AE_CONFIRMED" "$AE_RECEIPT" - || return 1
  AE_CHILD_SEEN="$AE_CHILD_SEEN $1 "
}

ae_child_finish() {
  [ -n "${AFTERPARTY_APPLY_DIR:-}" ] || return 0
  local pg previous_ifs="${IFS-$' \t\n'}" state_rc
  IFS=','
  for pg in $PGID_FILTER; do
    IFS="$previous_ifs"
    case "$AE_CHILD_SEEN" in *" $pg "*) IFS=','; continue ;; esac
    ae_process_reset
    if [ "$PS_STATUS" = ok ]; then
      fp_group_state "$pg"; state_rc=$?
      if [ "$state_rc" -eq 1 ]; then
        ae_process_decision gone already-absent 'The group was absent before Afterparty sent a signal.'
        AE_CONFIRMED=1
      elif [ "$state_rc" -eq 0 ]; then
        ae_process_decision vetoed not-selected 'The category and protection checks did not select this group.'
      fi
    fi
    ae_child_emit "$pg" || { IFS="$previous_ifs"; return 1; }
    IFS=','
  done
  IFS="$previous_ifs"
}
