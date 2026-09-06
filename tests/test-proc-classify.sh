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
# document -- real agent sessions run past 20 KB of argv -- and ordinary
# English prose in it straddles an unanchored alternative: "bundle".."/dev",
# "turbocharge".."dev", "webpack".."observe", "deno task".."dev". Each pairs
# a `.*` alternative with words that legitimately occur in documentation.
# 771xx are the genuine dev servers those alternatives exist to catch.
# pgid 99999 is "our" shell's group.
#
# The fixture runtime is deliberately NOT named `claude`. The Dev servers
# listing filters PROTECT_RE before it prints, so a protected name would be
# stripped from the section whatever DEV_RE did, and C1 would keep passing
# with the greedy patterns fully restored -- asserting nothing. C0 below
# pins that choice so the masking cannot creep back in; `claude` itself is
# covered by C3.
SHIM="$T/shim"
mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
P='agentd --settings /Users/x/.gc/settings.json [city]'
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
    printf '77106 1 77106 0.0 00:11:22 bun --watch run dev\n'
    printf '77107 1 77107 0.0 00:11:22 turbo watch dev\n'
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

# ---------- C0: the fixture runtime must not be protect-listed ----------
# C1 reads the rendered Dev servers section, and that listing filters
# PROTECT_RE before it prints. So if the fixture command is ever protected,
# every C1 case passes without testing anything -- which is exactly what
# happened when the fixture was named `claude` and the protect entry landed
# a commit later: the greedy patterns could be restored wholesale and C1
# stayed green. Fail loudly here rather than silently asserting nothing.
. "$LIB/protect.sh"
protected() { printf '%s\n' "$1" | grep -Eiq -- "$PROTECT_RE"; }
FIXTURE='agentd --settings /Users/x/.gc/settings.json [city] the bundle is easy'
if protected "$FIXTURE"; then
  fail "C0: fixture runtime is protect-listed -- every C1 case below is vacuous"
else
  pass "C0: fixture runtime is not protect-listed (C1 assertions are live)"
fi

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
# The last two are the forms the first tightening pass lost: bounding the gap
# to an optional literal " run" dropped `bun --watch run dev` and Turborepo
# 2.x's `turbo watch dev`, so the gap now admits flags and subcommands but
# still never spans a bare prose word.
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
77106 bun---watch-run-dev
77107 turbo-watch-dev
REAL

# ---------- C3: agent runtimes are protected, their spawned servers are not ----------
# Defence in depth behind C1: if a future pattern misclassifies a live agent
# session, the protect list is the last thing between it and a SIGTERM.
# The entry must anchor on the executable. A bare "claude" would also match
# the ".claude/shell-snapshots/..." path that Claude Code puts in the argv of
# every shell it spawns, so the wrapper sharing a dev server's process group
# would test as protected and pgid_has_protected would make real dev servers
# permanently unkillable -- silently gutting the tool's main job.
while IFS='|' read -r want desc cmd; do
  if protected "$cmd"; then got=protected; else got=killable; fi
  if [ "$got" = "$want" ]; then
    pass "C3: $desc is $want"
  else
    fail "C3: $desc is $got, want $want"
  fi
done <<'CASES'
protected|bare agent session|claude --dangerously-skip-permissions --effort max
protected|agent invoked by absolute path|/Users/x/.local/bin/claude --output-format stream-json
killable|dev-server wrapper carrying a .claude path|/bin/zsh -c source /Users/x/.claude/shell-snapshots/snap.sh && npm run dev
killable|plain dev server|npm run dev
killable|agent-owned path but not the executable|node /Users/x/.claude/plugins/marketplaces/afterparty/tools/server.mjs
CASES

# ---------- C4/C5: every category, not just dev ----------
# DEV_RE was anchored in 0.6.1 after prose in a 20 KB agent argv classified a
# live session as a dev server. TESTS_RE and BROWSER_RE were left as they were,
# and this suite only ever exercised dev -- which is precisely why nobody
# noticed. cat_for_command is tested directly here: it is the function both the
# audit listing and plan's eligibility gate resolve categories with.
. "$LIB/categories.sh"

while IFS='|' read -r want desc cmd; do
  got="$(cat_for_command "$cmd" 2>/dev/null || printf 'none')"
  if [ "$got" = "$want" ]; then
    pass "C4: $desc -> $want"
  else
    fail "C4: $desc -> '$got', want '$want'"
  fi
done <<'CASES'
tests|a real vitest runner by path|node /repo/node_modules/.bin/vitest --watch
tests|pytest invoked directly|pytest tests/unit
tests|pytest invoked as a module|python -m pytest tests/unit
none|a clone URL is not a dev-server executable|git clone https://github.com/encode/uvicorn.git
none|an absolute executable with a browser-cache argument is not a browser|/usr/bin/git clone /Users/u/ms-playwright/chrome
none|prompt prose is not an npm command|agentd please run npm run dev for me
none|combined shell command flags remain ambiguous|bash -lc next dev
tests|jest via npx|npx jest --runInBand
tests|the npm test script|npm test
tests|ava by path|/repo/node_modules/.bin/ava
none|a JVM is not a test runner|java -jar idea.jar
none|a JVM with heap flags|/usr/bin/java -Xmx4g -jar gradle-daemon.jar
none|prose naming pytest in an agent prompt|claude --effort max [city] remember to run pytest before pushing
none|prose naming jest in an agent prompt|claude [city] the jest suite is flaky, investigate it
none|prose naming mocha and jasmine|claude [city] mocha and jasmine are both configured here
CASES

while IFS='|' read -r want desc cmd; do
  got="$(cat_for_command "$cmd" 2>/dev/null || printf 'none')"
  if [ "$got" = "$want" ]; then
    pass "C5: $desc -> $want"
  else
    fail "C5: $desc -> '$got', want '$want'"
  fi
done <<'CASES'
browser|chrome under remote debugging|/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222
browser|a playwright-managed browser|/Users/x/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium --headless
none|an MCP bridge is not an automation browser|node /x/node_modules/mcp-chrome/dist/index.js
none|prose naming playwright and chromium|claude [city] use playwright to test chromium rendering later
none|prose naming puppeteer|claude [city] the Google Chrome profile needs puppeteer removed
CASES

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
