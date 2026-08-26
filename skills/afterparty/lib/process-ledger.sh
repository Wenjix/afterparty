#!/usr/bin/env bash
# process-ledger.sh - track long-running processes an agent starts, then stop
# only those recorded process groups when the task is done. Default actions are
# dry-run so cleanup never surprises the user.
#
# Usage:
#   process-ledger.sh add --pid 123 --kind dev --port 3000 --purpose "verify UI" -- pnpm dev website
#   process-ledger.sh list
#   process-ledger.sh list --json       # JSON Lines (one object per row)
#   process-ledger.sh stop              # dry run for current repo (--all: every repo)
#   process-ledger.sh stop --kill       # stop recorded live groups (--keep <pgid> spares one)
#   process-ledger.sh prune             # drop dead entries for current repo
set -uo pipefail

LEDGER_CUSTOM=0
if [ -n "${AGENT_PROCESS_LEDGER:-}" ]; then
  LEDGER="$AGENT_PROCESS_LEDGER"
  LEDGER_CUSTOM=1
else
  LEDGER="${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/ledger.tsv"
fi
LEDGER_LOCK="${LEDGER}.lock"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROTECT_RE (never signal these) is shared with audit-processes.sh.
. "$DIR/protect.sh"
# JSON Lines helpers for list --json.
. "$DIR/json.sh"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
# Private local record of confirmed mutation outcomes.
. "$DIR/journal.sh"
SELF_PGID="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"

usage() {
  sed -n '2,12p' "$0"
}

ensure_ledger() {
  local ledger_dir
  ledger_dir="$(dirname "$LEDGER")"
  if [ "$LEDGER_CUSTOM" -eq 1 ] && [ -d "$ledger_dir" ]; then
    : # The caller owns this directory and its sharing policy.
  else
    state_secure_dir "$ledger_dir" || return
  fi
  (umask 077 && touch "$LEDGER") || return
  LEDGER_TMP=""
  trap - EXIT INT TERM
  chmod 600 "$LEDGER" 2>/dev/null || true
}

clean_field() {
  printf '%s' "$1" | tr '\t\n' '  '
}

# Tab is IFS whitespace, so consecutive tabs collapse during read and an
# empty field (pgid, port, purpose, command) would shift every column after
# it. Pad empty fields with "-" before splitting; readers map "-" back to
# empty via unpad. Known collision: a purpose that is literally "-" reads as
# empty — implausible enough to accept. On-disk format is unchanged.
pad_row() {
  local l="$1"
  while [ "${l#*$'\t\t'}" != "$l" ]; do
    l="${l//$'\t\t'/$'\t'-$'\t'}"
  done
  case "$l" in *$'\t') l="${l}-" ;; esac
  printf '%s' "$l"
}

unpad() {
  if [ "${1:-}" = "-" ]; then printf ''; else printf '%s' "${1:-}"; fi
}

# True when two workspace paths name the same tree: identical, or one contains
# the other. Git repos already normalise to a shared toplevel; this gives
# non-git workspaces the same behaviour instead of keying on an exact cwd.
same_workspace_tree() {
  local a="${1%/}" b="${2%/}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case "$a" in
    "$b") return 0 ;;
    "$b"/*) return 0 ;;
  esac
  case "$b" in
    "$a"/*) return 0 ;;
  esac
  return 1
}

workspace_root() {
  local dir="${1:-$PWD}"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$dir"
}

pgid_for() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

command_for() {
  ps -o command= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//'
}

is_live() {
  ps -p "$1" >/dev/null 2>&1
}

is_protected_pid() {
  local pid="$1" command
  command="$(command_for "$pid")"
  if command -v rg >/dev/null 2>&1; then
    printf '%s\n' "$command" | rg --no-config -iq -- "$PROTECT_RE"
  else
    printf '%s\n' "$command" | grep -Eiq -- "$PROTECT_RE"
  fi
}

pgid_exists() {
  local pgid="$1" members
  if ! members=$(ps -Ao pgid= 2>/dev/null); then
    return 2
  fi
  if command -v rg >/dev/null 2>&1; then
    printf '%s\n' "$members" | tr -d ' ' | rg --no-config -q "^${pgid}$"
  else
    printf '%s\n' "$members" | tr -d ' ' | grep -q "^${pgid}$"
  fi
}

print_header() {
  local hc="" hr=""
  if [ "$STYLE_ON" -eq 1 ]; then hc="$C_DIM"; hr="$C_RESET"; fi
  printf '%s%-5s %-7s %-7s %-8s %-6s %-6s %-24s %s%s\n' "$hc" STATUS PID PGID KIND PORT CPU PURPOSE COMMAND "$hr"
}

row_matches() {
  local want_root="$1" all_roots="$2" want_kind="$3" root="$4" kind="$5"
  # A non-git workspace has no toplevel to normalise to, so workspace_root
  # falls back to the exact cwd of `add` — and an exact-equality test then made
  # a row recorded in a subdirectory invisible from the project root, and vice
  # versa. `stop --kill` silently skipped processes it had recorded itself.
  # Rows in the same tree match in either direction; --all is still the way to
  # reach the whole machine.
  if [ "$all_roots" -ne 1 ] && ! same_workspace_tree "$root" "$want_root"; then
    return 1
  fi
  if [ -n "$want_kind" ] && [ "$kind" != "$want_kind" ]; then
    return 1
  fi
  return 0
}

add_entry() {
  local pid="" kind="other" port="" purpose="" command_label="" pgid ts root cwd

  while [ $# -gt 0 ]; do
    case "$1" in
      --pid) pid="${2:?}"; shift 2 ;;
      --kind) kind="${2:?}"; shift 2 ;;
      --port) port="${2:?}"; shift 2 ;;
      --purpose) purpose="${2:?}"; shift 2 ;;
      --) shift; command_label="$*"; break ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown add arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ -z "$pid" ]; then
    echo "add requires --pid" >&2
    exit 2
  fi
  case "$pid" in
    *[!0-9]*|0|1)
      echo "invalid pid $pid" >&2
      exit 2
      ;;
  esac
  if ! is_live "$pid"; then
    echo "pid $pid is not live" >&2
    exit 2
  fi

  pgid="$(pgid_for "$pid")"
  case "$pgid" in
    '') ;;
    *[!0-9]*|0|1)
      echo "invalid pgid ${pgid:-empty} for pid $pid" >&2
      exit 2
      ;;
  esac
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  root="$(workspace_root "$PWD")"
  cwd="$PWD"
  [ -n "$command_label" ] || command_label="$(command_for "$pid")"

  ensure_ledger || { echo "could not initialize ledger: $LEDGER" >&2; return 1; }
  if ! state_lock_acquire "$LEDGER_LOCK"; then
    echo "ledger is busy: $LEDGER" >&2
    return 1
  fi
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(clean_field "$ts")" \
      "$(clean_field "$root")" \
      "$(clean_field "$cwd")" \
      "$(clean_field "$pid")" \
      "$(clean_field "$pgid")" \
      "$(clean_field "$kind")" \
      "$(clean_field "$port")" \
      "$(clean_field "$purpose")" \
      "$(clean_field "$command_label")" >> "$LEDGER"; then
    state_lock_release "$LEDGER_LOCK"
    echo "could not append to ledger: $LEDGER" >&2
    return 1
  fi
  chmod 600 "$LEDGER" 2>/dev/null || true
  state_lock_release "$LEDGER_LOCK"

  s_ok "recorded pid $pid pgid ${pgid:-unknown} kind $kind port ${port:-none}"
}

list_entries() {
  local all_roots=0 want_root want_kind="" json=0 __row ts root cwd pid pgid kind port purpose command_label status cpu jcpu rc rr N_LIVE
  want_root="$(workspace_root "$PWD")"

  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all_roots=1; shift ;;
      --root) want_root="$(workspace_root "${2:?}")"; shift 2 ;;
      --kind) want_kind="${2:?}"; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown list arg: $1" >&2; exit 2 ;;
    esac
  done

  ensure_ledger
  if [ "$json" -eq 0 ]; then
    s_dim "Ledger: $LEDGER"
    print_header
  fi
  N_LIVE=0
  while IFS= read -r __row; do
    IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label <<< "$(pad_row "$__row")"
    pgid="$(unpad "$pgid")" port="$(unpad "$port")" purpose="$(unpad "$purpose")" command_label="$(unpad "$command_label")"
    [ -n "${pid:-}" ] || continue
    row_matches "$want_root" "$all_roots" "$want_kind" "$root" "$kind" || continue
    status="dead"
    cpu="-"
    if is_live "$pid"; then
      status="live"
      cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
      N_LIVE=$((N_LIVE + 1))
    fi
    if [ "$json" -eq 1 ]; then
      jcpu="$cpu"
      [ "$jcpu" = "-" ] && jcpu=""
      json_row "$(json_kv section ledger)" "$(json_kv status "$status")" \
        "$(json_kvn pid "$pid")" "$(json_kvn pgid "${pgid:-}")" "$(json_kv kind "$kind")" \
        "$(json_kvn port "${port:-}")" "$(json_kvz cpu "$jcpu")" "$(json_kv purpose "${purpose:-}")" \
        "$(json_kv command "${command_label:-}")" "$(json_kv root "$root")" "$(json_kv ts "$ts")"
    else
      rc=""; rr=""
      if [ "$STYLE_ON" -eq 1 ] && [ "$status" = "dead" ]; then rc="$C_DIM"; rr="$C_RESET"; fi
      printf '%s%-5s %-7s %-7s %-8s %-6s %-6s %-24s %.80s%s\n' \
        "$rc" "$status" "$pid" "${pgid:-?}" "$kind" "${port:-?}" "${cpu:-?}" "${purpose:-}" "${command_label:-}" "$rr"
    fi
  done < "$LEDGER"
  if [ "$json" -eq 0 ]; then
    tally_add ledger.live "$N_LIVE"
  fi
}

stop_entries() {
  local do_kill=0 all_roots=0 want_root want_kind="" keep_pgid="" __row ts root cwd pid pgid kind port purpose command_label groups="" signaled_groups="" group current_pgid current_cmd protection_rc n_skip=0 n_keep=0 n_prot=0 n_failed=0 segs
  want_root="$(workspace_root "$PWD")"

  while [ $# -gt 0 ]; do
    case "$1" in
      --kill) do_kill=1; shift ;;
      --all) all_roots=1; shift ;;
      --root) want_root="$(workspace_root "${2:?}")"; shift 2 ;;
      --kind) want_kind="${2:?}"; shift 2 ;;
      --keep-pgid|--keep) keep_pgid="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown stop arg: $1" >&2; exit 2 ;;
    esac
  done

  ensure_ledger
  if [ "$do_kill" -eq 1 ]; then
    s_mode "$C_RED" "STOP" " - settling the tab, stopping recorded groups" \
      "STOP - recorded live process groups"
  else
    s_mode "$C_YEL" "DRY RUN" " - the tab is open; nothing stopped yet (--kill to settle up)" \
      "DRY RUN - recorded live process groups"
  fi
  while IFS= read -r __row; do
    IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label <<< "$(pad_row "$__row")"
    pgid="$(unpad "$pgid")" port="$(unpad "$port")" purpose="$(unpad "$purpose")" command_label="$(unpad "$command_label")"
    [ -n "${pid:-}" ] || continue
    row_matches "$want_root" "$all_roots" "$want_kind" "$root" "$kind" || continue
    case "$pid" in
      *[!0-9]*|0|1)
        s_skip "  skip ledger row: invalid pid $pid"
        n_failed=$((n_failed + 1))
        continue
        ;;
    esac
    case "$pgid" in
      *[!0-9]*|0|1)
        s_skip "  skip pid $pid: invalid pgid ${pgid:-empty}"
        n_failed=$((n_failed + 1))
        continue
        ;;
    esac
    is_live "$pid" || continue
    if [ -z "$pgid" ] || [ "$pgid" = "$SELF_PGID" ]; then
      s_skip "  skip pid $pid: pgid is shared with this shell (${pgid:-unknown})"
      n_skip=$((n_skip + 1))
      continue
    fi
    # Recycled-pid defense: never trust a recorded row blindly. A recycled
    # pid virtually never keeps its recorded pgid, and a changed command
    # line is the other tell. (On Git Bash pgid_for is empty — no-op.)
    current_pgid="$(pgid_for "$pid")"
    if [ -n "$current_pgid" ] && [ "$current_pgid" != "$pgid" ]; then
      s_skip "  skip pid $pid: group changed since it was recorded (pid recycled?)"
      n_skip=$((n_skip + 1))
      continue
    fi
    if [ -n "${command_label:-}" ]; then
      current_cmd="$(command_for "$pid")"
      case "$current_cmd" in
        ''|*"$command_label"*) ;;
        *)
          s_skip "  skip pid $pid: command changed since it was recorded (pid recycled?)"
          n_skip=$((n_skip + 1))
          continue
          ;;
      esac
    fi
    if [ -n "$keep_pgid" ] && [ "$pgid" = "$keep_pgid" ]; then
      s_skip "  keep pgid $pgid: ${purpose:-$command_label}"
      n_keep=$((n_keep + 1))
      continue
    fi
    if is_protected_pid "$pid"; then
      s_skip "  protect pid $pid pgid $pgid: $(command_for "$pid")"
      n_prot=$((n_prot + 1))
      continue
    fi
    # The recorded pid may be fine while a protected sibling shares its
    # group — never signal the whole group in that case.
    if pgid_has_protected "$pgid"; then
      s_skip "  protect pgid $pgid: shares its group with a protected process"
      n_prot=$((n_prot + 1))
      continue
    else
      protection_rc=$?
      if [ "$protection_rc" -eq 3 ]; then
        s_skip "  pgid $pgid had already exited — nothing to signal"
        continue
      fi

      if [ "$protection_rc" -eq 2 ]; then
        s_skip "  could not inspect pgid $pgid for protected members — skipped"
        n_failed=$((n_failed + 1))
        continue
      fi
    fi
    case " $groups " in *" $pgid "*) continue ;; esac
    groups="$groups $pgid"
    if [ "$do_kill" -eq 1 ]; then
      s_kill "  kill pgid $pgid: ${purpose:-$command_label}"
    else
      s_would "  would kill pgid $pgid: ${purpose:-$command_label}"
    fi
  done < "$LEDGER"

  if [ -z "$groups" ]; then
    s_dim "  nothing to stop"
    if cards_on; then
      echo
      s_card_open
      s_card_line "${C_BOLD}${C_GRN}✨ ledger clear — nobody left on the tab${C_RESET}"
      segs="$(s_segments \
        "$([ "$n_prot" -gt 0 ] && echo "$G_SKIP $n_prot protected")" \
        "$([ "$n_keep" -gt 0 ] && echo "$n_keep kept")" \
        "$([ "$n_skip" -gt 0 ] && echo "$n_skip skipped")" \
        "$([ "$n_failed" -gt 0 ] && echo "$n_failed failed")")"
      if [ -n "$segs" ]; then s_card_line "   $segs"; fi
      if [ "$n_failed" -gt 0 ]; then
        s_card_line "   no action taken — protection could not be verified"
      else
        s_card_line "   see you next session 🎉"
      fi
      s_card_close
    fi
    if [ "$n_failed" -gt 0 ]; then return 1; fi
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $groups
  N_GROUPS=$#
  if [ "$do_kill" -eq 0 ]; then
    if cards_on; then
      echo
      s_card_open
      s_card_line "${C_BOLD}${C_YEL}🧹 the damage — ledger${C_RESET}"
      segs="$(s_segments \
        "$G_ACT $N_GROUPS would-kill" \
        "$([ "$n_prot" -gt 0 ] && echo "$G_SKIP $n_prot protected")" \
        "$([ "$n_keep" -gt 0 ] && echo "$n_keep kept")" \
        "$([ "$n_skip" -gt 0 ] && echo "$n_skip skipped")")"
      s_card_line "   $segs"
      s_card_line "   $(s_n "$N_GROUPS" 'recorded process group still on the tab' 'recorded process groups still on the tab')"
      s_card_line
      s_card_line "   closing time: ${C_CYAN}afterparty stop --kill${C_RESET}"
      s_card_close
    fi
    if [ "$n_failed" -gt 0 ]; then return 1; fi
    return 0
  fi

  N_STOPPED=0
  for group in $groups; do
    # The earlier discovery check can be stale by the time every ledger row
    # has been considered. Recheck immediately before SIGTERM.
    if pgid_has_protected "$group"; then
      s_skip "  protect pgid $group: shares its group with a protected process"
      n_prot=$((n_prot + 1))
      continue
    else
      protection_rc=$?
      if [ "$protection_rc" -eq 3 ]; then
        # Already gone: nothing to signal, and NOT a failure. Falling through
        # here signalled a pgid that ps had just reported absent — if the id is
        # reused in that gap an unrelated group takes the signal.
        s_skip "  pgid $group had already exited — nothing to signal"
        continue
      fi

      if [ "$protection_rc" -eq 2 ]; then
        s_skip "  could not recheck pgid $group before SIGTERM — skipped"
        journal_action ledger_group.stop "pgid:$group" failed "protection unavailable before SIGTERM"
        n_failed=$((n_failed + 1))
        continue
      fi
    fi
    signaled_groups="$signaled_groups $group"
    if kill -TERM -"$group" 2>/dev/null; then
      s_kill "  SIGTERM -> pgid $group"
    fi
  done
  groups="$signaled_groups"
  if [ -n "$groups" ]; then
    s_heartbeat "waiting 2s for stragglers"
    sleep 2
  fi
  for group in $groups; do
    if pgid_exists "$group"; then
      if pgid_has_protected "$group"; then
        s_skip "  pgid $group became protected before SIGKILL — skipped"
        journal_action ledger_group.stop "pgid:$group" failed "protected member detected before SIGKILL"
        n_prot=$((n_prot + 1))
        n_failed=$((n_failed + 1))
        continue
      else
        protection_rc=$?
        if [ "$protection_rc" -eq 3 ]; then
          # SIGTERM landed and the group drained. Success, not "already gone" --
          # that verdict belongs only to a PRE-signal check.
          s_ok "  pgid $group exited after SIGTERM"
          N_STOPPED=$((N_STOPPED + 1))
          journal_action ledger_group.stop "pgid:$group" succeeded "exited after SIGTERM"
          continue
        fi

        if [ "$protection_rc" -eq 2 ]; then
          s_skip "  could not recheck pgid $group before SIGKILL — skipped"
          journal_action ledger_group.stop "pgid:$group" failed "protection unavailable before SIGKILL"
          n_failed=$((n_failed + 1))
          continue
        fi
      fi
      kill -KILL -"$group" 2>/dev/null && s_kill "  SIGKILL -> pgid $group (straggler)"
      sleep 0.1
      if pgid_exists "$group"; then
        s_skip "  failed to stop pgid $group"
        journal_action ledger_group.stop "pgid:$group" failed "group still has members"
        n_failed=$((n_failed + 1))
      else
        protection_rc=$?
        if [ "$protection_rc" -eq 3 ]; then
          # The confirmation scan found no members: the group is gone, which is
          # exactly what this loop exists to confirm.
          N_STOPPED=$((N_STOPPED + 1))
          journal_action ledger_group.stop "pgid:$group" succeeded "group confirmed absent"
          continue
        fi

        if [ "$protection_rc" -eq 2 ]; then
          s_skip "  could not confirm pgid $group exited"
          journal_action ledger_group.stop "pgid:$group" failed "exit could not be confirmed"
          n_failed=$((n_failed + 1))
        else
          N_STOPPED=$((N_STOPPED + 1))
          journal_action ledger_group.stop "pgid:$group" succeeded "group confirmed absent"
        fi
      fi
    else
      protection_rc=$?
      if [ "$protection_rc" -eq 3 ]; then
        s_skip "  pgid $group had already exited — nothing to signal"
        continue
      fi

      if [ "$protection_rc" -eq 2 ]; then
        s_skip "  could not confirm pgid $group exited"
        journal_action ledger_group.stop "pgid:$group" failed "exit could not be confirmed"
        n_failed=$((n_failed + 1))
      else
        N_STOPPED=$((N_STOPPED + 1))
        journal_action ledger_group.stop "pgid:$group" succeeded "group confirmed absent"
      fi
    fi
  done
  if cards_on; then
    echo
    s_card_open
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty stop --kill${C_RESET}"
    segs="$(s_segments \
      "$([ "$N_STOPPED" -gt 0 ] && echo "$G_OK $N_STOPPED sent home")" \
      "$([ "$n_prot" -gt 0 ] && echo "$G_SKIP $n_prot protected")" \
      "$([ "$n_failed" -gt 0 ] && echo "$G_SKIP $n_failed failed")")"
    if [ -n "$segs" ]; then s_card_line "   $segs"; fi
    if [ "$N_STOPPED" -gt 0 ]; then
      s_card_line "   $(s_n "$N_STOPPED" 'process group sent home' 'process groups sent home')"
    else
      s_card_line "   no process-group exit was confirmed"
    fi
    s_card_line
    s_card_line "   thanks for partying responsibly 🎉"
    s_card_close
  fi
  if [ "$n_failed" -gt 0 ]; then return 1; fi
}

prune_entries() {
  local all_roots=0 want_root tmp ledger_dir __row ts root cwd pid pgid kind port purpose command_label kept=0 dropped=0
  want_root="$(workspace_root "$PWD")"

  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all_roots=1; shift ;;
      --root) want_root="$(workspace_root "${2:?}")"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown prune arg: $1" >&2; exit 2 ;;
    esac
  done

  ensure_ledger || { echo "could not initialize ledger: $LEDGER" >&2; return 1; }
  if ! state_lock_acquire "$LEDGER_LOCK"; then
    echo "ledger is busy: $LEDGER" >&2
    return 1
  fi
  ledger_dir="$(dirname "$LEDGER")"
  # A trap, because an interrupted prune otherwise leaves a partial copy of the
  # ledger next to the real one forever: nothing sweeps it, and it carries the
  # same 0600 contents. The EXIT trap covers the ordinary path; INT/TERM cover
  # the session ending underneath a prune, which is exactly when this runs.
  ledger_tmp_cleanup() { [ -z "${LEDGER_TMP:-}" ] || rm -f "$LEDGER_TMP"; }
  trap ledger_tmp_cleanup EXIT
  trap 'ledger_tmp_cleanup; exit 130' INT
  trap 'ledger_tmp_cleanup; exit 143' TERM
  if ! tmp="$(mktemp "$ledger_dir/.ledger.tsv.XXXXXX")"; then
    state_lock_release "$LEDGER_LOCK"
    echo "could not create ledger temporary file" >&2
  LEDGER_TMP="$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  while IFS= read -r __row; do
    IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label <<< "$(pad_row "$__row")"
    pgid="$(unpad "$pgid")" port="$(unpad "$port")" purpose="$(unpad "$purpose")" command_label="$(unpad "$command_label")"
    [ -n "${pid:-}" ] || continue
    if row_matches "$want_root" "$all_roots" "" "$root" "$kind" && ! is_live "$pid"; then
      dropped=$((dropped + 1))
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$root" "$cwd" "$pid" "$pgid" "$kind" "$port" "$purpose" "$command_label" >> "$tmp"
    kept=$((kept + 1))
  done < "$LEDGER"
  if ! mv -f -- "$tmp" "$LEDGER"; then
    rm -f -- "$tmp" 2>/dev/null || true
    LEDGER_TMP=""
    trap - EXIT INT TERM
    state_lock_release "$LEDGER_LOCK"
    echo "could not replace ledger: $LEDGER" >&2
    return 1
  fi
  chmod 600 "$LEDGER" 2>/dev/null || true
  state_lock_release "$LEDGER_LOCK"
  s_ok "pruned $dropped dead entr$([ "$dropped" -eq 1 ] && echo y || echo ies); kept $kept"
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

case "$cmd" in
  add) add_entry "$@" ;;
  list) list_entries "$@" ;;
  stop) stop_entries "$@" ;;
  prune) prune_entries "$@" ;;
  -h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac
