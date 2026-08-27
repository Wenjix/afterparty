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
