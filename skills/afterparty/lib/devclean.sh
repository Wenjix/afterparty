#!/usr/bin/env bash
# devclean.sh - devclean-style cleanup for agent/dev-machine leaks.
#
# Preview is the default. Copy a target ID from the preview, then select it
# with --apply --target ID. No mode grants blanket mutation approval.
#
# Usage:
#   devclean.sh [--orphans]              # preview orphan process candidates
#   devclean.sh --deep                   # preview daemon and simulator targets
#   devclean.sh --optimize               # preview settings, dumps and launch agents
#   devclean.sh --disk                   # preview rebuildable caches; never signals
#   devclean.sh --history                # preview stale transcripts/logs/recordings
#   devclean.sh --disk --apply --target ID # apply one reviewed target
#   devclean.sh --target ID --target ID  # select multiple targets
#   devclean.sh --dry-run                # force preview
#   devclean.sh --documents-root DIR    # where --disk scans for project artifacts
#   devclean.sh --project-maxdepth N    # --disk project scan depth (default 6)
#   devclean.sh --no-repo-artifacts     # --disk: skip the current-repo artifact pass
#   devclean.sh --allow-broad-documents-root # permit HOME/root project scans
set -uo pipefail

# Every cleanup target below is composed from $HOME; an empty HOME would turn
# them into root-anchored paths.
if [ -z "${HOME:-}" ]; then
  echo "devclean.sh: HOME is not set; refusing to run" >&2
  exit 2
fi
if [ ! -d "$HOME" ]; then
  echo "devclean.sh: HOME is not a directory; refusing to run" >&2
  exit 2
fi
HOME_CANONICAL="$(cd "$HOME" && pwd -P)"
case "$HOME_CANONICAL" in
  /|/?|[A-Za-z]:/)
    echo "devclean.sh: unsafe HOME root ($HOME_CANONICAL); refusing to run" >&2
    exit 2
    ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
# Private local record of confirmed mutation outcomes.
. "$DIR/journal.sh"
. "$DIR/fingerprint.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"
. "$DIR/protect.sh"
OS="$(uname -s)"

DRY_RUN=1
DEEP=0
OPTIMIZE=0
DISK=0
HISTORY=0
ORPHANS=0
REQUESTED_TARGETS=()
SEEN_TARGETS=""
N_UNSELECTED=0 N_WITHHELD=0 N_CACHE_DONE=0 N_HISTORY_DONE=0
DOCUMENTS_ROOT="$HOME/Documents"
PROJECT_MAXDEPTH=6
RUN_REPO_ARTIFACTS=1
ALLOW_BROAD_DOCUMENTS_ROOT=0

usage() {
  sed -n '2,19p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply|--kill|--clean) DRY_RUN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --deep) DEEP=1; shift ;;
    --orphans) ORPHANS=1; shift ;;
    --optimize) OPTIMIZE=1; shift ;;
    --disk) DISK=1; shift ;;
    --history) HISTORY=1; shift ;;
    --target) REQUESTED_TARGETS+=("${2:?}"); shift 2 ;;
    --documents-root) DOCUMENTS_ROOT="${2:?}"; shift 2 ;;
    --project-maxdepth) PROJECT_MAXDEPTH="${2:?}"; shift 2 ;;
    --no-repo-artifacts) RUN_REPO_ARTIFACTS=0; shift ;;
    --allow-broad-documents-root) ALLOW_BROAD_DOCUMENTS_ROOT=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done
if [ "$DEEP" -eq 0 ] && [ "$OPTIMIZE" -eq 0 ] && [ "$DISK" -eq 0 ] && [ "$HISTORY" -eq 0 ]; then
  ORPHANS=1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "${#REQUESTED_TARGETS[@]}" -eq 0 ]; then
  echo 'devclean: --apply requires --target ID from a preview of the same modes and scope' >&2
  exit 2
fi

case "$PROJECT_MAXDEPTH" in
  ''|*[!0-9]*) echo "--project-maxdepth wants a whole number" >&2; exit 2 ;;
esac
if [ "$DISK" -eq 1 ] && [ -d "$DOCUMENTS_ROOT" ]; then
  DOCUMENTS_ROOT="$(cd "$DOCUMENTS_ROOT" && pwd -P)"
  if [ "$DRY_RUN" -eq 0 ] && [ "$ALLOW_BROAD_DOCUMENTS_ROOT" -eq 0 ]; then
    case "$DOCUMENTS_ROOT" in
      /|/?|[A-Za-z]:/|"$HOME_CANONICAL")
        echo "devclean.sh: broad documents root ($DOCUMENTS_ROOT); pass --allow-broad-documents-root to opt in" >&2
        exit 2
        ;;
    esac
    # A parent of HOME (for example $HOME/.. or /Users) is broader still: it
    # can traverse sibling home directories even though it is not itself a
    # filesystem root. Canonicalization above makes this prefix proof stable.
    case "$HOME_CANONICAL" in
      "$DOCUMENTS_ROOT"/*)
        echo "devclean.sh: broad documents root ($DOCUMENTS_ROOT) contains HOME; pass --allow-broad-documents-root to opt in" >&2
        exit 2
        ;;
    esac
  fi
fi

mode_label() {
  [ "$DRY_RUN" -eq 1 ] && echo "DRY RUN" || echo "APPLY"
}

MODE_C="$C_YEL"
if [ "$DRY_RUN" -eq 0 ]; then MODE_C="$C_RED"; fi
N_PROC=0
N_PROC_STOPPED=0
N_OPT=0   # optimize findings/actions: crash reporters, crashpad files, agents
N_OPT_DONE=0
N_FAILED=0
# Age gate for Codex session transcripts; default matches Claude Code's
# default transcript retention. Override via the environment.
CODEX_SESSION_AGE_DAYS="${CODEX_SESSION_AGE_DAYS:-30}"
case "$CODEX_SESSION_AGE_DAYS" in
  ''|0|*[!0-9]*) echo "CODEX_SESSION_AGE_DAYS wants a positive whole number of days" >&2; exit 2 ;;
esac

# IDs bind an explicit action to the reviewed object. Hashes keep whitespace
# and shell metacharacters out of the copyable selection argument.
target_id() { printf '%s:%s' "$1" "$(printf '%s' "$2" | fp_hash)"; }
target_gate() {
  local id="$1" effect="$2" chosen
  s_dim "  target: $id — $effect"
  case " $SEEN_TARGETS " in *" $id "*) return 1 ;; esac
  SEEN_TARGETS="$SEEN_TARGETS $id"
  [ "$DRY_RUN" -eq 0 ] || return 0
  for chosen in "${REQUESTED_TARGETS[@]}"; do
    [ "$chosen" = "$id" ] && return 0
  done
  N_UNSELECTED=$((N_UNSELECTED + 1))
  s_dim '    not selected'
  return 1
}
withhold() {
  s_skip "  withheld $1: $2"
  N_WITHHELD=$((N_WITHHELD + 1))
}

PROCESS_CONTEXT="$(mktemp -d)" || exit 1
trap 'rm -rf "$PROCESS_CONTEXT"' EXIT
refresh_process_context() {
  ws_index > "$PROCESS_CONTEXT/ws" 2>/dev/null || rm -f "$PROCESS_CONTEXT/ws"
  ws_pid_cwd --strict > "$PROCESS_CONTEXT/cwd" 2>/dev/null || rm -f "$PROCESS_CONTEXT/cwd"
}
# PPID 1 is only discovery evidence. A reviewed PID must also belong to this
# user, have no terminal, be at least an hour old, and occupy a known stale
# workspace at low CPU. Running agents and shared MCP helpers stay protected.
process_policy() {
  local pid="$1" identity="$2" facts uid etime tty cpu seconds cwd owner touched verdict
  if printf '%s\n' "${identity#* }" | match_i "$PROTECT_RE" >/dev/null 2>&1; then
    printf 'protected process'; return 0
  fi
  facts="$(ps -o uid=,etime=,tty=,%cpu= -p "$pid" 2>/dev/null)" || facts=""
  read -r uid etime tty cpu <<< "$facts"
  if [ -z "$facts" ] || [ "${uid:-}" != "$(id -u)" ]; then printf 'owner or activity unavailable'; return 0; fi
  if ! printf '%s\n' "${cpu:-}" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then printf 'CPU evidence unavailable'; return 0; fi
  case "${tty:-}" in '?'|'??'|'-') : ;; *) printf 'attached to a terminal'; return 0 ;; esac
  seconds="$(printf '%s' "$etime" | awk '
    /^[0-9]+(-[0-9]+)?:[0-9]+(:[0-9]+)?$/ {
      days=0; s=$0; if (index(s,"-")) {split(s,d,"-"); days=d[1]; s=d[2]}
      n=split(s,p,":"); if(n==2) print days*86400+p[1]*60+p[2]; else print days*86400+p[1]*3600+p[2]*60+p[3]
    }')"
  if [ -z "$seconds" ] || [ "$seconds" -lt 3600 ]; then printf 'recent process or unknown runtime'; return 0; fi
  if [ ! -f "$PROCESS_CONTEXT/cwd" ] || [ ! -f "$PROCESS_CONTEXT/ws" ]; then printf 'workspace scan unavailable'; return 0; fi
  cwd="$(awk -F '\t' -v p="$pid" '$1==p {print $2; exit}' "$PROCESS_CONTEXT/cwd")"
  owner="$(ws_owner_of "$cwd" < "$PROCESS_CONTEXT/ws")" || owner=""
  if [ -z "$cwd" ] || [ -z "$owner" ]; then printf 'no known workspace activity'; return 0; fi
  touched="$(awk -F '\t' -v w="$owner" '$2==w {print $1; exit}' "$PROCESS_CONTEXT/ws")"
  verdict="$(elig_verdict "$touched" "${cpu:-999}" "$(date +%s)")"
  [ "$verdict" = eligible ] || printf 'workspace %s' "$verdict"
}

human_mb() {
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f MB", kb / 1024 }'
}

unique_words() {
  tr ' ' '\n' | awk 'NF && !seen[$0]++' | xargs 2>/dev/null
}

join_re() {
  local IFS='|'
  printf '%s' "$*"
}

is_live_pid() {
  ps -p "$1" >/dev/null 2>&1
}

# Return 0 when PID is present, 1 when a successful full-table scan proves it
# absent, and 2 when the scan itself is unavailable. Targeted `ps -p` uses the
# same nonzero status for absence and some inspection failures, so it is not a
# sufficient postcondition after a signal.
pid_exists() {
  local pid="$1" snapshot rc
  if ! snapshot="$(ps -Ao pid= 2>/dev/null)"; then return 2; fi
  [ -n "$snapshot" ] || return 2
  printf '%s\n' "$snapshot" | grep -Eq "^[[:space:]]*${pid}[[:space:]]*$"
  rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# rg when available, grep -E otherwise, so the ps fallback path in
# pids_by_pattern still matches when ripgrep is missing.
match_i() {
  if command -v rg >/dev/null 2>&1; then rg --no-config -i -- "$1"; else grep -Ei -- "$1"; fi
}

# Stable identity includes parent, start time, and command. A recycled PID can
# still match the same broad category regex; comparing this full fingerprint
# prevents that different process from inheriting the old cleanup decision.
process_identity() {
  local identity parent weekday month day clock year command
  identity="$(LC_ALL=C ps -o ppid=,lstart=,command= -p "$1" 2>/dev/null)" || return
  [ -n "$identity" ] || return 1
  read -r parent weekday month day clock year command <<< "$identity"
  case "$parent:$year:$clock" in
    *[!0-9:]*|::*|*::* ) return 1 ;;
  esac
  [ -n "$command" ] && [ -n "$weekday" ] && [ -n "$month" ] && [ -n "$day" ] || return 1
  printf '%s\n' "$identity" \
    | tr '\t\r\n' '   ' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/[[:space:]]*$//'
}

identity_from_rows() {
  local wanted="$1" rows="$2" row_pid identity
  while IFS=$'\t' read -r row_pid identity; do
    if [ "$row_pid" = "$wanted" ]; then
      printf '%s' "$identity"
      [ -n "$identity" ]
      return
    fi
  done <<< "$rows"
  return 1
}

# Return 0 when PID still has its discovery fingerprint and scope, 1 when it
# changed, and 2 when it cannot be inspected.
pid_identity_matches() {
  local pid="$1" expected="$2" pattern="$3" scope="$4" current ppid rc policy
  if ! current="$(process_identity "$pid")"; then return 2; fi
  [ "$current" = "$expected" ] || return 1
  policy="$(process_policy "$pid" "$current")"
  [ -z "$policy" ] || return 2
  ppid="${current%% *}"
  if [ "$scope" = "orphans" ] && [ "$ppid" != "1" ]; then return 1; fi
  printf '%s\n' "$current" | match_i "$pattern" >/dev/null 2>&1
  rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

rss_kb_for() {
  ps -o rss= -p "$1" 2>/dev/null | awk '{print int($1)}'
}

filter_pids() {
  local pid
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    case "$pid" in *[!0-9]*|0|1) continue ;; esac
    [ "$pid" = "$$" ] && continue
    is_live_pid "$pid" || continue
    printf '%s\n' "$pid"
  done | unique_words
}

pids_by_pattern() {
  local pattern="$1" scope="${2:-all}" rc
  if command -v pgrep >/dev/null 2>&1; then
    if [ "$scope" = "orphans" ]; then
      pgrep -P 1 -f "$pattern" 2>/dev/null; rc=$?
    else
      pgrep -f "$pattern" 2>/dev/null; rc=$?
    fi
    [ "$rc" -le 1 ] || : > "$PROCESS_CONTEXT/discovery-incomplete"
    return
  fi

  if [ "$scope" = "orphans" ]; then
    ps -eo ppid=,pid=,command= 2>/dev/null | awk '$1 == 1 { $1=""; print }' | match_i "$pattern" | awk '{print $1}' || true
  else
    ps -eo pid=,command= 2>/dev/null | match_i "$pattern" | awk '{print $1}' || true
  fi
}

print_process_table() {
  local pids="$1" pid rss total=0 count=0 hc="" hr="" line
  [ -n "$pids" ] || return 1

  if [ "$STYLE_ON" -eq 1 ]; then hc="$C_DIM"; hr="$C_RESET"; fi
  printf '  %s%-7s %-7s %-7s %-8s %-6s %-10s %s%s\n' "$hc" PID PPID PGID RSS CPU ELAPSED COMMAND "$hr"
  for pid in $pids; do
    rss="$(rss_kb_for "$pid")"
    total=$((total + ${rss:-0}))
    count=$((count + 1))
    line="$(ps -o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p "$pid" 2>/dev/null)"
    [ -n "$line" ] || continue
    if [ "$STYLE_ON" -eq 1 ]; then
      # Styled rows render in bash so RSS/CPU carry severity tints and
      # ELAPSED is humanized; the plain awk path below stays byte-exact.
      # set -f: a COMMAND field containing * must never glob against cwd.
      # shellcheck disable=SC2086
      set -f; set -- $line; set +f
      [ $# -ge 7 ] || continue
      printf '  %-7s %-7s %-7s %s %s %-10s ' "$1" "$2" "$3" \
        "$(s_sevcell "$4" 262144 1048576 "$(printf '%-8s' "$4")")" \
        "$(s_sevcell "$5" 10 50 "$(printf '%-6s' "$5")")" \
        "$(s_etime "$6")"
      shift 6
      printf '%s\n' "$*"
    else
      printf '%s\n' "$line" | awk '{printf "  %-7s %-7s %-7s %-8s %-6s %-10s ", $1,$2,$3,$4,$5,$6; for(i=7;i<=NF;i++) printf "%s ", $i; print ""}'
    fi
  done
  echo "  count: $count; rss: $(human_mb "$total")"
}

terminate_pids() {
  local pids="$1" pattern="$2" scope="$3" identities="$4" pid expected waited remaining eligible="" handled="" identity_rc state_rc stopped=0 failed=0
  [ -n "$pids" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    s_would "  would SIGTERM PIDs: $pids"
    return 0
  fi

  refresh_process_context

  for pid in $pids; do
    expected="$(identity_from_rows "$pid" "$identities")" || expected=""
    if [ -n "$expected" ] && pid_identity_matches "$pid" "$expected" "$pattern" "$scope"; then
      eligible="$eligible $pid"
      kill -TERM "$pid" 2>/dev/null && s_kill "  SIGTERM -> pid $pid"
    else
      identity_rc=$?
      [ -n "$expected" ] || identity_rc=2
      if [ "$identity_rc" -eq 1 ]; then
        s_skip "  pid $pid identity changed before signal — skipped"
        journal_action process.stop "pid:$pid" failed "identity changed before signal"
      else
        s_skip "  could not inspect pid $pid immediately before signal — skipped"
        journal_action process.stop "pid:$pid" failed "identity unavailable before signal"
      fi
      failed=$((failed + 1))
    fi
  done
  eligible="$(printf '%s\n' "$eligible" | xargs 2>/dev/null)"
  if [ -z "$eligible" ]; then
    N_FAILED=$((N_FAILED + failed))
    return 1
  fi
  pids="$eligible"

  s_heartbeat "waiting up to 2s for PIDs to exit"
  waited=0
  while [ "$waited" -lt 4 ]; do
    remaining=""
    for pid in $pids; do
      if pid_exists "$pid"; then
        remaining="$remaining $pid"
      else
        state_rc=$?
        # An unavailable scanner cannot prove exit; keep the PID in the
        # unresolved set so it can never be counted as successfully stopped.
        [ "$state_rc" -eq 2 ] && remaining="$remaining $pid"
      fi
    done
    remaining="$(printf '%s\n' "$remaining" | xargs 2>/dev/null)"
    if [ -z "$remaining" ]; then
      # shellcheck disable=SC2086
      set -- $pids
      N_PROC_STOPPED=$((N_PROC_STOPPED + $#))
      for pid in $pids; do
        journal_action process.stop "pid:$pid" succeeded "process confirmed absent"
      done
      N_FAILED=$((N_FAILED + failed))
      [ "$failed" -eq 0 ]
      return
    fi
    sleep 0.5
    waited=$((waited + 1))
  done

  refresh_process_context
  for pid in $remaining; do
    expected="$(identity_from_rows "$pid" "$identities")" || expected=""
    if [ -n "$expected" ] && pid_identity_matches "$pid" "$expected" "$pattern" "$scope"; then
      kill -KILL "$pid" 2>/dev/null && s_kill "  SIGKILL -> pid $pid"
    else
      identity_rc=$?
      [ -n "$expected" ] || identity_rc=2
      handled="$handled $pid"
      if [ "$identity_rc" -eq 1 ]; then
        s_skip "  pid $pid identity changed before SIGKILL — skipped"
        journal_action process.stop "pid:$pid" failed "identity changed before SIGKILL"
      else
        s_skip "  could not inspect pid $pid before SIGKILL — skipped"
        journal_action process.stop "pid:$pid" failed "identity unavailable before SIGKILL"
      fi
      failed=$((failed + 1))
    fi
  done
  sleep 0.1
  for pid in $pids; do
    case " $handled " in *" $pid "*) continue ;; esac
    if pid_exists "$pid"; then
      s_skip "  failed to stop pid $pid"
      journal_action process.stop "pid:$pid" failed "process still live"
      failed=$((failed + 1))
    else
      state_rc=$?
      if [ "$state_rc" -eq 2 ]; then
        s_skip "  could not confirm pid $pid exited"
        journal_action process.stop "pid:$pid" failed "exit could not be confirmed"
        failed=$((failed + 1))
      else
        journal_action process.stop "pid:$pid" succeeded "process confirmed absent"
        stopped=$((stopped + 1))
      fi
    fi
  done
  N_PROC_STOPPED=$((N_PROC_STOPPED + stopped))
  N_FAILED=$((N_FAILED + failed))
  [ "$failed" -eq 0 ]
}

cleanup_pattern() {
  local label="$1" pattern="$2" scope="${3:-all}" pids identities="" pid identity policy approved="" tid
  pids="$(filter_pids $(pids_by_pattern "$pattern" "$scope"))"
  s_hdr "$label ($scope)"
  if [ -e "$PROCESS_CONTEXT/discovery-incomplete" ]; then
    withhold "$label" 'process discovery unavailable'; return 1
  fi
  if [ -z "$pids" ]; then
    s_dim "  (none)"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $pids
  N_PROC=$((N_PROC + $#))
  print_process_table "$pids"
  for pid in $pids; do
    identity="$(process_identity "$pid")" || identity=""
    [ -n "$identity" ] && policy="$(process_policy "$pid" "$identity")" || policy='identity unavailable'
    if [ -n "$policy" ]; then withhold "pid $pid" "$policy"; continue; fi
    tid="pid:$pid:$(printf '%s' "$identity" | fp_hash)"
    target_gate "$tid" "stop reviewed idle PID $pid; restarting its command may be necessary" || continue
    identities="${identities}${pid}"$'\t'"${identity}"$'\n'
    approved="$approved $pid"
  done
  terminate_pids "$approved" "$pattern" "$scope" "$identities"
}

ORPHAN_PATTERNS=(
  'mcp-server|playwright-mcp|chrome-devtools-mcp|@playwright/mcp'
  'context7|mobile-mcp|mcporter daemon'
  'language_server_macos|language_server_linux'
  'npm exec @playwright|npm exec @mobilenext|npm exec @upstash'
  'webpack-dev-server|vite.*--host|next-server|next dev|esbuild.*--serve|turbopack'
  'flutter_tester|dart.*(tooling-daemon|devtools|development-service)|(^|/)fvm '
  'adb.*logcat|log stream.*Runner'
  '(^| )claude( |$)'
  'zsh.*shell-snapshots/snapshot-zsh.*tasks/.*\.output'
  'tail -f.*/tmp/claude-.*/tasks/.*\.output'
  'kiro_cli_desktop|codex.*--dangerously|windsurf'
  'ChatGPTHelper|FigmaAgent|FirebaseCrashlytics/upload-symbols'
)

run_safe_orphans() {
  local re
  re="$(join_re "${ORPHAN_PATTERNS[@]}")"
  s_lead "$MODE_C" "devclean orphan candidates ($(mode_label))" "devclean orphan candidates ($(mode_label))"
  cleanup_pattern "Orphan process candidates" "$re" "orphans"
}

run_deep() {
  echo
  s_lead "$MODE_C" "Deep daemon audit ($(mode_label))" "Deep daemon audit ($(mode_label))"
  cleanup_pattern "Kotlin LSP" 'kotlinLsp' all
  cleanup_pattern "Gradle Daemon" 'org\.gradle\.launcher\.daemon|GradleDaemon' all
  cleanup_pattern "Flutter Daemon" 'flutter_tools\.snapshot daemon' all
  cleanup_pattern "FVM Processes" '(^|/)fvm ' all
  cleanup_pattern "Orphaned xcodebuild" 'xcodebuild' orphans
  cleanup_pattern "Antigravity Language Server" 'language_server_macos_arm|language_server_macos|language_server_linux' all
  cleanup_pattern "Logi Options+ Agent" 'logioptionsplus_agent' all
  cleanup_pattern "Ruby/Fastlane/CocoaPods" 'ruby.*fastlane|pod install' orphans
  cleanup_pattern "LogiRightSight" 'LogiRightSight' all

  preview_simulators
}

preview_simulators() {
  local udid name tid state
  [ "$OS" = Darwin ] && command -v xcrun >/dev/null 2>&1 || return 0
  s_hdr "iOS Simulators — select individual devices"
  if ! command -v python3 >/dev/null 2>&1; then withhold simulators 'Python 3 is required for device-state inspection'; return 1; fi
  if ! xcrun simctl list devices -j > "$PROCESS_CONTEXT/simulators" 2>/dev/null; then
    withhold simulators 'device-state inspection unavailable'; return 1
  fi
  if ! python3 - "$PROCESS_CONTEXT/simulators" > "$PROCESS_CONTEXT/booted" <<'SIMS'
import json, re, sys
with open(sys.argv[1]) as source:
    obj = json.load(source)
for devices in obj["devices"].values():
    for device in devices:
        if device["state"] == "Booted":
            udid = device["udid"]
            if not re.fullmatch(r"[0-9A-Fa-f-]+", udid):
                raise ValueError("invalid simulator identity")
            print(udid + "\t" + re.sub(r"[\x00-\x1f]", " ", device["name"]))
SIMS
  then withhold simulators 'malformed device-state output'; return 1; fi
  while IFS=$'\t' read -r udid name; do
    [ -n "$udid" ] || continue
    N_OPT=$((N_OPT + 1))
    tid="$(target_id simulator "$(id -u):$udid")"
    target_gate "$tid" "shut down simulator $name ($udid); interrupts apps running on this device" || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      s_would "  would run: xcrun simctl shutdown $udid"
    else
      if xcrun simctl shutdown "$udid" 2>/dev/null \
        && xcrun simctl list devices -j > "$PROCESS_CONTEXT/simulators-after" 2>/dev/null \
        && python3 - "$PROCESS_CONTEXT/simulators-after" "$udid" <<'SIMS'
import json, sys
with open(sys.argv[1]) as source:
    obj = json.load(source)
states = [d["state"] for group in obj["devices"].values() for d in group if d["udid"] == sys.argv[2]]
sys.exit(0 if states == ["Shutdown"] else 1)
SIMS
      then
        N_OPT_DONE=$((N_OPT_DONE + 1)); s_ok "  confirmed simulator shutdown: $name"
        journal_action simulator.shutdown "$udid" succeeded 'device state is Shutdown'
      else
        N_FAILED=$((N_FAILED + 1)); s_skip "  could not confirm simulator shutdown: $name"
        journal_action simulator.shutdown "$udid" failed 'Shutdown state could not be confirmed'
      fi
    fi
  done < "$PROCESS_CONTEXT/booted"

}

patch_crash_reporters() {
  local dirs argv canonical label found=0 result setting digest tid backup
  dirs=( "$HOME/.vscode" "$HOME/.cursor" "$HOME/.windsurf" "$HOME/.antigravity" "$HOME/.kiro" "$HOME/.vscode-oss" )
  s_hdr "IDE crash reporters — persistent settings"
  for dir in "${dirs[@]}"; do
    argv="$dir/argv.json"
    [ -f "$argv" ] || continue
    if ! canonical="$(home_file_canonical "$argv")"; then
      found=1; withhold "$argv" 'settings path escapes HOME or is a symlink'; continue
    fi
    argv="$canonical"
    if ! command -v python3 >/dev/null 2>&1; then
      found=1; withhold "$argv" 'Python 3 is required to inspect JSONC safely'; continue
    fi
    if ! result="$(python3 "$DIR/devclean-settings.py" inspect "$argv" 2>/dev/null)"; then
      found=1; withhold "$argv" 'active JSONC setting cannot be inspected'; continue
    fi
    setting="${result%%$'\t'*}"; digest="${result#*$'\t'}"
    [ "$setting" = enabled ] || continue
    found=1; N_OPT=$((N_OPT + 1))
    label="$(basename "$dir" | sed 's/^\.//')"
    tid="$(target_id setting "$argv:$digest")"
    target_gate "$tid" "persistently disable crash reporting in $label; restart the application afterward" || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      s_would "  would disable crash reporter in $label ($argv)"
    elif backup="$(python3 "$DIR/devclean-settings.py" disable "$argv" "$digest")"; then
      N_OPT_DONE=$((N_OPT_DONE + 1))
      s_ok "  disabled crash reporter in $label"
      printf '    Restore after closing the app: cp -- %q %q\n' "$backup" "$argv"
      journal_action config.update "$argv" succeeded "disabled crash reporter; restore=$backup"
    else
      N_FAILED=$((N_FAILED + 1))
      s_skip "  failed to disable crash reporter in $label"
      journal_action config.update "$argv" failed 'active JSONC setting was not changed'
    fi
  done
  [ "$found" -eq 1 ] || s_dim "  (none enabled)"
}

count_files() {
  local root="$1" pattern="${2:-}"
  if [ -n "$pattern" ]; then
    find "$root" -name "$pattern" -type f -print 2>/dev/null
  else
    find "$root" -type f -print 2>/dev/null
  fi | wc -l | tr -d ' '
}

clean_crashpad_dumps() {
  local count=0 unsafe=0 unavailable=0 dir diag canonical n remaining removed tid
  s_hdr "Crashpad dumps"

  if [ "$OS" = "Darwin" ]; then
    for dir in "$HOME/Library/Application Support"/*/Crashpad/pending "$HOME/Library/Application Support"/*/Crashpad/completed; do
      [ -d "$dir" ] || continue
      if ! canonical="$(home_dir_canonical "$dir")"; then
        unsafe=$((unsafe + 1))
        s_skip "  refusing Crashpad directory outside HOME: $dir"
        if [ "$DRY_RUN" -eq 0 ]; then
          N_FAILED=$((N_FAILED + 1))
          journal_action crash_dump.clean "$dir" failed "target resolves outside HOME or is a symlink"
        fi
        continue
      fi
      dir="$canonical"
      if ! n="$(count_files "$dir")"; then
        unavailable=$((unavailable + 1))
        s_skip "  could not inspect Crashpad directory: $dir"
        if [ "$DRY_RUN" -eq 0 ]; then
          N_FAILED=$((N_FAILED + 1))
          journal_action crash_dump.clean "$dir" failed "initial scan unavailable"
        fi
        continue
      fi
      [ "${n:-0}" -gt 0 ] || continue
      count=$((count + n))
      tid="$(target_id dumps "$dir:$(fp_for_artifact "$dir")")"
      target_gate "$tid" "permanently delete $n diagnostic files under $dir" || continue
      if [ "$DRY_RUN" -eq 1 ]; then
        s_would "  would delete $n files under $dir"
      else
        find "$dir" -type f -exec rm -f {} + 2>/dev/null
        if ! remaining="$(count_files "$dir")"; then
          s_skip "  could not confirm Crashpad cleanup under $dir"
          journal_action crash_dump.clean "$dir" failed "postcondition scan unavailable"
          N_FAILED=$((N_FAILED + 1))
          continue
        fi
        removed=$((n - ${remaining:-0}))
        [ "$removed" -lt 0 ] && removed=0
        N_OPT_DONE=$((N_OPT_DONE + removed))
        if [ "${remaining:-0}" -eq 0 ]; then
          s_ok "  deleted $removed files under $dir"
          journal_action crash_dump.clean "$dir" succeeded "files=$removed"
        else
          s_skip "  failed to delete ${remaining:-0} files under $dir"
          journal_action crash_dump.clean "$dir" failed "deleted=$removed; remaining=${remaining:-0}"
          N_FAILED=$((N_FAILED + 1))
        fi
      fi
    done

    diag="$HOME/Library/Logs/DiagnosticReports"
    if [ -d "$diag" ]; then
      if ! canonical="$(home_dir_canonical "$diag")"; then
        unsafe=$((unsafe + 1))
        s_skip "  refusing diagnostic reports outside HOME: $diag"
        if [ "$DRY_RUN" -eq 0 ]; then
          N_FAILED=$((N_FAILED + 1))
          journal_action crash_dump.clean "$diag" failed "target resolves outside HOME or is a symlink"
        fi
      else
        diag="$canonical"
        if ! n="$(count_files "$diag" 'chrome_crashpad_handler*.ips')"; then
          unavailable=$((unavailable + 1))
          s_skip "  could not inspect diagnostic reports: $diag"
          if [ "$DRY_RUN" -eq 0 ]; then
            N_FAILED=$((N_FAILED + 1))
            journal_action crash_dump.clean "$diag" failed "initial scan unavailable"
          fi
          n=0
        fi
      if [ "${n:-0}" -gt 0 ]; then
          count=$((count + n))
          tid="$(target_id dumps "$diag:$(fp_for_artifact "$diag")")"
          if ! target_gate "$tid" "permanently delete $n crashpad diagnostic reports under $diag"; then return 0; fi
          if [ "$DRY_RUN" -eq 1 ]; then
            s_would "  would delete $n chrome_crashpad_handler reports"
          else
            find "$diag" -name 'chrome_crashpad_handler*.ips' -type f -exec rm -f {} + 2>/dev/null
            if ! remaining="$(count_files "$diag" 'chrome_crashpad_handler*.ips')"; then
              s_skip "  could not confirm diagnostic report cleanup under $diag"
              journal_action crash_dump.clean "$diag" failed "postcondition scan unavailable"
              N_FAILED=$((N_FAILED + 1))
            else
              removed=$((n - ${remaining:-0}))
              [ "$removed" -lt 0 ] && removed=0
              N_OPT_DONE=$((N_OPT_DONE + removed))
              if [ "${remaining:-0}" -eq 0 ]; then
                s_ok "  deleted $removed chrome_crashpad_handler reports"
                journal_action crash_dump.clean "$diag" succeeded "files=$removed"
              else
                s_skip "  failed to delete ${remaining:-0} chrome_crashpad_handler reports"
                journal_action crash_dump.clean "$diag" failed "deleted=$removed; remaining=${remaining:-0}"
                N_FAILED=$((N_FAILED + 1))
              fi
            fi
          fi
        fi
      fi
    fi
  else
    for dir in "$HOME/.config"/*/Crashpad/pending "$HOME/.config"/*/Crashpad/completed; do
      [ -d "$dir" ] || continue
      if ! canonical="$(home_dir_canonical "$dir")"; then
        unsafe=$((unsafe + 1))
        s_skip "  refusing Crashpad directory outside HOME: $dir"
        if [ "$DRY_RUN" -eq 0 ]; then
          N_FAILED=$((N_FAILED + 1))
          journal_action crash_dump.clean "$dir" failed "target resolves outside HOME or is a symlink"
        fi
        continue
      fi
      dir="$canonical"
      if ! n="$(count_files "$dir")"; then
        unavailable=$((unavailable + 1))
        s_skip "  could not inspect Crashpad directory: $dir"
        if [ "$DRY_RUN" -eq 0 ]; then
          N_FAILED=$((N_FAILED + 1))
          journal_action crash_dump.clean "$dir" failed "initial scan unavailable"
        fi
        continue
      fi
      [ "${n:-0}" -gt 0 ] || continue
      count=$((count + n))
      tid="$(target_id dumps "$dir:$(fp_for_artifact "$dir")")"
      target_gate "$tid" "permanently delete $n diagnostic files under $dir" || continue
      if [ "$DRY_RUN" -eq 1 ]; then
        s_would "  would delete $n files under $dir"
      else
        find "$dir" -type f -exec rm -f {} + 2>/dev/null
        if ! remaining="$(count_files "$dir")"; then
          s_skip "  could not confirm Crashpad cleanup under $dir"
          journal_action crash_dump.clean "$dir" failed "postcondition scan unavailable"
          N_FAILED=$((N_FAILED + 1))
          continue
        fi
        removed=$((n - ${remaining:-0}))
        [ "$removed" -lt 0 ] && removed=0
        N_OPT_DONE=$((N_OPT_DONE + removed))
        if [ "${remaining:-0}" -eq 0 ]; then
          s_ok "  deleted $removed files under $dir"
          journal_action crash_dump.clean "$dir" succeeded "files=$removed"
        else
          s_skip "  failed to delete ${remaining:-0} files under $dir"
          journal_action crash_dump.clean "$dir" failed "deleted=$removed; remaining=${remaining:-0}"
          N_FAILED=$((N_FAILED + 1))
        fi
      fi
    done
  fi

  N_OPT=$((N_OPT + count + unsafe + unavailable))
  [ "$count" -gt 0 ] || [ "$unsafe" -gt 0 ] || [ "$unavailable" -gt 0 ] || s_dim "  (none)"
}

disable_background_agents() {
  s_hdr "Background agents"
  if [ "$OS" != "Darwin" ] || ! command -v launchctl >/dev/null 2>&1; then
    s_dim "  launchctl unavailable"
    return 0
  fi

  local entries entry label name found=0 tid
  entries=(
    "com.openai.chat-helper:ChatGPTHelper"
    "com.figma.agent:FigmaAgent"
  )
  for entry in "${entries[@]}"; do
    label="${entry%%:*}"
    name="${entry##*:}"
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || continue
    found=1
    N_OPT=$((N_OPT + 1))
    tid="$(target_id launch-agent "$(id -u):$label")"
    target_gate "$tid" "persistently disable $name ($label), including future logins" || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      s_would "  would disable $name ($label)"
    else
      if launchctl disable "gui/$(id -u)/$label" 2>/dev/null; then
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
          N_OPT_DONE=$((N_OPT_DONE + 1))
          s_ok "  disabled $name ($label)"
          s_dim "    Restore: launchctl enable gui/$(id -u)/$label ; then reopen $name's application"
          journal_action background_agent.disable "$label" succeeded "$name"
        else
          N_FAILED=$((N_FAILED + 1))
          s_skip "  failed to stop $name ($label)"
          journal_action background_agent.disable "$label" failed "agent still registered"
        fi
      else
        N_FAILED=$((N_FAILED + 1))
        s_skip "  failed to disable $name ($label)"
        journal_action background_agent.disable "$label" failed "launchctl disable failed"
      fi
    fi
  done
  [ "$found" -eq 1 ] || s_dim "  (none registered)"
}

run_optimize() {
  echo
  s_lead "$MODE_C" "Optimize audit ($(mode_label))" "Optimize audit ($(mode_label))"
  patch_crash_reporters
  clean_crashpad_dumps
  disable_background_agents
}

DISK_TOTAL_KB=0
DISK_FOUND_KB=0

size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print int($1)}'
}

# Resolve an existing path and prove it remains below HOME. Resolving the
# parent catches ~/.config -> /shared; rejecting a final symlink catches a
# linked argv.json/dump directory without depending on non-portable realpath.
home_path_canonical() {
  local target="$1" kind="$2" canonical parent base
  [ -e "$target" ] || return 1
  [ ! -L "$target" ] || return 1
  case "$kind" in
    dir)
      [ -d "$target" ] || return 1
      canonical="$(cd "$target" && pwd -P)" || return 1
      ;;
    file)
      [ -f "$target" ] || return 1
      parent="$(dirname "$target")"
      base="$(basename "$target")"
      parent="$(cd "$parent" && pwd -P)" || return 1
      canonical="$parent/$base"
      ;;
    *) return 1 ;;
  esac
  case "$canonical" in
    "$HOME_CANONICAL"/*) printf '%s' "$canonical" ;;
    *) return 1 ;;
  esac
}

home_dir_canonical() { home_path_canonical "$1" dir; }
home_file_canonical() { home_path_canonical "$1" file; }

# Styled DRY-RUN buffers each disk section's rows and redraws them as
# share-of-section meters at the section boundary (disk_flush). Plain output
# and --apply keep streaming the legacy lines: plain is a byte contract
# (tests grep piped "would clean ..." lines) and apply must narrate
# destructive work live, not after the fact. Buffer appends must run in the
# main shell — the clean_* helpers already do (find via process substitution).
DISK_BUF=()
disk_buffering() { [ "$STYLE_ON" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; }
disk_flush() {
  disk_buffering || return 0
  [ "${#DISK_BUF[@]}" -gt 0 ] || return 0
  local row type kb label detail total=0
  for row in ${DISK_BUF[@]+"${DISK_BUF[@]}"}; do
    IFS=$'\t' read -r type kb label detail <<< "$row"
    [ "$label" = "-" ] && label=""
    [ "$type" = meter ] && total=$((total + kb))
  done
  for row in ${DISK_BUF[@]+"${DISK_BUF[@]}"}; do
    # "-" is the sentinel for an empty label. Tab is IFS-whitespace, so an
    # actually-empty field collapses and every later column shifts left --
    # which silently swallowed the pnpm line: the text landed in $label and
    # $detail, the thing printed, was empty. Third occurrence of this hazard
    # in the repo; CLAUDE.md documents it.
    IFS=$'\t' read -r type kb label detail <<< "$row"
    [ "$label" = "-" ] && label=""
    if [ "$type" = meter ]; then
      if [ -n "$detail" ]; then
        printf '  %-26.26s %s %s  %s%s%s\n' "$label" \
          "$(s_sizecell "$kb" "$(s_meter "$kb" "$total")")" \
          "$(s_sizecell "$kb" "$(printf '%9s' "$(s_kb "$kb")")")" \
          "$C_DIM" "$detail" "$C_RESET"
      else
        printf '  %-26.26s %s %s\n' "$label" \
          "$(s_sizecell "$kb" "$(s_meter "$kb" "$total")")" \
          "$(s_sizecell "$kb" "$(printf '%9s' "$(s_kb "$kb")")")"
      fi
    else
      s_would "  $detail"
    fi
  done
  DISK_BUF=()
}

clean_dir() {
  local label="$1" target="$2" kind="${3:-cache}" kb canonical tid fp operation=cache.clean
  [ -d "$target" ] || return 0
  [ -L "$target" ] && return 0
  if ! canonical="$(home_dir_canonical "$target")"; then
    s_skip "  refusing $label outside HOME: $target"
    if [ "$DRY_RUN" -eq 0 ]; then
      journal_action cache.clean "$target" failed "target resolves outside HOME"
      N_FAILED=$((N_FAILED + 1))
    fi
    return 1
  fi
  target="$canonical"
  [ "$kind" != history ] || operation=history.clean
  s_heartbeat "sizing up $target"
  kb="$(size_kb "$target")"
  [ "${kb:-0}" -ge 1024 ] || return 0
  DISK_FOUND_KB=$((DISK_FOUND_KB + kb))
  fp="$(fp_for_artifact "$target")" || fp=""
  if [ -z "$fp" ]; then withhold "$label" 'filesystem identity unavailable'; return 1; fi
  tid="$kind:$fp"
  if [ "$kind" = history ]; then
    target_gate "$tid" "permanently delete history under $target; cannot be rebuilt" || return 0
  else
    target_gate "$tid" "delete rebuildable $label at $target; future runs may rebuild or download it" || return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    DISK_TOTAL_KB=$((DISK_TOTAL_KB + kb))
    if disk_buffering; then
      DISK_BUF+=("$(printf 'meter\t%s\t%s\t%s' "$kb" "$label" "$target")")
    else
      s_would "  would clean $label: $target ($(human_mb "$kb"))"
    fi
  else
    if [ "$kind" = history ] && ! history_is_stale "$target"; then
      withhold "$label" 'recent or unavailable history activity at removal'; return 1
    fi
    if [ "$(fp_for_artifact "$target")" != "$fp" ]; then withhold "$label" 'identity changed before removal'; return 1; fi
    if rm -rf -- "$target" 2>/dev/null && [ ! -e "$target" ]; then
      DISK_TOTAL_KB=$((DISK_TOTAL_KB + kb))
      if [ "$kind" = history ]; then N_HISTORY_DONE=$((N_HISTORY_DONE + 1)); else N_CACHE_DONE=$((N_CACHE_DONE + 1)); fi
      s_ok "  cleaned $label: $target ($(human_mb "$kb"))"
      journal_action "$operation" "$target" succeeded "kilobytes=$kb; label=$label"
    else
      s_skip "  failed to clean $label: $target"
      journal_action "$operation" "$target" failed "target still exists; label=$label"
      N_FAILED=$((N_FAILED + 1))
      return 1
    fi
  fi
}

# The roaming project scan is REPORT-ONLY as of 0.9.0.
#
# clean_dir targets an exact, named cache path -- ~/.gradle/caches is a cache by
# definition and stays live. clean_find is different in kind: it walks
# $DOCUMENTS_ROOT looking for a NAME, and its whole filter set was "not a
# symlink, parent holds a sentinel, >= 1 MB". No liveness check, no git-tracked
# veto, no age gate, and no requirement that the target ever appeared in a dry
# run. Verified: it deleted a 4 MB node_modules from an unrelated git repo that
# the user never named.
#
# Reinstalling node_modules is not free -- native modules, private registries,
# a lockfile that no longer resolves -- and doing it to a project someone is
# mid-task in is worse. Removal moves behind plan/apply with typed artifact
# targets and an exact generated-target allowlist.
clean_find_withheld() {
  [ "$DRY_RUN" -eq 0 ] || return 1
  return 0
}

clean_find() {
  local label="$1" scan_dir="$2" dir_name="$3" parent_files=() found=0 total=0 deleted=0 freed=0 d parent_dir valid pf kb
  shift 3
  parent_files=("$@")
  [ -d "$scan_dir" ] || return 0

  s_heartbeat "scanning $scan_dir for $dir_name dirs"
  while IFS= read -r -d '' d; do
    [ -n "$d" ] || continue
    [ -L "$d" ] && continue
    parent_dir="$(dirname "$d")"
    valid=0
    if [ "${#parent_files[@]}" -eq 0 ]; then
      valid=1
    else
      for pf in "${parent_files[@]}"; do
        if [ -f "$parent_dir/$pf" ]; then
          valid=1
          break
        fi
      done
    fi
    [ "$valid" -eq 1 ] || continue
    kb="$(size_kb "$d")"
    [ "${kb:-0}" -ge 1024 ] || continue
    found=$((found + 1))
    total=$((total + kb))
    withhold "$label" "$d (roaming discovery is report-only; review this directory manually)"
  done < <(find "$scan_dir" -mindepth 1 -maxdepth "$PROJECT_MAXDEPTH" -type d -name "$dir_name" -prune -print0 2>/dev/null)

  [ "$found" -gt 0 ] || return 0
  s_dim "  report-only: $found $label dirs ($(human_mb "$total")); excluded from reclaimable total"
}

# Codex CLI keeps every session transcript forever (no built-in retention),
# so old ones are fair game — but recent transcripts power resume and are the
# audit trail of what agents did. Delete only date folders older than
# CODEX_SESSION_AGE_DAYS, mirroring Claude Code's default retention. The
# YYYY/MM/DD layout makes this a zero-padded string comparison, no mtimes.
# A successful scan of every regular file must prove retention age. The date
# bucket is only discovery: a resumed old session can have fresh file mtimes.
history_is_stale() {
  local path="$1" file stamp seen=0 cutoff
  cutoff=$(( $(date +%s) - CODEX_SESSION_AGE_DAYS * 86400 ))
  find "$path" -type f -print0 > "$PROCESS_CONTEXT/history-files" 2>/dev/null || return 2
  while IFS= read -r -d '' file; do
    stamp="$(ws_mtime "$file")" || return 2
    case "$stamp" in ''|*[!0-9]*) return 2 ;; esac
    [ "$stamp" -lt "$cutoff" ] || return 1
    seen=1
  done < "$PROCESS_CONTEXT/history-files"
  [ "$seen" -eq 1 ] || return 2
}

clean_history() {
  local label="$1" path="$2" rc
  [ -d "$path" ] || return 0
  if history_is_stale "$path"; then
    clean_dir "$label" "$path" history
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then withhold "$label" "recent activity under $path; retained"
    else withhold "$label" "complete activity evidence unavailable for $path; retained"; fi
  fi
}

clean_codex_sessions() {
  local base="$HOME/.codex/sessions" cutoff d rel
  [ -d "$base" ] || return 0
  cutoff="$(date -d "$CODEX_SESSION_AGE_DAYS days ago" +%Y/%m/%d 2>/dev/null \
    || date -v -"${CODEX_SESSION_AGE_DAYS}d" +%Y/%m/%d 2>/dev/null)"
  [ -n "$cutoff" ] || return 0
  for d in "$base"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]; do
    [ -d "$d" ] || continue
    rel="${d#"$base"/}"
    if [ "$rel" \< "$cutoff" ]; then
      clean_history "Codex sessions (>${CODEX_SESSION_AGE_DAYS}d since activity)" "$d"
    fi
  done
}

# pnpm's store is content-addressed and shared by every pnpm project, so
# rm -rf (the clean_dir treatment) would evict packages live repos still
# link to. `pnpm store prune` drops only unreferenced packages — that is the
# only action ever taken here. Dry run reports the store size as context;
# apply counts the actually-freed space toward the disk total.
clean_pnpm_store() {
  command -v pnpm >/dev/null 2>&1 || return 0
  local store kb_before kb_after freed size_known=1
  store="$(pnpm store path 2>/dev/null)"
  [ -n "$store" ] && [ -d "$store" ] || return 0
  s_heartbeat "sizing up pnpm store"
  kb_before="$(size_kb "$store")"
  case "$kb_before" in ''|*[!0-9]*) size_known=0 ;; esac
  target_gate "$(target_id package-store "$store")" "run pnpm store prune for shared store $store" || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    # Store size is context, not reclaimable space — buffer a bar-less note
    # row so it never inflates the section's meter shares.
    if disk_buffering; then
      if [ "$size_known" -eq 1 ]; then
        DISK_BUF+=("$(printf 'note\t0\t-\twould run pnpm store prune (store: %s)' "$(human_mb "$kb_before")")")
      else
        DISK_BUF+=("$(printf 'note\t0\t-\twould run pnpm store prune (store size unavailable)')")
      fi
    else
      if [ "$size_known" -eq 1 ]; then
        s_would "  would run pnpm store prune (store: $(human_mb "$kb_before"))"
      else
        s_would "  would run pnpm store prune (store size unavailable)"
      fi
    fi
    return 0
  fi
  if ! pnpm store prune >/dev/null 2>&1; then
    s_skip "  failed to prune pnpm store"
    journal_action cache.clean "$store" failed "pnpm store prune failed"
    N_FAILED=$((N_FAILED + 1))
    return 1
  fi
  N_CACHE_DONE=$((N_CACHE_DONE + 1))
  kb_after="$(size_kb "$store")"
  case "$kb_after" in ''|*[!0-9]*) size_known=0 ;; esac
  if [ "$size_known" -eq 0 ]; then
    s_ok "  pruned pnpm store (size change unavailable)"
    journal_action cache.clean "$store" succeeded "label=pnpm store; kilobytes unavailable"
    return 0
  fi
  freed=$(( ${kb_before:-0} - ${kb_after:-0} ))
  [ "$freed" -lt 0 ] && freed=0
  DISK_TOTAL_KB=$((DISK_TOTAL_KB + freed))
  s_ok "  pruned pnpm store: freed $(human_mb "$freed") (now $(human_mb "${kb_after:-0}"))"
  # journal_action returns nonzero when the journal is busy, and this is the
  # last statement of the function -- without || true a busy journal would make
  # a successful prune look like a failed one to the caller.
  journal_action cache.clean "$store" succeeded "kilobytes=$freed; label=pnpm store" || true
}

clean_fvm_incomplete() {
  local base ver_dir ver_name
  for base in "$HOME/fvm/versions" "$HOME/.fvm/versions"; do
    [ -d "$base" ] || continue
    for ver_dir in "$base"/*; do
      [ -d "$ver_dir" ] || continue
      [ ! -f "$ver_dir/bin/flutter" ] || continue
      ver_name="$(basename "$ver_dir")"
      clean_dir "FVM incomplete ($ver_name)" "$ver_dir"
    done
  done
}

run_repo_artifacts() {
  [ "$RUN_REPO_ARTIFACTS" -eq 1 ] || return 0
  [ -x "$DIR/clean-artifacts.sh" ] || return 0
  if ! git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    return 0
  fi

  s_hdr "Current repo artifacts"
  AFTERPARTY_CARD=0 "$DIR/clean-artifacts.sh"
  printf '  Repository artifacts are report-only here. Review: afterparty plan --root %q\n' "$PWD"
}

run_disk() {
  echo
  s_lead "$MODE_C" "Disk cleanup audit ($(mode_label))" "Disk cleanup audit ($(mode_label))"

  s_hdr "macOS developer caches"
  if [ "$OS" = "Darwin" ]; then
    clean_dir "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"
    clean_dir "iOS DeviceSupport" "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
    clean_dir "XCTestDevices" "$HOME/Library/Developer/XCTestDevices"
    clean_dir "CocoaPods cache" "$HOME/Library/Caches/CocoaPods"
    clean_dir "Playwright cache" "$HOME/Library/Caches/ms-playwright"
  else
    s_dim "  (not macOS)"
  fi

  disk_flush
  s_hdr "Cross-platform developer caches"
  clean_dir "Gradle caches" "$HOME/.gradle/caches"
  clean_dir "Gradle wrapper" "$HOME/.gradle/wrapper"
  clean_dir "CocoaPods repos" "$HOME/.cocoapods/repos"
  clean_dir "Pub cache" "$HOME/.pub-cache"
  clean_dir "npm cache" "$HOME/.npm"
  clean_pnpm_store

  disk_flush
  s_hdr "Incomplete SDK downloads"
  clean_fvm_incomplete

  disk_flush
  s_hdr "Project artifacts under $DOCUMENTS_ROOT"
  clean_find "project build/" "$DOCUMENTS_ROOT" "build" \
    "pubspec.yaml" "build.gradle" "build.gradle.kts" "Makefile" "CMakeLists.txt"
  clean_find "project .dart_tool/" "$DOCUMENTS_ROOT" ".dart_tool" "pubspec.yaml"
  clean_find "project .gradle/" "$DOCUMENTS_ROOT" ".gradle" "build.gradle" "build.gradle.kts" "settings.gradle"
  clean_find "project node_modules/" "$DOCUMENTS_ROOT" "node_modules" "package.json"

  disk_flush
  run_repo_artifacts

  echo
  if [ "$DISK_TOTAL_KB" -gt 0 ]; then
    if [ "$STYLE_ON" -eq 1 ]; then
      # Styled total tints the figure; the else-branch keeps the exact
      # legacy bytes.
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'Global disk reclaimable: %s\n' "$(s_sizecell "$DISK_TOTAL_KB" "$(human_mb "$DISK_TOTAL_KB")")"
      else
        printf 'Global disk reclaimed: %s\n' "$(s_sizecell "$DISK_TOTAL_KB" "$(human_mb "$DISK_TOTAL_KB")")"
      fi
    else
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "Global disk reclaimable: $(human_mb "$DISK_TOTAL_KB")"
      else
        echo "Global disk reclaimed: $(human_mb "$DISK_TOTAL_KB")"
      fi
    fi
  elif [ "$DRY_RUN" -eq 0 ] && [ "$DISK_FOUND_KB" -gt 0 ]; then
    echo "Global disk reclaimed: 0.0 MB (cleanup failures above)"
  else
    echo "No significant global dev caches found."
  fi
}

run_history() {
  s_hdr "History retention — permanent deletion, ${CODEX_SESSION_AGE_DAYS} days since last activity"
  clean_codex_sessions
  clean_history "Codex logs" "$HOME/.codex/log"
  clean_history "Gemini browser recordings" "$HOME/.gemini/antigravity/browser_recordings"
  disk_flush
}

followup_command() {
  local selected
  [ "$HISTORY" -eq 0 ] || printf 'CODEX_SESSION_AGE_DAYS=%s ' "$CODEX_SESSION_AGE_DAYS"
  printf 'afterparty devclean'
  [ "$ORPHANS" -eq 0 ] || printf ' --orphans'
  [ "$DEEP" -eq 0 ] || printf ' --deep'
  [ "$OPTIMIZE" -eq 0 ] || printf ' --optimize'
  [ "$DISK" -eq 0 ] || printf ' --disk'
  [ "$HISTORY" -eq 0 ] || printf ' --history'
  if [ "$DISK" -eq 1 ]; then
    printf ' --documents-root %q --project-maxdepth %q' "$DOCUMENTS_ROOT" "$PROJECT_MAXDEPTH"
    [ "$RUN_REPO_ARTIFACTS" -eq 1 ] || printf ' --no-repo-artifacts'
    [ "$ALLOW_BROAD_DOCUMENTS_ROOT" -eq 0 ] || printf ' --allow-broad-documents-root'
  fi
  printf ' --apply --target <reviewed-id>'
}

if [ "$DRY_RUN" -eq 1 ]; then
  s_lead "$MODE_C" "Mode: $(mode_label) — look, don't touch" "Mode: $(mode_label)"
else
  s_lead "$MODE_C" "Mode: $(mode_label) — closing time" "Mode: $(mode_label)"
fi
if [ "$ORPHANS" -eq 1 ] || [ "$DEEP" -eq 1 ]; then refresh_process_context; fi
[ "$ORPHANS" -eq 1 ] && run_safe_orphans
[ "$DEEP" -eq 1 ] && run_deep
[ "$OPTIMIZE" -eq 1 ] && run_optimize
[ "$DISK" -eq 1 ] && run_disk
[ "$HISTORY" -eq 1 ] && run_history

if [ "$DRY_RUN" -eq 0 ]; then
  for requested in "${REQUESTED_TARGETS[@]}"; do
    case " $SEEN_TARGETS " in
      *" $requested "*) : ;;
      *) withhold "$requested" 'not found with the reviewed identity in the selected modes; preview again' ;;
    esac
  done
  printf 'Selected cleanup: %s process(es) stopped, %s cache action(s), %s history action(s), %s settings/dump/agent actions, %s withheld, %s unselected, %s failed\n' \
    "$N_PROC_STOPPED" "$N_CACHE_DONE" "$N_HISTORY_DONE" "$N_OPT_DONE" "$N_WITHHELD" "$N_UNSELECTED" "$N_FAILED"
elif [ -n "$SEEN_TARGETS" ]; then
  printf 'To apply selected targets: '; followup_command; printf '\n'
fi

if [ "$DEEP" -eq 0 ] && [ "$OPTIMIZE" -eq 0 ] && [ "$DISK" -eq 0 ] && [ "$HISTORY" -eq 0 ]; then
  echo
  s_dim "Other previews: --deep, --optimize, --disk, or --history. Apply requires selected target IDs."
fi

# Finale card (styled runs only; doctor suppresses via AFTERPARTY_CARD=0).
if cards_on; then
  echo
  s_card_open
  if [ "$DRY_RUN" -eq 0 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty devclean --apply${C_RESET}"
    segs="$(s_segments \
      "$([ "$N_PROC_STOPPED" -gt 0 ] && echo "$G_OK $(s_n "$N_PROC_STOPPED" 'proc' 'procs')")" \
      "$([ "$N_OPT_DONE" -gt 0 ] && echo "$G_OK $N_OPT_DONE tidied")" \
      "$([ "$DISK_TOTAL_KB" -gt 0 ] && echo "$(human_mb "$DISK_TOTAL_KB") freed")" \
      "$([ "$N_WITHHELD" -gt 0 ] && echo "$G_SKIP $N_WITHHELD withheld")" \
      "$([ "$N_FAILED" -gt 0 ] && echo "$G_SKIP $N_FAILED failed")")"
    if [ -n "$segs" ]; then s_card_line "   $segs"; fi
    if [ "$N_PROC_STOPPED" -eq 0 ] && [ "$DISK_TOTAL_KB" -eq 0 ] && [ "$N_OPT_DONE" -eq 0 ] && [ "$N_FAILED" -eq 0 ]; then
      if [ "$N_WITHHELD" -gt 0 ] || [ "$N_UNSELECTED" -gt 0 ]; then
        s_card_line "   no work confirmed — $N_WITHHELD withheld, $N_UNSELECTED unselected"
      else s_card_line "   nothing needed doing — already spotless ✨"; fi
    else
      [ "$N_PROC_STOPPED" -gt 0 ] && s_card_line "   $(s_n "$N_PROC_STOPPED" 'process sent home' 'processes sent home')"
      [ "$N_OPT_DONE" -gt 0 ] && s_card_line "   tidied $(s_n "$N_OPT_DONE" 'optimize target' 'optimize targets')"
      [ "$DISK_TOTAL_KB" -gt 0 ] && s_card_line "   $(human_mb "$DISK_TOTAL_KB") hauled to the curb"
      [ "$N_FAILED" -gt 0 ] && s_card_line "   $N_FAILED action(s) could not be confirmed"
      [ "$N_WITHHELD" -gt 0 ] && s_card_line "   $N_WITHHELD target(s) withheld; see reasons above"
      s_card_line
      s_card_line "   thanks for partying responsibly 🎉"
    fi
  elif [ "$N_PROC" -gt 0 ] || [ "$DISK_TOTAL_KB" -gt 0 ] || [ "$N_OPT" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — devclean${C_RESET}"
    segs="$(s_segments \
      "$([ "$N_PROC" -gt 0 ] && echo "$G_ACT $(s_n "$N_PROC" 'proc' 'procs')")" \
      "$([ "$N_OPT" -gt 0 ] && echo "$G_ACT $N_OPT to tidy")" \
      "$([ "$DISK_TOTAL_KB" -gt 0 ] && echo "$(human_mb "$DISK_TOTAL_KB") reclaimable")")"
    s_card_line "   $segs"
    [ "$N_PROC" -gt 0 ] && s_card_line "   $(s_n "$N_PROC" 'orphaned process still partying' 'orphaned processes still partying')"
    [ "$N_OPT" -gt 0 ] && s_card_line "   $(s_n "$N_OPT" 'optimize target to tidy' 'optimize targets to tidy')"
    [ "$DISK_TOTAL_KB" -gt 0 ] && s_card_line "   $(human_mb "$DISK_TOTAL_KB") of caches to haul out"
    s_card_line
    s_card_line "   select target IDs from the preview above"
    s_card_line "   $(followup_command)"
  elif [ "$N_WITHHELD" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}$N_WITHHELD target(s) withheld — manual review required${C_RESET}"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — the house is quiet${C_RESET}"
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
fi

if [ "$N_FAILED" -gt 0 ] || { [ "$DRY_RUN" -eq 0 ] && [ "$N_WITHHELD" -gt 0 ]; }; then exit 1; fi
