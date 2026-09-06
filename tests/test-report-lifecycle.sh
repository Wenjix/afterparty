#!/usr/bin/env bash
# Disposable installed-bundle tests: no real process scans or cleanup.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
mkdir -p "$T/install space" "$T/w" "$T/other" "$T/shim" "$T/home"
cp -R "$REPO/skills/afterparty" "$T/install space/afterparty"
LIB="$T/install space/afterparty/lib"; BIN="$T/install space/afterparty/bin/afterparty"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never
export AFTERPARTY_TEST_SCANS="$T/scans"
unset AFTERPARTY_JOURNAL AFTERPARTY_RETENTION_DAYS CLAUDE_SESSION_ID AFTERPARTY_SESSION_ID
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS+1)); }
pass() { echo "ok: $*"; }
for child in process-ledger audit-processes audit-git; do
  cat > "$LIB/$child.sh" <<'CHILD'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$AFTERPARTY_TEST_SCANS"
printf '=== Fixture section ===\nnode --token "private multiword" https://alice:password@example.test Authorization: Bearer session-secret\n'
cat <<'CREDENTIALS'
node --config '{"token":"json-secret", "client_secret":"json-client"}' --password="quoted\" tail-secret"
CREDENTIALS
case "$0:${AFTERPARTY_TEST_FAIL:-}" in *audit-git.sh:git) echo 'git inspection failed' >&2; exit 1 ;; esac
CHILD
  chmod +x "$LIB/$child.sh"
done
cd "$T/w" || exit 1
_b=$FAILS
AFTERPARTY_SESSION_ID=session-a bash "$BIN" audit --report > "$T/complete" 2> "$T/err" || fail 'L1: complete fixture failed'
REPORT="$(bash "$BIN" report-path)"
grep -q 'Status: complete. Session: session-a' "$REPORT" || fail 'L1: missing complete session identity'
AFTERPARTY_SESSION_ID=session-b AFTERPARTY_TEST_FAIL=git bash "$BIN" audit --report > "$T/partial" 2> "$T/err"; rc=$?
[ "$rc" -ne 0 ] || fail 'L1: failed report returned success'
grep -q 'Status: incomplete. Session: session-b. Failed sections: git' "$REPORT" || fail 'L1: partial status was not persisted'
grep -q 'git inspection failed' "$REPORT" || fail 'L1: failed section diagnostic disappeared'
bash "$BIN" report --show > "$T/show"; rc=$?
[ "$rc" -ne 0 ] || fail 'L1: incomplete report --show returned success'
[ "$(find "${REPORT%/*}/sessions" -name 'session-*.md' | wc -l | tr -d ' ')" = 2 ] || fail 'L1: concurrent session identity was overwritten'
grep -Eq 'private|multiword|alice:password|session-secret|json-secret|json-client|tail-secret' "$REPORT" && fail 'L1: common command credentials persisted'
grep -q '\[REDACTED\]' "$REPORT" || fail 'L1: redaction path was not entered'
[ "$FAILS" -eq "$_b" ] && pass 'L1: reports preserve failures, redaction and separate session identities'

_b=$FAILS
AFTERPARTY_SESSION_ID=concurrent-one bash "$BIN" audit --report > "$T/concurrent-one" 2> "$T/concurrent-one.err" &
P1=$!
AFTERPARTY_SESSION_ID=concurrent-two bash "$BIN" audit --report > "$T/concurrent-two" 2> "$T/concurrent-two.err" &
P2=$!
wait "$P1" || fail 'L6: first concurrent report failed'
wait "$P2" || fail 'L6: second concurrent report failed'
for session in concurrent-one concurrent-two; do
  grep -q "Session: $session" "$T/$session" || fail "L6: concurrent output described another session"
  find "${REPORT%/*}/sessions" -name "$session-*.md" | grep -q . || fail "L6: concurrent archive missing"
done
[ "$FAILS" -eq "$_b" ] && pass 'L6: concurrent writers retain their own report and output'
# Restore a partial latest snapshot for the reminder assertions below.
AFTERPARTY_SESSION_ID=session-b AFTERPARTY_TEST_FAIL=git bash "$BIN" audit --report >/dev/null 2>/dev/null

_b=$FAILS
BEFORE="$(wc -l < "$T/scans")"
bash "$BIN" report --remind > "$T/remind"
grep -q 'incomplete.*minutes old.*session session-b' "$T/remind" || fail 'L2: reminder lost age/status/session'
[ "$(wc -l < "$T/scans")" = "$BEFORE" ] || fail 'L2: reminder ran an audit'
printf '{"session_id":"hook-session"}\n' | bash "$BIN" report --session-end > "$T/hook"
bash "$BIN" report --remind > "$T/remind"
grep -q 'hook-session.*No exit-time audit was run' "$T/remind" || fail 'L2: marker failed to distinguish session end from audit'
[ "$(wc -l < "$T/scans")" = "$BEFORE" ] || fail 'L2: SessionEnd ran an audit'
grep -q 'Session: session-b' "$REPORT" || fail 'L2: exit marker overwrote the explicit audit'
[ "$FAILS" -eq "$_b" ] && pass 'L2: lifecycle only writes a marker and reminds with explicit report freshness'

_b=$FAILS
JLIB="$REPO/skills/afterparty/lib"
(cd "$T/w" && bash -c '. "$1/journal.sh"; journal_action fixture.one target succeeded "--password secret"' _ "$JLIB") || fail 'L3: fixture receipt failed'
(cd "$T/other" && bash -c '. "$1/journal.sh"; journal_action fixture.two target succeeded' _ "$JLIB") || fail 'L3: other receipt failed'
bash "$REPO/bin/afterparty" actions > "$T/actions"
grep -q 'fixture.one' "$T/actions" || fail 'L3: current workspace receipt missing'
grep -q 'fixture.two' "$T/actions" && fail 'L3: another workspace leaked into default history'
bash "$REPO/bin/afterparty" actions --all > "$T/all"
grep -q 'fixture.two' "$T/all" || fail 'L3: --all failed to widen history'
bash "$REPO/bin/afterparty" actions --since 9999-01-01 > "$T/since"
[ ! -s "$T/since" ] || fail 'L3: --since ignored'
grep -q '"detail":"--password \[REDACTED\]"' "$T/actions" || fail 'L3: journal detail not redacted'
mkdir -p "$T/fail-cache/agent-processes/actions.jsonl"
XDG_CACHE_HOME="$T/fail-cache" bash -c '. "$1/journal.sh"; journal_action fixture.fail target succeeded' _ "$JLIB" 2> "$T/journal.err"; rc=$?
[ "$rc" -ne 0 ] || fail 'L3: append failure returned success'
grep -q 'could not append' "$T/journal.err" || fail 'L3: append failure path not reached'
[ "$FAILS" -eq "$_b" ] && pass 'L3: scoped history, date filters, redaction and receipt failures are observable'

_b=$FAILS
DETAIL=$(cat <<'CREDENTIALS'
node --config '{"token":"journal-json-secret"}' --password="quoted\" journal-tail-secret"
CREDENTIALS
)
bash -c '. "$1/journal.sh"; journal_action fixture.credentials target succeeded "$2"' _ "$JLIB" "$DETAIL" || fail 'L7: credential receipt failed'
bash "$REPO/bin/afterparty" actions > "$T/credential-actions"
grep -q 'fixture.credentials' "$T/credential-actions" || fail 'L7: credential receipt not persisted'
grep -Eq 'journal-json-secret|journal-tail-secret' "$T/credential-actions" && fail 'L7: structured/escaped credentials persisted'
[ "$FAILS" -eq "$_b" ] && pass 'L7: structured and escaped credentials are redacted in persisted receipts'

_b=$FAILS
ACTIONS="$(bash "$REPO/bin/afterparty" actions-path)"
printf '{"schema_version":1,"timestamp":"2000-01-01T00:00:00Z","operation":"old-fixture"}\n' >> "$ACTIONS"
bash -c '. "$1/journal.sh"; journal_action fixture.keep target succeeded' _ "$JLIB"
grep -q old-fixture "$ACTIONS" || fail 'L4: default retention erased history'
AFTERPARTY_RETENTION_DAYS=30 bash -c '. "$1/journal.sh"; journal_action fixture.retain target succeeded' _ "$JLIB" || fail 'L4: opt-in retention failed'
grep -q old-fixture "$ACTIONS" && fail 'L4: requested retention kept expired fixture'
grep -q fixture.retain "$ACTIONS" || fail 'L4: retention lost new receipt'
NUMBER="$(bash -c '. "$1/json.sh"; json_kvn port 03000' _ "$JLIB")"
[ "$NUMBER" = '"port":3000' ] || fail 'L4: numeric JSON leading zero not normalized'
[ "$FAILS" -eq "$_b" ] && pass 'L4: retention is opt-in and numeric JSON is canonical'

# Invoke the installed skill from another cwd after the host literal macro
# substitution, and execute the slash injection through its actual Bash body.
_b=$FAILS
cat > "$T/shim/ps" <<'PS'
#!/usr/bin/env bash
printf 'PID PGID %%CPU COMMAND\n4001 4001 0.0 node fixture.js\n'
PS
cat > "$T/shim/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in *-d\ cwd*) printf 'p4001\nfcwd\nn%s\n' "$AFTERPARTY_FIXTURE_CWD" ;; *) exit 1 ;; esac
LS
chmod +x "$T/shim/ps" "$T/shim/lsof"
PY="$(command -v python3 || command -v python)"
PATH="$T/shim:$PATH" AFTERPARTY_FIXTURE_CWD="$T/w" "$PY" - "$REPO" "$T/install space/afterparty" "$T" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys
repo, bundle, temp = map(pathlib.Path, sys.argv[1:])
skill=(bundle/'SKILL.md').read_text()
assert len(skill.split()) < 250
assert '$CLAUDE_SKILL_DIR' not in skill
command=skill.split('```bash')[1].strip().splitlines()[0].replace('${CLAUDE_SKILL_DIR}', str(bundle))
r=subprocess.run(['bash','-c',command],capture_output=True,text=True)
assert r.returncode == 0, r.stderr
assert 'process' in r.stdout, r.stdout
source=(repo/'commands/afterparty.md').read_text()
command=re.search(r'!`(.*?)`',source,re.S).group(1)
plugin=temp/'plugin'; (plugin/'skills').mkdir(parents=True)
shutil.copytree(bundle, plugin/'skills/afterparty')
command=command.replace('${CLAUDE_PLUGIN_ROOT}',str(plugin))
env=os.environ.copy();env['AFTERPARTY_TEST_FAIL']='git'
r=subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True)
assert r.returncode == 0 and 'AFTERPARTY AUDIT INCOMPLETE' in r.stdout, (r.returncode,r.stdout,r.stderr)
hook=json.loads((repo/'hooks/hooks.json').read_text())['hooks']['SessionEnd'][0]['hooks'][0]
assert not hook.get('async') and hook['timeout'] <= 1
args=[a.replace('${CLAUDE_PLUGIN_ROOT}', str(plugin)) for a in hook['args']]
r=subprocess.run([hook['command'],*args],input='{"session_id":"installed-hook"}',capture_output=True,text=True)
assert r.returncode == 0,r.stderr
PY
[ "$?" -eq 0 ] || fail 'L5: installed skill/command/hook invocation failed'
[ "$FAILS" -eq "$_b" ] && pass 'L5: installed bundle, failure-preserving slash command and hook execute'
exit $((FAILS > 0))
