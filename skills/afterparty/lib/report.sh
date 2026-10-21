# shellcheck shell=bash
# Durable report identity and lifecycle reminders. Sourced by the router.
. "$DIR/privacy.sh"

report_session_id() {
  local session="${AFTERPARTY_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  case "$session" in ''|*[!a-zA-Z0-9_-]*) session="manual-$(date +%s)-$$" ;; esac
  printf '%.128s' "$session"
}

report_cache_dir() {
  printf '%s/reports/%s' "$(state_cache_root)" "$(state_workspace_key "$PWD")"
}

report_meta() {
  sed -n "s/^<!-- afterparty $2=\(.*\) -->$/\1/p" "$1" | head -1
}

# The archive is immutable per invocation. The canonical path is only the
# latest completed write, never evidence of which concurrent session ended.
report_persist() {
  local body="$1" rc="$2" failed="$3" dest cache tmp archive session epoch stamp status
  dest="$(state_report_path "$PWD")" || return 1
  cache="$(report_cache_dir)" || return 1
  state_secure_dir "$cache/sessions" || return 1
  case "$dest" in "$cache"/*) state_secure_dir "${dest%/*}" || return 1 ;; esac
  session="$(report_session_id)"; epoch="$(date +%s)"; stamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  status=complete; [ "$rc" -eq 0 ] || status=incomplete
  tmp="$(mktemp "${dest%/*}/.report.md.XXXXXX")" || return 1
  archive="$cache/sessions/$session-$epoch-$$.md"
  if ! {
    printf '# afterparty report — what the last session left behind\n\n'
    printf '<!-- afterparty generated_epoch=%s -->\n' "$epoch"
    printf '<!-- afterparty session_id=%s -->\n' "$session"
    printf '<!-- afterparty status=%s -->\n' "$status"
    printf '<!-- afterparty failed_sections=%s -->\n' "${failed:-none}"
    printf 'generated %s — afterparty audit --report\n\n' "$stamp"
    printf 'Status: %s. Session: %s. Failed sections: %s.\n\n' "$status" "$session" "${failed:-none}"
    printf 'Session snapshot: %s\n\n' "$archive"
    privacy_redact < "$body"
  } > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! cp "$tmp" "$archive" || ! chmod 600 "$archive" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"; return 1
  fi
  printf 'note: writing audit report to %s\n' "$dest" >&2
  cat "$archive"
}

report_remind() {
  local path="$1" epoch status session age now marker
  if [ -f "$path" ]; then
    epoch="$(report_meta "$path" generated_epoch)"
    status="$(report_meta "$path" status)"; session="$(report_meta "$path" session_id)"
    now="$(date +%s)"; age=unknown
    case "$epoch" in ''|*[!0-9]*) ;; *) age="$(( (now - epoch) / 60 )) minutes" ;; esac
    printf 'Afterparty: last explicit audit is %s (%s old; session %s): %s. Check its scope before you start another service.\n' \
      "${status:-unknown}" "$age" "${session:-unknown}" "$path"
  fi
  marker="$(report_cache_dir)/session-ended.md"
  if [ -f "$marker" ]; then cat "$marker"; fi
  local docs_dir summary
  docs_dir="$(state_docs_dir "$PWD")" || return 1
  for summary in "$docs_dir/scan-summary.txt" "$docs_dir/review-summary.txt"; do
    [ ! -f "$summary" ] || cat "$summary"
  done
}

report_session_end() {
  local input session cache tmp stamp archive
  # Hook input contains a UUID. Only this field is retained, never transcript
  # content. This path performs no process/filesystem audit or cleanup.
  input="$(cat)"
  session="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_-]*\)".*/\1/p')"
  [ -z "$session" ] || AFTERPARTY_SESSION_ID="$session"
  session="$(report_session_id)"; stamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cache="$(report_cache_dir)" || return 1
  state_secure_dir "$cache/sessions" || return 1
  tmp="$(mktemp "$cache/.session-ended.XXXXXX")" || return 1
  printf 'Afterparty: session %s ended at %s. Afterparty did not run an audit at session end. Run afterparty audit --report for current information.\n' "$session" "$stamp" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  archive="$cache/sessions/$session-ended-$(date +%s)-$$.md"
  if ! cp "$tmp" "$archive" || ! chmod 600 "$archive" || ! mv -f "$tmp" "$cache/session-ended.md"; then
    rm -f "$tmp"; return 1
  fi
}
