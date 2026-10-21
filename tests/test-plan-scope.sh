#!/usr/bin/env bash
# Plans communicate exactly which workspace/group a person is approving.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_TRANSCRIPT_ROOT="$T/transcripts"
unset PLAN_CPU_9001 PLAN_CPU_9002
mkdir -p "$HOME" "$T/shim" "$T/transcripts/one" "$T/transcripts/two"
git init -qb main "$T/one"; git init -qb main "$T/two"
export SCOPE_ONE="$(cd "$T/one" && pwd -P)" SCOPE_TWO="$(cd "$T/two" && pwd -P)"
printf '{"cwd":"%s"}\n' "$SCOPE_ONE" > "$T/transcripts/one/session.jsonl"
printf '{"cwd":"%s"}\n' "$SCOPE_TWO" > "$T/transcripts/two/session.jsonl"
touch -t 202001010000 "$T/transcripts/one/session.jsonl" "$T/transcripts/two/session.jsonl"
cat > "$T/shim/ps" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *pgid=,command=*) printf '9001 npm run dev\n9002 npm run dev\n' ;;
  *pgid=,lstart=,command=*) printf '9001 Tue Aug 18 09:00:00 2026 npm run dev\n9002 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu,command*) printf '9001 9001 %s npm run dev --token private-value\n9002 9002 %s npm run dev\n' "${PLAN_CPU_9001:-0}" "${PLAN_CPU_9002:-0}" ;;
  *) exit 1 ;;
esac
SHIM
cat > "$T/shim/lsof" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*) printf 'p9001\nfcwd\nn%s\np9002\nfcwd\nn%s\n' "$SCOPE_ONE" "$SCOPE_TWO" ;;
  *) printf 'p9001\nn127.0.0.1:3000\np9002\nn127.0.0.1:3001\n' ;;
esac
SHIM
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH" AFTERPARTY_STYLE=never
cd "$SCOPE_ONE"
bash "$REPO/skills/afterparty/lib/plan.sh" > "$T/local"
grep -q -- '^- \[ \] eligible.*pgid 9001' "$T/local"
! grep -q 'pgid 9002' "$T/local"
! grep -q -- '^- \[x\]' "$T/local"
grep -q 'member 9001: npm run dev' "$T/local"
grep -q 'listening ports: 3000' "$T/local"
grep -q 'consequence: stop every member' "$T/local"
grep -q 'cpu 0.0' "$T/local"
! grep -q private-value "$T/local"
echo 'ok: SC1: current-repository plans are unchecked and expose scope, members, ports and consequences without common secrets'
bash "$REPO/skills/afterparty/lib/plan.sh" --all > "$T/all"
grep -q -- '^- \[ \] eligible.*pgid 9001' "$T/all"
grep -q -- '^- \[ \] eligible.*pgid 9002' "$T/all"
grep -q 'machine-wide' "$T/all"
bash "$REPO/skills/afterparty/lib/plan.sh" --root "$SCOPE_TWO" > "$T/other"
grep -q -- '^- \[ \] eligible.*pgid 9002' "$T/other"
! grep -q 'pgid 9001' "$T/other"
echo 'ok: SC2: explicit --all and --root change the reviewed process scope'

PLAN_CPU_9002=NaN bash "$REPO/skills/afterparty/lib/plan.sh" > "$T/local-invalid"
grep -q -- '^- \[ \] eligible.*pgid 9001' "$T/local-invalid"
! grep -q 'pgid 9002' "$T/local-invalid"
PLAN_CPU_9002=NaN bash "$REPO/skills/afterparty/lib/plan.sh" --json > "$T/local-invalid.json"
grep -q '"collection_status":"complete"' "$T/local-invalid.json"
grep -q '"name":"processes".*"status":"complete"' "$T/local-invalid.json"
! grep -q '"name":"processes".*"status":"unavailable"' "$T/local-invalid.json"
set +e
PLAN_CPU_9002=NaN bash "$REPO/skills/afterparty/lib/plan.sh" --all --json > "$T/all-invalid.json"
all_invalid_rc=$?
set -e
[ "$all_invalid_rc" -eq 1 ]
PLAN_CPU_9002=NaN bash "$REPO/skills/afterparty/lib/plan.sh" --all > "$T/all-invalid"
grep -q -- '^- \[⊘\] cpu-unavailable pgid 9002' "$T/all-invalid"
grep -q '"collection_status":"incomplete"' "$T/all-invalid.json"
grep -q '"name":"processes".*"status":"unavailable"' "$T/all-invalid.json"
echo 'ok: SC3: out-of-scope invalid CPU does not spoil local plans, while machine-wide plans report it'

AFTERPARTY_BUSY_CPU=20 PLAN_CPU_9001=20.04 bash "$REPO/skills/afterparty/lib/plan.sh" > "$T/rounding-over"
grep -qE '^- \[⊘\] working *pgid 9001 .*cpu 20.0$' "$T/rounding-over"
grep -A1 -E 'working *pgid 9001' "$T/rounding-over" | grep -Fq 'not offered: CPU use (20.0) exceeds the limit.'
! grep -qE '^- \[ \] eligible.*pgid 9001' "$T/rounding-over"
AFTERPARTY_BUSY_CPU=20 PLAN_CPU_9001=20.04 bash "$REPO/skills/afterparty/lib/plan.sh" --json > "$T/rounding-over.json"
grep -q '"cpu_max":20.04.*"target":"9001"' "$T/rounding-over.json"
AFTERPARTY_BUSY_CPU=20 PLAN_CPU_9001=20.0 bash "$REPO/skills/afterparty/lib/plan.sh" > "$T/rounding-at"
grep -q -- '^- \[ \] eligible.*pgid 9001' "$T/rounding-at"
echo 'ok: SC4: raw CPU drives eligibility and snapshots while displays stay rounded'
