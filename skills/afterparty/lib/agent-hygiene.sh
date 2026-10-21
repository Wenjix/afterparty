#!/usr/bin/env bash
# agent-hygiene.sh - entrypoint for process tracking, cleanup and documentation
# evidence. Skills route deterministic work here; documentation review and
# selected document edits belong to the invoking agent.
#
# Usage:
#   agent-hygiene.sh list [--json] [--all|--root DIR] [--kind KIND]
#   agent-hygiene.sh audit [--strict] [--json|--report]
#   agent-hygiene.sh audit --kill tests,dev,browser [--pgid ID[,ID...]] [--keep ID]
#   agent-hygiene.sh add --pid 123 --kind dev --port 3000 --purpose "verify UI" -- pnpm dev website
#   agent-hygiene.sh stop [--kill] [--keep PGID] [--all|--root DIR] [--kind KIND]
#   agent-hygiene.sh prune [--all|--root DIR]
#   agent-hygiene.sh git [--clean] [--age <days>] [--root <dir>] [--json]
#   agent-hygiene.sh artifacts [--root DIR] [--caches-only] [--plan|--clean]
#   agent-hygiene.sh builds [--projects-root DIR ...] [--max-depth N] [--json|--plain] [--ascii]
#   agent-hygiene.sh devclean [--orphans|--deep|--optimize|--disk|--history] [--apply --target ID]
#   agent-hygiene.sh glance [--oneline] [--json]
#   agent-hygiene.sh docs [--root DIR] [--since REF|--full] [--json] [--report]
#   agent-hygiene.sh docs --show|--report-path|--template SCAN_ID|--check SCAN_ID|--save-review FILE
#   agent-hygiene.sh plan [--root DIR] [--all] [--artifacts-only] [--caches-only] [--json]
#   agent-hygiene.sh review [--root DIR] [--all] [--artifacts-only] [--caches-only] [--output FILE] [--ascii]
#   agent-hygiene.sh apply [--json] <plan.md>
#   agent-hygiene.sh doctor [--strict]
#   agent-hygiene.sh report [--show|--remind]
#   agent-hygiene.sh report-path
#   agent-hygiene.sh actions [--all|--workspace DIR] [--since YYYY-MM-DD] [--path]
#   agent-hygiene.sh actions-path
#   agent-hygiene.sh --version
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TTY-gated styling, finale cards, and the composite tally (plain on pipes).
. "$DIR/style.sh"
# Shared private-state locations (reports, ledger, action journal).
. "$DIR/state.sh"
. "$DIR/report.sh"
. "$DIR/journal.sh"

usage() {
  cat <<'USAGE'
Usage: afterparty <command> [options]

Inspect
  audit [--strict] [--json|--report]   Report processes, listeners, and Git findings
  glance [--oneline|--json]           Workspace activity; read-only
  list [--json] [--all|--root DIR]    Recorded process groups
  git [--root DIR] [--json]           Report Git findings; --clean is report-only
  artifacts [--root DIR]             Build/cache inventory; --clean is report-only
  builds [--projects-root DIR ...]    Build output across projects; read-only TUI
         [--max-depth N] [--json|--plain] [--ascii]
  doctor [--strict]                  Combined diagnostics

Review
  plan [--root DIR] [--all] [--json]  Unchecked cleanup proposals
       [--artifacts-only] [--caches-only]
  review [--root DIR] [--all]         Mark targets, review choices, and save a plan
         [--output FILE] [--ascii] [--artifacts-only] [--caches-only]
  docs [--root DIR] [--since REF|--full] [--json] [--report]
                                    Collect documentation evidence for agent review
  devclean [--orphans|--deep|--optimize|--disk|--history]
                                    Preview cleanup targets and their IDs

Act on reviewed choices
  apply [--json] <plan.md>            Check targets again. Apply only checked choices.
  stop --kill [--keep PGID] [--all|--root DIR] [--kind KIND]
  audit --kill tests,dev,browser [--pgid ID[,ID...]] [--keep ID]
  devclean <mode> --apply --target ID
  add --pid PID --kind KIND --port PORT --purpose TEXT -- command
  prune [--all|--root DIR]            Delete records for absent process groups

History
  report [--show|--remind]            Read the saved audit
  report-path                       Locate the saved audit
  actions [--all|--workspace DIR] [--since YYYY-MM-DD] [--path]
  actions-path                      Locate cleanup receipts
  --version                         Show the installed version

Start with afterparty glance. Then run afterparty review.
Review saves your choices. Run afterparty apply <saved-plan> to apply them.
Use afterparty <command> --help for command options.
Review the targets before you run a cleanup command.
USAGE
}

# The one finale card for the composite audit, fed by the children's tally.
print_finale_card() {
  local killed found live gitf bytes stashes listeners prot unavailable proc_failed git_failed failed segs
  killed="$(tally_get procs.killed)"
  prot="$(tally_get procs.protected)"
  found="$(tally_get procs.found)"
  live="$(tally_get ledger.live)"
  gitf="$(tally_get git.findings)"
  bytes="$(tally_get git.litter_bytes)"
  stashes="$(tally_get git.stashes)"
  listeners="$(tally_get procs.listeners)"
  unavailable="$(tally_get procs.unavailable)"
  proc_failed="$(tally_get procs.failed)"
  git_failed="$(tally_get git.failed)"
  failed=$((proc_failed + git_failed))
  echo
  s_card_open
  if [ "$killed" -gt 0 ] || [ "$prot" -gt 0 ] || [ "$failed" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 Cleanup receipt: afterparty audit --kill${C_RESET}"
    segs="$(s_segments \
      "$([ "$killed" -gt 0 ] && echo "$G_OK $killed stopped")" \
      "$([ "$prot" -gt 0 ] && echo "$G_SKIP $prot protected")" \
      "$([ "$failed" -gt 0 ] && echo "$G_SKIP $failed failed")" \
      "$([ "$gitf" -gt 0 ] && echo "$G_ACT $(s_n "$gitf" 'Git finding' 'Git findings')")" \
      "$([ "$live" -gt 0 ] && echo "$G_ACT $(s_n "$live" 'live ledger entry' 'live ledger entries')")")"
    s_card_line "   $segs"
    if [ "$killed" -gt 0 ]; then
      s_card_line "   $(s_n "$killed" 'process group stopped' 'process groups stopped')"
    elif [ "$prot" -gt 0 ]; then
      s_card_line "   No process group stopped. $(s_n "$prot" 'group is protected' 'groups are protected')."
    else
      s_card_line "   Afterparty did not confirm any process group exit."
    fi
    [ "$failed" -gt 0 ] && s_card_line "   Afterparty could not confirm $failed cleanup action(s)."
    if [ "$gitf" -gt 0 ]; then
      s_card_line "   Remaining: $(s_n "$gitf" 'Git finding' 'Git findings')"
    fi
    if [ "$live" -gt 0 ]; then
      s_card_line "   Remaining: $(s_n "$live" 'live ledger entry' 'live ledger entries')"
    fi
    s_card_line
    s_card_line "   Review the results above."
  elif [ $((found + live + gitf)) -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 Audit results${C_RESET}"
    segs="$(s_segments \
      "$([ "$found" -gt 0 ] && echo "$G_ACT $(s_n "$found" 'process candidate' 'process candidates')")" \
      "$([ "$live" -gt 0 ] && echo "$G_ACT $(s_n "$live" 'live ledger entry' 'live ledger entries')")" \
      "$([ "$gitf" -gt 0 ] && echo "$G_ACT $(s_n "$gitf" 'Git finding' 'Git findings')")" \
      "$([ "$listeners" -gt 0 ] && echo "$(s_n "$listeners" 'listener' 'listeners')")" \
      "$([ "$unavailable" -gt 0 ] && echo "$G_SKIP $unavailable unavailable")")"
    s_card_line "   $segs"
    if [ "$found" -gt 0 ]; then
      s_card_line "   $(s_n "$found" 'process candidate found' 'process candidates found')"
    fi
    if [ "$live" -gt 0 ]; then
      s_card_line "   $(s_n "$live" 'ledger entry has a live process' 'ledger entries have live processes')"
    fi
    if [ "$gitf" -gt 0 ]; then
      if [ "$bytes" -gt 0 ]; then
        s_card_line "   $(s_n "$gitf" 'Git finding' 'Git findings') (${bytes} B in conflict files)"
      else
        s_card_line "   $(s_n "$gitf" 'Git finding' 'Git findings')"
      fi
    fi
    if [ "$listeners" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$listeners" 'localhost listener detected' 'localhost listeners detected'))${C_RESET}"
    fi
    if [ "$stashes" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$stashes" 'stash retained' 'stashes retained'))${C_RESET}"
    fi
    if [ "$unavailable" -gt 0 ]; then
      s_card_line "${C_DIM}   ($unavailable scan(s) unavailable. The audit is incomplete.)${C_RESET}"
    fi
    s_card_line
    s_card_line "   Commands for reviewed targets:"
    if [ "$live" -gt 0 ]; then
      s_card_command "     ${C_CYAN}afterparty stop --kill${C_RESET}"
    fi
    if [ "$found" -gt 0 ]; then
      s_card_command "     ${C_CYAN}afterparty audit --kill tests,dev,browser --pgid <reviewed-pgid>${C_RESET}"
    fi
    if [ "$gitf" -gt 0 ]; then
      s_card_command "     ${C_CYAN}afterparty plan${C_RESET}"
      s_card_line "     git --clean is report-only"
    fi
  elif [ "$unavailable" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}⚠ The audit is incomplete.${C_RESET}"
    s_card_line "   $unavailable scan(s) unavailable"
    s_card_line "   Install the missing tools. Then run ${C_CYAN}afterparty doctor${C_RESET}."
  else
    s_card_line "${C_BOLD}${C_GRN}✓ No cleanup candidates found in the inspected scope.${C_RESET}"
    if [ "$listeners" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$listeners" 'localhost listener detected' 'localhost listeners detected'))${C_RESET}"
    fi
    if [ "$stashes" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$stashes" 'stash retained' 'stashes retained'))${C_RESET}"
    fi
    s_card_line "   See you next session."
  fi
  s_card_close
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

case "$cmd" in
  --version|-V)
    VERSION_FILE="$DIR/../VERSION"
    [ -f "$VERSION_FILE" ] || { echo "afterparty version file is missing" >&2; exit 1; }
    sed -n '1p' "$VERSION_FILE"
    ;;
  list)
    exec "$DIR/process-ledger.sh" list "$@"
    ;;
  add)
    exec "$DIR/process-ledger.sh" add "$@"
    ;;
  stop)
    exec "$DIR/process-ledger.sh" stop "$@"
    ;;
  prune)
    exec "$DIR/process-ledger.sh" prune "$@"
    ;;
  audit)
    # Composite report: ledger, stray processes, git leftovers. --json flows
    # to every part (JSON Lines compose across scripts); --report writes the
    # human report to report.md — at the repo root only when the repo
    # gitignores it (litter guard), otherwise to a workspace-keyed cache path.
    REPORT=0 JSON_FLAG=""
    ARGS=()
    for a in "$@"; do
      case "$a" in
        --report) REPORT=1 ;;
        --json) JSON_FLAG="--json"; ARGS+=("$a") ;;
        *) ARGS+=("$a") ;;
      esac
    done
    if [ "$REPORT" -eq 1 ] && [ -n "$JSON_FLAG" ]; then
      echo "--report and --json are mutually exclusive" >&2
      exit 2
    fi
    run_audit() {
      local audit_rc=0
      REPORT_STRICT="${REPORT_STRICT:-}"
      local section child_rc
      for section in ledger processes git; do
        child_rc=0
        case "$section" in
          ledger) "$DIR/process-ledger.sh" list ${JSON_FLAG:+"$JSON_FLAG"} || child_rc=$? ;;
          processes) "$DIR/audit-processes.sh" ${REPORT_STRICT:+"$REPORT_STRICT"} ${ARGS[@]+"${ARGS[@]}"} || child_rc=$? ;;
          git) "$DIR/audit-git.sh" ${JSON_FLAG:+"$JSON_FLAG"} || child_rc=$? ;;
        esac
        if [ "$child_rc" -ne 0 ]; then
          audit_rc=1
          [ -z "${REPORT_STATUS_FILE:-}" ] || printf '%s\n' "$section" >> "$REPORT_STATUS_FILE"
          printf 'audit section %s incomplete (exit %s)\n' "$section" "$child_rc" >&2
        fi
      done
      return "$audit_rc"
    }
    if [ "$REPORT" -eq 1 ]; then
      REPORT_WORK="$(mktemp -d)" || exit 1
      trap 'rm -rf "$REPORT_WORK"' EXIT
      REPORT_STATUS_FILE="$REPORT_WORK/status"
      : > "$REPORT_STATUS_FILE"
      REPORT_STRICT=--strict
      REPORT_RC=0
      (export AFTERPARTY_STYLE=never; run_audit) > "$REPORT_WORK/raw" 2>&1 || REPORT_RC=$?
      sed -e 's/^=== \(.*\) ===$/## \1/' "$REPORT_WORK/raw" > "$REPORT_WORK/body"
      REPORT_FAILED="$(paste -sd, "$REPORT_STATUS_FILE")"
      report_persist "$REPORT_WORK/body" "$REPORT_RC" "$REPORT_FAILED" || exit 1
      if [ "$REPORT_RC" -ne 0 ]; then
        echo "note: report written, but at least one audit reported a problem" >&2
      fi
      exit "$REPORT_RC"
    else
      if [ "$STYLE_ON" -eq 1 ] && [ -z "$JSON_FLAG" ]; then
        s_banner "afterparty audit" "Scan processes, listeners, and Git findings."
        if AFTERPARTY_TALLY="$(mktemp "${TMPDIR:-/tmp}/afterparty-tally.XXXXXX" 2>/dev/null)"; then
          export AFTERPARTY_TALLY
        else
          # No tally file: suppress the children's cards rather than showing
          # three separate ones.
          AFTERPARTY_TALLY=""
          export AFTERPARTY_CARD=0
        fi
      fi
      AUDIT_RC=0
      run_audit || AUDIT_RC=$?
      if [ -n "${AFTERPARTY_TALLY:-}" ]; then
        print_finale_card
        rm -f "$AFTERPARTY_TALLY"
      fi
      exit "$AUDIT_RC"
    fi
    ;;
  git)
    exec "$DIR/audit-git.sh" "$@"
    ;;
  artifacts)
    exec "$DIR/clean-artifacts.sh" "$@"
    ;;
  builds)
    exec bash "$DIR/builds.sh" "$@"
    ;;
  devclean)
    exec "$DIR/devclean.sh" "$@"
    ;;
  glance)
    exec "$DIR/glance.sh" "$@"
    ;;
  docs)
    exec bash "$DIR/docs.sh" "$@"
    ;;
  review)
    exec "$DIR/review.sh" "$@"
    ;;
  plan)
    exec "$DIR/plan.sh" "$@"
    ;;
  apply)
    exec "$DIR/apply.sh" "$@"
    ;;
  doctor)
    # One long checkup, no finale cards.
    DOCTOR_STRICT=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --strict) DOCTOR_STRICT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown doctor arg: $1" >&2; exit 2 ;;
      esac
    done
    export AFTERPARTY_CARD=0
    DOCTOR_FAILED=0
    "$DIR/process-ledger.sh" list || DOCTOR_FAILED=1
    if [ "$DOCTOR_STRICT" -eq 1 ]; then
      "$DIR/audit-processes.sh" --strict || DOCTOR_FAILED=1
    else
      "$DIR/audit-processes.sh" || DOCTOR_FAILED=1
    fi
    "$DIR/audit-git.sh" || DOCTOR_FAILED=1
    "$DIR/clean-artifacts.sh" || DOCTOR_FAILED=1
    "$DIR/devclean.sh" || DOCTOR_FAILED=1
    exit "$DOCTOR_FAILED"
    ;;
  report-path)
    state_report_path "$PWD"
    ;;
  report)
    REPORT_FILE="$(state_report_path "$PWD")"
    case "${1:---show}" in
      --remind)
        report_remind "$REPORT_FILE"
        ;;
      --session-end) report_session_end ;;
      --show)
        if [ -f "$REPORT_FILE" ]; then
          cat "$REPORT_FILE"
          [ "$(report_meta "$REPORT_FILE" status)" != incomplete ] || exit 1
        else
          echo "no afterparty report for this workspace" >&2
          exit 1
        fi
        ;;
      *) echo "unknown report arg: $1" >&2; exit 2 ;;
    esac
    ;;
  actions-path)
    state_actions_path
    ;;
  actions)
    journal_show "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac
