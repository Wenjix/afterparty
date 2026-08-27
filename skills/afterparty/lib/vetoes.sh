# shellcheck shell=bash
# vetoes.sh - the checks a ticked checkbox cannot override, sourced (not run).
#
# plan proposes and a person disposes, but approval is not the last word on
# safety. A human ticking a box is asserting "yes, clean this up" -- they are
# not asserting "this path is not a symlink out of the scan scope", because
# that is not something a person can see in a list. Those structural facts are
# re-established at apply time, every time, and a failing one refuses the item
# no matter who approved it.
#
# The vetoes are deliberately about STRUCTURE, not staleness. Whether a
# worktree is old enough to remove is a judgement the person makes; whether it
# holds uncommitted work is not a judgement at all. Staleness belongs to
# eligible.sh and can be overridden by a tick; nothing here can.
#
# veto_for prints a reason token on stdout and returns 0. Callers test the
# token, never the exit status, and tests assert the specific token: an item
# withheld by an earlier rule than the one under test looks exactly like the
# rule working, which is how five assertions in this suite were once found
# unable to fail.

# Physical path of $1: symlinks resolved, no trailing slash. Fails (nonzero,
# empty) when the path cannot be reached, which callers treat as a veto rather
# than as permission.
veto_phys() {
  local p="$1" d b
  if [ -d "$p" ]; then
    ( cd -- "$p" 2>/dev/null && pwd -P ) || return 1
    return 0
  fi
  d="$(dirname -- "$p")"
  b="$(basename -- "$p")"
  d="$( cd -- "$d" 2>/dev/null && pwd -P )" || return 1
  case "$d" in
    /) printf '/%s' "$b" ;;
    *) printf '%s/%s' "$d" "$b" ;;
  esac
}

# True when $1 is the top level of a git repository (main worktree or linked).
veto_is_repo_root() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  # Byte-exact: two DIFFERENT multibyte paths compare equal under macOS awk's
  # locale collation, and shell [ = ] is byte-exact, so compare here rather
  # than shelling the comparison out.
  [ "$(veto_phys "$top")" = "$(veto_phys "$1")" ]
}

# True when $1 is the MAIN worktree of its repository. Removing it is not a
# worktree operation at all -- it is deleting the repo.
veto_is_main_worktree() {
  local gitdir common
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) : ;;
    *) common="$(cd -- "$1" 2>/dev/null && cd -- "$common" 2>/dev/null && pwd -P)" || return 1 ;;
  esac
  [ "$(veto_phys "$gitdir")" = "$(veto_phys "$common")" ]
}

# True when git tracks anything at or under $1.
veto_is_tracked() {
  local p="$1" repo rel listed
  repo="$(git -C "$(dirname -- "$p")" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$repo" ] || return 1
  rel="${p#"$repo"/}"
  # No `| head -1`: this file is sourced into scripts running `set -o pipefail`,
  # where closing the pipe early SIGPIPEs the producer and the pipeline reports
  # failure even though the value was captured. That is the bug that made every
  # process fingerprint come back empty in production.
  listed="$(git -C "$repo" ls-files -- "$rel" 2>/dev/null)" || return 1
  [ -n "$listed" ]
}

# True when a nested git repository lives anywhere below $1. The outer repo
# cannot see those files with ls-files, so tracked-ness does not protect them.
veto_has_nested_repo() {
  local found
  found="$(find "$1" -mindepth 1 \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null)" || return 1
  [ -n "$found" ]
}

# True when $1 has uncommitted work -- tracked modifications OR untracked files.
# Cannot-prove-clean counts as dirty: `git status` failing is not evidence of a
# clean tree.
veto_is_dirty() {
  local st
  st="$(git -C "$1" status --porcelain 2>/dev/null)" || return 0
  [ -n "$st" ]
}

# veto_for <type> <path> <root> -> reason token on stdout, empty when clear.
#
#   artifact  root is the scan SCOPE; the target must sit physically inside it.
#   worktree  root is the owning REPO; a linked worktree legitimately lives
#             outside it, so containment is not the test -- occupancy,
#             main-worktree status and cleanliness are.
veto_for() {
  local type="${1:-}" path="${2:-}" root="${3:-}" phys rphys cwd

  case "$type" in
    artifact|worktree) : ;;
    *) printf 'unknown-type'; return 0 ;;
  esac

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'gone'; return 0
  fi
  # Checked before existence-of-target so a DANGLING symlink reports as a
  # symlink rather than as an absent path: what matters is that the name is a
  # link, not where it currently points.
  if [ -L "$path" ]; then
    printf 'symlink'; return 0
  fi
  if ! phys="$(veto_phys "$path")" || [ -z "$phys" ]; then
    printf 'unreachable'; return 0
  fi

  if [ "$type" = worktree ]; then
    cwd="$(pwd -P 2>/dev/null)" || cwd=""
    # Standing in it, or anywhere under it. Removing the directory out from
    # under the running process leaves every relative path broken.
    if [ -n "$cwd" ] && { [ "$cwd" = "$phys" ] || case "$cwd" in "$phys"/*) true ;; *) false ;; esac; }; then
      printf 'current'; return 0
    fi
    if veto_is_main_worktree "$phys"; then
      printf 'main-worktree'; return 0
    fi
    if veto_is_dirty "$phys"; then
      printf 'dirty'; return 0
    fi
    printf ''
    return 0
  fi

  # --- artifact ---------------------------------------------------------
  if ! rphys="$(veto_phys "$root")" || [ -z "$rphys" ]; then
    printf 'unreachable-scope'; return 0
  fi
  # The scan root itself is scope, never a candidate: `find` applies its
  # predicates to the starting point too, and a repository may legitimately be
  # named build/ or .cache.
  if [ "$phys" = "$rphys" ]; then
    printf 'scope-root'; return 0
  fi
  # Physical, not lexical. A lexical prefix test passes a path whose PARENT is
  # a symlink out of the scope, and then deletes outside it.
  case "$phys" in
    "$rphys"/*) : ;;
    *) printf 'scope-escape'; return 0 ;;
  esac
  if veto_is_repo_root "$phys"; then
    printf 'repo-root'; return 0
  fi
  if veto_has_nested_repo "$phys"; then
    printf 'nested-repo'; return 0
  fi
  if veto_is_tracked "$phys"; then
    printf 'tracked'; return 0
  fi
  printf ''
}
