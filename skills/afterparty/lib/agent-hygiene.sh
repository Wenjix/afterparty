#!/usr/bin/env bash
# agent-hygiene.sh - one script entrypoint for agent process tracking, audit,
# and cleanup. The skill should route here instead of reimplementing logic in
# prompt text.
#
# Usage:
#   agent-hygiene.sh list [--json] [--all]
#   agent-hygiene.sh audit [--kill <tests|dev|browser>] [--keep <pgid>] [--json] [--report]
#   agent-hygiene.sh add --pid 123 --kind dev --port 3000 --purpose "verify UI" -- pnpm dev website
#   agent-hygiene.sh stop [--kill] [--keep <pgid>] [--all]
#   agent-hygiene.sh prune
#   agent-hygiene.sh git [--clean] [--age <days>] [--root <dir>] [--json]
#   agent-hygiene.sh artifacts [clean-artifacts args...]
#   agent-hygiene.sh devclean [--deep] [--optimize] [--disk] [--apply]
#   agent-hygiene.sh doctor
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TTY-gated styling, finale cards, and the composite tally (plain on pipes).
. "$DIR/style.sh"

usage() {
  sed -n '2,15p' "$0"
}

# The one finale card for the composite audit, fed by the children's tally.
print_finale_card() {
  local killed found live gitf bytes stashes listeners
  killed="$(tally_get procs.killed)"
  found="$(tally_get procs.found)"
  live="$(tally_get ledger.live)"
  gitf="$(tally_get git.findings)"
  bytes="$(tally_get git.litter_bytes)"
  stashes="$(tally_get git.stashes)"
  listeners="$(tally_get procs.listeners)"
  echo
  s_card_open
  if [ "$killed" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty audit --kill${C_RESET}"
    s_card_line "   $(s_n "$killed" 'process group shown the door' 'process groups shown the door')"
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
    s_card_line
    s_card_line "   closing time:"
    if [ "$live" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty stop --kill${C_RESET}"
    fi
    if [ "$found" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty audit --kill tests,dev,browser${C_RESET}"
    fi
    if [ "$gitf" -gt 0 ]; then
      s_card_line "     ${C_CYAN}afterparty git --clean${C_RESET}"
    fi
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
    # to every part (JSON Lines compose across scripts); --report tees the
    # human report to report.md — at the repo root only when the repo
    # gitignores it (litter guard), otherwise next to the ledger.
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
      "$DIR/process-ledger.sh" list ${JSON_FLAG:+"$JSON_FLAG"}
      "$DIR/audit-processes.sh" ${ARGS[@]+"${ARGS[@]}"}
      "$DIR/audit-git.sh" ${JSON_FLAG:+"$JSON_FLAG"}
    }
    if [ "$REPORT" -eq 1 ]; then
      if ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" \
        && git check-ignore -q "$ROOT_DIR/report.md" 2>/dev/null; then
        REPORT_FILE="$ROOT_DIR/report.md"
      else
        REPORT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/report.md"
        mkdir -p "$(dirname "$REPORT_FILE")"
      fi
      echo "note: writing audit report to $REPORT_FILE" >&2
      # Children write into this pipe (not a tty) so their output is plain,
      # and AFTERPARTY_STYLE=never makes that unconditional — a globally
      # exported =always must never put ANSI into report.md. The sed turns
      # the "=== X ===" headers into markdown H2s for the next session's
      # reader; contract data lines never match the pattern.
      (
        export AFTERPARTY_STYLE=never
        printf '# afterparty report — what the last session left behind\n\n'
        printf 'generated %s — afterparty audit --report\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        run_audit
      ) | sed -e 's/^=== \(.*\) ===$/## \1/' | tee "$REPORT_FILE"
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
      run_audit
      if [ -n "${AFTERPARTY_TALLY:-}" ]; then
        print_finale_card
        rm -f "$AFTERPARTY_TALLY"
      fi
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
  doctor)
    # One long checkup, no finale cards.
    export AFTERPARTY_CARD=0
    "$DIR/process-ledger.sh" list
    "$DIR/audit-processes.sh"
    "$DIR/audit-git.sh"
    "$DIR/clean-artifacts.sh"
    "$DIR/devclean.sh"
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
