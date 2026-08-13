#!/usr/bin/env bash
# Category-classification tests using a fake ps/pgrep/lsof PATH shim.
# Companion to test-proc-tables.sh: that suite pins how rows are RENDERED,
# this one pins WHICH rows land in a category at all — the decision that
# `--kill <category>` acts on. DRY-RUN ONLY: the canned pids must never be
# signalled, so no --kill/--apply runs in here, ever.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

# ---------- PATH shim: canned process world ----------
# 770xx are agent runtimes, NOT dev servers. Their argv embeds a prompt
# document -- real `claude` sessions run past 20 KB of argv -- and ordinary
# English prose in it straddles an unanchored alternative: "bundle".."/dev",
# "turbocharge".."dev", "webpack".."observe", "deno task".."dev". Each pairs
# a `.*` alternative with words that legitimately occur in documentation.
# 771xx are the genuine dev servers those alternatives exist to catch.
# pgid 99999 is "our" shell's group.
SHIM="$T/shim"
mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
P='claude --settings /Users/x/.gc/settings.json [city]'
case "$*" in
  *pid,ppid,pgid,%cpu,etime,command*)
    printf '77001 1 77001 0.0 12-05:39:30 %s the bundle is easy to attach so each step writes via redirect > /dev/null\n' "$P"
    printf '77003 1 77003 0.0 12-05:39:30 %s turbocharge the refinery loop before the agent reaches /dev/null\n' "$P"
    printf '77004 1 77004 0.0 12-05:39:30 %s unwrap the webpack of context and observe what the polecat did\n' "$P"
    printf '77005 1 77005 0.0 12-05:39:30 %s deno task notes live beside the dev journal\n' "$P"
    printf '77101 1 77101 0.0 00:11:22 npm run dev\n'
    printf '77102 1 77102 0.0 00:11:22 bun run dev\n'
    printf '77103 1 77103 0.0 00:11:22 turbo run dev --filter=web\n'
    printf '77104 1 77104 0.0 00:11:22 node_modules/.bin/webpack serve\n'
    printf '77105 1 77105 0.0 00:11:22 deno task dev\n'
    ;;
  *-o\ pid=,ppid=,pgid=,rss=,%cpu=,etime=,command=*)
    printf '77001 1 77001 524288 0.0 12-05:39:30 %s\n' "$P" ;;
  *-o\ rss=*) printf '524288\n' ;;
  *-Ao\ pgid=,command=*) printf '99999 -zsh\n' ;;
  *-o\ pgid=*-p*|*-o\ pgid=\ -p*) printf '99999\n' ;;
  *-Ao\ pgid=*) printf '99999\n' ;;
  *-Ao\ pid=*) exit 0 ;;
  *-p\ 77*) exit 0 ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/pgrep" <<'PG'
#!/usr/bin/env bash
exit 1
PG
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
exit 1
LS
chmod +x "$SHIM/ps" "$SHIM/pgrep" "$SHIM/lsof"
export PATH="$SHIM:$PATH"

# Print only the body of the "=== <title> ... ===" section named by $1.
section() {
  awk -v want="$1" '
    /^=== / { inside = (index($0, want) > 0); next }
    inside  { print }
  '
}

OUT="$(AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" 2>/dev/null)"
DEV="$(printf '%s\n' "$OUT" | section 'Dev servers')"

# ---------- C1: prompt prose never classifies an agent as a dev server ----------
# Each row fails while its DEV_RE alternative leaves `.*` unbounded: the match
# spans ~40 chars of prose here and >1.8 KB in the wild, so `audit --kill dev`
# is offered a live agent session to SIGTERM.
while read -r pid trap_desc; do
  if printf '%s\n' "$DEV" | grep -q "$pid"; then
    fail "C1/$pid: agent runtime classified as a dev server (prose: $trap_desc)"
  else
    pass "C1/$pid: prose \"$trap_desc\" does not classify as a dev server"
  fi
done <<'TRAPS'
77001 bundle..dev
77003 turbocharge..dev
77004 webpack..observe
77005 deno-task..dev
TRAPS

# ---------- C2: genuine dev servers still classified ----------
# Positive controls. Guard the C1 fix against over-correcting by gutting the
# alternatives it tightens -- these are what the dev category exists to catch.
while read -r pid cmd_desc; do
  if printf '%s\n' "$DEV" | grep -q "$pid"; then
    pass "C2/$pid: \"$cmd_desc\" still classified as a dev server"
  else
    fail "C2/$pid: genuine dev server \"$cmd_desc\" lost from the dev category"
  fi
done <<'REAL'
77101 npm-run-dev
77102 bun-run-dev
77103 turbo-run-dev
77104 webpack-serve
77105 deno-task-dev
REAL

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
