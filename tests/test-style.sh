#!/usr/bin/env bash
# Style-layer tests: plain mode equivalence (piped auto == AFTERPARTY_STYLE=never),
# styled mode via AFTERPARTY_STYLE=always, JSON immunity, NO_COLOR precedence,
# and card placement.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
BIN="$REPO/bin/afterparty"
PY="$(command -v python3 || command -v python)"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

LEDGER="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tverify UI\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$LEDGER"

# ---------- plain-mode equivalence ----------
# Piped auto output must equal AFTERPARTY_STYLE=never output byte-for-byte.
# Only deterministic commands qualify (process listings embed live cpu/etime).
eq() { # name command...
  local name="$1" gl; shift
  "$@" > "$T/a-$name" 2>/dev/null
  AFTERPARTY_STYLE=never "$@" > "$T/b-$name" 2>/dev/null
  diff -q "$T/a-$name" "$T/b-$name" >/dev/null || fail "plain drift (auto vs never): $name"
  grep -q "$ESC" "$T/a-$name" && fail "ANSI leaked into piped auto output: $name"
  for gl in '▸' '✓' '⊘' '█' '░' '◐'; do
    grep -qF -- "$gl" "$T/a-$name" && fail "glyph leaked into piped auto output: $name ($gl)"
  done
}
eq git bash "$LIB/audit-git.sh"
eq artifacts bash "$LIB/clean-artifacts.sh"
AGENT_PROCESS_LEDGER="$LEDGER" eq list bash "$LIB/process-ledger.sh" list
AGENT_PROCESS_LEDGER="$LEDGER" eq stop bash "$LIB/process-ledger.sh" stop
pass "plain mode: piped auto == never, no ANSI"

# Non-deterministic commands: piped auto must at least be ANSI-free.
for c in "$LIB/audit-processes.sh" "$LIB/devclean.sh"; do
  bash "$c" > "$T/nd.out" 2>/dev/null
  grep -q "$ESC" "$T/nd.out" && fail "ANSI leaked into piped output: $c"
done
pass "plain mode: process listings ANSI-free when piped"

# ---------- A1-A4: styled git run ----------
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"${ESC}["*) : ;; *) fail "A1: no ANSI in styled output" ;; esac
echo "$OUT" | grep -q 'DRY RUN'             || fail "A2: DRY RUN lost in styled mode"
echo "$OUT" | grep -q 'Summary:'            || fail "A2: Summary: lost in styled mode"
echo "$OUT" | grep -q 'Nothing was changed.' || fail "A2: Nothing was changed. lost"
echo "$OUT" | grep -q '● Worktrees'          || fail "A3: styled header missing"
echo "$OUT" | grep -q '=== Worktrees ==='    && fail "A3: legacy header leaked into styled mode"
echo "$OUT" | grep -q '╭'                    || fail "A4: card frame missing"
echo "$OUT" | grep -Eq 'spotless|the damage' || fail "A4: card verdict missing"
pass "A1-A4: styled git output (ANSI, contracts, glyph header, card)"

# ---------- A5: JSON immune to styling ----------
for c in "bash $LIB/audit-git.sh --json" "bash $LIB/audit-processes.sh --json"; do
  J="$(AFTERPARTY_STYLE=always $c 2>/dev/null)"
  case "$J" in *"$ESC"*) fail "A5: ESC leaked into JSON: $c" ;; esac
  printf '%s\n' "$J" | "$PY" -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' || fail "A5: invalid JSONL: $c"
done
J="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" list --json 2>/dev/null)"
case "$J" in *"$ESC"*) fail "A5: ESC leaked into ledger JSON" ;; esac
printf '%s\n' "$J" | "$PY" -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' || fail "A5: invalid ledger JSONL"
pass "A5: --json byte-clean under AFTERPARTY_STYLE=always"

# ---------- A6: NO_COLOR precedence ----------
OUT="$(NO_COLOR=1 AFTERPARTY_STYLE=always bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"${ESC}["*) : ;; *) fail "A6: AFTERPARTY_STYLE=always should beat NO_COLOR" ;; esac
OUT="$(NO_COLOR=1 bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"${ESC}["*) fail "A6: NO_COLOR alone must stay plain" ;; esac
pass "A6: NO_COLOR precedence both directions"

# ---------- A7: composite = exactly one card, banner, no tally litter ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" "$BIN" audit 2>/dev/null)"
N_CARDS="$(printf '%s\n' "$OUT" | grep -c '╭')"
[ "$N_CARDS" = "1" ] || fail "A7: composite should show exactly 1 card, got $N_CARDS"
echo "$OUT" | grep -q 'afterparty — last call' || fail "A7: banner missing"
ls "${TMPDIR:-/tmp}"/afterparty-tally.* >/dev/null 2>&1 && fail "A7: tally tmp files left behind"
pass "A7: composite audit (one card, banner, tally cleaned)"

# ---------- A7b: protected-only composite kill gets a truthful receipt ----------
# Fake only the OS process boundary. The matching group has a protected
# cursor-server sibling, and its deliberately nonexistent PGID could not
# signal a real process even if the guard regressed.
PROT_SHIM="$T/protected-shim"
mkdir -p "$PROT_SHIM"
cat > "$PROT_SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pid,ppid,pgid,%cpu,etime,command*)
    printf '2147483000 1 2147483000 1.0 00:10 nodemon /tmp/fake\n' ;;
  *-Ao\ pgid=,command=*)
    printf '2147483000 cursor-server\n' ;;
  *-o\ pgid=*-p*|*-o\ pgid=\ -p*)
    printf '999999999\n' ;;
  *-Ao\ pid=*)
    exit 0 ;;
  *)
    exit 1 ;;
esac
PS
chmod +x "$PROT_SHIM/ps"
PROT_LEDGER="$T/protected-ledger.tsv"
: > "$PROT_LEDGER"
OUT="$(PATH="$PROT_SHIM:$PATH" AFTERPARTY_STYLE=always \
  AGENT_PROCESS_LEDGER="$PROT_LEDGER" "$BIN" audit --kill dev 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '⊘ 1 protected' \
  || fail "A7b: protected-only composite receipt lost protected count"
printf '%s\n' "$OUT" | grep -qF 'spotless — nobody crashed on your couch' \
  && fail "A7b: protected-only composite kill rendered a false spotless card"
pass "A7b: protected-only composite kill receipt"

# ---------- A7c: explicit keep is visible only in styled output ----------
# Reuse the impossible PGID fixture above. The public CLI must route keep
# before the protected-group guard and must never reach the signal path.
SIGNAL_MARKER="$T/keep-signal-path"
cat > "$PROT_SHIM/sleep" <<'SLEEP'
#!/usr/bin/env bash
: "${AFTERPARTY_TEST_SIGNAL_MARKER:?}"
printf 'signal path entered\n' >> "$AFTERPARTY_TEST_SIGNAL_MARKER"
SLEEP
chmod +x "$PROT_SHIM/sleep"
OUT="$(PATH="$PROT_SHIM:$PATH" AFTERPARTY_STYLE=always \
  AFTERPARTY_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" \
  AGENT_PROCESS_LEDGER="$PROT_LEDGER" \
  "$BIN" audit --kill dev --keep 2147483000 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '⊘ keep pgid 2147483000: requested via --keep' \
  || fail "A7c: styled explicit keep decision missing"
[ ! -e "$SIGNAL_MARKER" ] \
  || fail "A7c: explicitly kept pgid reached the signal path"

OUT="$(PATH="$PROT_SHIM:$PATH" bash \
  "$LIB/audit-processes.sh" --kill dev --keep 2147483000 2>/dev/null)"
EXPECTED="$(printf '%s\n' \
  "Killing category 'dev' (keep: 2147483000)" \
  "  nothing to kill" \
  "0 stopped · 0 protected · 0 already gone · 0 failed" \
  "done")"
[ "$OUT" = "$EXPECTED" ] || fail "A7c: explicit keep changed legacy plain output"
pass "A7c: explicit keep decision styled, legacy plain output stable"

# ---------- A8: stop styled ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" stop 2>/dev/null)"
echo "$OUT" | grep -q 'DRY RUN' || fail "A8: stop styled lost DRY RUN"
echo "$OUT" | grep -q '╭'       || fail "A8: stop card missing"
pass "A8: stop styled banner + card"

# ---------- A9: doctor shows no cards ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" "$BIN" doctor 2>/dev/null)"
N_CARDS="$(printf '%s\n' "$OUT" | grep -c '╭' || true)"
[ "$N_CARDS" = "0" ] || fail "A9: doctor should show 0 cards, got $N_CARDS"
pass "A9: doctor card-free"

# ---------- S1: git — ▸ on would-lines, ⊘ on skip decisions, plain stable ----------
# Deterministic fixture: one untracked litter file + a fresh (young) index.lock.
GITFIX="$T/gitfix"
git init -qb main "$GITFIX" 2>/dev/null || git init -q "$GITFIX"
git -C "$GITFIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo x > "$GITFIX/foo.orig"
touch "$GITFIX/.git/index.lock"
eq gitfix bash "$LIB/audit-git.sh" --root "$GITFIX"
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-git.sh" --root "$GITFIX" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '▸ would remove foo.orig' || fail "S1: styled would-line missing ▸"
printf '%s\n' "$OUT" | grep -qF '⊘ left alone:' || fail "S1: young index.lock decision missing ⊘"
printf '%s\n' "$OUT" | grep -qF '⊘ main:' && fail "S1: main-worktree policy line must stay glyph-free"
printf '%s\n' "$OUT" | grep -qF '▸ 1 would-clean' || fail "S1: git damage card missing segment line"
pass "S1: git glyphs (styled) + gitfix plain stability"

# ---------- S2: ledger stop — ⊘ on skip decision lines ----------
LED_SKIP="$T/ledger-skip.tsv"
SKIP_SHIM="$T/skip-shim"; mkdir -p "$SKIP_SHIM"
cat > "$SKIP_SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command=") printf '12345 77777 Sun Sep 6 10:00:00 2026 sleepx\n' ;;
  "-o pgid= -p "*) printf '77777\n' ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SKIP_SHIM/ps"
SKIP_PROOF="$(PATH="$SKIP_SHIM:$PATH" bash -c '. "$1/fingerprint.sh"; fp_members_for_pgid 77777' _ "$LIB")"
[ -n "$SKIP_PROOF" ] || fail "S2: identity fixture unavailable before shared-shell check"
printf '2026-07-14T00:00:00Z\t%s\t%s\t12345\t77777\tdev\t-\t-\tsleepx\t%s\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" "$SKIP_PROOF" > "$LED_SKIP"
PATH="$SKIP_SHIM:$PATH" AGENT_PROCESS_LEDGER="$LED_SKIP" eq stopskip bash "$LIB/process-ledger.sh" stop
OUT="$(PATH="$SKIP_SHIM:$PATH" AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LED_SKIP" bash "$LIB/process-ledger.sh" stop 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '⊘ skip pid 12345: pgid is shared with this shell (77777)' || fail "S2: proven shared-shell skip decision missing ⊘"
printf '%s\n' "$OUT" | grep -qF '1 skipped' || fail "S2: ledger-clear card missing skipped segment"
pass "S2: stop skip glyphs (styled) + plain stability"

# ---------- S3: artifacts — ⊘ on git-tracked skip ----------
ARTFIX="$T/artfix"
git init -qb main "$ARTFIX" 2>/dev/null || git init -q "$ARTFIX"
mkdir -p "$ARTFIX/.cache" "$ARTFIX/dist"
echo keep > "$ARTFIX/.cache/keep.txt"
git -C "$ARTFIX" -c core.autocrlf=false add .cache/keep.txt
git -C "$ARTFIX" -c user.email=t@t -c user.name=t commit -qm init
dd if=/dev/zero of="$ARTFIX/dist/blob" bs=1024 count=200 2>/dev/null
eq artfix bash "$LIB/clean-artifacts.sh" --root "$ARTFIX"
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/clean-artifacts.sh" --root "$ARTFIX" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '⊘ skip (tracked): .cache' || fail "S3: artifacts skip decision missing ⊘"
pass "S3: artifacts skip glyphs (styled) + plain stability"

# ---------- S4: artifacts styled size tints + category share meters ----------
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/clean-artifacts.sh" --root "$ARTFIX" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '█' || fail "S4: category meter bars missing in styled mode"
printf '%s\n' "$OUT" | grep -qF "${ESC}[32m" || fail "S4: small size cell not green-tinted"
printf '%s\n' "$OUT" | grep -q 'Reclaimable total:' || fail "S4: total line lost in styled mode"
printf '%s\n' "$OUT" | grep -qF '▸ 1 path' || fail "S4: artifacts damage card missing segment line"
pass "S4: artifacts meters + size tints (styled)"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
