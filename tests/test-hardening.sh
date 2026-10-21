#!/usr/bin/env bash
# Dogfood hardening contracts: plugin lifecycle, capability reporting,
# mutation safety, shared state, and standalone packaging.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tests/devclean-fixtures.sh"
PY="$(command -v python3 || command -v python)"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
trap 'cd /; rm -rf "$T"' EXIT

# Mutation tests use synthetic process identifiers. Override Bash's kill
# builtin in those child shells so a coincidentally live host PID/PGID can
# never receive a test signal; KILL_CALLS also lets tests assert escalation.
cat > "$T/noop-signals.sh" <<'SH'
kill() {
  case "${1:-}" in
    -TERM|-KILL)
      printf '%s %s\n' "${1:-}" "${2:-}" >> "$KILL_CALLS"
      return 0
      ;;
    *) builtin kill "$@" ;;
  esac
}
SH

# ---------- H1: SessionEnd marker is bounded and shell-tokenization-free ----------
if "$PY" - "$REPO/hooks/hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)

hook = manifest["hooks"]["SessionEnd"][0]["hooks"][0]
assert hook["type"] == "command"
assert hook["command"] == "bash"
assert hook["args"] == [
    "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty",
    "report",
    "--session-end",
]
assert not hook.get("async", False)
assert hook["timeout"] == 1
PY
then
  pass "H1: SessionEnd report uses an bounded synchronous exec-form hook"
else
  fail "H1: SessionEnd hook is not bounded synchronous exec form"
fi

# ---------- H2: fallback reports are namespaced by workspace ----------
mkdir -p "$T/home" "$T/cache" "$T/repo-one" "$T/repo-two"
git -C "$T/repo-one" init -q
git -C "$T/repo-two" init -q
R1="$(cd "$T/repo-one" && HOME="$T/home" XDG_CACHE_HOME="$T/cache" bash "$REPO/bin/afterparty" report-path)"
RC1=$?
R2="$(cd "$T/repo-two" && HOME="$T/home" XDG_CACHE_HOME="$T/cache" bash "$REPO/bin/afterparty" report-path)"
RC2=$?
if [ "$RC1" -ne 0 ] || [ "$RC2" -ne 0 ]; then
  fail "H2: report-path command failed ($RC1/$RC2)"
elif [ "$R1" = "$R2" ]; then
  fail "H2: separate repositories resolved to the same fallback report"
elif [[ "$R1" != "$T/cache/agent-processes/reports/"*/report.md ]] \
  || [[ "$R2" != "$T/cache/agent-processes/reports/"*/report.md ]]; then
  fail "H2: fallback reports were not placed in repo-scoped cache directories"
else
  pass "H2: fallback reports are namespaced by workspace"
fi

# ---------- H3: report writes use the canonical path and private final file ----------
(cd "$T/repo-one" && HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" audit --report >"$T/report.out" 2>"$T/report.err")
REPORT_RC=$?
if [ "$REPORT_RC" -ne 0 ] && { [ "$REPORT_RC" -ne 1 ] || ! grep -q 'Status: incomplete' "$R1"; }; then
  fail "H3: audit --report exit=$REPORT_RC"
elif [ ! -f "$R1" ]; then
  fail "H3: report was not written to report-path output ($R1)"
elif ! grep -q '^# afterparty report' "$R1"; then
  fail "H3: persisted report is incomplete"
elif find "$(dirname "$R1")" -maxdepth 1 -name '.report.md.*' | grep -q .; then
  fail "H3: atomic report temporary file was left behind"
else
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
      MODE="$(stat -c %a "$R1" 2>/dev/null || stat -f %Lp "$R1" 2>/dev/null)"
      [ "$MODE" = "600" ] || fail "H3: report mode is $MODE, want 600"
      ;;
  esac
  [ "$FAILS" -gt 0 ] || pass "H3: report writes atomically to a private canonical path"
fi

# ---------- H4: SessionStart surfaces the existing report without rerunning audit ----------
if "$PY" - "$REPO/hooks/hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)

hook = manifest["hooks"]["SessionStart"][0]["hooks"][0]
assert hook["type"] == "command"
assert hook["command"] == "bash"
assert hook["args"] == [
    "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty",
    "report",
    "--remind",
]
PY
then
  REMINDER="$(cd "$T/repo-one" && HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
    bash "$REPO/bin/afterparty" report --remind)"
  if [[ "$REMINDER" == *"$R1"* ]]; then
    pass "H4: SessionStart exposes the prior report path"
  else
    fail "H4: report reminder did not expose the prior report path"
  fi
else
  fail "H4: SessionStart report reminder hook is missing"
fi

# ---------- H5: unavailable process scans are explicit in human + JSON output ----------
mkdir -p "$T/cap-shim"
# pnpm resolves its store from the OS passwd entry, NOT $HOME or XDG vars, so
# the fixture isolation every other binary here relies on does not apply to it.
# Without this shim `bash tests/run.sh` runs `pnpm store prune` against the
# developer's real shared store. Third HOME-immune surface after pgrep and
# launchctl.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/cap-shim/pnpm"
chmod +x "$T/cap-shim/pnpm"
cat > "$T/cap-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid="*) exit 1 ;;
  "-Ao "*) exit 1 ;;
  "-o pgid= -p "*) exit 1 ;;
  "-p "*) exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/cap-shim/ps"
PATH="$T/cap-shim:$PATH" AFTERPARTY_STYLE=always \
  bash "$REPO/skills/afterparty/lib/audit-processes.sh" >"$T/cap.out" 2>"$T/cap.err"
CAP_RC=$?
PATH="$T/cap-shim:$PATH" AFTERPARTY_STYLE=always \
  bash "$REPO/skills/afterparty/lib/audit-processes.sh" --json >"$T/cap.jsonl" 2>"$T/cap-json.err"
CAP_JSON_RC=$?
if [ "$CAP_RC" -ne 0 ] || [ "$CAP_JSON_RC" -ne 0 ]; then
  fail "H5: degraded dry-run should remain reportable ($CAP_RC/$CAP_JSON_RC)"
elif ! grep -q 'audit is incomplete' "$T/cap.out"; then
  fail "H5: human output did not mark the audit incomplete"
elif grep -q 'No process candidates found' "$T/cap.out"; then
  fail "H5: unavailable process scan produced a No process candidates found claim"
elif "$PY" - "$T/cap.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    rows = [json.loads(line) for line in f if line.strip()]

assert rows
assert all(row.get("schema_version") == 1 for row in rows)
assert any(
    row.get("section") == "capability"
    and row.get("name") == "processes"
    and row.get("status") == "unavailable"
    for row in rows
)
PY
then
  pass "H5: unavailable scanners are explicit and never reported No process candidates found"
else
  fail "H5: JSON output omitted versioned process capability state"
fi

# ---------- H6: doctor --strict fails on degraded capabilities ----------
cat > "$T/cap-shim/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$T/cap-shim/pgrep"
# devclean --optimize's background-agent step addresses the real login session
# (`launchctl print|disable|bootout gui/<uid>/<label>`) no matter what HOME is
# set to, so an --apply under this shim would disable the developer's actual
# ChatGPT/Figma agents. Report "nothing registered" instead; no case here
# asserts on that branch, so this only removes the side effect.
cat > "$T/cap-shim/launchctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$T/cap-shim/launchctl"
(cd "$T/repo-one" && PATH="$T/cap-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" doctor --strict >"$T/doctor.out" 2>"$T/doctor.err")
DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ]; then
  fail "H6: doctor --strict succeeded despite unavailable process scanning"
elif ! grep -q 'unavailable' "$T/doctor.out"; then
  fail "H6: doctor --strict did not explain the degraded capability"
else
  pass "H6: doctor --strict fails when an audit capability is unavailable"
fi

# ---------- H7: destructive artifact cleanup requires a repository by default ----------
mkdir -p "$T/nonrepo/build"
printf 'keep me\n' > "$T/nonrepo/build/important.txt"
AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" artifacts --clean --root "$T/nonrepo" \
  >"$T/artifact-guard.out" 2>"$T/artifact-guard.err"
ART_GUARD_RC=$?
if [ "$ART_GUARD_RC" -ne 2 ]; then
  fail "H7: non-repository artifact clean exit=$ART_GUARD_RC, want 2"
elif [ ! -f "$T/nonrepo/build/important.txt" ]; then
  fail "H7: non-repository artifact was deleted without explicit opt-in"
else
  pass "H7: artifact cleanup refuses non-repository roots by default"
fi

# ---------- H8: explicit non-repo mode still rejects the user's home root ----------
mkdir -p "$T/broad-home/build"
printf 'keep me too\n' > "$T/broad-home/build/important.txt"
HOME="$T/broad-home" AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" artifacts --clean \
  --allow-non-repo-root --root "$T/broad-home" >"$T/broad-root.out" 2>"$T/broad-root.err"
BROAD_RC=$?
if [ "$BROAD_RC" -ne 2 ]; then
  fail "H8: home-root artifact clean exit=$BROAD_RC, want 2"
elif [ ! -f "$T/broad-home/build/important.txt" ]; then
  fail "H8: broad home-root cleanup deleted an artifact"
else
  pass "H8: artifact cleanup rejects broad home/root targets"
fi

# ---------- H9: category kills can be narrowed to reviewed PGIDs ----------
mkdir -p "$T/pgid-shim"
cat > "$T/pgid-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "41234 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-Ao pid="*) echo "41234" ;;
  "-Ao pid,ppid,pgid,%cpu,etime,command"*)
    echo "41234 1 77777 2.0 00:20 next dev --port 3000"
    ;;
  "-Ao pgid=,command="*) echo "77777 next dev --port 3000" ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/pgid-shim/ps"
PATH="$T/pgid-shim:$PATH" AFTERPARTY_STYLE=never \
  bash "$REPO/skills/afterparty/lib/audit-processes.sh" --kill dev --pgid 88888 \
  >"$T/pgid.out" 2>"$T/pgid.err"
PGID_RC=$?
PATH="$T/pgid-shim:$PATH" bash "$REPO/skills/afterparty/lib/audit-processes.sh" \
  --kill dev --pgid '88888,nope' >/dev/null 2>"$T/pgid-invalid.err"
PGID_INVALID_RC=$?
if [ "$PGID_RC" -ne 0 ]; then
  fail "H9: exact PGID filter exit=$PGID_RC"
elif ! grep -q 'nothing to kill' "$T/pgid.out"; then
  fail "H9: nonmatching reviewed PGID did not narrow the category to zero"
elif [ "$PGID_INVALID_RC" -ne 2 ]; then
  fail "H9: invalid PGID filter exit=$PGID_INVALID_RC, want 2"
else
  pass "H9: category kills accept only validated, reviewed PGIDs"
fi

# ---------- H10: protected-group inspection failures fail closed ----------
mkdir -p "$T/protect-shim"
cat > "$T/protect-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "41234 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-Ao pid="*) echo "41234" ;;
  "-Ao pid,ppid,pgid,%cpu,etime,command"*)
    echo "41234 1 77777 2.0 00:20 next dev --port 3000"
    ;;
  "-Ao pgid=,command="*) exit 1 ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/protect-shim/ps"
BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h10-kill.calls" PATH="$T/protect-shim:$PATH" AFTERPARTY_STYLE=never \
  bash "$REPO/skills/afterparty/lib/audit-processes.sh" --kill dev --pgid 77777 \
  >"$T/protect.out" 2>"$T/protect.err"
PROTECT_RC=$?
if [ "$PROTECT_RC" -ne 1 ]; then
  fail "H10: protection inspection failure exit=$PROTECT_RC, want 1"
elif ! grep -q 'could not inspect pgid 77777' "$T/protect.out"; then
  fail "H10: protection inspection failure was not explained"
else
  pass "H10: protected-group inspection failures skip the group and fail closed"
fi

# ---------- H11: ledger-owned group stops also fail closed ----------
mkdir -p "$T/ledger-shim"
cat > "$T/ledger-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "12345 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p 12345") echo "77777" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-p 12345") exit 0 ;;
  "-Ao pgid=,command="*) exit 1 ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/ledger-shim/ps"
LEDGER_ROOT="$(git -C "$T/repo-one" rev-parse --show-toplevel)"
. "$REPO/skills/afterparty/lib/fingerprint.sh"
printf '2026-07-31T00:00:00Z\t%s\t%s\t12345\t77777\tdev\t3000\ttest server\tnext dev\t%s\n' \
  "$LEDGER_ROOT" "$LEDGER_ROOT" "$(PATH="$T/ledger-shim:$PATH" fp_members_for_pgid 77777)" > "$T/fail-closed-ledger.tsv"
(cd "$T/repo-one" && BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h11-kill.calls" PATH="$T/ledger-shim:$PATH" HOME="$T/home" \
  AGENT_PROCESS_LEDGER="$T/fail-closed-ledger.tsv" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" stop --kill >"$T/ledger-protect.out" 2>"$T/ledger-protect.err")
LEDGER_PROTECT_RC=$?
if [ "$LEDGER_PROTECT_RC" -ne 1 ]; then
  fail "H11: ledger protection inspection failure exit=$LEDGER_PROTECT_RC, want 1"
elif ! grep -q 'could not inspect pgid 77777' "$T/ledger-protect.out"; then
  fail "H11: ledger protection inspection failure was not explained"
else
  pass "H11: ledger group stops fail closed when protection cannot be inspected"
fi

# ---------- H12: malformed ledger process IDs are rejected before signaling ----------
mkdir -p "$T/id-shim"
cat > "$T/id-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-o pgid= -p 12345") echo "0" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-p 12345") exit 0 ;;
  "-Ao pgid=,command="*) echo "0 next dev --port 3000" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/id-shim/ps"
printf '2026-07-31T00:00:00Z\t%s\t%s\t12345\t0\tdev\t3000\ttest server\tnext dev\n' \
  "$LEDGER_ROOT" "$LEDGER_ROOT" > "$T/invalid-id-ledger.tsv"
(cd "$T/repo-one" && PATH="$T/id-shim:$PATH" HOME="$T/home" \
  AGENT_PROCESS_LEDGER="$T/invalid-id-ledger.tsv" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" stop >"$T/invalid-id.out" 2>"$T/invalid-id.err")
INVALID_ID_RC=$?
if [ "$INVALID_ID_RC" -ne 1 ]; then
  fail "H12: invalid ledger PGID exit=$INVALID_ID_RC, want 1"
elif ! grep -q 'invalid pgid 0' "$T/invalid-id.out"; then
  fail "H12: invalid ledger PGID was not explained"
else
  pass "H12: malformed ledger process IDs are rejected before signaling"
fi

# ---------- H13: process mutation is unavailable when full process inspection is unavailable ----------
(cd "$T/repo-one" && PATH="$T/cap-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" audit --kill dev \
  >"$T/unavailable-kill.out" 2>"$T/unavailable-kill.err")
UNAVAILABLE_KILL_RC=$?
if [ "$UNAVAILABLE_KILL_RC" -ne 1 ]; then
  fail "H13: unavailable process kill exit=$UNAVAILABLE_KILL_RC, want 1"
elif ! grep -q 'cannot kill process groups' "$T/unavailable-kill.out"; then
  fail "H13: unavailable process kill was not explained"
else
  pass "H13: process mutation refuses to run without full process inspection"
fi

# Artifact mutation fixtures use the same typed approval flow as the CLI.
mkdir -p "$T/artifact-proc-shim"
cat > "$T/artifact-proc-shim/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p9991\nfcwd\nn%s\n' "$TEST_ARTIFACT_SCOPE"
SH
chmod +x "$T/artifact-proc-shim/lsof"
approved_artifact() {
  local artifact_root="$1" artifact_fp
  . "$REPO/skills/afterparty/lib/fingerprint.sh"
  artifact_root="$(cd "$artifact_root" && pwd -P)"
  artifact_fp="$(fp_for_artifact "$artifact_root/build")" || return 1
  printf -- '- [x] artifact path %s/build\n      type: artifact  fingerprint: %s  root: %s\n' "$artifact_root" "$artifact_fp" "$artifact_root" > "$T/artifact-approved.md"
  TEST_ARTIFACT_SCOPE="$artifact_root" PATH="$T/artifact-proc-shim:$PATH" bash "$REPO/bin/afterparty" apply "$T/artifact-approved.md"
}

# ---------- H14: artifact receipts and exit status reflect deletion failures ----------
mkdir -p "$T/artifact-fail/build" "$T/rm-shim"
git -C "$T/artifact-fail" init -q
printf 'cannot delete me\n' > "$T/artifact-fail/build/file.txt"
cat > "$T/rm-shim/rm" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$T/rm-shim/rm"
PATH="$T/rm-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  approved_artifact "$T/artifact-fail" \
  >"$T/artifact-fail.out" 2>"$T/artifact-fail.err"
ART_FAIL_RC=$?
if [ "$ART_FAIL_RC" -ne 1 ]; then
  fail "H14: failed artifact deletion exit=$ART_FAIL_RC, want 1"
elif ! grep -q 'failed to delete' "$T/artifact-fail.out"; then
  fail "H14: failed artifact deletion was not reported"
elif grep -q '(freed)' "$T/artifact-fail.out"; then
  fail "H14: failed artifact deletion was reported as freed"
elif [ ! -f "$T/artifact-fail/build/file.txt" ]; then
  fail "H14: failure fixture unexpectedly disappeared"
else
  pass "H14: artifact receipts report confirmed deletions and partial failures"
fi

# ---------- H15: process receipts require confirmed group exit ----------
(cd "$T/repo-one" && BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h15-kill.calls" \
  PATH="$T/pgid-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" audit --kill dev --pgid 77777 \
  >"$T/kill-fail.out" 2>"$T/kill-fail.err")
KILL_FAIL_RC=$?
if [ "$KILL_FAIL_RC" -ne 1 ]; then
  fail "H15: unconfirmed process-group exit=$KILL_FAIL_RC, want 1"
elif ! grep -q 'failed to stop pgid 77777' "$T/kill-fail.out"; then
  fail "H15: unconfirmed process-group exit was not reported"
else
  pass "H15: process receipts count only confirmed group exits"
fi

# ---------- H16: ledger receipts also require confirmed group exit ----------
mkdir -p "$T/ledger-outcome-shim"
cat > "$T/ledger-outcome-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "12345 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p 12345") echo "77777" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-p 12345") exit 0 ;;
  "-Ao pid=") echo "12345" ;;
  "-Ao pgid=,command="*) echo "77777 next dev --port 3000" ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/ledger-outcome-shim/ps"
printf '2026-07-31T00:00:00Z\t%s\t%s\t12345\t77777\tdev\t3000\ttest server\tnext dev\t%s\n' \
  "$LEDGER_ROOT" "$LEDGER_ROOT" "$(PATH="$T/ledger-outcome-shim:$PATH" fp_members_for_pgid 77777)" > "$T/outcome-ledger.tsv"
(cd "$T/repo-one" && BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h16-kill.calls" \
  PATH="$T/ledger-outcome-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  AGENT_PROCESS_LEDGER="$T/outcome-ledger.tsv" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" stop --kill >"$T/ledger-outcome.out" 2>"$T/ledger-outcome.err")
LEDGER_OUTCOME_RC=$?
if [ "$LEDGER_OUTCOME_RC" -ne 1 ]; then
  fail "H16: unconfirmed ledger group exit=$LEDGER_OUTCOME_RC, want 1"
elif ! grep -q 'failed to stop pgid 77777' "$T/ledger-outcome.out"; then
  fail "H16: unconfirmed ledger group exit was not reported"
else
  pass "H16: ledger receipts count only confirmed group exits"
fi

# ---------- H17: global cache cleanup reports only confirmed deletion ----------
mkdir -p "$T/devclean-home/.gradle/caches" "$T/devclean-home/Documents" "$T/devclean-rm-shim"
dd if=/dev/zero of="$T/devclean-home/.gradle/caches/cache.bin" bs=1024 count=2048 2>/dev/null
cat > "$T/devclean-rm-shim/rm" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$T/devclean-rm-shim/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
# pnpm resolves its store from the OS passwd entry, not $HOME — see the note at
# the cap-shim above. Without this, H17 runs a real `pnpm store prune`, and
# because clean_pnpm_store adds freed bytes to DISK_TOTAL_KB, any nonzero real
# prune shifts the total and makes H17's NEGATIVE assertion pass even if the
# gradle-accounting bug it exists to catch has regressed.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/devclean-rm-shim/pnpm"
chmod +x "$T/devclean-rm-shim/rm" "$T/devclean-rm-shim/pgrep" "$T/devclean-rm-shim/pnpm"
PATH="$T/devclean-rm-shim:$PATH" HOME="$T/devclean-home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --disk --no-repo-artifacts \
  --documents-root "$T/devclean-home/Documents" >"$T/devclean-disk.out" 2>"$T/devclean-disk.err"
DEVCLEAN_DISK_RC=$?
if [ "$DEVCLEAN_DISK_RC" -ne 1 ]; then
  fail "H17: failed global cache deletion exit=$DEVCLEAN_DISK_RC, want 1"
elif ! grep -q 'failed to clean Gradle caches' "$T/devclean-disk.out"; then
  fail "H17: failed global cache deletion was not explained"
elif grep -q 'Global disk reclaimed: 2.0 MB' "$T/devclean-disk.out"; then
  fail "H17: failed global cache deletion was counted as reclaimed"
elif [ ! -f "$T/devclean-home/.gradle/caches/cache.bin" ]; then
  fail "H17: failure fixture unexpectedly disappeared"
else
  pass "H17: global cache receipts count only confirmed deletions"
fi

# ---------- H18: PID cleanup reports only confirmed process exit ----------
mkdir -p "$T/devclean-proc-shim" "$T/devclean-proc-home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/devclean-proc-shim/pnpm"
chmod +x "$T/devclean-proc-shim/pnpm"
cat > "$T/devclean-proc-shim/pgrep" <<'SH'
#!/usr/bin/env bash
echo 12345
SH
cat > "$T/devclean-proc-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-p 12345") exit 0 ;;
  "-o rss= -p 12345") echo "1024" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-o ppid=,lstart=,command= -p 12345") echo "1 Thu Jul 31 00:00:00 2026 next dev --port 3000" ;;
  "-o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p 12345")
    echo "12345 1 77777 1024 1.0 00:20 next dev --port 3000"
    ;;
  "-Ao pid=") echo "12345" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/devclean-proc-shim/pgrep" "$T/devclean-proc-shim/ps"
devclean_policy_fixture "$T/devclean-proc-shim" 12345
BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h18-kill.calls" \
  PATH="$T/devclean-proc-shim:$PATH" HOME="$T/devclean-proc-home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" \
  >"$T/devclean-proc.out" 2>"$T/devclean-proc.err"
DEVCLEAN_PROC_RC=$?
if [ "$DEVCLEAN_PROC_RC" -ne 1 ]; then
  fail "H18: unconfirmed PID exit=$DEVCLEAN_PROC_RC, want 1"
elif ! grep -q 'failed to stop pid 12345' "$T/devclean-proc.out"; then
  fail "H18: unconfirmed PID exit was not explained"
else
  pass "H18: PID cleanup receipts count only confirmed exits"
fi

# ---------- H19: mutations append a private, versioned action journal ----------
mkdir -p "$T/artifact-ok/build"
git -C "$T/artifact-ok" init -q
printf 'delete me\n' > "$T/artifact-ok/build/file.txt"
HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  approved_artifact "$T/artifact-ok" \
  >"$T/artifact-ok.out" 2>"$T/artifact-ok.err"
ART_OK_RC=$?
ACTIONS_PATH="$(HOME="$T/home" XDG_CACHE_HOME="$T/cache" bash "$REPO/bin/afterparty" actions-path)"
ACTIONS_RC=$?
HOME="$T/home" XDG_CACHE_HOME="$T/cache" bash "$REPO/bin/afterparty" actions --all >"$T/actions.out"
ACTIONS_SHOW_RC=$?
if [ "$ART_OK_RC" -ne 0 ] || [ "$ACTIONS_RC" -ne 0 ] || [ "$ACTIONS_SHOW_RC" -ne 0 ]; then
  fail "H19: action journal commands failed ($ART_OK_RC/$ACTIONS_RC/$ACTIONS_SHOW_RC)"
elif [ "$ACTIONS_PATH" != "$T/cache/agent-processes/actions.jsonl" ]; then
  fail "H19: unexpected action journal path: $ACTIONS_PATH"
elif ! cmp -s "$ACTIONS_PATH" "$T/actions.out"; then
  fail "H19: actions command did not expose the canonical journal"
elif "$PY" - "$ACTIONS_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    rows = [json.loads(line) for line in f if line.strip()]

artifact_rows = [row for row in rows if row.get("operation") == "artifact.clean"]
assert all(row.get("schema_version") == 1 for row in rows)
assert all(row.get("timestamp") and row.get("workspace") for row in artifact_rows)
assert any(row.get("status") == "succeeded" for row in artifact_rows)
assert any(row.get("status") == "failed" for row in artifact_rows)
assert any(row.get("operation") == "process_group.stop" and row.get("status") == "failed" for row in rows)
assert any(row.get("operation") == "ledger_group.stop" and row.get("status") == "failed" for row in rows)
assert any(row.get("operation") == "cache.clean" and row.get("status") == "failed" for row in rows)
assert any(row.get("operation") == "process.stop" and row.get("status") == "failed" for row in rows)
PY
then
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
      ACTION_MODE="$(stat -c %a "$ACTIONS_PATH" 2>/dev/null || stat -f %Lp "$ACTIONS_PATH" 2>/dev/null)"
      [ "$ACTION_MODE" = "600" ] || fail "H19: action journal mode is $ACTION_MODE, want 600"
      ;;
  esac
  [ "$FAILS" -gt 0 ] || pass "H19: mutations append a private, versioned action journal"
else
  fail "H19: action journal rows are incomplete or invalid"
fi

# ---------- H20: ledger add and prune serialize without losing entries ----------
mkdir -p "$T/ledger-race-shim" "$T/ledger-race-sync"
REAL_MV="$(command -v mv)"
cat > "$T/ledger-race-shim/mv" <<'SH'
#!/usr/bin/env bash
touch "$LEDGER_RACE_SYNC/ready"
while [ ! -f "$LEDGER_RACE_SYNC/release" ]; do sleep 0.05; done
exec "$LEDGER_RACE_REAL_MV" "$@"
SH
cat > "$T/ledger-race-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "12345 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-p 12345") exit 0 ;;
  "-p 54321") exit 1 ;;
  "-o pgid= -p 12345") echo "77777" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/ledger-race-shim/mv" "$T/ledger-race-shim/ps"
printf '2026-07-31T00:00:00Z\t%s\t%s\t54321\t88888\tdev\t3001\tdead server\tnext dev\n' \
  "$LEDGER_ROOT" "$LEDGER_ROOT" > "$T/race-ledger.tsv"
(cd "$T/repo-one" && PATH="$T/ledger-race-shim:$PATH" HOME="$T/home" \
  AGENT_PROCESS_LEDGER="$T/race-ledger.tsv" LEDGER_RACE_SYNC="$T/ledger-race-sync" \
  LEDGER_RACE_REAL_MV="$REAL_MV" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" prune --all >"$T/race-prune.out" 2>"$T/race-prune.err") &
PRUNE_JOB=$!
for _ in {1..100}; do [ -f "$T/ledger-race-sync/ready" ] && break; sleep 0.05; done
if [ ! -f "$T/ledger-race-sync/ready" ]; then
  fail "H20: prune did not reach the controlled commit point"
  touch "$T/ledger-race-sync/release"
else
  (cd "$T/repo-one" && PATH="$T/ledger-race-shim:$PATH" HOME="$T/home" \
    AGENT_PROCESS_LEDGER="$T/race-ledger.tsv" AFTERPARTY_STYLE=never \
    bash "$REPO/bin/afterparty" add --pid 12345 --kind dev --port 3000 \
    --purpose race-test -- next dev >"$T/race-add.out" 2>"$T/race-add.err") &
  ADD_JOB=$!
  # Give an unlocked add ample time to append before prune replaces its stale
  # snapshot. A locked add remains blocked and appends after the release.
  sleep 5
  touch "$T/ledger-race-sync/release"
  wait "$PRUNE_JOB"; PRUNE_RACE_RC=$?
  wait "$ADD_JOB"; ADD_RACE_RC=$?
  if [ "$PRUNE_RACE_RC" -ne 0 ] || [ "$ADD_RACE_RC" -ne 0 ]; then
    fail "H20: concurrent ledger commands failed ($PRUNE_RACE_RC/$ADD_RACE_RC)"
  elif ! awk -F '\t' '$4 == 12345 { found=1 } END { exit !found }' "$T/race-ledger.tsv"; then
    fail "H20: prune overwrote an entry added concurrently"
  else
    case "$(uname -s)" in
      MINGW*|MSYS*) ;;
      *)
        LEDGER_MODE="$(stat -c %a "$T/race-ledger.tsv" 2>/dev/null || stat -f %Lp "$T/race-ledger.tsv" 2>/dev/null)"
        [ "$LEDGER_MODE" = "600" ] || fail "H20: ledger mode is $LEDGER_MODE, want 600"
        ;;
    esac
    [ "$FAILS" -gt 0 ] || pass "H20: ledger add and prune are serialized and private"
  fi
fi

# ---------- H21: global cleanup rejects a filesystem-root HOME ----------
PATH="$T/cap-shim:$PATH" HOME=/ AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" \
  >"$T/devclean-root.out" 2>"$T/devclean-root.err"
DEVCLEAN_ROOT_RC=$?
if [ "$DEVCLEAN_ROOT_RC" -ne 2 ]; then
  fail "H21: filesystem-root HOME cleanup exit=$DEVCLEAN_ROOT_RC, want 2"
elif ! grep -q 'unsafe HOME' "$T/devclean-root.err"; then
  fail "H21: filesystem-root HOME rejection was not explained"
else
  pass "H21: global cleanup rejects a filesystem-root HOME"
fi

# ---------- H22: ledger add validates identifiers before persisting ----------
PATH="$T/ledger-race-shim:$PATH" HOME="$T/home" AGENT_PROCESS_LEDGER="$T/invalid-add-ledger.tsv" \
  AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" add --pid -1 --kind dev \
  --purpose invalid -- next dev >"$T/invalid-add.out" 2>"$T/invalid-add.err"
INVALID_ADD_RC=$?
if [ "$INVALID_ADD_RC" -ne 2 ]; then
  fail "H22: invalid add PID exit=$INVALID_ADD_RC, want 2"
elif ! grep -q 'invalid pid -1' "$T/invalid-add.err"; then
  fail "H22: invalid add PID was not rejected by identifier validation"
elif [ -s "$T/invalid-add-ledger.tsv" ]; then
  fail "H22: invalid add PID was persisted"
else
  pass "H22: ledger add rejects invalid process identifiers"
fi

# ---------- H23: project-artifact scans reject broad roots by default ----------
PATH="$T/cap-shim:$PATH" HOME="$T/home" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --disk --no-repo-artifacts \
  --documents-root "$T/home" >"$T/devclean-doc-root.out" 2>"$T/devclean-doc-root.err"
DEVCLEAN_DOC_ROOT_RC=$?
if [ "$DEVCLEAN_DOC_ROOT_RC" -ne 2 ]; then
  fail "H23: home-wide documents scan exit=$DEVCLEAN_DOC_ROOT_RC, want 2"
elif ! grep -q 'broad documents root' "$T/devclean-doc-root.err"; then
  fail "H23: broad documents-root rejection was not explained"
else
  pass "H23: project-artifact scans reject broad roots by default"
fi

# ---------- H24: optimize mode verifies configuration mutations ----------
mkdir -p "$T/opt-fail-home/.vscode" "$T/opt-fail-shim"
printf '{"enable-crash-reporter": true}\n' > "$T/opt-fail-home/.vscode/argv.json"
REAL_PYTHON="$(command -v python3)"
export REAL_PYTHON
cat > "$T/opt-fail-shim/python3" <<'SH'
#!/usr/bin/env bash
case "$*" in *devclean-settings.py\ disable*) exit 1 ;; esac
exec "$REAL_PYTHON" "$@"
SH
cat > "$T/opt-fail-shim/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
# See the cap-shim launchctl note: keep off the real launchd registry.
cat > "$T/opt-fail-shim/launchctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/opt-fail-shim/pnpm"
chmod +x "$T/opt-fail-shim/pnpm"
chmod +x "$T/opt-fail-shim/python3" "$T/opt-fail-shim/pgrep" "$T/opt-fail-shim/launchctl"
PATH="$T/opt-fail-shim:$PATH" HOME="$T/opt-fail-home" XDG_CACHE_HOME="$T/cache" \
  AFTERPARTY_STYLE=never reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --optimize \
  >"$T/opt-fail.out" 2>"$T/opt-fail.err"
OPT_FAIL_RC=$?
if [ "$OPT_FAIL_RC" -ne 1 ]; then
  fail "H24: failed config optimization exit=$OPT_FAIL_RC, want 1"
elif ! grep -q 'failed to disable crash reporter' "$T/opt-fail.out"; then
  fail "H24: failed config optimization was not explained"
elif ! grep -q '"enable-crash-reporter": true' "$T/opt-fail-home/.vscode/argv.json"; then
  fail "H24: failed config fixture changed unexpectedly"
else
  pass "H24: optimize mode reports only verified configuration changes"
fi

# ---------- H25: a report-only git --clean writes no receipt ----------
# --clean used to apply the safe subset, and this pinned that a FAILED removal
# propagated to exit 1, the summary and the journal. Removal is now refused
# outright (moving behind plan/apply as a typed worktree target), so the
# invariant worth pinning is the receipt rule from the other direction: a run
# that did nothing must claim nothing. A false success row here would be worse
# than the missing one it replaces.
mkdir -p "$T/git-fail"
git -C "$T/git-fail" init -q
printf 'conflict residue\n' > "$T/git-fail/merge.orig"
JOURNAL_BEFORE=0
[ -f "$T/cache/agent-processes/actions.jsonl" ] \
  && JOURNAL_BEFORE="$(awk '/git\./ {n++} END {print n+0}' "$T/cache/agent-processes/actions.jsonl")"
HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" git --clean --root "$T/git-fail" \
  >"$T/git-fail.out" 2>"$T/git-fail.err"
GIT_FAIL_RC=$?
JOURNAL_AFTER=0
[ -f "$T/cache/agent-processes/actions.jsonl" ] \
  && JOURNAL_AFTER="$(awk '/git\./ {n++} END {print n+0}' "$T/cache/agent-processes/actions.jsonl")"
if [ "$GIT_FAIL_RC" -ne 2 ]; then
  fail "H25: report-only git --clean exit=$GIT_FAIL_RC, want 2"
elif ! grep -q 'report-only' "$T/git-fail.err"; then
  fail "H25: refusal did not explain itself"
elif [ "$JOURNAL_AFTER" -ne "$JOURNAL_BEFORE" ]; then
  fail "H25: a refused cleanup wrote $((JOURNAL_AFTER - JOURNAL_BEFORE)) journal row(s) — receipts must describe work that happened"
elif [ ! -f "$T/git-fail/merge.orig" ]; then
  fail "H25: the litter fixture was deleted by a report-only run"
elif ! grep -q 'merge.orig' "$T/git-fail.out"; then
  fail "H25: the litter was not even reported — that is a no-op, not report-only"
else
  pass "H25: a report-only git --clean reports, removes nothing, and journals nothing"
fi

# ---------- H26: standalone package metadata has one synchronized version ----------
CLI_VERSION="$(bash "$REPO/bin/afterparty" --version 2>"$T/version.err")"
VERSION_RC=$?
if [ "$VERSION_RC" -ne 0 ]; then
  fail "H26: --version exit=$VERSION_RC"
elif "$PY" - "$REPO" "$CLI_VERSION" <<'PY'
import json
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
cli_version = sys.argv[2]
version = (repo / "skills/afterparty/VERSION").read_text(encoding="utf-8").strip()
plugin = json.loads((repo / ".claude-plugin/plugin.json").read_text(encoding="utf-8"))
skill = (repo / "skills/afterparty/SKILL.md").read_text(encoding="utf-8")
changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")

metadata_version = re.search(r'^  version: ["\']?([^"\'\n]+)', skill, re.MULTILINE)
assert version == cli_version == plugin["version"]
assert metadata_version and metadata_version.group(1) == version
assert f"## [{version}]" in changelog
PY
then
  if [ ! -f "$REPO/skills/afterparty/LICENSE" ]; then
    fail "H26: standalone skill omitted its license"
  elif ! "$PY" - "$REPO/LICENSE" "$REPO/skills/afterparty/LICENSE" <<'PY'
import pathlib
import sys

assert pathlib.Path(sys.argv[1]).read_text(encoding="utf-8") == pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
PY
  then
    fail "H26: standalone skill license differs from the repository license"
  else
    pass "H26: standalone package version and license metadata are synchronized"
  fi
else
  fail "H26: package version metadata is missing or inconsistent"
fi

# ---------- H27: artifact guards apply after repository-root expansion ----------
mkdir -p "$T/home-repo/project/build"
git -C "$T/home-repo" init -q
printf 'home-owned artifact\n' > "$T/home-repo/project/build/keep.txt"
HOME="$T/home-repo" AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" artifacts --clean \
  --root "$T/home-repo/project" >"$T/home-repo.out" 2>"$T/home-repo.err"
HOME_REPO_RC=$?
if [ "$HOME_REPO_RC" -ne 2 ]; then
  fail "H27: home-root repository expansion exit=$HOME_REPO_RC, want 2"
elif [ ! -f "$T/home-repo/project/build/keep.txt" ]; then
  fail "H27: repository-root expansion bypassed the home guard"
else
  pass "H27: artifact root guards cover the final repository scope"
fi

# ---------- H28: custom ledger parents retain caller-managed permissions ----------
mkdir -p "$T/custom-ledger-parent" "$T/chmod-shim"
REAL_CHMOD="$(command -v chmod)"
cat > "$T/chmod-shim/chmod" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHMOD_CALLS"
exec "$REAL_CHMOD" "$@"
SH
chmod +x "$T/chmod-shim/chmod"
CHMOD_CALLS="$T/chmod.calls" REAL_CHMOD="$REAL_CHMOD" PATH="$T/chmod-shim:$PATH" \
  HOME="$T/home" AGENT_PROCESS_LEDGER="$T/custom-ledger-parent/ledger.tsv" \
  AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" list >/dev/null 2>"$T/custom-ledger.err"
CUSTOM_LEDGER_RC=$?
if [ "$CUSTOM_LEDGER_RC" -ne 0 ]; then
  fail "H28: custom ledger list exit=$CUSTOM_LEDGER_RC"
elif grep -Fq "700 $T/custom-ledger-parent" "$T/chmod.calls"; then
  fail "H28: custom ledger parent permissions were overwritten"
else
  (cd "$T/repo-one" && HOME="$T/home" AGENT_PROCESS_LEDGER=relative-ledger.tsv \
    AFTERPARTY_STYLE=never bash "$REPO/bin/afterparty" prune >/dev/null 2>"$T/relative-ledger.err")
  RELATIVE_LEDGER_RC=$?
  if [ "$RELATIVE_LEDGER_RC" -ne 0 ]; then
    fail "H28: relative ledger lock exit=$RELATIVE_LEDGER_RC"
  else
    pass "H28: custom ledger parents and relative locks are handled safely"
  fi
fi

# ---------- H29: devclean revalidates PID identity immediately before signaling ----------
mkdir -p "$T/devclean-identity-shim" "$T/devclean-identity-home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/devclean-identity-shim/pnpm"
chmod +x "$T/devclean-identity-shim/pnpm"
cat > "$T/devclean-identity-shim/pgrep" <<'SH'
#!/usr/bin/env bash
echo 12345
SH
cat > "$T/devclean-identity-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-p 12345") exit 0 ;;
  "-o rss= -p 12345") echo "1024" ;;
  "-o command= -p 12345") echo "unrelated user process" ;;
  "-o ppid=,lstart=,command= -p 12345") echo "1 Thu Jul 31 00:00:00 2026 unrelated user process" ;;
  "-o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p 12345")
    echo "12345 1 77777 1024 1.0 00:20 next dev --port 3000"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/devclean-identity-shim/pgrep" "$T/devclean-identity-shim/ps"
devclean_policy_fixture "$T/devclean-identity-shim" 12345
BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h29-kill.calls" \
  PATH="$T/devclean-identity-shim:$PATH" HOME="$T/devclean-identity-home" \
  XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" \
  >"$T/devclean-identity.out" 2>"$T/devclean-identity.err"
IDENTITY_RC=$?
if [ "$IDENTITY_RC" -ne 1 ]; then
  fail "H29: changed PID identity exit=$IDENTITY_RC, want 1"
elif ! grep -q 'pid 12345 identity changed' "$T/devclean-identity.out"; then
  fail "H29: changed PID identity was not reported before signaling"
elif [ -s "$T/h29-kill.calls" ]; then
  fail "H29: changed PID identity was signaled"
else
  pass "H29: devclean fails closed when PID identity changes"
fi

# ---------- H30: matching recycled PIDs are rejected by stable identity ----------
mkdir -p "$T/devclean-recycle-shim" "$T/devclean-recycle-home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/devclean-recycle-shim/pnpm"
chmod +x "$T/devclean-recycle-shim/pnpm"
cat > "$T/devclean-recycle-shim/pgrep" <<'SH'
#!/usr/bin/env bash
echo 12345
SH
cat > "$T/devclean-recycle-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-p 12345") exit 0 ;;
  "-o rss= -p 12345") echo "1024" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-o ppid=,lstart=,command= -p 12345")
    if [ ! -f "$IDENTITY_COUNT" ]; then
      printf 'first\n' > "$IDENTITY_COUNT"
      echo "1 Thu Jul 31 00:00:00 2026 next dev --port 3000"
    else
      echo "1 Thu Jul 31 00:00:01 2026 next dev --port 3000"
    fi
    ;;
  "-o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p 12345")
    echo "12345 1 77777 1024 1.0 00:20 next dev --port 3000"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/devclean-recycle-shim/pgrep" "$T/devclean-recycle-shim/ps"
devclean_policy_fixture "$T/devclean-recycle-shim" 12345
IDENTITY_COUNT="$T/identity.count" BASH_ENV="$T/noop-signals.sh" \
  KILL_CALLS="$T/h30-kill.calls" PATH="$T/devclean-recycle-shim:$PATH" \
  HOME="$T/devclean-recycle-home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" \
  >"$T/devclean-recycle.out" 2>"$T/devclean-recycle.err"
RECYCLE_RC=$?
if [ "$RECYCLE_RC" -ne 1 ]; then
  fail "H30: recycled matching PID exit=$RECYCLE_RC, want 1"
elif ! grep -q 'not found with the reviewed identity' "$T/devclean-recycle.out"; then
  fail "H30: matching recycled PID was not rejected by stable identity"
elif [ -s "$T/h30-kill.calls" ]; then
  fail "H30: recycled matching PID was signaled"
else
  pass "H30: devclean compares stable PID identity before signaling"
fi

# ---------- H31: an artifact-named repository is never its own candidate ----------
mkdir -p "$T/artifact-scope/build"
git -C "$T/artifact-scope/build" init -q
printf 'repository data\n' > "$T/artifact-scope/build/important.txt"
HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" artifacts --clean --root "$T/artifact-scope/build" \
  >"$T/artifact-scope.out" 2>"$T/artifact-scope.err"
ARTIFACT_SCOPE_RC=$?
if [ "$ARTIFACT_SCOPE_RC" -ne 2 ]; then
  fail "H31: artifact-named repository exit=$ARTIFACT_SCOPE_RC"
elif [ ! -d "$T/artifact-scope/build/.git" ] || [ ! -f "$T/artifact-scope/build/important.txt" ]; then
  fail "H31: repository root named build was treated as an artifact"
else
  pass "H31: repository scope is never treated as an artifact candidate"
fi

# ---------- H32: audit rechecks protection before SIGKILL ----------
mkdir -p "$T/audit-escalation-shim"
cat > "$T/audit-escalation-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "41234 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-Ao pid="*) echo "41234" ;;
  "-Ao pid,ppid,pgid,%cpu,etime,command"*)
    echo "41234 1 77777 2.0 00:20 next dev --port 3000"
    ;;
  "-Ao pgid=,command="*)
    count=0
    [ ! -f "$PS_PROTECT_COUNT" ] || count="$(sed -n '1p' "$PS_PROTECT_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$PS_PROTECT_COUNT"
    if [ "$count" -ge 2 ]; then
      echo "77777 Codex"
    else
      echo "77777 next dev --port 3000"
    fi
    ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/audit-escalation-shim/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/audit-escalation-shim/ps" "$T/audit-escalation-shim/sleep"
PS_PROTECT_COUNT="$T/audit-protect.count" BASH_ENV="$T/noop-signals.sh" \
  KILL_CALLS="$T/h32-kill.calls" PATH="$T/audit-escalation-shim:$PATH" \
  HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/skills/afterparty/lib/audit-processes.sh" --kill dev --pgid 77777 \
  >"$T/audit-escalation.out" 2>"$T/audit-escalation.err"
AUDIT_ESCALATION_RC=$?
H32_TERM_CALLS="$(grep -c '^-TERM -77777$' "$T/h32-kill.calls" 2>/dev/null || true)"
if [ "$AUDIT_ESCALATION_RC" -ne 1 ]; then
  fail "H32: protected escalation exit=$AUDIT_ESCALATION_RC, want 1"
elif ! grep -q 'became protected before SIGKILL' "$T/audit-escalation.out"; then
  fail "H32: protection change before SIGKILL was not explained"
elif [ "${H32_TERM_CALLS:-0}" -ne 1 ] || grep -q '^-KILL ' "$T/h32-kill.calls"; then
  fail "H32: audit signaled a group after it became protected"
else
  pass "H32: audit rechecks group protection before every signal"
fi

# ---------- H33: ledger rechecks protection before SIGKILL ----------
mkdir -p "$T/ledger-escalation-shim"
cat > "$T/ledger-escalation-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,pgid=,lstart=,command="*) echo "12345 77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-Ao pgid=,lstart=,command="*) echo "77777 Tue Aug 18 09:00:00 2026 next dev --port 3000" ;;
  "-o pgid= -p 12345") echo "77777" ;;
  "-o pgid= -p "*) echo "99999" ;;
  "-o command= -p 12345") echo "next dev --port 3000" ;;
  "-p 12345") exit 0 ;;
  "-Ao pgid=,command="*)
    count=0
    [ ! -f "$PS_PROTECT_COUNT" ] || count="$(sed -n '1p' "$PS_PROTECT_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$PS_PROTECT_COUNT"
    if [ "$count" -ge 3 ]; then
      echo "77777 Codex"
    else
      echo "77777 next dev --port 3000"
    fi
    ;;
  "-Ao pgid="*) echo "77777" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/ledger-escalation-shim/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/ledger-escalation-shim/ps" "$T/ledger-escalation-shim/sleep"
printf '2026-07-31T00:00:00Z\t%s\t%s\t12345\t77777\tdev\t3000\ttest server\tnext dev\t%s\n' \
  "$LEDGER_ROOT" "$LEDGER_ROOT" "$(PATH="$T/ledger-escalation-shim:$PATH" fp_members_for_pgid 77777)" > "$T/escalation-ledger.tsv"
(cd "$T/repo-one" && PS_PROTECT_COUNT="$T/ledger-protect.count" \
  BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h33-kill.calls" \
  PATH="$T/ledger-escalation-shim:$PATH" HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  AGENT_PROCESS_LEDGER="$T/escalation-ledger.tsv" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" stop --kill >"$T/ledger-escalation.out" 2>"$T/ledger-escalation.err")
LEDGER_ESCALATION_RC=$?
H33_TERM_CALLS="$(grep -c '^-TERM -77777$' "$T/h33-kill.calls" 2>/dev/null || true)"
if [ "$LEDGER_ESCALATION_RC" -ne 1 ]; then
  fail "H33: protected ledger escalation exit=$LEDGER_ESCALATION_RC, want 1"
elif ! grep -q 'became protected before SIGKILL' "$T/ledger-escalation.out"; then
  fail "H33: ledger protection change before SIGKILL was not explained"
elif [ "${H33_TERM_CALLS:-0}" -ne 1 ] || grep -q '^-KILL ' "$T/h33-kill.calls"; then
  fail "H33: ledger signaled a group after it became protected"
else
  pass "H33: ledger rechecks group protection before every signal"
fi

# ---------- H34: cache targets cannot escape HOME through a symlink parent ----------
mkdir -p "$T/symlink-home/Documents" "$T/outside-gradle/caches"
dd if=/dev/zero of="$T/outside-gradle/caches/keep.bin" bs=1024 count=2048 2>/dev/null
if ln -s "$T/outside-gradle" "$T/symlink-home/.gradle" 2>/dev/null \
    && [ -L "$T/symlink-home/.gradle" ]; then
  PATH="$T/cap-shim:$PATH" HOME="$T/symlink-home" XDG_CACHE_HOME="$T/cache" \
    AFTERPARTY_STYLE=never reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --disk \
    --no-repo-artifacts --documents-root "$T/symlink-home/Documents" \
    >"$T/symlink-home.out" 2>"$T/symlink-home.err"
  SYMLINK_HOME_RC=$?
  if [ "$SYMLINK_HOME_RC" -ne 1 ]; then
    fail "H34: HOME symlink escape exit=$SYMLINK_HOME_RC, want 1"
  elif [ ! -f "$T/outside-gradle/caches/keep.bin" ]; then
    fail "H34: cache cleanup escaped HOME through a symlink parent"
  elif ! grep -q 'outside HOME' "$T/symlink-home.out"; then
    fail "H34: HOME symlink escape was not explained"
  else
    pass "H34: cache cleanup cannot escape HOME through symlink parents"
  fi
else
  pass "H34: symlink escape fixture unavailable here (covered by Linux CI)"
fi

# ---------- H35: PID exit confirmation fails closed when scanning fails ----------
mkdir -p "$T/devclean-confirm-shim" "$T/devclean-confirm-home"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/devclean-confirm-shim/pnpm"
chmod +x "$T/devclean-confirm-shim/pnpm"
cat > "$T/devclean-confirm-shim/pgrep" <<'SH'
#!/usr/bin/env bash
echo 12346
SH
cat > "$T/devclean-confirm-shim/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-p 12346") exit 0 ;;
  "-o rss= -p 12346") echo "1024" ;;
  "-o ppid=,lstart=,command= -p 12346") echo "1 Thu Jul 31 00:00:00 2026 next dev --port 3000" ;;
  "-o pid=,ppid=,pgid=,rss=,%cpu=,etime=,command= -p 12346")
    echo "12346 1 77777 1024 1.0 00:20 next dev --port 3000"
    ;;
  "-Ao pid=") exit 1 ;;
  *) exit 1 ;;
esac
SH
cat > "$T/devclean-confirm-shim/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/devclean-confirm-shim/pgrep" "$T/devclean-confirm-shim/ps" "$T/devclean-confirm-shim/sleep"
devclean_policy_fixture "$T/devclean-confirm-shim" 12346
BASH_ENV="$T/noop-signals.sh" KILL_CALLS="$T/h35-kill.calls" \
  PATH="$T/devclean-confirm-shim:$PATH" HOME="$T/devclean-confirm-home" \
  XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" \
  >"$T/devclean-confirm.out" 2>"$T/devclean-confirm.err"
CONFIRM_RC=$?
if [ "$CONFIRM_RC" -ne 1 ]; then
  fail "H35: unavailable PID confirmation exit=$CONFIRM_RC, want 1"
elif ! grep -q 'could not confirm pid 12346 exited' "$T/devclean-confirm.out"; then
  fail "H35: unavailable PID confirmation was not explained"
elif ! grep -q '"target":"pid:12346".*"status":"failed"' "$T/cache/agent-processes/actions.jsonl"; then
  fail "H35: unavailable PID confirmation was not journaled as failed"
elif grep -q '"target":"pid:12346".*"status":"succeeded"' "$T/cache/agent-processes/actions.jsonl"; then
  fail "H35: unavailable PID confirmation was journaled as success"
else
  pass "H35: PID receipts require an available confirmation scan"
fi

# ---------- H36: persisted reports never clobber an unrelated ignored file ----------
mkdir -p "$T/report-owner-repo"
git -C "$T/report-owner-repo" init -q
printf 'report.md\n' > "$T/report-owner-repo/.gitignore"
printf 'user-owned ignored report\n' > "$T/report-owner-repo/report.md"
REPORT_OWNER_PATH="$(cd "$T/report-owner-repo" && HOME="$T/home" XDG_CACHE_HOME="$T/cache" \
  bash "$REPO/bin/afterparty" report-path)"
(cd "$T/report-owner-repo" && PATH="$T/cap-shim:$PATH" HOME="$T/home" \
  XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" audit --report > "$T/report-owner.out" 2> "$T/report-owner.err")
REPORT_OWNER_RC=$?
if [ "$REPORT_OWNER_RC" -ne 1 ] || ! grep -q 'Status: incomplete' "$REPORT_OWNER_PATH"; then
  fail "H36: cache-fallback report exit=$REPORT_OWNER_RC"
elif [ "$REPORT_OWNER_PATH" = "$T/report-owner-repo/report.md" ]; then
  fail "H36: unrelated ignored report.md was selected as Afterparty state"
elif [ "$(cat "$T/report-owner-repo/report.md")" != 'user-owned ignored report' ]; then
  fail "H36: unrelated ignored report.md was overwritten"
elif [ ! -f "$REPORT_OWNER_PATH" ] || ! grep -q '^# afterparty report' "$REPORT_OWNER_PATH"; then
  fail "H36: fallback report was not persisted"
else
  pass "H36: persisted reports do not clobber unrelated ignored files"
fi

# ---------- H37: every artifact collector respects nested repositories ----------
mkdir -p "$T/nested-boundary/embedded/node_modules/.cache"
git -C "$T/nested-boundary" init -q
git -C "$T/nested-boundary/embedded" init -q
printf 'nested cache\n' > "$T/nested-boundary/embedded/node_modules/.cache/keep.txt"
printf 'nested compiler state\n' > "$T/nested-boundary/embedded/project.tsbuildinfo"
HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  bash "$REPO/bin/afterparty" artifacts --clean --root "$T/nested-boundary" \
  >"$T/nested-boundary.out" 2>"$T/nested-boundary.err"
NESTED_BOUNDARY_RC=$?
if [ "$NESTED_BOUNDARY_RC" -ne 2 ]; then
  fail "H37: nested-repository artifact scan exit=$NESTED_BOUNDARY_RC"
elif [ ! -f "$T/nested-boundary/embedded/node_modules/.cache/keep.txt" ] \
    || [ ! -f "$T/nested-boundary/embedded/project.tsbuildinfo" ]; then
  fail "H37: a direct artifact collector crossed a nested-repository boundary"
else
  pass "H37: every artifact collector respects nested repositories"
fi

# ---------- H38: optimize targets cannot escape HOME through symlink parents ----------
mkdir -p "$T/opt-symlink-home" "$T/outside-vscode" "$T/outside-crash/App/Crashpad/pending"
printf '{"enable-crash-reporter": true}\n' > "$T/outside-vscode/argv.json"
printf 'keep dump\n' > "$T/outside-crash/App/Crashpad/pending/keep.dmp"
CRASH_LINK_OK=0
if ln -s "$T/outside-vscode" "$T/opt-symlink-home/.vscode" 2>/dev/null \
    && [ -L "$T/opt-symlink-home/.vscode" ]; then
  case "$(uname -s)" in
    Darwin)
      mkdir -p "$T/opt-symlink-home/Library"
      if ln -s "$T/outside-crash" "$T/opt-symlink-home/Library/Application Support" 2>/dev/null \
          && [ -L "$T/opt-symlink-home/Library/Application Support" ]; then
        CRASH_LINK_OK=1
      fi
      ;;
    *)
      if ln -s "$T/outside-crash" "$T/opt-symlink-home/.config" 2>/dev/null \
          && [ -L "$T/opt-symlink-home/.config" ]; then
        CRASH_LINK_OK=1
      fi
      ;;
  esac
fi
if [ "$CRASH_LINK_OK" -eq 1 ]; then
  PATH="$T/cap-shim:$PATH" HOME="$T/opt-symlink-home" XDG_CACHE_HOME="$T/cache" \
    AFTERPARTY_STYLE=never reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --optimize \
    >"$T/opt-symlink.out" 2>"$T/opt-symlink.err"
  OPT_SYMLINK_RC=$?
  if [ "$OPT_SYMLINK_RC" -ne 1 ]; then
    fail "H38: optimize symlink escape exit=$OPT_SYMLINK_RC, want 1"
  elif ! grep -q '"enable-crash-reporter": true' "$T/outside-vscode/argv.json" \
      || [ ! -f "$T/outside-crash/App/Crashpad/pending/keep.dmp" ]; then
    fail "H38: optimize mutation escaped HOME through a symlink parent"
  elif ! grep -q 'settings path escapes HOME' "$T/opt-symlink.out" \
      || ! grep -q 'Crashpad directory outside HOME' "$T/opt-symlink.out"; then
    fail "H38: optimize symlink refusals were not explained"
  else
    pass "H38: optimize mutations cannot escape HOME through symlink parents"
  fi
else
  pass "H38: optimize symlink fixtures unavailable here (covered by Linux CI)"
fi

# ---------- H39: project scans reject ancestors of HOME by default ----------
mkdir -p "$T/broad-ancestor/home" "$T/broad-ancestor/sibling/project/build"
printf 'sibling data\n' > "$T/broad-ancestor/sibling/project/Makefile"
printf 'keep sibling build\n' > "$T/broad-ancestor/sibling/project/build/keep.txt"
PATH="$T/cap-shim:$PATH" HOME="$T/broad-ancestor/home" XDG_CACHE_HOME="$T/cache" \
  AFTERPARTY_STYLE=never reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --disk \
  --no-repo-artifacts --documents-root "$T/broad-ancestor" \
  >"$T/broad-ancestor.out" 2>"$T/broad-ancestor.err"
BROAD_ANCESTOR_RC=$?
if [ "$BROAD_ANCESTOR_RC" -ne 2 ]; then
  fail "H39: HOME-ancestor documents root exit=$BROAD_ANCESTOR_RC, want 2"
elif [ ! -f "$T/broad-ancestor/sibling/project/build/keep.txt" ]; then
  fail "H39: a HOME-ancestor scan reached a sibling project"
elif ! grep -q 'contains HOME' "$T/broad-ancestor.err"; then
  fail "H39: HOME-ancestor refusal was not explained"
else
  pass "H39: project scans reject ancestors of HOME by default"
fi

# ---------- H40: Crashpad receipts require a successful post-scan ----------
mkdir -p "$T/crash-confirm-home" "$T/crash-find-shim"
case "$(uname -s)" in
  Darwin) CRASH_CONFIRM_DIR="$T/crash-confirm-home/Library/Application Support/App/Crashpad/pending" ;;
  *) CRASH_CONFIRM_DIR="$T/crash-confirm-home/.config/App/Crashpad/pending" ;;
esac
mkdir -p "$CRASH_CONFIRM_DIR"
CRASH_CONFIRM_DIR="$(cd "$CRASH_CONFIRM_DIR" && pwd -P)"
printf 'delete candidate\n' > "$CRASH_CONFIRM_DIR/dump.dmp"
REAL_FIND="$(command -v find)"
cat > "$T/crash-find-shim/find" <<'SH'
#!/usr/bin/env bash
FIND_TARGET=""
if [ -d "${1:-}" ]; then
  FIND_TARGET="$(cd "$1" 2>/dev/null && pwd -P)" || FIND_TARGET=""
fi
if [ "$FIND_TARGET" = "$CRASHPAD_TARGET" ]; then
  for arg in "$@"; do
    if [ "$arg" = "-exec" ]; then printf 'deleted\n' > "$FIND_COUNT_STATE"; exec "$REAL_FIND" "$@"; fi
  done
  if [ ! -f "$FIND_COUNT_STATE" ]; then
    exec "$REAL_FIND" "$@"
  fi
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
chmod +x "$T/crash-find-shim/find"
CRASHPAD_TARGET="$CRASH_CONFIRM_DIR" FIND_COUNT_STATE="$T/crash-find.count" \
  REAL_FIND="$REAL_FIND" PATH="$T/crash-find-shim:$T/cap-shim:$PATH" \
  HOME="$T/crash-confirm-home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never \
  reviewed_devclean "$REPO/skills/afterparty/lib/devclean.sh" --optimize \
  >"$T/crash-confirm.out" 2>"$T/crash-confirm.err"
CRASH_CONFIRM_RC=$?
if [ "$CRASH_CONFIRM_RC" -ne 1 ]; then
  fail "H40: unavailable Crashpad post-scan exit=$CRASH_CONFIRM_RC, want 1"
elif ! grep -q 'could not confirm Crashpad cleanup' "$T/crash-confirm.out"; then
  fail "H40: unavailable Crashpad post-scan was not explained"
elif ! grep -F '"operation":"crash_dump.clean"' "$T/cache/agent-processes/actions.jsonl" \
    | grep -F '"status":"failed"' | grep -Fq "\"target\":\"$CRASH_CONFIRM_DIR\""; then
  fail "H40: unavailable Crashpad post-scan was not journaled as failed"
elif grep -F '"operation":"crash_dump.clean"' "$T/cache/agent-processes/actions.jsonl" \
    | grep -F '"status":"succeeded"' | grep -Fq "\"target\":\"$CRASH_CONFIRM_DIR\""; then
  fail "H40: unavailable Crashpad post-scan was journaled as success"
else
  pass "H40: Crashpad receipts require a successful postcondition scan"
fi

if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
