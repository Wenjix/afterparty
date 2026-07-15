#!/usr/bin/env bash
# process-ledger.sh - track long-running processes an agent starts, then stop
# only those recorded process groups when the task is done. Default actions are
# dry-run so cleanup never surprises the user.
#
# Usage:
#   process-ledger.sh add --pid 123 --kind dev --port 3000 --purpose "verify UI" -- pnpm dev website
#   process-ledger.sh list
#   process-ledger.sh list --json       # JSON Lines (one object per row)
#   process-ledger.sh stop              # dry run for current repo
#   process-ledger.sh stop --kill       # stop recorded live groups for current repo
#   process-ledger.sh prune             # drop dead entries for current repo
set -uo pipefail

LEDGER="${AGENT_PROCESS_LEDGER:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/ledger.tsv}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROTECT_RE (never signal these) is shared with audit-processes.sh.
. "$DIR/protect.sh"
# JSON Lines helpers for list --json.
. "$DIR/json.sh"
SELF_PGID="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"

usage() {
  sed -n '2,12p' "$0"
}

ensure_ledger() {
  mkdir -p "$(dirname "$LEDGER")"
  touch "$LEDGER"
}

clean_field() {
  printf '%s' "$1" | tr '\t\n' '  '
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
    printf '%s\n' "$command" | rg -iq -- "$PROTECT_RE"
  else
    printf '%s\n' "$command" | grep -Eiq -- "$PROTECT_RE"
  fi
}

pgid_exists() {
  local pgid="$1"
  if command -v rg >/dev/null 2>&1; then
    ps -Ao pgid= 2>/dev/null | tr -d ' ' | rg -q "^${pgid}$"
  else
    ps -Ao pgid= 2>/dev/null | tr -d ' ' | grep -q "^${pgid}$"
  fi
}

print_header() {
  printf '%-5s %-7s %-7s %-8s %-6s %-6s %-24s %s\n' STATUS PID PGID KIND PORT CPU PURPOSE COMMAND
}

row_matches() {
  local want_root="$1" all_roots="$2" want_kind="$3" root="$4" kind="$5"
  if [ "$all_roots" -ne 1 ] && [ "$root" != "$want_root" ]; then
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
  if ! is_live "$pid"; then
    echo "pid $pid is not live" >&2
    exit 2
  fi

  pgid="$(pgid_for "$pid")"
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  root="$(workspace_root "$PWD")"
  cwd="$PWD"
  [ -n "$command_label" ] || command_label="$(command_for "$pid")"

  ensure_ledger
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$ts")" \
    "$(clean_field "$root")" \
    "$(clean_field "$cwd")" \
    "$(clean_field "$pid")" \
    "$(clean_field "$pgid")" \
    "$(clean_field "$kind")" \
    "$(clean_field "$port")" \
    "$(clean_field "$purpose")" \
    "$(clean_field "$command_label")" >> "$LEDGER"

  echo "recorded pid $pid pgid ${pgid:-unknown} kind $kind port ${port:-none}"
}

list_entries() {
  local all_roots=0 want_root want_kind="" json=0 ts root cwd pid pgid kind port purpose command_label status cpu jcpu
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
    echo "Ledger: $LEDGER"
    print_header
  fi
  while IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label; do
    [ -n "${pid:-}" ] || continue
    row_matches "$want_root" "$all_roots" "$want_kind" "$root" "$kind" || continue
    status="dead"
    cpu="-"
    if is_live "$pid"; then
      status="live"
      cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
    fi
    if [ "$json" -eq 1 ]; then
      jcpu="$cpu"
      [ "$jcpu" = "-" ] && jcpu=""
      json_row "$(json_kv section ledger)" "$(json_kv status "$status")" \
        "$(json_kvn pid "$pid")" "$(json_kvn pgid "${pgid:-}")" "$(json_kv kind "$kind")" \
        "$(json_kvz port "${port:-}")" "$(json_kvz cpu "$jcpu")" "$(json_kv purpose "${purpose:-}")" \
        "$(json_kv command "${command_label:-}")" "$(json_kv root "$root")" "$(json_kv ts "$ts")"
    else
      printf '%-5s %-7s %-7s %-8s %-6s %-6s %-24s %.80s\n' \
        "$status" "$pid" "${pgid:-?}" "$kind" "${port:-?}" "${cpu:-?}" "${purpose:-}" "${command_label:-}"
    fi
  done < "$LEDGER"
}

stop_entries() {
  local do_kill=0 all_roots=0 want_root want_kind="" keep_pgid="" ts root cwd pid pgid kind port purpose command_label groups="" group
  want_root="$(workspace_root "$PWD")"

  while [ $# -gt 0 ]; do
    case "$1" in
      --kill) do_kill=1; shift ;;
      --all) all_roots=1; shift ;;
      --root) want_root="$(workspace_root "${2:?}")"; shift 2 ;;
      --kind) want_kind="${2:?}"; shift 2 ;;
      --keep-pgid) keep_pgid="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown stop arg: $1" >&2; exit 2 ;;
    esac
  done

  ensure_ledger
  echo "$([ "$do_kill" -eq 1 ] && echo "STOP" || echo "DRY RUN") - recorded live process groups"
  while IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label; do
    [ -n "${pid:-}" ] || continue
    row_matches "$want_root" "$all_roots" "$want_kind" "$root" "$kind" || continue
    is_live "$pid" || continue
    if [ -z "$pgid" ] || [ "$pgid" = "$SELF_PGID" ]; then
      echo "  skip pid $pid: pgid is shared with this shell (${pgid:-unknown})"
      continue
    fi
    if [ -n "$keep_pgid" ] && [ "$pgid" = "$keep_pgid" ]; then
      echo "  keep pgid $pgid: ${purpose:-$command_label}"
      continue
    fi
    if is_protected_pid "$pid"; then
      echo "  protect pid $pid pgid $pgid: $(command_for "$pid")"
      continue
    fi
    case " $groups " in *" $pgid "*) continue ;; esac
    groups="$groups $pgid"
    echo "  $([ "$do_kill" -eq 1 ] && echo "kill" || echo "would kill") pgid $pgid: ${purpose:-$command_label}"
  done < "$LEDGER"

  [ -n "$groups" ] || { echo "  nothing to stop"; return 0; }
  [ "$do_kill" -eq 1 ] || return 0

  for group in $groups; do
    kill -TERM -"$group" 2>/dev/null && echo "  SIGTERM -> pgid $group"
  done
  sleep 2
  for group in $groups; do
    if pgid_exists "$group"; then
      kill -KILL -"$group" 2>/dev/null && echo "  SIGKILL -> pgid $group (straggler)"
    fi
  done
}

prune_entries() {
  local all_roots=0 want_root tmp ts root cwd pid pgid kind port purpose command_label kept=0 dropped=0
  want_root="$(workspace_root "$PWD")"

  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all_roots=1; shift ;;
      --root) want_root="$(workspace_root "${2:?}")"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown prune arg: $1" >&2; exit 2 ;;
    esac
  done

  ensure_ledger
  tmp="$(mktemp)"
  while IFS=$'\t' read -r ts root cwd pid pgid kind port purpose command_label; do
    [ -n "${pid:-}" ] || continue
    if row_matches "$want_root" "$all_roots" "" "$root" "$kind" && ! is_live "$pid"; then
      dropped=$((dropped + 1))
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$root" "$cwd" "$pid" "$pgid" "$kind" "$port" "$purpose" "$command_label" >> "$tmp"
    kept=$((kept + 1))
  done < "$LEDGER"
  mv "$tmp" "$LEDGER"
  echo "pruned $dropped dead entr$([ "$dropped" -eq 1 ] && echo y || echo ies); kept $kept"
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
