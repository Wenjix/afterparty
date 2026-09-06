#!/usr/bin/env bash
# Process-table rendering tests using a fake ps/pgrep/lsof PATH shim, so the
# tables are deterministic on every machine (Git Bash included, where real
# `ps` lacks -Ao). DRY-RUN ONLY: the canned pids must never be signalled, so
# no --kill/--apply runs in here, ever.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

# ---------- PATH shim: canned process world ----------
# One stray vitest (pid 41234, 87.3 %cpu, up 1d2h) and one orphaned
# next-server (pid 51234, 2 GB rss). pgid 99999 is "our" shell's group.
SHIM="$T/shim"
mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pid,ppid,pgid,%cpu,etime,command*)
    printf '41234 1 41234 87.3 1-02:03:04 node /repo/node_modules/.bin/vitest --watch\n' ;;
  *-o\ pid=,ppid=,pgid=,rss=,%cpu=,etime=,command=*)
    printf '51234 1 51234 2097152 87.3 03:04:05 next-server /app\n' ;;
  *-o\ rss=*) printf '2097152\n' ;;
  *-o\ pgid=*-p*|*-o\ pgid=\ -p*) printf '99999\n' ;;
  *-eo\ ppid=,pid=,command=*) printf '1 51234 next-server /app\n' ;;
  *-Ao\ pgid=*) printf '99999\n' ;;
  *-Ao\ pid=*) exit 0 ;;
  *-p\ 41234*|*-p\ 51234*) exit 0 ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/pgrep" <<'PG'
#!/usr/bin/env bash
# devclean orphan scan: always report the canned next-server orphan.
printf '51234\n'
PG
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
exit 1
LS
chmod +x "$SHIM/ps" "$SHIM/pgrep" "$SHIM/lsof"
export PATH="$SHIM:$PATH"

# ---------- P1: audit-processes styled table (severity + humanized etime) ----------
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-processes.sh" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'vitest --watch' || fail "P1: canned vitest row missing entirely"
printf '%s\n' "$OUT" | grep -qF "${ESC}[31m87.3" || fail "P1: 87.3 %cpu cell not red"
printf '%s\n' "$OUT" | grep -qF '1d 2h' || fail "P1: etime not humanized in styled table"
printf '%s\n' "$OUT" | grep -qF '1-02:03:04' && fail "P1: raw etime leaked into styled table"
pass "P1: audit-processes styled severity + etime"

# ---------- P2: audit-processes plain table byte-stable, raw etime ----------
bash "$LIB/audit-processes.sh" > "$T/p-a" 2>/dev/null
AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" > "$T/p-b" 2>/dev/null
diff -q "$T/p-a" "$T/p-b" >/dev/null || fail "P2: plain drift (auto vs never)"
grep -q "$ESC" "$T/p-a" && fail "P2: ANSI leaked into piped table"
grep -qF '1-02:03:04' "$T/p-a" || fail "P2: plain table lost raw etime"
grep -qF '1d 2h' "$T/p-a" && fail "P2: humanized etime leaked into plain table"
pass "P2: audit-processes plain table stable"

# ---------- P3: devclean styled RSS severity, plain stable ----------
mkdir -p "$T/h"
OUT="$(HOME="$T/h" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'next-server' || fail "P3: canned orphan row missing entirely"
printf '%s\n' "$OUT" | grep -qF "${ESC}[31m2097152" || fail "P3: 2 GB rss cell not red"
printf '%s\n' "$OUT" | grep -qF "${ESC}[31m87.3" || fail "P3: 87.3 %cpu cell not red"
printf '%s\n' "$OUT" | grep -qF '3h 4m' || fail "P3: etime not humanized in styled table"
printf '%s\n' "$OUT" | grep -qF '03:04:05' && fail "P3: raw etime leaked into styled table"
HOME="$T/h" bash "$LIB/devclean.sh" > "$T/d-a" 2>/dev/null
HOME="$T/h" AFTERPARTY_STYLE=never bash "$LIB/devclean.sh" > "$T/d-b" 2>/dev/null
diff -q "$T/d-a" "$T/d-b" >/dev/null || fail "P3: devclean plain drift (auto vs never)"
grep -q "$ESC" "$T/d-a" && fail "P3: ANSI leaked into piped devclean table"
grep -q 'count: 1; rss: 2048.0 MB' "$T/d-a" || fail "P3: rss footer wrong or missing"
grep -qF '03:04:05' "$T/d-a" || fail "P3: plain table lost raw etime"
grep -qF '3h 4m' "$T/d-a" && fail "P3: humanized etime leaked into plain table"
pass "P3: devclean rss severity styled + plain stable"

# ---------- P4: devclean --disk styled meters, plain keeps streaming ----------
# Fixture HOME with one 2 MB Gradle cache; failing pnpm shim keeps the pnpm
# pass inert and fast; empty documents root skips the project scan.
DH="$T/diskhome"
mkdir -p "$DH/.gradle/caches"
dd if=/dev/zero of="$DH/.gradle/caches/blob" bs=1024 count=2048 2>/dev/null
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/pnpm"
chmod +x "$SHIM/pnpm"
HOME="$DH" bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" > "$T/k-a" 2>/dev/null
HOME="$DH" AFTERPARTY_STYLE=never bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" > "$T/k-b" 2>/dev/null
diff -q "$T/k-a" "$T/k-b" >/dev/null || fail "P4: plain disk drift (auto vs never)"
grep -qF 'would clean Gradle caches:' "$T/k-a" || fail "P4: plain disk row lost its streaming text"
grep -qF '█' "$T/k-a" && fail "P4: meters leaked into plain output"
OUT="$(HOME="$DH" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '█' || fail "P4: styled disk meters missing"
printf '%s\n' "$OUT" | grep -qF 'Gradle caches' || fail "P4: meter row label missing"
printf '%s\n' "$OUT" | grep -qF 'would clean Gradle caches:' && fail "P4: styled dry-run should buffer rows into meters, not stream them"
printf '%s\n' "$OUT" | grep -q 'Global disk reclaimable:' || fail "P4: global total line lost in styled mode"
printf '%s\n' "$OUT" | grep -qF '▸ 1 proc' && fail "P4: --disk unexpectedly included orphan process cleanup"
printf '%s\n' "$OUT" | grep -qF '2.0 MB reclaimable' || fail "P4: devclean damage card missing reclaimable segment"
pass "P4: devclean disk meters (styled dry-run) + plain streaming"

# ---------- P6: heartbeats announce slow scans, styled stderr only ----------
ERR="$(HOME="$DH" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" 2>&1 >/dev/null)"
printf '%s\n' "$ERR" | grep -qF '◐ sizing up' || fail "P6: heartbeat missing on styled stderr"
HOME="$DH" bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" 2>"$T/hb-e" >/dev/null
grep -qF '◐' "$T/hb-e" && fail "P6: heartbeat leaked into piped stderr"
pass "P6: heartbeats (styled stderr only)"

# ---------- P5: composite audit damage card carries measured segments ----------
BIN="$REPO/bin/afterparty"
FAKELED="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tverify UI\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$FAKELED"
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$FAKELED" "$BIN" audit 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '▸ 1 stray' || fail "P5: composite damage card missing stray segment"
pass "P5: composite audit segment line"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
