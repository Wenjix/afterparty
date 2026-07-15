# style.sh - shared terminal styling, sourced (not executed) by every lib
# script. Styling is ADDITIVE and TTY-gated: pipes, --json, report.md, and
# NO_COLOR always get the legacy plain bytes (that plain output is a contract
# surface — external greps and report.md depend on it). Precedence:
# AFTERPARTY_STYLE=always|never|auto (default auto) > NO_COLOR / TERM=dumb >
# isatty per stream. Banners and finale cards exist only in styled mode.
# Rule for call sites: never interpolate C_* into stdout outside a
# [ "$STYLE_ON" -eq 1 ] branch.

STYLE_ON=0 STYLE_ERR=0
case "${AFTERPARTY_STYLE:-auto}" in
  always)
    STYLE_ON=1 STYLE_ERR=1
    ;;
  never) ;;
  *)
    if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
      if [ -t 1 ]; then STYLE_ON=1; fi
      if [ -t 2 ]; then STYLE_ERR=1; fi
    fi
    ;;
esac

if [ "$STYLE_ON" -eq 1 ] || [ "$STYLE_ERR" -eq 1 ]; then
  C_RESET=$'\033[0m'  C_BOLD=$'\033[1m'  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'   C_GRN=$'\033[32m'  C_YEL=$'\033[33m'
  C_MAG=$'\033[35m'   C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GRN='' C_YEL='' C_MAG='' C_CYAN=''
fi
CARD_RULE='──────────────────────────────────────────────'

# Section header: styled "● X" vs the legacy "=== X ===" (byte-identical,
# including the leading blank line the callers used to echo themselves).
s_hdr() {
  if [ "$STYLE_ON" -eq 1 ]; then
    printf '\n%s%s● %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
  else
    printf '\n=== %s ===\n' "$1"
  fi
}

# Whole-line tints; plain mode passes the text through unchanged, so contract
# substrings inside the line stay contiguous in both modes.
s_would() { if [ "$STYLE_ON" -eq 1 ]; then printf '%s%s%s\n' "$C_YEL" "$*" "$C_RESET"; else printf '%s\n' "$*"; fi; }
s_ok()    { if [ "$STYLE_ON" -eq 1 ]; then printf '%s%s%s\n' "$C_GRN" "$*" "$C_RESET"; else printf '%s\n' "$*"; fi; }
s_kill()  { if [ "$STYLE_ON" -eq 1 ]; then printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET"; else printf '%s\n' "$*"; fi; }
s_dim()   { if [ "$STYLE_ON" -eq 1 ]; then printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; else printf '%s\n' "$*"; fi; }

# Warning on stderr; gates on the stderr tty independently of stdout.
s_warn() {
  if [ "$STYLE_ERR" -eq 1 ]; then
    printf '%s%swarning:%s %s\n' "$C_BOLD" "$C_YEL" "$C_RESET" "$*" >&2
  else
    printf 'warning: %s\n' "$*" >&2
  fi
}

# Session banner: styled-mode only; plain output gains nothing (additive).
s_banner() {
  [ "$STYLE_ON" -eq 1 ] || return 0
  printf '%s%s🎉 %s%s\n' "$C_BOLD" "$C_MAG" "$1" "$C_RESET"
  if [ -n "${2:-}" ]; then
    printf '%s   %s%s\n' "$C_DIM" "$2" "$C_RESET"
  fi
  echo
}

# Mode banner whose PLAIN form must stay byte-identical to the legacy line.
# Styled form bolds+colors the leading mode word (HEAD) and swaps in TAIL;
# the ANSI sits outside HEAD so "DRY RUN" stays a contiguous substring.
s_mode() {  # COLOR HEAD TAIL PLAIN_LINE
  if [ "$STYLE_ON" -eq 1 ]; then
    printf '%s%s%s%s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET" "$3"
  else
    printf '%s\n' "$4"
  fi
}

# Whole-line lead banner with distinct styled and plain texts.
s_lead() {  # COLOR STYLED_LINE PLAIN_LINE
  if [ "$STYLE_ON" -eq 1 ]; then
    printf '%s%s%s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"
  else
    printf '%s\n' "$3"
  fi
}

# "N singular" / "N plural" (no trailing newline).
s_n() { if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }

# Finale card frame: open-right box, so emoji double-width can never break
# the alignment of a right edge.
s_card_open()  { printf '%s╭%s%s\n' "$C_MAG" "$CARD_RULE" "$C_RESET"; }
s_card_close() { printf '%s╰%s%s\n' "$C_MAG" "$CARD_RULE" "$C_RESET"; }
s_card_line() {
  if [ $# -eq 0 ] || [ -z "${1:-}" ]; then
    printf '%s│%s\n' "$C_MAG" "$C_RESET"
  else
    printf '%s│%s  %s\n' "$C_MAG" "$C_RESET" "$1"
  fi
}

# Should this script print its own finale card? Not when plain, not when a
# composite parent is collecting the tally, not when cards are suppressed.
cards_on() {
  [ "$STYLE_ON" -eq 1 ] || return 1
  [ -z "${AFTERPARTY_TALLY:-}" ] || return 1
  [ "${AFTERPARTY_CARD:-1}" != "0" ] || return 1
  return 0
}

# Composite tally: children append counters; the router sums them for the
# single finale card. Append-safe (duplicate keys are summed).
tally_add() {  # KEY N
  if [ -n "${AFTERPARTY_TALLY:-}" ] && [ -w "${AFTERPARTY_TALLY:-}" ]; then
    printf '%s\t%s\n' "$1" "${2:-0}" >> "$AFTERPARTY_TALLY"
  fi
  return 0
}

tally_get() {  # KEY -> summed integer (0 when absent)
  awk -F'\t' -v k="$1" '$1 == k { s += $2 } END { printf "%d", s }' \
    "${AFTERPARTY_TALLY:-/dev/null}" 2>/dev/null || printf '0'
}
