#!/usr/bin/env bash
# agent-hygiene.sh - one script entrypoint for agent process tracking, audit,
# and cleanup. The skill should route here instead of reimplementing logic in
# prompt text.
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
#   agent-hygiene.sh devclean [--orphans|--deep|--optimize|--disk|--history] [--apply --target ID]
#   agent-hygiene.sh glance [--oneline] [--json]
#   agent-hygiene.sh plan [--root DIR] [--all] [--artifacts-only] [--caches-only]
#   agent-hygiene.sh apply <plan.md>
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
  # The header ends at set; additional usage lines must remain visible.
  sed -n '2,/^set -euo pipefail/{ /^set /d; p; }' "$0"
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
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty audit --kill${C_RESET}"
    segs="$(s_segments \
      "$([ "$killed" -gt 0 ] && echo "$G_OK $killed killed")" \
      "$([ "$prot" -gt 0 ] && echo "$G_SKIP $prot protected")" \
      "$([ "$failed" -gt 0 ] && echo "$G_SKIP $failed failed")" \
      "$([ "$gitf" -gt 0 ] && echo "$G_ACT $(s_n "$gitf" 'git leftover' 'git leftovers')")" \
      "$([ "$live" -gt 0 ] && echo "$G_ACT $live on the tab")")"
    s_card_line "   $segs"
    if [ "$killed" -gt 0 ]; then
      s_card_line "   $(s_n "$killed" 'process group shown the door' 'process groups shown the door')"
    elif [ "$prot" -gt 0 ]; then
      s_card_line "   nothing stopped — $(s_n "$prot" 'group was protected' 'groups were protected')"
    else
      s_card_line "   no process-group exit was confirmed"
    fi
    [ "$failed" -gt 0 ] && s_card_line "   $failed cleanup action(s) could not be confirmed"
    if [ "$gitf" -gt 0 ]; then
      s_card_line "   still on the tab: $(s_n "$gitf" 'git leftover' 'git leftovers')"
    fi
    if [ "$live" -gt 0 ]; then
      s_card_line "   still on the tab: $(s_n "$live" 'ledger entry' 'ledger entries')"
    fi
    s_card_line
    s_card_line "   thanks for partying responsibly 🎉"
  elif [ $((found + live + gitf)) -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage${C_RESET}"
    segs="$(s_segments \
      "$([ "$found" -gt 0 ] && echo "$G_ACT $(s_n "$found" 'stray' 'strays')")" \
      "$([ "$live" -gt 0 ] && echo "$G_ACT $live on the tab")" \
      "$([ "$gitf" -gt 0 ] && echo "$G_ACT $(s_n "$gitf" 'git leftover' 'git leftovers')")" \
      "$([ "$listeners" -gt 0 ] && echo "$(s_n "$listeners" 'listener' 'listeners')")" \
      "$([ "$unavailable" -gt 0 ] && echo "$G_SKIP $unavailable unavailable")")"
    s_card_line "   $segs"
    if [ "$found" -gt 0 ]; then
      s_card_line "   $(s_n "$found" 'stray process still partying' 'stray processes still partying')"
    fi
    if [ "$live" -gt 0 ]; then
      s_card_line "   $(s_n "$live" 'ledger entry live on the tab' 'ledger entries live on the tab')"
    fi
    if [ "$gitf" -gt 0 ]; then
      if [ "$bytes" -gt 0 ]; then
        s_card_line "   $(s_n "$gitf" 'git leftover' 'git leftovers') (${bytes} B of litter)"
      else
        s_card_line "   $(s_n "$gitf" 'git leftover' 'git leftovers')"
      fi
    fi
    if [ "$listeners" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$listeners" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    fi
    if [ "$stashes" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$stashes" 'stash on the shelf — your call' 'stashes on the shelf — your call'))${C_RESET}"
    fi
    if [ "$unavailable" -gt 0 ]; then
      s_card_line "${C_DIM}   ($unavailable scanner(s) unavailable — audit incomplete)${C_RESET}"
    fi
    s_card_line
    s_card_line "   closing time:"
    if [ "$live" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty stop --kill${C_RESET}"
    fi
    if [ "$found" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty audit --kill tests,dev,browser --pgid <reviewed-pgid>${C_RESET}"
    fi
    if [ "$gitf" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty plan${C_RESET}  (git --clean is report-only)"
    fi
  elif [ "$unavailable" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}⚠ audit incomplete — no clean bill of health${C_RESET}"
    s_card_line "   $unavailable scanner(s) unavailable"
    s_card_line "   run ${C_CYAN}afterparty doctor${C_RESET} after installing the missing tools"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — nobody crashed on your couch${C_RESET}"
    if [ "$listeners" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$listeners" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    fi
    if [ "$stashes" -gt 0 ]; then
      s_card_line "${C_DIM}   ($(s_n "$stashes" 'stash on the shelf — your call' 'stashes on the shelf — your call'))${C_RESET}"
    fi
    s_card_line "   see you next session 🎉"
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
        s_banner "afterparty — last call" "let's see what the session left behind"
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
  devclean)
    exec "$DIR/devclean.sh" "$@"
    ;;
  glance)
    exec "$DIR/glance.sh" "$@"
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
