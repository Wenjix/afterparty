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

# ---------- H8: width lookup, Unicode wrapping, and the no-Python fallback ----------
for cols in 60 80 120; do
  got="$(COLUMNS="$cols" sty s_columns)"
  [ "$got" = "$cols" ] || fail "H8: COLUMNS=$cols resolved to $got"
done
[ "$(COLUMNS=bad sty s_columns)" = 80 ] || fail 'H8: malformed width did not fall back to 80'
[ "$(COLUMNS=0 sty s_columns)" = 80 ] || fail 'H8: zero width did not fall back to 80'
RAW='  /workspace/日本語-project/long-name/another-long-name/dist with extra details'
OUT="$(printf '%s\n' "$RAW" | COLUMNS=60 sty s_wrap)"
printf '%s\n' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null || fail 'H8: native wrapping cut UTF-8'
[ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "$(printf '%s' "$RAW" | tr -d '[:space:]')" ] || fail 'H8: wrapping lost identity text'
[ "$(printf '%s\n' "$RAW" | COLUMNS=60 pln s_wrap)" = "$RAW" ] || fail 'H8: plain wrapping changed text'
OUT="$(printf '%s\n' "$RAW" | COLUMNS=60 AFTERPARTY_STYLE=always bash -c '
  . "$1"
  command() { if [ "$*" = "-v python3" ]; then return 1; fi; builtin command "$@"; }
  s_wrap' _ "$STYLE")"
printf '%s\n' "$OUT" | grep -qF '\xe6' || fail 'H8: missing Python did not enter byte-escape fallback'
printf '%s\n' "$OUT" | awk 'length($0)>59 {bad=1} END {exit bad}' || fail 'H8: fallback overflowed its width'
printf '%s\n' "$OUT" | grep -q 'extra details' || fail 'H8: fallback lost tail text'
pass 'H8: width fallback and complete UTF-8/ASCII identities'

# A redirected stdin must not hide the active output terminal's size.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$STYLE" "$BASH" <<'PYTEST' || fail 'H9: output terminal width'
import os, subprocess, sys
if os.name != 'nt':
    import fcntl, pty, struct, termios
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 93, 0, 0))
        for columns in ('60', None):
            env = dict(os.environ, AFTERPARTY_STYLE='always')
            env.pop('COLUMNS', None)
            if columns:
                env['COLUMNS'] = columns
            result = subprocess.run([sys.argv[2], '-c', '. "$1"; printf "%s\\n" "$S_COLUMNS"; s_columns',
                                     'fixture', sys.argv[1]], env=env, stdin=subprocess.DEVNULL,
                                    stdout=slave, stderr=subprocess.PIPE, timeout=5)
            assert result.returncode == 0, result.stderr
            assert os.read(master, 1024).split() == [b'93', b'93']
    finally:
        os.close(slave)
        os.close(master)
PYTEST
  pass 'H9: active output terminal wins over COLUMNS with redirected stdin'
fi

# Wrapping cannot erase significant path spaces or rewrite shell escapes.
python3 - "$STYLE" "$BASH" <<'PYTEST' || fail 'H10: lossless identity and command rendering'
import os, re, subprocess, sys
env = dict(os.environ, AFTERPARTY_STYLE='always', COLUMNS='60')
def styled(script, *args, text=None):
    result = subprocess.run([sys.argv[2], '-c', '. "$1"; ' + script, 'fixture', sys.argv[1], *args],
                            input=text, text=True, encoding='utf-8', capture_output=True, env=env, timeout=5)
    assert result.returncode == 0, result.stderr
    return re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
base = '    Path: /work/' + 'a' * 41
outputs = []
for suffix in (' suffix', '  suffix', r'\ suffix'):
    original = base + suffix
    lines = styled('s_wrap', text=original + '\n').splitlines()
    assert len(lines) > 1, 'fixture did not enter wrapping'
    assert lines[0] + ''.join(line[4:] for line in lines[1:]) == original
    outputs.append(lines)
assert outputs[0] != outputs[1], 'distinct path spaces became identical'
root = r'/tmp/project  space/日本語/with\backslash'
line = styled('export LC_ALL=C; printf -v quoted %q "$2"; s_card_command "afterparty plan --root $quoted"', root)
assert len(line.splitlines()) == 1, 'copyable command gained hard line breaks'
assert line.startswith('│  afterparty plan'), 'command rendering was not entered'
command = line[len('│  '):]
result = subprocess.run([sys.argv[2], '-c', 'afterparty() { printf "%s\\0" "$@"; }; ' + command],
                        capture_output=True, timeout=5)
assert result.returncode == 0, result.stderr
assert result.stdout.split(b'\0') == [b'plan', b'--root', root.encode(), b'']
PYTEST
pass 'H10: significant spaces and copyable shell quoting survive rendering'

# Review can retain focus attributes without changing ordinary NO_COLOR output.
python3 - "$STYLE" "$BASH" <<'PYTEST' || fail 'H11: review NO_COLOR attributes'
import os, subprocess, sys
if os.name != 'nt':
    import pty
    master, slave = pty.openpty()
    try:
        for mode, attributes in (('auto', b'1'), ('never', b'0')):
            env = dict(os.environ, AFTERPARTY_STYLE=mode, NO_COLOR='1', TERM='xterm-256color')
            script = ('. "$1"; s_review_theme; '
                      'printf "%s|%s|%s|%s\\n" "$AFTERPARTY_REVIEW_COLOR" '
                      '"$AFTERPARTY_REVIEW_ATTRIBUTES" "$AFTERPARTY_REVIEW_BOLD" "$C_BOLD"')
            result = subprocess.run([sys.argv[2], '-c', script, 'fixture', sys.argv[1]],
                                    env=env, stdin=subprocess.DEVNULL, stdout=slave,
                                    stderr=subprocess.PIPE, timeout=5)
            assert result.returncode == 0, result.stderr
            color, actual, bold, ordinary = os.read(master, 1024).strip().split(b'|')
            assert color == b'0', 'NO_COLOR enabled review hues'
            assert actual == attributes, (mode, actual)
            assert bold == (b'\x1b[1m' if attributes == b'1' else b''), (mode, bold)
            assert ordinary == b'', 'review changed ordinary CLI attributes'
    finally:
        os.close(slave)
        os.close(master)
PYTEST
pass 'H11: review NO_COLOR keeps focus attributes; ordinary CLI stays plain'

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
