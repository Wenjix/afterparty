# shellcheck shell=bash
# categories.sh - the kill categories, sourced (not executed) by
# audit-processes.sh and plan.sh so both use one definition, the same way
# protect.sh is shared.
#
# Two rules, both learned the hard way, and both pinned by tests/test-proc-classify.sh.
#
# 1. No alternative may span a space with `.*`. An agent runtime carries its
#    whole prompt in argv (>20 KB), so an unbounded gap lets ordinary prose
#    ("bundle" ... "/dev") classify a live session as a dev server.
#
# 2. A bare tool name must be anchored to command position -- start of string or
#    after a "/" -- never to a space. Prose says " the jest suite is flaky" with
#    spaces on both sides exactly as a command would, so a space anchor cannot
#    tell them apart. `ava ` unanchored matched the substring in `java `, which
#    made `audit --kill tests` SIGKILL any JVM: a JetBrains IDE, a Gradle
#    daemon, a Kafka broker. Nothing in PROTECT_RE covers those.
#
# Agent sessions survive misclassification because PROTECT_RE covers them, so
# for those this is a reporting bug. For a JVM there is no such backstop.
TESTS_RE='(^|/)(vitest|jest|mocha|jasmine|ava|pytest)([[:space:]]|$)|(npx|bunx|pnpm exec|pnpm dlx|yarn|node) (vitest|jest|mocha|jasmine|ava|pytest)|(npm|pnpm|yarn|bun) (run )?test'
DEV_RE='next dev|next start|nodemon|astro dev|remix vite|vite($| )|webpack[^ ]* serve|webpack-dev-server|turbo( (run|watch|--?[a-z][a-z0-9-]*))* dev|pnpm dev|pnpm start|npm run dev|npm run start|yarn dev|bun( (run|--?[a-z][a-z0-9-]*))* dev|deno task [a-z0-9:._-]*dev|ng serve|rails server|flask run|fastapi dev|uvicorn|python -m http.server'
BROWSER_RE='--remote-debugging-port|/ms-playwright/|mcp-chrome|/puppeteer/|(^|/)headless_shell([[:space:]]|$)'

# Category a command belongs to, or empty. Order matters: tests before dev, so
# "npm test" does not read as a dev server. Empty means afterparty has no
# safe kill discipline for it, and callers must not offer it for cleanup.
cat_for_command() {
  local cmd="$1"
  if printf '%s\n' "$cmd" | grep -Eiq -- "$TESTS_RE"; then printf 'tests'; return 0; fi
  if printf '%s\n' "$cmd" | grep -Eiq -- "$DEV_RE"; then printf 'dev'; return 0; fi
  if printf '%s\n' "$cmd" | grep -Eiq -- "$BROWSER_RE"; then printf 'browser'; return 0; fi
  return 1
}
