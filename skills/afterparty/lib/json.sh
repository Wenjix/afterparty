# shellcheck shell=bash
# json.sh - shared JSON Lines helpers, sourced (not executed) by the lib
# scripts that support --json: audit-git.sh, audit-processes.sh,
# process-ledger.sh. Pure Bash, no jq. Each finding is one compact object
# per line (JSON Lines) so the router's sequential script calls compose into
# one valid stream with no assembly step.
#
# Fidelity note: control characters in values (tabs, CRs, embedded newlines)
# are flattened to spaces rather than escaped — keeps every row single-line
# and the escaping obviously correct. Keys are trusted literals and are never
# escaped; values go through json_escape.

# Escape a string for use inside a JSON double-quoted value. Bash parameter
# expansion keeps this hot path fast on Git Bash, where spawning tr/sed for
# every field is disproportionately expensive.
json_escape() {
  local value="${1-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# "key":"value" (empty string allowed).
json_kv() { printf '"%s":"%s"' "$1" "$(json_escape "${2-}")"; }

# "key":"value", or "key":null when the value is empty.
json_kvz() {
  if [ -n "${2:-}" ]; then json_kv "$1" "$2"; else printf '"%s":null' "$1"; fi
}

# "key":<number>, or "key":null when the value is not a whole number.
json_kvn() {
  case "${2-}" in
    ''|*[!0-9]*) printf '"%s":null' "$1" ;;
    *) local number="$2"
       while [ "${#number}" -gt 1 ] && [ "${number#0}" != "$number" ]; do number="${number#0}"; done
       printf '"%s":%s' "$1" "$number" ;;
  esac
}

# "key":true/false (accepts 1/0/true/false), or "key":null otherwise.
json_kvb() {
  case "${2-}" in
    1|true) printf '"%s":true' "$1" ;;
    0|false) printf '"%s":false' "$1" ;;
    *) printf '"%s":null' "$1" ;;
  esac
}

# Join "key":value pairs into one object line. A pair argument may itself
# contain commas (e.g. an "applied"+"error" pair) — it is passed through as-is.
json_row() {
  local IFS=','
  if [ "$#" -gt 0 ]; then
    printf '{"schema_version":1,%s}\n' "$*"
  else
    printf '{"schema_version":1}\n'
  fi
}
