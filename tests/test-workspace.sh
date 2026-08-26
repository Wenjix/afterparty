#!/usr/bin/env bash
# workspace.sh unit tests: age formatting, mtime, transcript indexing, and pid
# attribution. READ-ONLY throughout -- workspace.sh never signals or deletes.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB/workspace.sh"

# ---------- W1: age bands the glance table renders ----------
while IFS='|' read -r secs want; do
  got="$(ws_human_age "$secs")"
  if [ "$got" = "$want" ]; then
    pass "W1: ${secs}s -> $want"
  else
    fail "W1: ${secs}s -> '$got', want '$want'"
  fi
done <<'CASES'
0|just now
59|just now
60|1m
900|15m
3600|1h 00m
24000|6h 40m
86400|1d 00h
183600|2d 03h
CASES

# ---------- W2: mtime reads real files and fails closed on missing ----------
touch "$T/f"
if [ -n "$(ws_mtime "$T/f")" ]; then pass "W2: mtime of a real file"; else fail "W2: no mtime for a real file"; fi
if ws_mtime "$T/nope" >/dev/null 2>&1; then
  fail "W2: missing file reported a mtime"
else
  pass "W2: missing file fails closed"
fi

# ---------- W3: identity comes from the recorded cwd, not the dir name ----------
# The slug is lossy -- both "/" and "." become "-" -- so decoding it is
# ambiguous. The transcript stamps its own cwd; read that instead.
R="$T/projects"
mkdir -p "$R/-Users-x-alpha" "$R/-Users-x-beta" "$R/empty"
printf '{"type":"user","cwd":"/Users/x/alpha","sessionId":"a"}\n' > "$R/-Users-x-alpha/a.jsonl"
printf '{"type":"user","cwd":"/Users/x/beta","sessionId":"b"}\n'  > "$R/-Users-x-beta/b.jsonl"
_b=$FAILS
OUT="$(AFTERPARTY_TRANSCRIPT_ROOT="$R" ws_index)"
printf '%s\n' "$OUT" | grep -q '/Users/x/alpha' || fail "W3: alpha missing from index"
printf '%s\n' "$OUT" | grep -q '/Users/x/beta'  || fail "W3: beta missing from index"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 2 ] || fail "W3: a transcript-less dir contributed a row"
# A literal tab, not "\t": GNU grep reads \t in a BRE as the letter t, while
# BSD grep reads it as a tab -- so the escaped form passes on macOS and fails
# on Linux.
TAB="$(printf '\t')"
printf '%s\n' "$OUT" | grep -q "^[0-9][0-9]*${TAB}/Users/x/alpha$" \
  || fail "W3: row is not <epoch>TAB<cwd>"
[ "$FAILS" -eq "$_b" ] && pass "W3: workspaces indexed by transcript-recorded cwd"

# ---------- W4: newest transcript in a workspace decides last-touched ----------
# The fixture is deliberately ADVERSARIAL. An earlier version wrote a fresh
# a.jsonl and a backdated older.jsonl, where the correct branch and a
# first-match-wins branch happened to select the SAME file, so the comparison
# ran but could not discriminate. Here the OLDEST file sorts first by name and
# the NEWEST sorts last, so any selection that is not genuinely
# recency-based picks the wrong one.
#
# The assertion is exact epoch EQUALITY, not "recent enough": a freshness range
# silently regains the same blind spot the moment the decoy is less than an
# hour old. Real ~/.claude/projects dirs hold many UUID-named transcripts whose
# glob order is unrelated to mtime, which is the case this protects.
backdate() {  # backdate <days> <file>
  touch -d "$1 days ago" "$2" 2>/dev/null \
    || touch -t "$(date -v -"$1"d +%Y%m%d%H%M)" "$2" \
    || fail "backdate: neither GNU nor BSD touch worked"
}
mkdir -p "$R/-Users-x-gamma"
for f in aaa-oldest mmm-middle zzz-newest; do
  printf '{"cwd":"/Users/x/gamma"}\n' > "$R/-Users-x-gamma/$f.jsonl"
done
backdate 300 "$R/-Users-x-gamma/aaa-oldest.jsonl"
backdate 100 "$R/-Users-x-gamma/mmm-middle.jsonl"
# zzz-newest keeps its creation mtime — the newest, and last in glob order.
_b=$FAILS
WANT="$(ws_mtime "$R/-Users-x-gamma/zzz-newest.jsonl")"
GOT="$(AFTERPARTY_TRANSCRIPT_ROOT="$R" ws_index | awk -F'\t' '$2=="/Users/x/gamma"{print $1}')"
[ -n "$GOT" ] || fail "W4: gamma missing from the index entirely"
[ "$GOT" = "$WANT" ] \
  || fail "W4: last-touched is $GOT, want $WANT (the newest transcript's mtime)"
[ "$FAILS" -eq "$_b" ] && pass "W4: newest transcript decides last-touched"

# ---------- W5: no transcript root degrades quietly ----------
if AFTERPARTY_TRANSCRIPT_ROOT="$T/absent" ws_index >/dev/null 2>&1; then
  pass "W5: missing transcript root degrades to empty"
else
  fail "W5: missing transcript root errored instead of degrading"
fi

# ---------- W6: pid attribution needs lsof and fails closed without it ----------
SHIM="$T/wsshim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nprintf "p7001\\nn/w/attributed\\n"\n' > "$SHIM/lsof"
chmod +x "$SHIM/lsof"
_b=$FAILS
GOT="$(PATH="$SHIM:$PATH" ws_for_pid 7001)"
[ "$GOT" = "/w/attributed" ] || fail "W6: ws_for_pid returned '$GOT', want /w/attributed"
if PATH="$T/nothing" ws_for_pid 7001 >/dev/null 2>&1; then
  fail "W6: ws_for_pid claimed a workspace with no lsof"
else
  [ "$FAILS" -eq "$_b" ] && pass "W6: pid attributed via lsof, fails closed without it"
fi

# ---------- W7: workspace labels must disambiguate ----------
# A bare basename collides the moment two projects share a leaf name, and
# "web", "api" and "server" are the most common leaf names there are. On the
# APPROVAL surface an ambiguous label is a wrong approval waiting to happen:
# two rows read identically and you cannot tell which one you are ticking.
_b=$FAILS
# Every pair here defeated an earlier attempt: basename collapsed the first
# pair, and parent/leaf collapsed the second AND rendered the third as a single
# segment because its parent and leaf are the same word.
while IFS='|' read -r p1 p2 why; do
  l1="$(ws_label "$p1")"; l2="$(ws_label "$p2")"
  [ "$l1" != "$l2" ] || fail "W7: $why — both render as '$l1'"
done <<'PAIRS'
/Users/x/alpha/web|/Users/x/beta/web|sibling projects sharing a leaf name
/client-one/apps/web|/client-two/apps/web|monorepo apps/ layout
/repo/web/web|/other/web/web|repeated segment names
PAIRS
[ "$(ws_label /repo/web/web)" != "web" ] \
  || fail "W7: a path whose parent and leaf match collapsed to one segment"
[ -n "$(ws_label '')" ] || fail "W7: an empty path must still produce some label"

# Width fitting must drop LEADING segments: the tail is what distinguishes two
# workspaces, so right-truncation would reintroduce the collision.
F1="$(ws_label_fit /client-one/apps/web 14)"
F2="$(ws_label_fit /client-two/apps/web 14)"
[ "$F1" != "$F2" ] || fail "W7: fitted labels collide at narrow widths: '$F1'"
printf '%s' "$F1" | grep -q 'web' || fail "W7: fitting dropped the distinguishing tail: $F1"
[ "${#F1}" -le 14 ] || fail "W7: fitted label is ${#F1} chars, over the 14 requested"
# and in BYTES, which is what a %-Ns column actually pads by. A multibyte
# marker made this overflow by 2 under a non-UTF-8 locale.
B1="$(printf '%s' "$F1" | wc -c | tr -d '[:space:]')"
[ "$B1" -le 14 ] || fail "W7: fitted label is $B1 BYTES, over the 14 requested"
[ "$FAILS" -eq "$_b" ] && pass "W7: workspace labels distinguish projects that share a leaf name"

# ---------- W8: labels are unique within the table being displayed ----------
# Uniqueness only has to hold among the rows actually shown, so it is computed
# there: one segment where that suffices, more only where it does not. A label
# that is unambiguous but unreadable is its own failure on a surface whose job
# is to be scanned.
_b=$FAILS
LBL="$(printf '%s\n' \
  /Users/x/Documents/GitHub/proxymates \
  /Users/x/Documents/GitHub/loupe \
  /Users/x/orca/afterparty \
  /client-one/apps/web \
  /client-two/apps/web | ws_unique_labels)"
[ "$(printf '%s\n' "$LBL" | wc -l | tr -d '[:space:]')" -eq 5 ] \
  || fail "W8: expected one label per path"
# every label distinct
DUP="$(printf '%s\n' "$LBL" | cut -f2 | sort | uniq -d)"
[ -z "$DUP" ] || fail "W8: duplicate labels rendered: $DUP"
# short where it can be
[ "$(printf '%s\n' "$LBL" | awk -F'\t' '$1 ~ /proxymates$/ {print $2}')" = "proxymates" ] \
  || fail "W8: an unambiguous workspace was not shortened to one segment"
# longer only where it must be
W1="$(printf '%s\n' "$LBL" | awk -F'\t' '$1 == "/client-one/apps/web" {print $2}')"
printf '%s' "$W1" | grep -q 'client-one' \
  || fail "W8: a colliding workspace was not lengthened enough to distinguish it: $W1"
[ "$FAILS" -eq "$_b" ] && pass "W8: labels are the shortest suffix unique within the displayed table"

# ---------- W9: uniqueness must survive rendering ----------
# Labels that ws_unique_labels made distinct were being right-truncated to a
# fixed column width, which merged them again — reintroducing the exact
# collision the labelling exists to prevent. Renderers pad now, never truncate.
_b=$FAILS
LONG_A="/Users/x/aaaaaaaaaaaaaaaaaaaaaaaaaaaaX/web"
LONG_B="/Users/x/aaaaaaaaaaaaaaaaaaaaaaaaaaaaY/web"
LL="$(printf '%s\n%s\n' "$LONG_A" "$LONG_B" | ws_unique_labels | cut -f2)"
L1="$(printf '%s\n' "$LL" | sed -n 1p)"; L2="$(printf '%s\n' "$LL" | sed -n 2p)"
[ "$L1" != "$L2" ] || fail "W9: long-prefix workspaces share a label"
# and after the renderer's field width
R1="$(printf '%-28s' "$L1")"; R2="$(printf '%-28s' "$L2")"
[ "$R1" != "$R2" ] || fail "W9: labels merge once rendered into a 28-column field"
# glance must not carry a truncating precision on the workspace column
grep -q '%-28\.28s' "$LIB/glance.sh" \
  && fail "W9: glance still truncates the workspace column, which can merge distinct labels"
[ "$FAILS" -eq "$_b" ] && pass "W9: distinct labels stay distinct through rendering"

# ---------- W10: repeated owners must not defeat shortening ----------
# Callers pass one row per finding, and two process groups in one workspace is
# the normal case. Counting a path twice made every suffix look ambiguous, so
# that workspace fell back to its absolute path exactly when it was busiest.
_b=$FAILS
DL="$(printf '%s\n' /Users/x/GitHub/loupe /Users/x/GitHub/loupe /Users/x/orca/afterparty | ws_unique_labels)"
[ "$(printf '%s\n' "$DL" | awk -F'\t' '$1 ~ /loupe$/ {print $2}' | head -1)" = "loupe" ] \
  || fail "W10: a workspace appearing twice fell back to its full path"
[ "$FAILS" -eq "$_b" ] && pass "W10: a repeated workspace still gets its short label"

# ---------- W11: multibyte paths are never cut mid-character ----------
# ${#var} and shell substrings measure bytes under a non-UTF-8 locale, so any
# width-based cut can land inside a codepoint. Renderers no longer truncate,
# so the label is emitted whole.
_b=$FAILS
JP1=/Users/x/プロジェクト/web
JP2=/Users/x/別プロジェクト/web
JL="$(printf '%s\n%s\n' "$JP1" "$JP2" | ws_unique_labels | cut -f2)"
J1="$(printf '%s\n' "$JL" | sed -n 1p)"; J2="$(printf '%s\n' "$JL" | sed -n 2p)"
[ "$J1" != "$J2" ] || fail "W11: multibyte workspaces share a label"
printf '%s' "$J1" | grep -q 'プロジェクト' \
  || fail "W11: the multibyte label was mangled: $J1"
# a cut mid-codepoint shows up as a replacement/partial byte sequence
printf '%s' "$J1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  || fail "W11: the label is not valid UTF-8 — it was cut mid-character"
[ "$FAILS" -eq "$_b" ] && pass "W11: multibyte labels stay whole and valid UTF-8"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
