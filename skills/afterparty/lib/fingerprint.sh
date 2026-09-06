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

# A member token binds PID, PGID, start time and command. Keeping the original
# members lets a group retain its identity after its launcher exits: an
# unchanged surviving member proves continuity; a recycled group has none.
# Return 0 with comma-separated PID:hash tokens, 1 absent, 2 unavailable.
fp_members_for_pgid() {
  local pg="$1" snapshot rows line pid token result=""
  case "$pg" in ''|*[!0-9]*) return 2 ;; esac
  snapshot="$(LC_ALL=C ps -Ao pid=,pgid=,lstart=,command= 2>/dev/null)" || return 2
  # A complete table includes at least the process doing the inspection.
  printf '%s\n' "$snapshot" | awk 'NF < 8 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ {bad=1} END {exit (bad || NR == 0)}' || return 2
  rows="$(printf '%s\n' "$snapshot" | awk -v g="$pg" '$2 == g {$1=$1; print}')" || return 2
  [ -n "$rows" ] || return 1
  while IFS= read -r line; do
    pid="${line#"${line%%[![:space:]]*}"}"; pid="${pid%%[[:space:]]*}"
    token="$(printf '%s' "$line" | fp_hash)" || return 2
    result="${result:+$result,}$pid:$token"
  done <<< "$rows"
  printf '%s' "$result"
}

fp_group_state() { fp_members_for_pgid "$1" >/dev/null; }

# 0 original member present; 1 group absent; 2 unavailable; 3 unverified/drift.
fp_group_matches() {
  local have pair expected="$2" previous_ifs
  have="$(fp_members_for_pgid "$1")" || return $?
  [ -n "$expected" ] && [ "$expected" != - ] || return 3
  previous_ifs="$IFS"; IFS=','
  for pair in $have; do
    case ",$expected," in *",$pair,"*) IFS="$previous_ifs"; return 0 ;; esac
  done
  IFS="$previous_ifs"
  return 3
}

# --- filesystem targets ---------------------------------------------------
#
# Process identity is "which process holds this pgid". Filesystem identity is
# the same question in a different shape: a path is a NAME, not a thing, and
# between plan and apply the name can come to point somewhere else -- a
# reinstall, a checkout, a restore from backup. Killing the wrong process and
# deleting the wrong directory are the same class of mistake.

# Artifact identity includes the available fractional mtime, ctime and birth
# time. Whole-second mtime plus inode collides when Linux immediately reuses a
# deleted directory's inode. GNU's textual time fields preserve nanoseconds;
# BSD's F time format requires explicit precision (its default is six digits).
# Fix locale/timezone so formatting does not change an unchanged identity.
fp_stat_id() {
  local out
  out="$(LC_ALL=C TZ=UTC0 stat -c '%d:%i:%y:%z:%w' -- "$1" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out="$(LC_ALL=C TZ=UTC0 stat -f '%d:%i:%.9Fm:%.9Fc:%.9FB' -- "$1" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

# Stable directory identity for a worktree or its Git administration. mtime
# and ctime are deliberately excluded: git status can replace the index and
# ignored build output can change directory metadata without replacing the
# worktree. Require creation time; inode alone can be recycled after removal.
# Filesystems/stat versions without birth time cannot establish this identity
# and therefore cannot authorize a worktree removal. Even supported birth time
# is limited by the filesystem's actual clock resolution and restore behavior.
fp_stat_object_id() {
  local out birth
  if out="$(LC_ALL=C TZ=UTC0 stat -c '%d:%i:%w' -- "$1" 2>/dev/null)" && [ -n "$out" ]; then
    birth="${out#*:}"; birth="${birth#*:}"
  elif out="$(LC_ALL=C TZ=UTC0 stat -f '%d:%i:%.9FB' -- "$1" 2>/dev/null)" && [ -n "$out" ]; then
    birth="${out#*:}"; birth="${birth#*:}"
  else
    return 1
  fi
  case "$birth" in ''|'-'|'?'|0|0.*|-1|-1.*) return 1 ;; esac
  printf '%s' "$out"
}

# Fingerprint of the worktree at $1. Nonzero when it is gone or not a worktree.
#
# Bind both the physical directory and its owning Git administration. Path,
# HEAD, branch and cleanliness alone also describe a replacement made from
# another clone, which is not the worktree a person approved. Cleanliness is IN
# the fingerprint as well as being a hard veto so changed work is visibly stale.
fp_for_worktree() {
  local p="$1" top head branch dirty admin common top_id admin_id common_id
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  top="$(cd "$top" && pwd -P)" || return 1
  admin="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 1
  # --git-common-dir may be relative to the worktree; normalize both Git paths
  # physically so symlink aliases do not change their identity.
  admin="$(cd "$top" && cd "$admin" && pwd -P)" || return 1
  common="$(cd "$top" && cd "$common" && pwd -P)" || return 1
  top_id="$(fp_stat_object_id "$top")" || return 1
  admin_id="$(fp_stat_object_id "$admin")" || return 1
  common_id="$(fp_stat_object_id "$common")" || return 1
  head="$(git -C "$p" rev-parse HEAD 2>/dev/null)" || head="(unborn)"
  branch="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="(detached)"
  # Cannot-prove-clean counts as dirty, matching veto_is_dirty: a failing
  # `git status` is not evidence of a clean tree.
  if ! dirty="$(git -C "$p" status --porcelain 2>/dev/null)"; then
    dirty="unknown"
  fi
  [ -n "$dirty" ] && dirty="dirty" || dirty="clean"
  printf '%s\n' "$top" "$top_id" "$admin" "$admin_id" "$common" "$common_id" \
    "$head" "$branch" "$dirty" | fp_hash
}

# Fingerprint of the artifact at $1. Nonzero when it is gone.
#
# What this proves is bounded: device, inode and available timestamp precision
# identify ordinary replacements, including rapid inode reuse. Coarse clocks,
# unavailable birth time or restored metadata can still collide; this is not a
# filesystem generation number. It does NOT prove the contents are
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
