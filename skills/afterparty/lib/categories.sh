# shellcheck shell=bash
# categories.sh - the kill categories, sourced (not executed) by
# audit-processes.sh and plan.sh so both use one definition, the same way
# protect.sh is shared.
#
# Alternatives never span a space with `.*`: an agent runtime carries its whole
# prompt in argv (>20 KB), so an unbounded gap lets ordinary prose ("bundle"
# ... "/dev") classify a live session as a dev server. See tests/test-proc-classify.sh.
TESTS_RE='vitest|jest|mocha|jasmine|ava |pytest|pnpm test|npm test|yarn test|vitest run|pnpm exec vitest'
DEV_RE='next dev|next start|nodemon|astro dev|remix vite|vite($| )|webpack[^ ]* serve|webpack-dev-server|turbo( (run|watch|--?[a-z][a-z0-9-]*))* dev|pnpm dev|pnpm start|npm run dev|npm run start|yarn dev|bun( (run|--?[a-z][a-z0-9-]*))* dev|deno task [a-z0-9:._-]*dev|ng serve|rails server|flask run|fastapi dev|uvicorn|python -m http.server'
BROWSER_RE='(Google Chrome|Chromium|Chrome Helper|headless_shell).*(remote-debugging|ms-playwright|mcp-chrome|puppeteer)|playwright.*(chromium|firefox|webkit)'

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
