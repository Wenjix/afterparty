# shellcheck shell=bash
# A private side channel alongside the canonical Markdown. Identity comes from
# collector variables, never from display text. NUL framing permits empty fields
# without the IFS-whitespace ambiguity of TSV.
plan_capture_init() {
  PLAN_CAPTURE="$1"
  mkdir -p "$PLAN_CAPTURE/items" "$PLAN_CAPTURE/capabilities" || return 1
  PLAN_DOCUMENT="$PLAN_CAPTURE/document"
  : > "$PLAN_DOCUMENT"
  PLAN_ITEM_COUNT=0
}

plan_record() { # type target scope fingerprint availability code reason consequence
  [ -n "${PLAN_CAPTURE:-}" ] || return 0
  PLAN_ITEM_COUNT=$((PLAN_ITEM_COUNT + 1))
  PLAN_ITEM="$PLAN_CAPTURE/items/$PLAN_ITEM_COUNT"
  printf '%s\0' "$(($(wc -l < "$PLAN_DOCUMENT") + 1))" "$@" > "$PLAN_ITEM"
  : > "$PLAN_ITEM.evidence"
}

plan_evidence() { # key value pairs; text has already passed display redaction
  [ -n "${PLAN_CAPTURE:-}" ] || return 0
  printf '%s\0' "$@" >> "$PLAN_ITEM.evidence"
}

plan_capability() { # name types status reason
  [ -n "${PLAN_CAPTURE:-}" ] || return 0
  printf '%s\0' "$@" > "$PLAN_CAPTURE/capabilities/$1"
}

plan_process_record() { # availability reason-code reason
  plan_record process-group "$pg" "$owner" "${fp:-}" "$1" "$2" "$3" \
    "Stop every member of PGID $pg. Afterparty sends TERM, then KILL if needed. Restart services manually."
  [ -n "${PLAN_CAPTURE:-}" ] || return 0
  local observed_cpu="$cpu"
  [ "$observed_cpu" != "-" ] || observed_cpu=""
  plan_evidence cpu_max "$observed_cpu" touched "$touched" observed_epoch "$NOW" category "${category:-}" \
    workspace "$owner" \
    sources "$(awk -F'\t' -v w="$owner" 'length($2)==length(w) && index($2,w)==1 {print $3}' "$T/ws-sources")" \
    members "$(awk -F'\t' -v pg="$pg" '$2==pg {print $1 "\t" $4}' "$T/ps" | privacy_redact)" \
    ports "$(awk -F'\t' -v pg="$pg" 'NR==FNR {if ($2==pg) p[$1]=1; next} $1 in p {print $2}' "$T/ps" "$T/ports")" \
    ports_status "$PORT_STATUS"
}

plan_worktree_record() { # availability reason-code reason
  plan_record worktree "$wtpath" "$repo" "${fp:-}" "$1" "$2" "$3" \
    'Delete this directory and its rebuildable ignored output. Other local data prevents removal.'
  plan_evidence branch "$branch" touched "$touched" observed_epoch "$NOW"
  [ -n "${PLAN_CAPTURE:-}" ] || return 0
  plan_evidence sources "$(awk -F'\t' -v w="$wtpath" -v r="$repo" '
    length($2)==length(w) && index($2,w)==1 {own=$3}
    length($2)==length(r) && index($2,r)==1 {parent=$3}
    END {print (own != "" ? own : parent)}' "$T/ws-sources")"
}
