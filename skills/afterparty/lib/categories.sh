# shellcheck shell=bash
# Classify executable/subcommand positions, never arbitrary argv prose or URLs.
# ps presents text rather than an argv array; ambiguous shell -c programs are
# deliberately unclassified. Their actual server/test children are observable.
cat_for_command() {
  local cmd="$1" depth="${2:-0}" exe script arg IFS=$' \t\n'
  [ "$depth" -lt 5 ] || return 1
  case "$cmd" in
    /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome\ *|/Applications/Chromium.app/Contents/MacOS/Chromium\ *)
      case "$cmd" in *\ --remote-debugging-port*) printf browser; return 0 ;; esac ;;
  esac
  # Disable globbing in the subshell; commands containing * remain literal.
  # shellcheck disable=SC2086
  set -f; set -- $cmd; set +f
  [ "$#" -gt 0 ] || return 1
  exe="${1##*/}"; exe="${exe%.exe}"; shift
  case "${cmd%%[[:space:]]*}" in
    /*/ms-playwright/*|/*/puppeteer/*)
      case "$exe" in chrome|chromium|Chromium|headless_shell|firefox) printf browser; return 0 ;; esac ;;
  esac
  case "$exe" in
    env)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          *=*|-i|--ignore-environment|--unset=*) shift ;;
          -u|--unset) [ "$#" -ge 2 ] || return 1; shift 2 ;;
          --) shift; break ;;
          -*) return 1 ;;
          *) break ;;
        esac
      done
      cat_for_command "$*" "$((depth + 1))"; return $? ;;
    node|nodejs|python|python2|python3|python2.*|python3.*|bash|sh|zsh)
      while [ "$#" -gt 0 ]; do
        case "$exe:$1" in bash:-*c*|sh:-*c*|zsh:-*c*) return 1 ;; esac
        case "$1" in
          -c|-e|--eval|--print) return 1 ;;
          -m) shift; break ;;
          -r|--require|--import) [ "$#" -ge 2 ] || return 1; shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [ "$#" -gt 0 ] || return 1
      script="${1##*/}"; script="${script%.js}"; script="${script%.mjs}"; script="${script%.cjs}"; shift
      cat_for_command "$script $*" "$((depth + 1))"; return $? ;;
    npx|bunx)
      while [ "$#" -gt 0 ]; do case "$1" in --yes|-y|--no-install) shift ;; -*) return 1 ;; *) break ;; esac; done
      cat_for_command "$*" "$((depth + 1))"; return $? ;;
    npm|pnpm|yarn|bun)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --filter|-F|--cwd|--prefix) [ "$#" -ge 2 ] || return 1; shift 2 ;;
          --watch|--hot|--silent) shift ;;
          *) break ;;
        esac
      done
      case "${1:-}" in exec|dlx) shift; cat_for_command "$*" "$((depth + 1))"; return $? ;; run) shift ;; esac
      case "${1:-}" in test|test:*|tests) printf tests; return 0 ;; dev|dev:*|start|start:*) printf dev; return 0 ;; esac
      if [ "$exe" = yarn ]; then cat_for_command "$*" "$((depth + 1))"; return $?; fi ;;
    vitest|jest|mocha|jasmine|ava|pytest) printf tests; return 0 ;;
    vite|nodemon|webpack-dev-server|uvicorn|http.server) printf dev; return 0 ;;
    next) case "${1:-}" in dev|start) printf dev; return 0 ;; esac ;;
    astro|fastapi) [ "${1:-}" = dev ] && { printf dev; return 0; } ;;
    webpack|ng) [ "${1:-}" = serve ] && { printf dev; return 0; } ;;
    rails) [ "${1:-}" = server ] && { printf dev; return 0; } ;;
    flask) [ "${1:-}" = run ] && { printf dev; return 0; } ;;
    remix) [ "${1:-}" = vite ] && { printf dev; return 0; } ;;
    deno) [ "${1:-}" = task ] && { case "${2:-}" in dev|dev:*|*:dev) printf dev; return 0 ;; esac; } ;;
    turbo)
      for arg in "$@"; do case "$arg" in run|watch|-*) : ;; dev) printf dev; return 0 ;; *) break ;; esac; done ;;
    headless_shell) printf browser; return 0 ;;
    chrome|chromium|Chromium|Google\ Chrome|firefox)
      case " $* " in *\ --remote-debugging-port*|*\ --headless*) printf browser; return 0 ;; esac ;;
  esac
  return 1
}
