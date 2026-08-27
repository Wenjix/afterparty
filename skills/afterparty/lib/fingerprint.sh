# shellcheck shell=bash
# fingerprint.sh - stable identity for a process group, sourced (not executed).
#
# This is what makes an approval bind. Between writing a plan and applying it
# the process table moves: pids die and the kernel recycles their numbers. A
# plan that named only a pgid would happily kill whatever drifted into the
# slot, with every check passing. Hashing the group's start time and command
# alongside the pgid means a recycled group reads as a different item and gets
# refused rather than re-targeted.
#
# Start time, not elapsed time: elapsed changes every second, start does not.

# 12 hex chars from stdin. Same ladder state.sh uses, so a machine without
# sha256sum still produces a usable id rather than an empty string.
fp_hash() {
  local digest sum bytes
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum)" || return 1
    printf '%s' "${digest%% *}" | cut -c1-12
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256)" || return 1
    printf '%s' "${digest%% *}" | cut -c1-12
    return 0
  fi
  read -r sum bytes _ < <(cksum) || return 1
  printf '%012d' "$((sum % 1000000000000))" | cut -c1-12
}

# Fingerprint of the process group $1. Nonzero when the group is gone, so a
# caller cannot mistake "vanished" for "unchanged".
fp_for_pgid() {
  local pg="$1" sig
  case "$pg" in ''|*[!0-9]*) return 1 ;; esac
  # No early `exit` in the awk: quitting mid-stream SIGPIPEs ps, and callers run
  # under `set -o pipefail`, so the pipeline reports failure even though the
  # value was captured correctly. Against a real ps -- hundreds of lines -- that
  # made every fingerprint come back empty.
  sig="$(ps -Ao pgid=,lstart=,command= 2>/dev/null | awk -v g="$pg" '$1 == g && !seen++ { print }')" || return 1
  [ -n "$sig" ] || return 1
  printf '%s' "$sig" | fp_hash
}

# --- filesystem targets ---------------------------------------------------
#
# Process identity is "which process holds this pgid". Filesystem identity is
# the same question in a different shape: a path is a NAME, not a thing, and
# between plan and apply the name can come to point somewhere else -- a
# reinstall, a checkout, a restore from backup. Killing the wrong process and
# deleting the wrong directory are the same class of mistake.

# dev:inode:mtime for $1, portably. GNU stat takes -c, BSD stat takes -f, and
# neither accepts the other's flag; try GNU first and fall back, the same
# GNU-then-BSD shape the touch and date calls in the tests use.
fp_stat_id() {
  local out
  out="$(stat -c '%d:%i:%Y' -- "$1" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out="$(stat -f '%d:%i:%m' -- "$1" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

# Fingerprint of the worktree at $1. Nonzero when it is gone or not a worktree.
#
# Path, HEAD, branch and cleanliness -- because "is this still the worktree I
# reviewed" is not answered by the path alone. Someone committing inside it, or
# leaving uncommitted work in it, changed the thing under review even though
# every byte of the path is identical. Cleanliness is IN the fingerprint as well
# as being a hard veto: the veto refuses the removal, and the fingerprint makes
# the plan visibly stale so the person re-reads it rather than re-ticking it.
fp_for_worktree() {
  local p="$1" top head branch dirty
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  head="$(git -C "$p" rev-parse HEAD 2>/dev/null)" || head="(unborn)"
  branch="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="(detached)"
  # Cannot-prove-clean counts as dirty, matching veto_is_dirty: a failing
  # `git status` is not evidence of a clean tree.
  if ! dirty="$(git -C "$p" status --porcelain 2>/dev/null)"; then
    dirty="unknown"
  fi
  [ -n "$dirty" ] && dirty="dirty" || dirty="clean"
  printf '%s\n%s\n%s\n%s\n' "$top" "$head" "$branch" "$dirty" | fp_hash
}

# Fingerprint of the artifact at $1. Nonzero when it is gone.
#
# What this proves is bounded, and the bound is worth stating: dev:inode
# identifies the directory itself, so a path re-created under the same name
# reads as a different item and is refused. It does NOT prove the contents are
# unchanged -- a directory's mtime does not move when a file deep inside it
# changes. Contents are not what approval was given for; the person approved
# "this artifact directory, which I judged abandoned", and staleness is
# re-checked separately at apply time.
fp_for_artifact() {
  local p="$1" id
  [ -n "$p" ] || return 1
  [ -e "$p" ] || return 1
  id="$(fp_stat_id "$p")" || return 1
  printf '%s\n%s\n' "$p" "$id" | fp_hash
}
