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
  # A safety threshold must never be silently zeroed by a malformed value.
  # "0.5" or "08" reaching $(( )) yields an error or an octal misparse, and a
  # zero idle window makes every live workspace instantly eligible for cleanup.
  # Non-integer or negative input falls back to the default and says so once.
  local raw_idle="${AFTERPARTY_IDLE_HOURS:-$ELIG_IDLE_HOURS}"
  case "$raw_idle" in
    ''|*[!0-9]*)
      [ -n "${ELIG_WARNED_IDLE:-}" ] || \
        echo "eligible.sh: AFTERPARTY_IDLE_HOURS='$raw_idle' is not a whole number of hours; using $ELIG_IDLE_HOURS" >&2
      ELIG_WARNED_IDLE=1
      raw_idle="$ELIG_IDLE_HOURS"
      ;;
  esac
  # 10# forces base 10: bare $((08)) is an invalid-octal error, and stripping a
  # single leading zero still breaks on "008". A user writing 08 means 8 hours.
  idle_secs=$(( 10#$raw_idle * 3600 ))
  [ "$idle_secs" -gt 0 ] || idle_secs=$(( ELIG_IDLE_HOURS * 3600 ))
  busy="${AFTERPARTY_BUSY_CPU:-$ELIG_BUSY_CPU}"
  case "$busy" in ''|*[!0-9.]*) busy="$ELIG_BUSY_CPU" ;; esac

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
