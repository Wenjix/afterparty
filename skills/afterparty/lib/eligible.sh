# shellcheck shell=bash
# eligible.sh - the two-signal rule, sourced (not executed).
#
# Process-plan eligibility combines old agent transcript-file activity with
# low maximum observed CPU in the group. These are conservative policy inputs,
# not proof that nobody is using the workspace or that its processes are idle:
#
#   transcript quiet, cpu busy  -> may be a long tool call; withhold.
#   transcript recent, cpu idle -> may be in use; withhold.
#   no transcript at all        -> no signal. NOT a licence to clean.
#
# That last case is the one that matters most. A workspace driven by hand has
# no transcript, so "unknown" must never fall through to eligible -- doing so
# would offer someone's live work for cleanup on the strength of no evidence.

# Defaults stay independent of the environment so invalid startup overrides
# cannot become their own fallback. Overrides are validated on every verdict.
ELIG_IDLE_HOURS=4
ELIG_BUSY_CPU=20

# Observed CPU must be decimal, nonnegative and finite in awk's number type.
elig_cpu_valid() {
  local cpu="${1:-}"
  [[ "$cpu" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || return 1
  LC_ALL=C awk -v c="$cpu" 'BEGIN {exit (tolower(sprintf("%g", c + 0)) ~ /inf|nan/)}'
}

# elig_verdict <last_touched_epoch|""> <max_cpu> <now> -> verdict on stdout.
#   eligible | in-use | working | unknown
# An eligible group has transcript age greater than AFTERPARTY_IDLE_HOURS
# (default 4) and maximum CPU at or below AFTERPARTY_BUSY_CPU (default 20).
# Filesystem targets do not require this verdict to permit checked removal.
elig_verdict() {
  local touched="${1:-}" cpu="${2:-}" now="${3:-0}" idle_secs busy decimal_idle
  # Re-read per call so a caller can override the thresholds per invocation.
  # A safety threshold must never be silently zeroed by a malformed value.
  # "0.5" or "08" reaching $(( )) yields an error or an octal misparse, and a
  # zero idle window makes every live workspace instantly eligible for cleanup.
  # Non-positive or non-integer input falls back to the default and says so once.
  local raw_idle="${AFTERPARTY_IDLE_HOURS:-$ELIG_IDLE_HOURS}"
  if ! [[ "$raw_idle" =~ ^[0-9]+$ ]] || ! [[ "$raw_idle" =~ [1-9] ]]; then
    [ -n "${ELIG_WARNED_IDLE:-}" ] || \
      echo "eligible.sh: AFTERPARTY_IDLE_HOURS='$raw_idle' is not a positive whole number of hours; using $ELIG_IDLE_HOURS" >&2
    ELIG_WARNED_IDLE=1
    raw_idle="$ELIG_IDLE_HOURS"
  fi
  decimal_idle="${raw_idle#"${raw_idle%%[!0]*}"}"
  # Multiplication can wrap a huge positive override to a short positive
  # interval. Withhold instead of silently shortening the requested limit.
  if [ "${#decimal_idle}" -gt 16 ] || [ "$decimal_idle" -gt 2562047788015215 ]; then
    [ -n "${ELIG_WARNED_IDLE:-}" ] || \
      echo "eligible.sh: AFTERPARTY_IDLE_HOURS='$raw_idle' exceeds 2562047788015215 hours. Process cleanup is withheld. Set AFTERPARTY_IDLE_HOURS to a smaller positive whole number." >&2
    ELIG_WARNED_IDLE=1
    printf 'unknown'
    return 0
  fi
  # 10# forces base 10: bare $((08)) is an invalid-octal error, and stripping a
  # single leading zero still breaks on "008". A user writing 08 means 8 hours.
  idle_secs=$(( 10#$decimal_idle * 3600 ))
  [ "$idle_secs" -gt 0 ] || idle_secs=$(( ELIG_IDLE_HOURS * 3600 ))
  busy="${AFTERPARTY_BUSY_CPU:-$ELIG_BUSY_CPU}"
  if ! [[ "$busy" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    [ -n "${ELIG_WARNED_BUSY:-}" ] || \
      echo "eligible.sh: AFTERPARTY_BUSY_CPU='$busy' is not a non-negative number; using $ELIG_BUSY_CPU" >&2
    ELIG_WARNED_BUSY=1
    busy="$ELIG_BUSY_CPU"
  fi

  case "$touched" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  # Missing or malformed CPU is unavailable evidence, never zero activity.
  # A syntactically decimal value must also fit the comparison tool's number.
  if ! elig_cpu_valid "$cpu"; then
    printf 'unknown'
    return 0
  fi

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
