#!/usr/bin/env bash
# clean-artifacts.sh — report (and optionally delete) regenerable build/cache
# artifacts in a repo: Turborepo/Next/Vite caches, build outputs, test artifacts,
# *.tsbuildinfo, eslint cache, coverage. Default is a DRY-RUN with sizes.
#
# Usage:
#   clean-artifacts.sh [--root DIR]          # report reclaimable space (dry run)
#   clean-artifacts.sh --plan [--root DIR]   # unchecked artifact proposal
#   clean-artifacts.sh --plan --caches-only # omit build outputs
#   clean-artifacts.sh --clean              # report-only, exits 2
#
# Safety: only well-known artifact paths are touched; node_modules/.git/nested
# repos are pruned; matched dirs are not descended into (no double counting);
# any path that still contains git-tracked files is skipped.
# Exit: 0 ok · 1 partial cleanup failure · 2 usage/scope refusal.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
# Private local record of confirmed mutation outcomes.
. "$DIR/journal.sh"
. "$DIR/vetoes.sh"
. "$DIR/fingerprint.sh"
. "$DIR/workspace.sh"

ROOT="$PWD"
DO_CLEAN=0 CLEAN_REQUESTED=0 AS_PLAN=0 CACHES_ONLY=0 ALLOW_NON_REPO_ROOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?}"; shift 2 ;;
    --clean) CLEAN_REQUESTED=1; shift ;;
    --plan) AS_PLAN=1; shift ;;
    --caches-only) CACHES_ONLY=1; shift ;;
    --allow-non-repo-root) ALLOW_NON_REPO_ROOT=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "artifact root is not a directory: $ROOT" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in *$'\n'*|*$'\r'*|*$'\t'*) echo "artifacts: unsupported control character in root" >&2; exit 2 ;; esac

if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$ROOT" rev-parse --show-toplevel)"
  ROOT="$(cd "$ROOT" && pwd -P)"
elif [ "$CLEAN_REQUESTED" -eq 1 ] && [ "$ALLOW_NON_REPO_ROOT" -ne 1 ]; then
  echo "refusing artifact cleanup outside a git repository: $ROOT (pass --allow-non-repo-root to override)" >&2
  exit 2
fi

# Scope checks apply to the final target. A child path can expand to a much
# broader Git top-level (including HOME), so guarding only the input is unsafe.
if [ "$CLEAN_REQUESTED" -eq 1 ] || [ "$AS_PLAN" -eq 1 ]; then
  HOME_ROOT=""
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    HOME_ROOT="$(cd "$HOME" && pwd -P)"
  fi
  case "$ROOT" in
    /|/[A-Za-z])
      echo "refusing artifact cleanup at a filesystem root: $ROOT" >&2
      exit 2
      ;;
  esac
  if [ -n "$HOME_ROOT" ] && [ "$ROOT" = "$HOME_ROOT" ]; then
    echo "refusing artifact cleanup at the user home root: $ROOT" >&2
    exit 2
  fi
fi
AFTERPARTY_JOURNAL_WORKSPACE="$ROOT"
AFTERPARTY_JOURNAL_WORKSPACE_INITIALIZED=1

# Artifact directory names. Bucketed by category at report time.
ARTIFACT_DIRS=(.turbo .vite .cache .parcel-cache .rollup.cache \
  .next dist build out .output .svelte-kit .astro storybook-static \
  coverage .nyc_output test-results playwright-report .playwright-mcp .vitest)

category_of() {
  case "$1" in
    .next|dist|build|out|.output|.svelte-kit|.astro|storybook-static) echo builds ;;
    coverage|.nyc_output|test-results|playwright-report|.playwright-mcp|.vitest) echo tests ;;
    *) echo caches ;;
  esac
}

# Complete discovery before rendering; an errored scan cannot propose deletions.
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
SCAN_INCOMPLETE=0
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
scan_paths() {
  local name="$1"; shift
  if ! find "$@" > "$T/$name" 2> "$T/$name.err" || [ -s "$T/$name.err" ]; then
    SCAN_INCOMPLETE=1
    echo "artifacts: scan incomplete ($name); cleanup is withheld" >&2
  fi
}
# Build a find prune expression for the artifact dir names.
prune_expr=()
for n in "${ARTIFACT_DIRS[@]}"; do prune_expr+=(-name "$n" -o); done
unset "prune_expr[$((${#prune_expr[@]} - 1))]"  # drop trailing -o

caches=() builds=() tests=()
add_path() {
  local p="$1" cat
  [ -e "$p" ] || return
  # `find` normally emits descendants, but its starting point also matches
  # predicates. A repository itself may legitimately be named build/.cache;
  # it is scope, never an artifact candidate.
  [ "$p" != "$ROOT" ] || return
  cat=$(category_of "$(basename "$p")")
  case "$cat" in
    builds) builds+=("$p") ;;
    tests) tests+=("$p") ;;
    *) caches+=("$p") ;;
  esac
}

scan_paths dirs "$ROOT" -mindepth 1   \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o   -type d \( "${prune_expr[@]}" \) -prune -print0
scan_paths dependencies "$ROOT" -mindepth 1   \( -name .git -o -name .venv -o -name target -o -name vendor \) -prune -o   -type d -name node_modules -prune -print0
scan_paths files "$ROOT" -mindepth 1   \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o   -type d \( "${prune_expr[@]}" \) -prune -o   -type f \( -name '*.tsbuildinfo' -o -name '.eslintcache' \) -print0
while IFS= read -r -d '' d; do [ -n "$d" ] && add_path "$d"; done < "$T/dirs"
while IFS= read -r -d '' d; do [ -d "$d/.cache" ] && caches+=("$d/.cache"); done < "$T/dependencies"
while IFS= read -r -d '' f; do [ -n "$f" ] && caches+=("$f"); done < "$T/files"
if [ "$AS_PLAN" -eq 1 ]; then
  printf '# afterparty plan schema: 1\n\n## Artifacts\n\n'
  printf 'Scope: %s; delete selected build/test/cache paths. Rebuilding may be required.\n\n' "$ROOT"
  ws_pid_cwd --strict > "$T/cwd" 2>/dev/null || rm -f "$T/cwd"
fi

TOTAL_KB=0 FREED_KB=0
N_PATHS=0 N_DELETED=0 N_FAILED=$SCAN_INCOMPLETE N_WITHHELD=0
process() {
  local label="$1"; shift
  local paths=("$@") printed=0 p rel kb reason fp
  for p in "${paths[@]}"; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    # Every collector funnels through this final boundary. In particular,
    # node_modules/.cache and standalone cache files are appended directly
    # rather than through add_path, so they need the same nested-repo guard.
    [ "$p" != "$ROOT" ] || continue
    case "$p" in *$'\n'*|*$'\r'*|*$'\t'*)
      printf 'artifacts: unsupported control character in target %q\n' "$p" >&2
      N_FAILED=$((N_FAILED + 1)); continue ;;
    esac
    rel="${p#"$ROOT"/}"
    reason="$(veto_for artifact "$p" "$ROOT")"
    [ "$SCAN_INCOMPLETE" -eq 0 ] || reason=scan-incomplete
    if [ "$AS_PLAN" -eq 1 ] && [ -z "$reason" ]; then
      if [ ! -f "$T/cwd" ]; then reason=occupancy-unavailable
      elif veto_is_occupied "$T/cwd" "$(veto_phys "$p")" "$p"; then reason=occupied; fi
    fi
    if [ -n "$reason" ]; then
      N_WITHHELD=$((N_WITHHELD + 1))
      case "$reason" in *unavailable*|*incomplete*) N_FAILED=$((N_FAILED + 1)) ;; esac
      if [ "$AS_PLAN" -eq 1 ]; then
        printf -- '- [⊘] %s path %s\n' "$reason" "$p"
      else s_skip "  skip ($reason): $rel"; fi
      continue
    fi
    if [ "$AS_PLAN" -eq 1 ]; then
      fp="$(fp_for_artifact "$p")" || fp=""
      if [ -n "$fp" ]; then
        printf -- '- [ ] artifact path %s\n' "$p"
        printf '      type: artifact  fingerprint: %s  root: %s\n' "$fp" "$ROOT"
        printf '      consequence: delete %s of rebuildable output; process working directories inside the target block removal\n' "$(human "$p")"
      else
        printf -- '- [⊘] identity-unavailable path %s\n' "$p"
        N_FAILED=$((N_FAILED + 1))
      fi
      continue
    fi
    if [ "$printed" -eq 0 ]; then s_hdr "$label"; printed=1; fi
    kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}'); TOTAL_KB=$((TOTAL_KB + ${kb:-0}))
    N_PATHS=$((N_PATHS + 1))
    if [ "$STYLE_ON" -eq 1 ]; then
      # Size cell carries a severity tint (100 MB warn / 1 GB hot); the plain
      # branch below keeps the exact legacy bytes.
      printf '  %s %s\n' "$(s_sizecell "${kb:-0}" "$(printf '%-6s' "$(human "$p")")")" "$rel"
    else
      printf '  %-6s %s\n' "$(human "$p")" "$rel"
    fi

  done
}

if [ "$AS_PLAN" -eq 0 ]; then
  s_lead "$C_YEL" "Repo: $ROOT (read-only artifact inventory)" "Repo: $ROOT (read-only; approve deletion through plan/apply)"
fi
# Per-category subtotals (diffed around each pass) feed the styled meters.
KB0=$TOTAL_KB KB_CACHES=0 KB_BUILDS=0 KB_TESTS=0
process "Caches (.turbo/.vite/.cache/*.tsbuildinfo)" "${caches[@]:-}"
KB_CACHES=$((TOTAL_KB - KB0)); KB0=$TOTAL_KB
[ "$CACHES_ONLY" -eq 0 ] && process "Build outputs (.next/dist/build/out)" "${builds[@]:-}"
KB_BUILDS=$((TOTAL_KB - KB0)); KB0=$TOTAL_KB
[ "$CACHES_ONLY" -eq 0 ] && process "Test artifacts (coverage/test-results/playwright)" "${tests[@]:-}"
KB_TESTS=$((TOTAL_KB - KB0))

if [ "$AS_PLAN" -eq 1 ]; then
  [ "$N_FAILED" -eq 0 ]; exit $?
fi
if [ "$CLEAN_REQUESTED" -eq 1 ]; then
  echo "artifacts --clean is report-only; save a plan with afterparty plan --root <repo>, review its boxes, then apply it." >&2
  exit 2
fi

if [ "$STYLE_ON" -eq 1 ]; then
  # Category share-of-total meters, then the total line with a tinted figure.
  # Both are styled-only; the else-branch keeps the legacy bytes.
  if [ "$TOTAL_KB" -gt 0 ]; then
    echo
    for mpair in "caches:$KB_CACHES" "builds:$KB_BUILDS" "tests:$KB_TESTS"; do
      mkb="${mpair#*:}"
      [ "$mkb" -gt 0 ] || continue
      printf '  %-7s %s %s\n' "${mpair%%:*}" "$(s_meter "$mkb" "$TOTAL_KB")" \
        "$(s_sizecell "$mkb" "$(s_kb "$mkb")")"
    done
  fi
  if [ "$DO_CLEAN" -eq 1 ]; then
    printf '\nReclaimed total: %s MB\n' "$(s_sizecell "$FREED_KB" "$((FREED_KB / 1024))")"
  else
    printf '\nReclaimable total: %s MB\n' "$(s_sizecell "$TOTAL_KB" "$((TOTAL_KB / 1024))")"
  fi
else
  if [ "$DO_CLEAN" -eq 1 ]; then
    printf '\nReclaimed total: %s MB\n' "$((FREED_KB / 1024))"
  else
    printf '\nReclaimable total: %s MB\n' "$((TOTAL_KB / 1024))"
  fi
fi

# Finale card (styled standalone runs only; devclean/doctor suppress it).
if cards_on; then
  echo
  s_card_open
  if [ "$DO_CLEAN" -eq 1 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty artifacts --clean${C_RESET}"
    segs="$(s_segments \
      "$([ "$N_DELETED" -gt 0 ] && echo "$G_OK $N_DELETED swept")" \
      "$([ "$N_FAILED" -gt 0 ] && echo "$G_SKIP $N_FAILED failed")" \
      "$([ "$FREED_KB" -ge 1024 ] && echo "$((FREED_KB / 1024)) MB freed")")"
    if [ -n "$segs" ]; then s_card_line "   $segs"; fi
    if [ "$N_DELETED" -gt 0 ]; then
      s_card_line "   swept $(s_n "$N_DELETED" 'path' 'paths') — $((FREED_KB / 1024)) MB back on the shelf"
      [ "$N_FAILED" -gt 0 ] && s_card_line "   $N_FAILED path(s) could not be deleted"
    elif [ "$N_FAILED" -gt 0 ]; then
      s_card_line "   nothing swept — $N_FAILED path(s) could not be deleted"
    else
      s_card_line "   nothing needed doing — already spotless ✨"
    fi
    s_card_line
    s_card_line "   thanks for partying responsibly 🎉"
  elif [ "$N_PATHS" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — artifacts${C_RESET}"
    segs="$(s_segments \
      "$G_ACT $(s_n "$N_PATHS" 'path' 'paths')" \
      "$([ "$TOTAL_KB" -ge 1024 ] && echo "$((TOTAL_KB / 1024)) MB")")"
    s_card_line "   $segs"
    s_card_line "   $(s_n "$N_PATHS" 'path' 'paths') of cups and confetti to pick up ($((TOTAL_KB / 1024)) MB)"
    s_card_line
    printf -v next_root %q "$ROOT"
    next_args="--artifacts-only --root $next_root"
    [ "$CACHES_ONLY" -eq 0 ] || next_args="$next_args --caches-only"
    s_card_line "   review: ${C_CYAN}afterparty plan $next_args${C_RESET}"
  else
    if [ "$N_WITHHELD" -gt 0 ] || [ "$N_FAILED" -gt 0 ]; then
      s_card_line "$N_WITHHELD retained; $N_FAILED inspection failures"
    else
      s_card_line "No artifact candidates found in the inspected scope"
    fi
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
fi

if [ "$N_WITHHELD" -gt 0 ]; then printf 'Retained: %s protected or unavailable path(s)\n' "$N_WITHHELD"; fi
if [ "$N_FAILED" -gt 0 ]; then exit 1; fi
