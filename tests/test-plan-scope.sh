#!/usr/bin/env bash
# Plans communicate exactly which workspace/group a person is approving.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_TRANSCRIPT_ROOT="$T/transcripts"
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
  *pid,pgid,%cpu,command*) printf '9001 9001 0 npm run dev --token private-value\n9002 9002 0 npm run dev\n' ;;
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
