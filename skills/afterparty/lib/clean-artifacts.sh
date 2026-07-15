#!/usr/bin/env bash
# clean-artifacts.sh — report (and optionally delete) regenerable build/cache
# artifacts in a repo: Turborepo/Next/Vite caches, build outputs, test artifacts,
# *.tsbuildinfo, eslint cache, coverage. Default is a DRY-RUN with sizes.
#
# Usage:
#   clean-artifacts.sh [--root DIR]          # report reclaimable space (dry run)
#   clean-artifacts.sh --clean [--root DIR]  # delete caches + build outputs
#   clean-artifacts.sh --clean --caches-only # delete caches only, keep build outputs
#   clean-artifacts.sh --clean --deep        # also run `pnpm store prune`
#
# Safety: only well-known artifact paths are touched; node_modules/.git/nested
# repos are pruned; matched dirs are not descended into (no double counting);
# any path that still contains git-tracked files is skipped. Exit: 0 ok · 2 usage.
set -uo pipefail

ROOT="$PWD"
DO_CLEAN=0 CACHES_ONLY=0 DEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?}"; shift 2 ;;
    --clean) DO_CLEAN=1; shift ;;
    --caches-only) CACHES_ONLY=1; shift ;;
    --deep) DEEP=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git -C "$ROOT" rev-parse --show-toplevel)"
fi

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

# A path is protected if git still tracks files inside it (don't nuke source).
is_tracked() { [ -n "$(git -C "$ROOT" ls-files -- "$1" 2>/dev/null | head -1)" ]; }
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

# Nested skill/plugin repos have their own tracked files. The root repo cannot
# see those with `git ls-files`, so treat each nested .git parent as a boundary.
nested_repos=()
while IFS= read -r git_marker; do
  [ -n "$git_marker" ] && nested_repos+=("$(dirname "$git_marker")")
done < <(
  find "$ROOT" -mindepth 2 \
    \( -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
    \( -type d -name .git -o -type f -name .git \) -prune -print 2>/dev/null)

is_under_nested_repo() {
  local p="$1" repo
  for repo in "${nested_repos[@]}"; do
    case "$p" in "$repo"|"$repo"/*) return 0 ;; esac
  done
  return 1
}

# Build a find prune expression for the artifact dir names.
prune_expr=()
for n in "${ARTIFACT_DIRS[@]}"; do prune_expr+=(-name "$n" -o); done
unset "prune_expr[$((${#prune_expr[@]} - 1))]"  # drop trailing -o

caches=() builds=() tests=()
add_path() {
  local p="$1" cat
  [ -e "$p" ] || return
  is_under_nested_repo "$p" && return
  cat=$(category_of "$(basename "$p")")
  case "$cat" in
    builds) builds+=("$p") ;;
    tests) tests+=("$p") ;;
    *) caches+=("$p") ;;
  esac
}

# Artifact dirs (pruned on match → never descend into a matched dir).
while IFS= read -r d; do [ -n "$d" ] && add_path "$d"; done < <(
  find "$ROOT" \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
    -type d \( "${prune_expr[@]}" \) -prune -print 2>/dev/null)
# node_modules/.cache without descending into node_modules contents.
while IFS= read -r d; do [ -n "$d" ] && caches+=("$d"); done < <(
  find "$ROOT" \( -name .git -o -name .venv -o -name target -o -name vendor \) -prune -o \
    -type d -name node_modules -prune -print 2>/dev/null \
    | while IFS= read -r nm; do [ -d "$nm/.cache" ] && printf '%s\n' "$nm/.cache"; done)
# tsbuildinfo + eslintcache files outside artifact dirs.
while IFS= read -r f; do [ -n "$f" ] && caches+=("$f"); done < <(
  find "$ROOT" \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name vendor \) -prune -o \
    -type d \( "${prune_expr[@]}" \) -prune -o \
    -type f \( -name '*.tsbuildinfo' -o -name '.eslintcache' \) -print 2>/dev/null)

TOTAL_KB=0
process() {
  local label="$1"; shift
  local paths=("$@") printed=0 p rel kb
  for p in "${paths[@]}"; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    rel="${p#"$ROOT"/}"
    if is_tracked "$rel"; then echo "  skip (git-tracked): $rel"; continue; fi
    if [ "$printed" -eq 0 ]; then echo; echo "=== $label ==="; printed=1; fi
    kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}'); TOTAL_KB=$((TOTAL_KB + ${kb:-0}))
    printf '  %-6s %s\n' "$(human "$p")" "$rel"
    [ "$DO_CLEAN" -eq 1 ] && rm -rf "$p" && echo "         deleted"
  done
}

echo "Repo: $ROOT $([ "$DO_CLEAN" -eq 1 ] && echo '(CLEAN)' || echo '(dry run — pass --clean to delete)')"
process "Caches (.turbo/.vite/.cache/*.tsbuildinfo)" "${caches[@]:-}"
[ "$CACHES_ONLY" -eq 0 ] && process "Build outputs (.next/dist/build/out)" "${builds[@]:-}"
process "Test artifacts (coverage/test-results/playwright)" "${tests[@]:-}"

printf '\nReclaimable total: %s MB%s\n' "$((TOTAL_KB / 1024))" "$([ "$DO_CLEAN" -eq 1 ] && echo ' (freed)' || echo '')"

if [ "$DO_CLEAN" -eq 1 ] && [ "$DEEP" -eq 1 ] && command -v pnpm >/dev/null 2>&1; then
  echo; echo "=== pnpm store prune ==="; pnpm store prune 2>&1 | tail -3
fi
