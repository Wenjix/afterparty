#!/usr/bin/env bash
# devclean.sh - devclean-style cleanup for agent/dev-machine leaks.
#
# Dry-run is the default. Pass --apply to terminate processes, patch settings, or
# delete rebuildable caches.
#
# Usage:
#   devclean.sh                         # audit safe orphaned dev processes
#   devclean.sh --apply                 # kill safe orphaned dev processes
#   devclean.sh --deep                  # include heavy daemon audit
#   devclean.sh --optimize              # audit IDE crash reporters / Crashpad / agents
#   devclean.sh --disk                  # audit global dev caches + project artifacts
#   devclean.sh --deep --disk --apply   # act on selected modes
#   devclean.sh --dry-run               # force dry-run (the default)
#   devclean.sh --documents-root DIR    # where --disk scans for project artifacts
#   devclean.sh --project-maxdepth N    # --disk project scan depth (default 6)
#   devclean.sh --no-repo-artifacts     # --disk: skip the current-repo artifact pass
set -uo pipefail

# Every cleanup target below is composed from $HOME; an empty HOME would turn
# them into root-anchored paths.
if [ -z "${HOME:-}" ]; then
  echo "devclean.sh: HOME is not set; refusing to run" >&2
  exit 2
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
OS="$(uname -s)"

DRY_RUN=1
DEEP=0
OPTIMIZE=0
DISK=0
DOCUMENTS_ROOT="$HOME/Documents"
PROJECT_MAXDEPTH=6
RUN_REPO_ARTIFACTS=1

usage() {
  sed -n '2,17p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply|--kill|--clean) DRY_RUN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --deep) DEEP=1; shift ;;
    --optimize) OPTIMIZE=1; shift ;;
    --disk) DISK=1; shift ;;
    --documents-root) DOCUMENTS_ROOT="${2:?}"; shift 2 ;;
    --project-maxdepth) PROJECT_MAXDEPTH="${2:?}"; shift 2 ;;
    --no-repo-artifacts) RUN_REPO_ARTIFACTS=0; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

mode_label() {
  [ "$DRY_RUN" -eq 1 ] && echo "DRY RUN" || echo "APPLY"
}

MODE_C="$C_YEL"
if [ "$DRY_RUN" -eq 0 ]; then MODE_C="$C_RED"; fi
N_PROC=0
N_OPT=0   # optimize findings/actions: crash reporters, crashpad files, agents
# Age gate for Codex session transcripts; default matches Claude Code's
# default transcript retention. Override via the environment.
CODEX_SESSION_AGE_DAYS="${CODEX_SESSION_AGE_DAYS:-30}"
case "$CODEX_SESSION_AGE_DAYS" in
  ''|*[!0-9]*) echo "CODEX_SESSION_AGE_DAYS wants a whole number of days" >&2; exit 2 ;;
esac

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

# rg when available, grep -E otherwise, so the ps fallback path in
# pids_by_pattern still matches when ripgrep is missing.
match_i() {
  if command -v rg >/dev/null 2>&1; then rg -i -- "$1"; else grep -Ei -- "$1"; fi
}

rss_kb_for() {
  ps -o rss= -p "$1" 2>/dev/null | awk '{print int($1)}'
}

filter_pids() {
  local pid
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    is_live_pid "$pid" || continue
    printf '%s\n' "$pid"
  done | unique_words
}

pids_by_pattern() {
  local pattern="$1" scope="${2:-all}"
  if command -v pgrep >/dev/null 2>&1; then
    if [ "$scope" = "orphans" ]; then
      pgrep -P 1 -f "$pattern" 2>/dev/null || true
    else
      pgrep -f "$pattern" 2>/dev/null || true
    fi
    return
  fi

  if [ "$scope" = "orphans" ]; then
    ps -eo ppid=,pid=,command= 2>/dev/null | awk '$1 == 1 { $1=""; print }' | match_i "$pattern" | awk '{print $1}' || true
  else
    ps -eo pid=,command= 2>/dev/null | match_i "$pattern" | awk '{print $1}' || true
  fi
}

print_process_table() {
  local pids="$1" pid rss total=0 count=0 hc="" hr=""
  [ -n "$pids" ] || return 1

  if [ "$STYLE_ON" -eq 1 ]; then hc="$C_DIM"; hr="$C_RESET"; fi
  printf '  %s%-7s %-7s %-7s %-8s %-6s %-10s %s%s\n' "$hc" PID PPID PGID RSS CPU ELAPSED COMMAND "$hr"
  for pid in $pids; do
    rss="$(rss_kb_for "$pid")"
    total=$((total + ${rss:-0}))
    count=$((count + 1))
    ps -o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p "$pid" 2>/dev/null \
      | awk '{printf "  %-7s %-7s %-7s %-8s %-6s %-10s ", $1,$2,$3,$4,$5,$6; for(i=7;i<=NF;i++) printf "%s ", $i; print ""}'
  done
  echo "  count: $count; rss: $(human_mb "$total")"
}

terminate_pids() {
  local pids="$1" pid waited remaining
  [ -n "$pids" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    s_would "  would SIGTERM PIDs: $pids"
    return 0
  fi

  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null && s_kill "  SIGTERM -> pid $pid"
  done

  waited=0
  while [ "$waited" -lt 4 ]; do
    remaining=""
    for pid in $pids; do
      is_live_pid "$pid" && remaining="$remaining $pid"
    done
    remaining="$(printf '%s\n' "$remaining" | xargs 2>/dev/null)"
    [ -z "$remaining" ] && return 0
    sleep 0.5
    waited=$((waited + 1))
  done

  for pid in $remaining; do
    kill -KILL "$pid" 2>/dev/null && s_kill "  SIGKILL -> pid $pid"
  done
}

cleanup_pattern() {
  local label="$1" pattern="$2" scope="${3:-all}" pids
  pids="$(filter_pids $(pids_by_pattern "$pattern" "$scope"))"
  s_hdr "$label ($scope)"
  if [ -z "$pids" ]; then
    s_dim "  (none)"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $pids
  N_PROC=$((N_PROC + $#))
  print_process_table "$pids"
  terminate_pids "$pids"
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
  s_lead "$MODE_C" "devclean safe orphan audit ($(mode_label))" "devclean safe orphan audit ($(mode_label))"
  cleanup_pattern "Safe orphaned dev processes" "$re" "orphans"
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

  if [ "$OS" = "Darwin" ] && command -v xcrun >/dev/null 2>&1; then
    s_hdr "iOS Simulators"
    sim_pids="$(filter_pids $(pids_by_pattern 'CoreSimulator|Simulator\.app' all))"
    if [ -n "$sim_pids" ]; then
      # shellcheck disable=SC2086
      set -- $sim_pids
      N_PROC=$((N_PROC + $#))
      print_process_table "$sim_pids"
      if [ "$DRY_RUN" -eq 1 ]; then
        s_would "  would run: xcrun simctl shutdown all"
      else
        xcrun simctl shutdown all 2>/dev/null && s_ok "  shutdown all simulators"
      fi
    else
      s_dim "  (none)"
    fi
  fi
}

patch_crash_reporters() {
  local dirs argv label
  dirs=(
    "$HOME/.vscode"
    "$HOME/.cursor"
    "$HOME/.windsurf"
    "$HOME/.antigravity"
    "$HOME/.kiro"
    "$HOME/.vscode-oss"
  )

  s_hdr "IDE crash reporters"
  found=0
  for dir in "${dirs[@]}"; do
    argv="$dir/argv.json"
    [ -f "$argv" ] || continue
    grep -q '"enable-crash-reporter"[[:space:]]*:[[:space:]]*true' "$argv" || continue
    found=1
    N_OPT=$((N_OPT + 1))
    label="$(basename "$dir" | sed 's/^\.//')"
    if [ "$DRY_RUN" -eq 1 ]; then
      s_would "  would disable crash reporter in $label ($argv)"
    else
      sed -i.bak 's/"enable-crash-reporter"[[:space:]]*:[[:space:]]*true/"enable-crash-reporter": false/' "$argv"
      rm -f "$argv.bak"
      s_ok "  disabled crash reporter in $label"
    fi
  done
  [ "$found" -eq 1 ] || s_dim "  (none enabled)"
}

clean_crashpad_dumps() {
  local count=0 dir diag
  s_hdr "Crashpad dumps"

  if [ "$OS" = "Darwin" ]; then
    for dir in "$HOME/Library/Application Support"/*/Crashpad/pending "$HOME/Library/Application Support"/*/Crashpad/completed; do
      [ -d "$dir" ] || continue
      n="$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
      [ "${n:-0}" -gt 0 ] || continue
      count=$((count + n))
      if [ "$DRY_RUN" -eq 1 ]; then
        s_would "  would delete $n files under $dir"
      else
        find "$dir" -type f -exec rm -f {} + 2>/dev/null
        s_ok "  deleted $n files under $dir"
      fi
    done

    diag="$HOME/Library/Logs/DiagnosticReports"
    if [ -d "$diag" ]; then
      n="$(find "$diag" -name 'chrome_crashpad_handler*.ips' -type f 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${n:-0}" -gt 0 ]; then
        count=$((count + n))
        if [ "$DRY_RUN" -eq 1 ]; then
          s_would "  would delete $n chrome_crashpad_handler reports"
        else
          find "$diag" -name 'chrome_crashpad_handler*.ips' -type f -exec rm -f {} + 2>/dev/null
          s_ok "  deleted $n chrome_crashpad_handler reports"
        fi
      fi
    fi
  else
    for dir in "$HOME/.config"/*/Crashpad/pending "$HOME/.config"/*/Crashpad/completed; do
      [ -d "$dir" ] || continue
      n="$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
      [ "${n:-0}" -gt 0 ] || continue
      count=$((count + n))
      if [ "$DRY_RUN" -eq 1 ]; then
        s_would "  would delete $n files under $dir"
      else
        find "$dir" -type f -exec rm -f {} + 2>/dev/null
        s_ok "  deleted $n files under $dir"
      fi
    done
  fi

  N_OPT=$((N_OPT + count))
  [ "$count" -gt 0 ] || s_dim "  (none)"
}

disable_background_agents() {
  s_hdr "Background agents"
  if [ "$OS" != "Darwin" ] || ! command -v launchctl >/dev/null 2>&1; then
    s_dim "  launchctl unavailable"
    return 0
  fi

  local entries entry label name found=0
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
    if [ "$DRY_RUN" -eq 1 ]; then
      s_would "  would disable $name ($label)"
    else
      launchctl disable "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      s_ok "  disabled $name ($label)"
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

size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print int($1)}'
}

clean_dir() {
  local label="$1" target="$2" kb
  [ -d "$target" ] || return 0
  [ -L "$target" ] && return 0
  kb="$(size_kb "$target")"
  [ "${kb:-0}" -ge 1024 ] || return 0
  DISK_TOTAL_KB=$((DISK_TOTAL_KB + kb))

  if [ "$DRY_RUN" -eq 1 ]; then
    s_would "  would clean $label: $target ($(human_mb "$kb"))"
  else
    rm -rf "$target"
    s_ok "  cleaned $label: $target ($(human_mb "$kb"))"
  fi
}

clean_find() {
  local label="$1" scan_dir="$2" dir_name="$3" parent_files=() found=0 total=0
  shift 3
  parent_files=("$@")
  [ -d "$scan_dir" ] || return 0

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
    if [ "$DRY_RUN" -eq 0 ]; then
      rm -rf "$d"
    fi
  done < <(find "$scan_dir" -maxdepth "$PROJECT_MAXDEPTH" -type d -name "$dir_name" -prune -print0 2>/dev/null)

  [ "$found" -gt 0 ] || return 0
  DISK_TOTAL_KB=$((DISK_TOTAL_KB + total))
  if [ "$DRY_RUN" -eq 1 ]; then
    s_would "  would clean $found $label dirs ($(human_mb "$total"))"
  else
    s_ok "  cleaned $found $label dirs ($(human_mb "$total"))"
  fi
}

# Codex CLI keeps every session transcript forever (no built-in retention),
# so old ones are fair game — but recent transcripts power resume and are the
# audit trail of what agents did. Delete only date folders older than
# CODEX_SESSION_AGE_DAYS, mirroring Claude Code's default retention. The
# YYYY/MM/DD layout makes this a zero-padded string comparison, no mtimes.
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
      clean_dir "Codex sessions (>${CODEX_SESSION_AGE_DAYS}d)" "$d"
    fi
  done
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
  if [ "$DRY_RUN" -eq 1 ]; then
    AFTERPARTY_CARD=0 "$DIR/clean-artifacts.sh"
  else
    AFTERPARTY_CARD=0 "$DIR/clean-artifacts.sh" --clean
  fi
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

  s_hdr "Cross-platform developer caches"
  clean_dir "Gradle caches" "$HOME/.gradle/caches"
  clean_dir "Gradle wrapper" "$HOME/.gradle/wrapper"
  clean_dir "CocoaPods repos" "$HOME/.cocoapods/repos"
  clean_dir "Pub cache" "$HOME/.pub-cache"
  clean_dir "npm cache" "$HOME/.npm"

  s_hdr "AI tool caches"
  clean_dir "Gemini browser recordings" "$HOME/.gemini/antigravity/browser_recordings"
  clean_codex_sessions
  clean_dir "Codex logs" "$HOME/.codex/log"
  clean_fvm_incomplete

  s_hdr "Project artifacts under $DOCUMENTS_ROOT"
  clean_find "project build/" "$DOCUMENTS_ROOT" "build" \
    "pubspec.yaml" "build.gradle" "build.gradle.kts" "Makefile" "CMakeLists.txt"
  clean_find "project .dart_tool/" "$DOCUMENTS_ROOT" ".dart_tool" "pubspec.yaml"
  clean_find "project .gradle/" "$DOCUMENTS_ROOT" ".gradle" "build.gradle" "build.gradle.kts" "settings.gradle"
  clean_find "project node_modules/" "$DOCUMENTS_ROOT" "node_modules" "package.json"

  run_repo_artifacts

  echo
  if [ "$DISK_TOTAL_KB" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "Global disk reclaimable: $(human_mb "$DISK_TOTAL_KB")"
    else
      echo "Global disk reclaimed: $(human_mb "$DISK_TOTAL_KB")"
    fi
  else
    echo "No significant global dev caches found."
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  s_lead "$MODE_C" "Mode: $(mode_label) — look, don't touch" "Mode: $(mode_label)"
else
  s_lead "$MODE_C" "Mode: $(mode_label) — closing time" "Mode: $(mode_label)"
fi
run_safe_orphans
[ "$DEEP" -eq 1 ] && run_deep
[ "$OPTIMIZE" -eq 1 ] && run_optimize
[ "$DISK" -eq 1 ] && run_disk

if [ "$DEEP" -eq 0 ] && [ "$OPTIMIZE" -eq 0 ] && [ "$DISK" -eq 0 ]; then
  echo
  s_dim "Tip: add --deep, --optimize, or --disk. Add --apply only after reviewing the dry run."
fi

# Finale card (styled runs only; doctor suppresses via AFTERPARTY_CARD=0).
if cards_on; then
  echo
  s_card_open
  if [ "$DRY_RUN" -eq 0 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty devclean --apply${C_RESET}"
    if [ "$N_PROC" -eq 0 ] && [ "$DISK_TOTAL_KB" -eq 0 ] && [ "$N_OPT" -eq 0 ]; then
      s_card_line "   nothing needed doing — already spotless ✨"
    else
      [ "$N_PROC" -gt 0 ] && s_card_line "   $(s_n "$N_PROC" 'process sent home' 'processes sent home')"
      [ "$N_OPT" -gt 0 ] && s_card_line "   tidied $(s_n "$N_OPT" 'optimize target' 'optimize targets')"
      [ "$DISK_TOTAL_KB" -gt 0 ] && s_card_line "   $(human_mb "$DISK_TOTAL_KB") hauled to the curb"
      s_card_line
      s_card_line "   thanks for partying responsibly 🎉"
    fi
  elif [ "$N_PROC" -gt 0 ] || [ "$DISK_TOTAL_KB" -gt 0 ] || [ "$N_OPT" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — devclean${C_RESET}"
    [ "$N_PROC" -gt 0 ] && s_card_line "   $(s_n "$N_PROC" 'orphaned process still partying' 'orphaned processes still partying')"
    [ "$N_OPT" -gt 0 ] && s_card_line "   $(s_n "$N_OPT" 'optimize target to tidy' 'optimize targets to tidy')"
    [ "$DISK_TOTAL_KB" -gt 0 ] && s_card_line "   $(human_mb "$DISK_TOTAL_KB") of caches to haul out"
    s_card_line
    s_card_line "   closing time: ${C_CYAN}afterparty devclean --apply${C_RESET}"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — the house is quiet${C_RESET}"
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
fi
