# shellcheck shell=bash
# eligible.sh - the two-signal rule, sourced (not executed).
#
# A workspace is forgotten only when nobody has spoken to it for hours AND
# nothing in it is working. Either signal alone lies:
#
#   transcript quiet, cpu busy  -> a long tool call. Still working.
#   transcript recent, cpu idle -> you are sitting in it right now.
#   no transcript at all        -> no signal. NOT a licence to clean.
#
# That last case is the one that matters most. A workspace driven by hand has
# no transcript, so "unknown" must never fall through to eligible -- doing so
# would offer someone's live work for cleanup on the strength of no evidence.

ELIG_IDLE_HOURS="${AFTERPARTY_IDLE_HOURS:-4}"
ELIG_BUSY_CPU="${AFTERPARTY_BUSY_CPU:-20}"

# elig_verdict <last_touched_epoch|""> <max_cpu> <now> -> verdict on stdout.
#   eligible | in-use | working | unknown
elig_verdict() {
  local touched="${1:-}" cpu="${2:-0}" now="${3:-0}" idle_secs busy
  # Re-read per call so a caller can override the thresholds per invocation.
  idle_secs=$(( ${AFTERPARTY_IDLE_HOURS:-$ELIG_IDLE_HOURS} * 3600 ))
  busy="${AFTERPARTY_BUSY_CPU:-$ELIG_BUSY_CPU}"

  case "$touched" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac

  if [ "$((now - touched))" -le "$idle_secs" ]; then
    printf 'in-use'
    return 0
  fi

  # awk, not shell arithmetic: cpu is a float and bash cannot compare those.
  if awk -v c="$cpu" -v b="$busy" 'BEGIN { exit !(c + 0 > b + 0) }'; then
    printf 'working'
    return 0
  fi

  printf 'eligible'
}
