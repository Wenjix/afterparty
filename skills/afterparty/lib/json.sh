# json.sh - shared JSON Lines helpers, sourced (not executed) by the lib
# scripts that support --json: audit-git.sh, audit-processes.sh,
# process-ledger.sh. Pure tr/sed, no jq. Each finding is one compact object
# per line (JSON Lines) so the router's sequential script calls compose into
# one valid stream with no assembly step.
#
# Fidelity note: control characters in values (tabs, CRs, embedded newlines)
# are flattened to spaces rather than escaped — keeps every row single-line
# and the escaping obviously correct. Keys are trusted literals and are never
# escaped; values go through json_escape.

# Escape a string for use inside a JSON double-quoted value.
json_escape() {
  printf '%s' "${1-}" \
    | tr '\t\r\n' '   ' \
    | tr -d '\000-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
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
    *) printf '"%s":%s' "$1" "$2" ;;
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
json_row() { local IFS=','; printf '{%s}\n' "$*"; }
