# shellcheck shell=bash
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
# Glyph vocabulary (single-width; shared by the line helpers and the card
# segment lines): pending action / done / skipped-protected / waiting.
G_ACT='▸' G_OK='✓' G_SKIP='⊘' G_WAIT='◐'

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
# substrings inside the line stay contiguous in both modes. Styled mode also
# marks the line's state with a glyph inserted after the leading indent
# (would=▸ pending, ok=✓ done, skip=⊘ decision). s_kill stays glyph-free (the
# red is the signal) and s_dim stays for glyph-free noise: "(none)", tips,
# legends. Use s_skip for per-item skip/protect DECISIONS, not for noise.
s__glyph_line() {  # COLOR GLYPH TEXT...  (styled branch only)
  local c="$1" g="$2"; shift 2
  local t="$*" lead
  lead="${t%%[! ]*}"
  printf '%s%s%s %s%s\n' "$c" "$lead" "$g" "${t#"$lead"}" "$C_RESET"
}
s_would() { if [ "$STYLE_ON" -eq 1 ]; then s__glyph_line "$C_YEL" "$G_ACT" "$@"; else printf '%s\n' "$*"; fi; }
s_ok()    { if [ "$STYLE_ON" -eq 1 ]; then s__glyph_line "$C_GRN" "$G_OK" "$@"; else printf '%s\n' "$*"; fi; }
s_skip()  { if [ "$STYLE_ON" -eq 1 ]; then s__glyph_line "$C_DIM" "$G_SKIP" "$@"; else printf '%s\n' "$*"; fi; }
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

# Severity-tinted cell: green < WARN, yellow >= WARN, red >= HOT. VALUE is
# numeric (floats truncate: "12.3" -> 12; non-numeric stays untinted). TEXT
# must arrive pre-padded — pad inside, color outside, or ANSI breaks %-Ns
# width math. Plain mode prints TEXT unchanged. No trailing newline.
s_sevcell() {  # VALUE WARN HOT TEXT...
  local v="${1%%.*}" w="$2" h="$3" c=''
  shift 3
  if [ "$STYLE_ON" -eq 1 ]; then
    case "$v" in
      ''|*[!0-9]*) ;;
      *) if [ "$v" -ge "$h" ]; then c="$C_RED"
         elif [ "$v" -ge "$w" ]; then c="$C_YEL"
         else c="$C_GRN"; fi ;;
    esac
  fi
  printf '%s%s%s' "$c" "$*" "${c:+$C_RESET}"
}

# Humanize ps etime ([[dd-]hh:]mm:ss): "1-02:03:04" -> "1d 2h", "03:04:05" ->
# "3h 4m", "13:05" -> "13m", "00:42" -> "42s". Plain mode and unparseable
# input pass through unchanged, so misuse can never drift the contract.
s_etime() {
  local e="$1" d=0 h=0 m s rest x
  [ "$STYLE_ON" -eq 1 ] || { printf '%s' "$e"; return 0; }
  case "$e" in *-*) d="${e%%-*}"; rest="${e#*-}" ;; *) rest="$e" ;; esac
  case "$rest" in
    *:*:*) h="${rest%%:*}"; rest="${rest#*:}"; m="${rest%%:*}"; s="${rest#*:}" ;;
    *:*)   m="${rest%%:*}"; s="${rest#*:}" ;;
    *)     printf '%s' "$e"; return 0 ;;
  esac
  for x in "$d" "$h" "$m" "$s"; do
    case "$x" in ''|*[!0-9]*) printf '%s' "$e"; return 0 ;; esac
  done
  d=$((10#$d)) h=$((10#$h)) m=$((10#$m)) s=$((10#$s))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# KB -> "3.2 GB" / "500 MB" for meter rows (styled branches only call this).
s_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GB", kb / 1048576
    else printf "%d MB", int(kb / 1024) }'
}

# Share-of-total meter, WIDTH cells (default 12). A nonzero share always
# shows at least one filled cell. Styled only; prints nothing in plain mode.
s_meter() {  # VALUE TOTAL [WIDTH]
  [ "$STYLE_ON" -eq 1 ] || return 0
  local v="${1:-0}" t="${2:-0}" w="${3:-12}" fill=0 i=0 bar=''
  if [ "$t" -gt 0 ] && [ "$v" -gt 0 ]; then
    fill=$(( (v * w + t / 2) / t ))
    [ "$fill" -lt 1 ] && fill=1
    [ "$fill" -gt "$w" ] && fill="$w"
  fi
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$fill" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    i=$((i + 1))
  done
  printf '%s' "$bar"
}

# │-joined segment line for finale cards; skips empty args, prints nothing
# when all are empty (callers gate the s_card_line on the result).
s_segments() {
  local out='' seg
  for seg in "$@"; do
    [ -n "$seg" ] || continue
    out="${out:+$out ${C_DIM}│${C_RESET} }$seg"
  done
  printf '%s' "$out"
}

# Honest pre-announcement before a slow step — one dim line, no spinner, no
# cursor tricks. Styled stderr only; piped/plain runs and report.md stay
# silent exactly as before.
s_heartbeat() {
  [ "$STYLE_ERR" -eq 1 ] || return 0
  printf '%s%s %s …%s\n' "$C_DIM" "$G_WAIT" "$*" "$C_RESET" >&2
}

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
