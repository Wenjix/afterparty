#!/usr/bin/env bash
# Cross-provider activity must survive the report -> approval -> apply flow.
# Copied consumers, intercepted machine tools/signals, and disposable Git/state
# keep this suite safe on developer machines as well as Git Bash CI.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: Codex integration fixtures require Python 3'; exit 0; }
T="$(mktemp -d)" || exit 1
T="$(cd "$T" && pwd -P)"
# Native Windows Python resolves MSYS mounts to drive paths; the synthetic
# process cwd must use that same physical spelling for activity attribution.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) T="$(cygpath -u "$(cygpath -am "$T")")" || exit 1 ;;
esac
trap 'cd /; rm -rf "$T"' EXIT
LIB="$T/lib"; SHIM="$T/shim"; WORK="$T/repo space"
cp -R "$REPO/skills/afterparty/lib" "$LIB"
mkdir -p "$SHIM" "$WORK" "$T/home" "$T/claude/project" "$T/codex/sessions/2000/01/01" "$T/codex/archived_sessions"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_STATE_HOME="$T/state"
export CODEX_HOME="$T/unused-codex" AFTERPARTY_CODEX_ROOT="$T/codex" AFTERPARTY_TRANSCRIPT_ROOT="$T/claude"
export AFTERPARTY_STYLE=never AFTERPARTY_JOURNAL=1 AFTERPARTY_IDLE_HOURS=4 AFTERPARTY_BUSY_CPU=20
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null PYTHONUTF8=1 PYTHONIOENCODING=utf-8
export FIXTURE_WORK="$WORK" FIXTURE_DEAD="$T/dead" FIXTURE_DELEGATED="$T/delegated" FIXTURE_SIGNALS="$T/signals" FIXTURE_TOOLS="$T/tools"
export FIXTURE_UID="$(id -u)" BASH_ENV="$T/bash-env"
unset AGENT_PROCESS_LEDGER AFTERPARTY_TALLY AFTERPARTY_RETENTION_DAYS
: > "$FIXTURE_DELEGATED"; : > "$FIXTURE_SIGNALS"; : > "$FIXTURE_TOOLS"
cat > "$BASH_ENV" <<'ENV'
kill() {
  case "${1:-}" in
    -TERM|-KILL|-9) printf '%s\n' "$*" >> "$FIXTURE_SIGNALS"; : > "$FIXTURE_DEAD" ;;
    -0) [ ! -e "$FIXTURE_DEAD" ] ;;
    *) echo 'unexpected fixture signal request' >&2; return 98 ;;
  esac
}
ENV
cat > "$SHIM/audit-processes.sh" <<'AUDIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_DELEGATED"
: > "$FIXTURE_DEAD"
AUDIT
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
alive() { [ ! -e "$FIXTURE_DEAD" ]; }
case "$*" in
  *pid=,pgid=,lstart=,command=*)
    printf '1 1 Tue Aug 18 09:00:00 2026 fixture-init\n'
    alive && printf '7001 7001 Tue Aug 18 09:00:00 2026 next dev\n' ;;
  *pgid=,lstart=,command=*) alive && printf '7001 Tue Aug 18 09:00:00 2026 next dev\n' ;;
  *pgid=,command=*) alive && printf '7001 next dev\n' ;;
  *pid,pgid,%cpu*) printf 'PID PGID %%CPU COMMAND\n'; alive && printf '7001 7001 0.0 next dev\n' ;;
  *ppid=,lstart=,command=*) alive && printf '1 Tue Aug 18 09:00:00 2026 next dev\n' ;;
  *uid=,etime=,tty=,%cpu=*) alive && printf '%s 02:00:00 ? 0.0\n' "$FIXTURE_UID" ;;
  *pid=,ppid=,pgid=,rss=,%cpu=,etime=,command=*) alive && printf '7001 1 7001 65536 0.0 02:00:00 next dev\n' ;;
  *rss=*) alive && printf '65536\n' ;;
  '-Ao pid='|'-eo pid=') printf '1\n'; alive && printf '7001\n' ;;
  '-p 7001') alive; exit $? ;;
  *) echo "unsupported fixture ps: $*" >&2; exit 98 ;;
esac
exit 0
PS
cat > "$SHIM/lsof" <<'LSOF'
#!/usr/bin/env bash
case "$*" in *-d\ cwd*) printf 'p7001\nfcwd\nn%s\n' "$FIXTURE_WORK" ;; *) exit 1 ;; esac
LSOF
cat > "$SHIM/pgrep" <<'PGREP'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >> "$FIXTURE_TOOLS"
[ ! -e "$FIXTURE_DEAD" ] || exit 1
printf '7001\n'
PGREP
for tool in kill launchctl pnpm; do
  cat > "$SHIM/$tool" <<'TOOL'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$FIXTURE_TOOLS"
exit 98
TOOL
done
chmod +x "$SHIM"/*
cp "$SHIM/audit-processes.sh" "$LIB/audit-processes.sh"
export PATH="$SHIM:${BASH%/*}:$PATH"
for tool in audit-processes.sh ps lsof pgrep launchctl pnpm; do
  [ "$(command -v "$tool")" = "$SHIM/$tool" ] || { echo "fixture interceptor missing: $tool" >&2; exit 1; }
done
bash -c '[ "$(type -t kill)" = function ]' || { echo 'fixture kill interceptor missing' >&2; exit 1; }
git init -q "$WORK" || exit 1
printf 'fixture\n' > "$WORK/README"
git -C "$WORK" add README || exit 1
git -C "$WORK" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture || exit 1
cd "$WORK" || exit 1
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
stale() { touch -t 202001010000 "$1"; }
reset_process() { rm -f "$FIXTURE_DEAD"; : > "$FIXTURE_DELEGATED"; : > "$FIXTURE_SIGNALS"; }
plan() { bash "$LIB/plan.sh" --root "$WORK" > "$T/plan.out" 2>&1; }
offered() { grep -qE '^- \[ \] eligible[[:space:]]+pgid 7001([[:space:]]|$)' "$T/plan.out"; }
approve() { sed 's/^- \[ \] eligible  pgid 7001 /- [x] eligible  pgid 7001 /' "$T/plan.out" > "$T/approved.md"; }
apply() { bash "$LIB/apply.sh" "$T/approved.md" > "$T/apply.out" 2>&1; }
delegated() { grep -q -- '--kill dev --pgid 7001 --expect 7001:' "$FIXTURE_DELEGATED"; }
show_failure() { cat "$1" >&2; }

# The positive control must reach the real consumers and the fake delegate.
printf '{"cwd":"%s"}\n' "$WORK" > "$T/claude/project/session.jsonl"
stale "$T/claude/project/session.jsonl"
_before=$FAILS
plan || fail 'CI1: stale Claude baseline plan failed'
offered || { fail 'CI1: baseline never offered PGID 7001'; show_failure "$T/plan.out"; }
approve
apply || { fail 'CI1: approved baseline did not complete'; show_failure "$T/apply.out"; }
delegated || fail 'CI1: approved baseline did not enter intercepted audit delegation'
grep -q '1 applied' "$T/apply.out" || fail 'CI1: baseline did not confirm the fixture process absent'
[ "$FAILS" -ne "$_before" ] || pass 'CI1: stale activity admits and delegates only the approved fixture group'
reset_process

# A resumed rollout can live in an old date bucket and change working dirs.
ROLLOUT="$T/codex/sessions/2000/01/01/rollout.jsonl"
printf '{"type":"session_meta","payload":{"cwd":"%s/previous"}}\n{"type":"turn_context","payload":{"cwd":"%s"}}\n' "$T" "$WORK" > "$ROLLOUT"
_before=$FAILS
bash "$LIB/glance.sh" --json > "$T/glance.jsonl" 2> "$T/glance.err"
python3 - "$T/glance.jsonl" <<'PY' || fail 'CI2: glance lost fresh Codex activity or provider provenance'
import json, sys, time
rows=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8') if line.strip()]
workspaces=[row for row in rows if row.get('section')=='workspace']
assert len(workspaces)==1, rows
row=workspaces[0]
assert row['last_touched'] >= time.time()-60, row
assert row['activity_source']=='claude-transcript,codex-transcript', row
PY
bash "$LIB/glance.sh" > "$T/glance.out" 2>&1
grep -q SOURCE "$T/glance.out" && grep -q 'Claude+Codex' "$T/glance.out" || fail 'CI2: plain glance omitted activity provenance'
plan
grep -qE '^- \[⊘\] in-use[[:space:]]+pgid 7001([[:space:]]|$)' "$T/plan.out" || { fail 'CI2: fresh Codex activity did not withhold PGID 7001'; show_failure "$T/plan.out"; }
apply; rc=$?
[ "$rc" -ne 0 ] && grep -qE 'pgid 7001 .*in-use' "$T/apply.out" || { fail 'CI2: old approval ignored a resumed Codex rollout'; show_failure "$T/apply.out"; }
[ ! -s "$FIXTURE_DELEGATED" ] || fail 'CI2: fresh activity reached audit delegation'
[ "$FAILS" -ne "$_before" ] || pass 'CI2: fresh Codex activity overrides stale Claude across glance, plan and apply'

# An unreadable provider must not fall back to otherwise valid stale evidence.
reset_process
printf '{broken\n' >> "$ROLLOUT"
_before=$FAILS
bash "$LIB/glance.sh" --json > "$T/glance.jsonl" 2> "$T/glance.err"
python3 - "$T/glance.jsonl" <<'PY' || fail 'CI3: corrupt Codex data did not make rendered activity unknown'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8') if line.strip()]
assert any(row.get('name')=='transcripts' and row.get('status')=='unavailable' for row in rows), rows
row=next(row for row in rows if row.get('section')=='workspace')
assert row['last_touched'] is None and row['activity_source'] is None, row
PY
plan
grep -qE '^- \[⊘\].*(unknown|unavailable).*pgid 7001([[:space:]]|$)' "$T/plan.out" || { fail 'CI3: corrupt provider did not withhold named plan group'; show_failure "$T/plan.out"; }
apply; rc=$?
[ "$rc" -ne 0 ] && grep -qE 'pgid 7001 .*(activity-unavailable|scan-incomplete|unknown)' "$T/apply.out" || { fail 'CI3: corrupt provider did not explicitly refuse the approved group'; show_failure "$T/apply.out"; }
[ ! -s "$FIXTURE_DELEGATED" ] || fail 'CI3: corrupt Codex data fell back to stale Claude and delegated'
[ "$FAILS" -ne "$_before" ] || pass 'CI3: malformed Codex activity cannot authorize cleanup via stale Claude fallback'

# Codex-only archived sessions are sufficient evidence when old and complete.
rm -f "$ROLLOUT" "$T/claude/project/session.jsonl"
ARCHIVE="$T/codex/archived_sessions/old.jsonl"
printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$WORK" > "$ARCHIVE"
stale "$ARCHIVE"
_before=$FAILS
reset_process
plan
offered || { fail 'CI4: archived Codex-only activity never admitted PGID 7001'; show_failure "$T/plan.out"; }
approve
apply || { fail 'CI4: Codex-only baseline apply failed'; show_failure "$T/apply.out"; }
delegated || fail 'CI4: Codex-only baseline never entered intercepted delegation'
[ "$FAILS" -ne "$_before" ] || pass 'CI4: stale archived Codex sessions support an actionable approval'

# The PID-based orphan path consumes the same evidence and refreshes it.
_before=$FAILS
reset_process
bash "$LIB/devclean.sh" --orphans > "$T/orphan.out" 2>&1
TARGET="$(sed -n 's/.*target: \([^ ]*\).*idle PID 7001.*/\1/p' "$T/orphan.out")"
[ -n "$TARGET" ] || { fail 'CI5: Codex-only orphan baseline never became selectable'; show_failure "$T/orphan.out"; }
if [ -n "$TARGET" ]; then
  bash "$LIB/devclean.sh" --orphans --apply --target "$TARGET" > "$T/orphan-apply.out" 2>&1
  [ "$?" -eq 0 ] && grep -q -- '-TERM 7001' "$FIXTURE_SIGNALS" || { fail 'CI5: reviewed stale orphan never entered intercepted TERM'; show_failure "$T/orphan-apply.out"; }
  reset_process
  touch "$ARCHIVE"
  bash "$LIB/devclean.sh" --orphans --apply --target "$TARGET" > "$T/orphan-apply.out" 2>&1
  [ "$?" -ne 0 ] && grep -qiE 'pid 7001.*workspace in-use' "$T/orphan-apply.out" || { fail 'CI5: resumed Codex orphan was not visibly withheld'; show_failure "$T/orphan-apply.out"; }
  [ ! -s "$FIXTURE_SIGNALS" ] || fail 'CI5: fresh Codex orphan received a signal'
fi
[ "$FAILS" -ne "$_before" ] || pass 'CI5: Codex activity also gates the individually approved orphan PID'

# New activity at the repository root must protect a stale indexed child;
# longest-prefix attribution cannot choose older evidence and permit cleanup.
_before=$FAILS
reset_process
mkdir -p "$WORK/subproject" "$T/claude/child"
printf '{"cwd":"%s/subproject"}\n' "$WORK" > "$T/claude/child/session.jsonl"
stale "$T/claude/child/session.jsonl"
touch "$ARCHIVE"
export FIXTURE_WORK="$WORK/subproject"
plan
grep -qE '^- \[⊘\] in-use[[:space:]]+pgid 7001([[:space:]]|$)' "$T/plan.out" || { fail 'CI6: recent Codex ancestor did not protect stale indexed child'; show_failure "$T/plan.out"; }
apply; rc=$?
[ "$rc" -ne 0 ] && grep -qE 'pgid 7001 .*in-use' "$T/apply.out" || { fail 'CI6: stale child inherited approval despite fresh Codex ancestor'; show_failure "$T/apply.out"; }
[ ! -s "$FIXTURE_DELEGATED" ] || fail 'CI6: fresh ancestor reached audit delegation'
[ "$FAILS" -ne "$_before" ] || pass 'CI6: fresh ancestor activity protects a stale indexed descendant'
grep -qE '^(launchctl|pnpm|kill) ' "$FIXTURE_TOOLS" && fail 'unexpected mutation tool was reached'
exit $((FAILS > 0))
