#!/usr/bin/env bash
# Unit tests for style.sh display helpers (severity cells, meters, humanized
# etime, glyph lines, segments, heartbeat). Pure string checks — fully
# runnable on Git Bash, where live process tables can't exercise these paths.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STYLE="$REPO/skills/afterparty/lib/style.sh"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

# Run one helper in a fresh shell that sourced style.sh, styled vs plain.
sty() { AFTERPARTY_STYLE=always bash -c '. "$1"; shift; "$@"' _ "$STYLE" "$@"; }
pln() { AFTERPARTY_STYLE=never  bash -c '. "$1"; shift; "$@"' _ "$STYLE" "$@"; }

# ---------- H1: s_etime humanizes ps etime in styled mode only ----------
[ "$(sty s_etime '1-02:03:04')" = '1d 2h' ] || fail "H1: 1-02:03:04 -> 1d 2h"
[ "$(sty s_etime '03:04:05')"   = '3h 4m' ] || fail "H1: 03:04:05 -> 3h 4m"
[ "$(sty s_etime '13:05')"      = '13m'   ] || fail "H1: 13:05 -> 13m"
[ "$(sty s_etime '00:42')"      = '42s'   ] || fail "H1: 00:42 -> 42s"
[ "$(sty s_etime 'junk')"       = 'junk'  ] || fail "H1: unparseable passes through"
[ "$(pln s_etime '1-02:03:04')" = '1-02:03:04' ] || fail "H1: plain passes through raw"
pass "H1: s_etime"

# ---------- H2: s_sevcell tints by threshold, plain byte-exact ----------
case "$(sty s_sevcell 55 10 50 '55.0')" in *"$ESC[31m"*) : ;; *) fail "H2: >=hot must be red" ;; esac
case "$(sty s_sevcell 12 10 50 '12')"   in *"$ESC[33m"*) : ;; *) fail "H2: >=warn must be yellow" ;; esac
case "$(sty s_sevcell 3 10 50 '3')"     in *"$ESC[32m"*) : ;; *) fail "H2: <warn must be green" ;; esac
case "$(sty s_sevcell '12.3' 10 50 '12.3')" in *"$ESC[33m"*) : ;; *) fail "H2: float truncates to int" ;; esac
case "$(sty s_sevcell '-' 10 50 '-')"   in *"$ESC"*) fail "H2: non-numeric must stay untinted" ;; esac
OUT="$(pln s_sevcell 55 10 50 '87.3  ')x"
[ "$OUT" = '87.3  x' ] || fail "H2: plain must pass padded text through byte-exact"
pass "H2: s_sevcell"

# ---------- H2b: s_sizecell owns the shared 100 MB / 1 GB policy ----------
case "$(sty s_sizecell 102399 'small')"  in *"$ESC[32m"*) : ;; *) fail "H2b: <100 MB must be green" ;; esac
case "$(sty s_sizecell 102400 'warn')"   in *"$ESC[33m"*) : ;; *) fail "H2b: 100 MB must be yellow" ;; esac
case "$(sty s_sizecell 1048576 'hot')"   in *"$ESC[31m"*) : ;; *) fail "H2b: 1 GB must be red" ;; esac
OUT="$(pln s_sizecell 1048576 'hot  ')x"
[ "$OUT" = 'hot  x' ] || fail "H2b: plain must pass padded text through byte-exact"
pass "H2b: s_sizecell"

# ---------- H3: s_meter share bars, styled only ----------
[ "$(sty s_meter 512 1024 12)"  = '██████░░░░░░' ] || fail "H3: half fills 6 of 12"
[ "$(sty s_meter 1 1024 12)"    = '█░░░░░░░░░░░' ] || fail "H3: nonzero share shows >=1 cell"
[ "$(sty s_meter 1024 1024 12)" = '████████████' ] || fail "H3: full share fills all"
[ "$(sty s_meter 0 0 12)"       = '░░░░░░░░░░░░' ] || fail "H3: zero total -> empty bar"
[ "$(sty s_meter 512 1024)"     = '██████░░░░░░' ] || fail "H3: width defaults to 12"
OUT="$(pln s_meter 512 1024)x"
[ "$OUT" = 'x' ] || fail "H3: plain mode prints nothing"
pass "H3: s_meter"

# ---------- H4: s_kb human sizes ----------
[ "$(sty s_kb 3355443)" = '3.2 GB' ] || fail "H4: kb -> GB one decimal"
[ "$(sty s_kb 512000)"  = '500 MB' ] || fail "H4: kb -> whole MB"
[ "$(sty s_kb 0)"       = '0 MB'   ] || fail "H4: zero -> 0 MB"
pass "H4: s_kb"

# ---------- H5: glyphs on action lines, plain byte-exact ----------
case "$(sty s_would '  would kill pgid 42')" in *'  ▸ would kill pgid 42'*) : ;; *) fail "H5: s_would styled gains ▸ after indent" ;; esac
[ "$(pln s_would '  would kill pgid 42')" = '  would kill pgid 42' ] || fail "H5: s_would plain byte-exact"
case "$(sty s_would 'would remove x')" in '▸ would remove x'*|*"m▸ would remove x"*) : ;; *) fail "H5: s_would glyph without indent" ;; esac
case "$(sty s_ok 'done')" in *'✓ done'*) : ;; *) fail "H5: s_ok styled gains ✓" ;; esac
[ "$(pln s_ok '  deleted')" = '  deleted' ] || fail "H5: s_ok plain byte-exact"
case "$(sty s_skip '  protect pgid 9: shared')" in *'⊘ protect pgid 9: shared'*) : ;; *) fail "H5: s_skip styled gains ⊘" ;; esac
case "$(sty s_skip '  protect pgid 9: shared')" in *"$ESC[2m"*) : ;; *) fail "H5: s_skip must be dim" ;; esac
[ "$(pln s_skip '  protect pgid 9: shared')" = '  protect pgid 9: shared' ] || fail "H5: s_skip plain byte-exact"
OUT="$(sty s_kill '  SIGTERM -> pgid 9')"
case "$OUT" in *'▸'*|*'✓'*|*'⊘'*) fail "H5: s_kill must stay glyph-free" ;; esac
case "$OUT" in *"$ESC[31m"*) : ;; *) fail "H5: s_kill still red" ;; esac
pass "H5: glyph lines"

# ---------- H6: s_segments joins nonempty parts ----------
OUT="$(sty s_segments '▸ 3 would-kill' '' '⊘ 1 protected')"
case "$OUT" in *'▸ 3 would-kill'*'│'*'⊘ 1 protected'*) : ;; *) fail "H6: segments join with │, skip empties" ;; esac
OUT="$(sty s_segments '' '')x"
[ "$OUT" = 'x' ] || fail "H6: all-empty -> empty output"
pass "H6: s_segments"

# ---------- H7: s_heartbeat styled-stderr only ----------
ERR="$(sty s_heartbeat 'sizing up x' 2>&1 >/dev/null)"
case "$ERR" in *'◐ sizing up x …'*) : ;; *) fail "H7: styled heartbeat on stderr" ;; esac
OUT="$(sty s_heartbeat 'sizing up x' 2>/dev/null)x"
[ "$OUT" = 'x' ] || fail "H7: heartbeat must not touch stdout"
ERR="$(pln s_heartbeat 'sizing up x' 2>&1 >/dev/null)x"
[ "$ERR" = 'x' ] || fail "H7: plain mode heartbeat silent"
ERR="$(AFTERPARTY_STYLE=always bash -c \
  '. "$1"; STYLE_ON=0; STYLE_ERR=1; s_heartbeat "sizing up x"' \
  _ "$STYLE" 2>&1 >/dev/null)x"
[ "$ERR" = 'x' ] || fail "H7: stdout-only pipeline state must stay silent"
pass "H7: s_heartbeat"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
