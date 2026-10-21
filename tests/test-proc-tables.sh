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
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
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
printf '%s\n' "$OUT" | grep -q "${ESC}\[31m *87[.]3" || fail "P1: 87.3 %cpu cell not red"
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
python3 - "$T/p-a" <<'PYTEST' || fail 'P2: legacy process row contract'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
assert '  PID     PPID    PGID    %CPU   ELAPSED    COMMAND' in lines
assert '  41234   1       41234   87.3   1-02:03:04 node /repo/node_modules/.bin/vitest --watch ' in lines
PYTEST
pass "P2: audit-processes plain table stable"

# ---------- P3: devclean styled RSS severity, plain stable ----------
mkdir -p "$T/h"
OUT="$(HOME="$T/h" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'next-server' || fail "P3: canned orphan row missing entirely"
printf '%s\n' "$OUT" | grep -q "${ESC}\[31m *2097152" || fail "P3: 2 GB rss cell not red"
printf '%s\n' "$OUT" | grep -q "${ESC}\[31m *87[.]3" || fail "P3: 87.3 %cpu cell not red"
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
printf '%s\n' "$ERR" | grep -qF '◐ Measure disk use' || fail "P6: heartbeat missing on styled stderr"
HOME="$DH" bash "$LIB/devclean.sh" --disk --no-repo-artifacts --documents-root "$DH/docs" 2>"$T/hb-e" >/dev/null
grep -qF '◐' "$T/hb-e" && fail "P6: heartbeat leaked into piped stderr"
pass "P6: heartbeats (styled stderr only)"

# ---------- P5: composite audit damage card carries measured segments ----------
BIN="$REPO/bin/afterparty"
FAKELED="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tverify UI\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$FAKELED"
OUT="$(COLUMNS=60 AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$FAKELED" "$BIN" audit 2>/dev/null)"
printf '%s\n' "$OUT" | grep -qF '▸ 1 process candidate' || fail "P5: composite damage card missing stray segment"
printf '%s\n' "$OUT" | grep -qF 'afterparty audit --kill tests,dev,browser --pgid <reviewed-pgid>' || fail 'P5: composite next step has hard line breaks'
pass "P5: composite audit segment line"

# ---------- P7: styled widths preserve the entire command and its Unicode ----------
# The old table silently stopped after nine command words. The distinctive tail
# is after that boundary, and both similar Unicode paths must remain visible.
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pid,ppid,pgid,%cpu,etime,command*)
    printf '41234 1 41234 87.3 1-02:03:04 node /repo/node_modules/.bin/vitest --watch one two three four five six /workspace/日本語-project-A/dist /workspace/日本語-project-B/dist final-argument\n' ;;
  *-o\ pgid=*-p*) printf '99999\n' ;;
  *-Ao\ pgid=*) printf '99999\n' ;;
  *-Ao\ pid=*) exit 0 ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *LISTEN*) printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 41234 u 26u IPv6 0x1 0t0 TCP [::1]:3000 (LISTEN)\n' ;;
  *) exit 1 ;;
esac
LS
for cols in 60 80 120; do
  COLUMNS="$cols" AFTERPARTY_STYLE=always bash "$LIB/audit-processes.sh" > "$T/width-$cols" 2>/dev/null
  python3 - "$T/width-$cols" "$cols" <<'PYTEST' || fail "P7: layout at $cols columns"
import re, sys, unicodedata
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding='utf-8')
plain = re.sub(r'\x1b\[[0-9;]*m', '', text)
assert 'final-argument' in plain, 'command tail was truncated'
joined = ''.join(plain.split())
assert '/workspace/日本語-project-A/dist' in joined
assert '/workspace/日本語-project-B/dist' in joined
assert 'COMMAND / LISTEN ADDRESS' in plain
assert '[::1]:3000' in joined, 'listener address was lost'
assert 'afterparty audit --kill tests --pgid <reviewed-pgids>' in plain, 'next step gained line breaks'
for line in plain.splitlines():
    if 'Stop reviewed groups: afterparty audit' in line:
        continue  # Keep copyable shell input on one logical line.
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in line)
    assert width < int(sys.argv[2]), (width, line)
if int(sys.argv[2]) < 80:
    assert 'PID 41234' in plain and 'CPU 87.3%' in plain, plain
else:
    assert 'ELAPSED' in plain and '41234' in plain, plain
PYTEST
done
# JSON is not a styled table, even under a forced palette and a narrow width.
COLUMNS=60 AFTERPARTY_STYLE=always bash "$LIB/audit-processes.sh" --json > "$T/narrow-json" 2>/dev/null
python3 - "$T/narrow-json" <<'PYTEST' || fail 'P7: styled narrow JSON'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
assert b'\x1b' not in raw
rows = [json.loads(line) for line in raw.splitlines()]
assert [r for r in rows if r['section'] == 'processes'] == [{
    'schema_version': 1, 'section': 'processes', 'category': 'tests', 'pid': 41234,
    'ppid': 1, 'pgid': 41234, 'cpu': '87.3', 'elapsed': '1-02:03:04',
    'command': 'node /repo/node_modules/.bin/vitest --watch one two three four five six /workspace/日本語-project-A/dist /workspace/日本語-project-B/dist final-argument'}]
PYTEST
AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" > "$T/plain-final" 2>/dev/null
NO_COLOR=1 AFTERPARTY_STYLE=auto bash "$LIB/audit-processes.sh" > "$T/no-color" 2>/dev/null
TERM=dumb AFTERPARTY_STYLE=auto bash "$LIB/audit-processes.sh" > "$T/dumb" 2>/dev/null
diff -q "$T/plain-final" "$T/no-color" >/dev/null || fail 'P7: NO_COLOR changed plain bytes'
diff -q "$T/plain-final" "$T/dumb" >/dev/null || fail 'P7: TERM=dumb changed plain bytes'
pass 'P7: 60/80/120-column styled layouts, full Unicode identities, plain/JSON contracts'

# ---------- P8: ledger detail keeps fields beyond the former display limit ----------
LED_ROOT="$T/日本語-workspace with  two spaces/another-long-component"
LED_COMMAND='node server.js --project 日本語 --one 1 --two 2 --three 3 --four 4 --five 5 --six 6 ledger-command-tail'
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tpurpose with  two spaces\t%s\n' \
  "$LED_ROOT" "$LED_ROOT" "$LED_COMMAND" > "$FAKELED"
for cols in 60 80 120; do
  COLUMNS="$cols" AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$FAKELED" "$BIN" list --all > "$T/ledger-$cols" 2>/dev/null
  python3 - "$T/ledger-$cols" "$cols" "$LED_ROOT" "$LED_COMMAND" <<'PYTEST' || fail "P8: ledger at $cols columns"
import re, sys, unicodedata
from pathlib import Path
plain = re.sub(r'\x1b\[[0-9;]*m', '', Path(sys.argv[1]).read_text(encoding='utf-8'))
assert 'STATUS' in plain and '999999' in plain, 'ledger row missing'
for label, expected in [('Purpose', 'purpose with  two spaces'), ('Command', sys.argv[4]), ('Workspace', sys.argv[3])]:
    lines = plain.split('    ' + label + ': ', 1)[1].splitlines()
    actual = lines[0]
    for line in lines[1:]:
        if re.match(r'    (Purpose|Command|Workspace): ', line):
            break
        assert line.startswith('    '), line
        actual += line[4:]
    assert actual == expected, (actual, expected)
for line in plain.splitlines():
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in line)
    assert width < int(sys.argv[2]), (width, line)
PYTEST
done
AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$FAKELED" "$BIN" list --all --json > "$T/ledger-json" 2>/dev/null
python3 - "$T/ledger-json" "$LED_COMMAND" "$LED_ROOT" <<'PYTEST' || fail 'P8: ledger JSON'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
assert b'\x1b' not in raw
rows = [json.loads(line) for line in raw.splitlines()]
assert rows == [{'schema_version': 1, 'section': 'ledger', 'status': 'unknown',
                 'pid': 999999, 'pgid': 999999, 'kind': 'dev', 'port': 3000, 'cpu': None,
                 'purpose': 'purpose with  two spaces', 'command': sys.argv[2],
                 'root': sys.argv[3], 'ts': '2026-07-14T00:00:00Z'}]
PYTEST
pass 'P8: ledger preserves complete command, purpose and workspace fields'

# ---------- P9: read-only artifact inventory and its quoted next step ----------
ART_ROOT="$T/artifact 日本語  project"
ART_REL='packages/日本語-long-project-name-with-two  spaces/dist'
mkdir -p "$ART_ROOT/$ART_REL"
git -C "$ART_ROOT" init -q
printf 'dist/\n' > "$ART_ROOT/.gitignore"
dd if=/dev/zero of="$ART_ROOT/$ART_REL/fixture" bs=1024 count=1024 2>/dev/null
for cols in 60 80 120; do
  COLUMNS="$cols" AFTERPARTY_STYLE=always "$BIN" artifacts --root "$ART_ROOT" > "$T/artifact-$cols" 2>/dev/null
  python3 - "$T/artifact-$cols" "$cols" "$ART_ROOT" "$ART_REL" "$BASH" <<'PYTEST' || fail "P9: artifacts at $cols columns"
import os, re, subprocess, sys, unicodedata
from pathlib import Path
plain = re.sub(r'\x1b\[[0-9;]*m', '', Path(sys.argv[1]).read_text(encoding='utf-8'))
assert 'Reclaimable total:' in plain and 'Build outputs' in plain
assert sys.argv[4] in re.sub(r'\n    ', '', plain), 'artifact path lost significant text'
commands = [line.split('review: ', 1)[1] for line in plain.splitlines() if 'review: afterparty plan' in line]
assert len(commands) == 1, 'copyable next step missing'
result = subprocess.run([sys.argv[5], '-c', 'afterparty() { printf "%s\\0" "$@"; }; ' + commands[0]], capture_output=True)
assert result.returncode == 0, result.stderr
args = result.stdout.decode().split('\0')
assert args[:3] == ['plan', '--artifacts-only', '--root'], args
assert os.path.realpath(args[3]) == os.path.realpath(sys.argv[3]), args
for line in plain.splitlines():
    if 'review: afterparty plan' in line:
        continue  # Shell commands retain one logical line so copying is faithful.
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in line)
    assert width < int(sys.argv[2]), (width, line)
PYTEST
done
pass 'P9: artifact identities and copyable next step at 60/80/120 columns'

printf 'conflict fixture\n' > "$ART_ROOT/fixture.orig"
COLUMNS=60 AFTERPARTY_STYLE=always "$BIN" git --root "$ART_ROOT" > "$T/git-next-step" 2>/dev/null
python3 - "$T/git-next-step" "$ART_ROOT" "$BASH" <<'PYTEST' || fail 'P10: Git next-step shell quoting'
import os, re, subprocess, sys
from pathlib import Path
plain = re.sub(r'\x1b\[[0-9;]*m', '', Path(sys.argv[1]).read_text(encoding='utf-8'))
assert 'fixture.orig' in plain, 'fixture did not enter Git findings'
commands = [line.split('review: ', 1)[1] for line in plain.splitlines() if 'review: afterparty plan' in line]
assert len(commands) == 1, 'next step missing'
result = subprocess.run([sys.argv[3], '-c', 'afterparty() { printf "%s\\0" "$@"; }; ' + commands[0]], capture_output=True)
assert result.returncode == 0, result.stderr
args = result.stdout.decode().split('\0')
assert args[:2] == ['plan', '--root'], args
assert os.path.realpath(args[2]) == os.path.realpath(sys.argv[2]), args
PYTEST
pass 'P10: Git next step preserves spaced Unicode scope'

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
