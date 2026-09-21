#!/usr/bin/env bash
# audit-processes.sh — report visible test/watch runners, dev servers and
# automation browsers. Classification does not prove an agent spawned them or
# that they are idle. --kill CATEGORY authorizes all matching visible groups;
# --pgid narrows that set. Signals affect every current member of a process
# group, including unclassified siblings; descendants in other groups remain.
# Identity checks and the bundled protection patterns can withhold signals.
#
# Usage:
#   audit-processes.sh                      # report all categories (dry run)
#   audit-processes.sh --kill tests         # all detected test/watch groups
#   audit-processes.sh --kill dev --keep 87239   # all detected dev groups except 87239
#   audit-processes.sh --kill browser       # all detected automation-browser groups
#   audit-processes.sh --kill tests,dev     # multiple machine-wide categories
#   audit-processes.sh --kill dev --pgid 123,456  # only reviewed groups
#   audit-processes.sh --kill dev --pgid 123 --expect 123:9f3ac1b2c3d4  # and only if unchanged
#   audit-processes.sh --json               # JSON Lines report (no --kill)
#   audit-processes.sh --strict             # nonzero for unavailable process/listener scans
#
# Exit codes: 0 report/no failed cleanup (may include protected or absent groups);
# 1 failed cleanup or unavailable scans with --strict; 2 usage error.
set -uo pipefail

# --- constants ---------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROTECT_RE (never signal these) is shared with process-ledger.sh.
. "$DIR/protect.sh"
# JSON Lines helpers for --json output.
. "$DIR/json.sh"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
# Private local record of confirmed mutation outcomes.
. "$DIR/journal.sh"

# Category patterns live in categories.sh so plan.sh matches on exactly the
# same definitions this script kills by; duplicating them is how the two drift.
. "$DIR/categories.sh"
# Identity is checked at the signal boundary. --expect supplies the reviewed
# fingerprint; otherwise the command captures one for each selected group.
. "$DIR/fingerprint.sh"
LOCALHOST_RE='^(node|bun|deno|python|uvicorn|ruby|rails|go|cargo|java|next|vite|webpack|cloudflared)[[:space:]]|:3000|:3001|:3002|:5173|:5174|:8000|:8080|:8787'

SELF_PID=$$
SELF_PGID=$(ps -o pgid= -p "$SELF_PID" 2>/dev/null | tr -d ' ')

# --- helpers -----------------------------------------------------------------
# rg when available, grep -E otherwise, so a missing ripgrep degrades to grep
# instead of reporting every category as "(none)".
HAVE_RG=0
command -v rg >/dev/null 2>&1 && HAVE_RG=1
[ "$HAVE_RG" -eq 1 ] || echo "note: ripgrep (rg) not found; matching with grep -E" >&2
PS_STATUS=ok PS_REASON="" PS_SNAPSHOT=""
if ! PS_SNAPSHOT="$(ps -Ao pid,ppid,pgid,%cpu,etime,command 2>/dev/null)" \
    || [ -z "$PS_SNAPSHOT" ]; then
  PS_STATUS=unavailable
  PS_REASON="ps cannot provide the detailed process table; use macOS/Linux or WSL"
  echo "warning: $PS_REASON" >&2
fi
LSOF_STATUS=ok LSOF_REASON=""
if ! command -v lsof >/dev/null 2>&1; then
  LSOF_STATUS=unavailable
  LSOF_REASON="lsof is not installed"
fi

match_i()  { if [ "$HAVE_RG" -eq 1 ]; then rg --no-config -i -- "$1"; else grep -Ei -- "$1"; fi; }
match_iv() { if [ "$HAVE_RG" -eq 1 ]; then rg --no-config -iv -- "$1"; else grep -Eiv -- "$1"; fi; }
match_v()  { if [ "$HAVE_RG" -eq 1 ]; then rg --no-config -v -- "$1"; else grep -Ev -- "$1"; fi; }
match_q()  { if [ "$HAVE_RG" -eq 1 ]; then rg --no-config -q -- "$1"; else grep -Eq -- "$1"; fi; }

# Print matching processes for a category, excluding protected and self.
list_matches() {
  local category="$1" line actual IFS=$' \t\n'
  [ "$PS_STATUS" = ok ] || return 2
  printf '%s\n' "$PS_SNAPSHOT" | match_iv "$PROTECT_RE" \
    | awk -v self="$SELF_PGID" '$1 ~ /^[0-9]+$/ && $3 != self' \
    | while IFS= read -r line; do
        # shellcheck disable=SC2086
        set -f; set -- $line; set +f
        [ "$#" -ge 6 ] || continue
        shift 5
        actual="$(cat_for_command "$*")" || continue
        [ "$actual" = "$category" ] && printf '%s\n' "$line"
      done
}

# Print a human report for a category. Sets LAST_N to the row count so the
# caller can tally findings.
report() {
  local label="$1" re="$2" rows hc="" hr="" line pid ppid pgid cpu et
  LAST_N=0
  if [ "$PS_STATUS" != "ok" ]; then
    s_hdr "$label"
    s_skip "  unavailable: $PS_REASON"
    return
  fi
  rows=$(list_matches "$re" || true)
  [ -n "$rows" ] && LAST_N=$(printf '%s\n' "$rows" | grep -c .)
  s_hdr "$label"
  if [ -z "$rows" ]; then
    s_dim "  (none)"
    return
  fi
  if [ "$STYLE_ON" -eq 1 ]; then hc="$C_DIM"; hr="$C_RESET"; fi
  printf '  %s%-7s %-7s %-7s %-6s %-10s %s%s\n' "$hc" PID PPID PGID %CPU ELAPSED COMMAND "$hr"
  if [ "$STYLE_ON" -eq 1 ]; then
    # Styled rows render in bash so %CPU can carry a severity tint and
    # ELAPSED reads as "1d 2h"; the plain awk path below stays byte-exact.
    echo "$rows" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      # set -f: a COMMAND field containing * must never glob against cwd.
      # shellcheck disable=SC2086
      set -f; set -- $line; set +f
      [ $# -ge 6 ] || continue
      pid="$1" ppid="$2" pgid="$3" cpu="$4" et="$5"
      shift 5
      printf '  %-7s %-7s %-7s %s %-10s %s\n' "$pid" "$ppid" "$pgid" \
        "$(s_sevcell "$cpu" 10 50 "$(printf '%-6s' "$cpu")")" \
        "$(s_etime "$et")" "${*:1:9}"
    done
  else
    echo "$rows" | while IFS= read -r line; do
      echo "$line" | awk '{printf "  %-7s %-7s %-7s %-6s %-10s ", $1,$2,$3,$4,$5; for(i=6;i<=NF && i<=14;i++) printf "%s ", $i; print ""}'
    done
  fi
}

report_localhost() {
  s_hdr "Localhost listeners (ports that may be active dev servers)"
  LAST_N=0
  if [ "$LSOF_STATUS" != "ok" ]; then
    s_skip "  unavailable: $LSOF_REASON"
    return
  fi
  rows="$LSOF_ROWS"
  if [ -z "$rows" ]; then
    s_dim "  (none)"
    return
  fi
  LAST_N=$(printf '%s\n' "$rows" | grep -c .)
  s_dim "  COMMAND     PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME"
  echo "$rows" | awk '{print "  " $0}'
}

# Distinct candidate pgids for a category. The caller applies --keep so styled
# output can narrate that per-item decision.
pgids_for() {
  local re="$1"
  list_matches "$re" | awk '{print $3}' | sort -u | while read -r pg; do
    [ -z "$pg" ] && continue
    echo "$pg"
  done
}

# Return 0 when a process group still has members, 1 when it is absent, and 2
# when membership could not be inspected. Keeping this tri-state avoids
# treating a failed `ps` call as proof that a group exited.
pgid_exists() { fp_group_state "$1"; }

# SIGTERM then SIGKILL a process group. Returns 0 only after the group is
# confirmed absent, so receipts describe outcomes rather than signal attempts.
# Expected fingerprint for a group under --expect, empty when unconstrained.
# A flag that takes a value must be given one. Returns the value, or fails so
# the caller can exit rather than continue with an unset positional.
need_value() {
  if [ "$#" -lt 2 ] || [ -z "${2-}" ]; then
    echo "$1 requires a value" >&2
    return 1
  fi
  printf '%s' "$2"
}

expected_fp_for() {
  local pg="$1" pair map
  # A caller-supplied expectation wins; otherwise fall back to the fingerprint
  # this run captured when it SELECTED the group. Discovery is heuristic and
  # its snapshot ages the whole length of a run — 2s of drain per group — so
  # the fingerprint is what turns a stale observation into proof that the thing
  # about to be signalled is still the thing that was chosen.
  for map in "$EXPECT_MAP" "$AUTO_FP_MAP"; do
    [ -n "$map" ] || continue
    OLD_IFS="$IFS"; IFS=','
    for pair in $map; do
      case "$pair" in "$pg":*) IFS="$OLD_IFS"; printf '%s' "${pair#*:}"; return 0 ;; esac
    done
    IFS="$OLD_IFS"
  done
  return 1
}

# True when the group is not what the caller approved. Checked immediately
# before every signal: pgid alone is not identity, and a group that exits and
# has its id reused between approval and SIGTERM would otherwise be killed on
# an approval that was never given for it. Missing proof also refuses signals.
identity_moved() {
  local pg="$1" want have
  want="$(expected_fp_for "$pg")" || return 0
  have="$(fp_for_pgid "$pg" 2>/dev/null)" || return 0
  [ "$have" != "$want" ]
}

record_process_outcome() {
  journal_action "$@" || { s_skip "  process outcome occurred but its receipt could not be recorded"; return 1; }
}

kill_group() {
  local pg="$1" state_rc protection_rc member_proof
  # kill -TERM -1 means every process this user owns; -0 means afterparty's own
  # group. Every other pgid entry point validates this; the one that actually
  # signals did not, and a pgid comes straight out of a ps column.
  case "$pg" in
    ''|*[!0-9]*) s_skip "  refusing a non-numeric process group id"; return 1 ;;
  esac
  if [ "$pg" -le 1 ]; then
    s_skip "  refusing process group $pg — 0 and 1 are never valid kill targets"
    record_process_outcome process_group.stop "pgid:$pg" failed "refused reserved process group"
    return 1
  fi
  # Re-evaluate the live group immediately before each signal. The discovery
  # snapshot may be stale, and a protected sibling can join while SIGTERM is
  # draining the group.
  if pgid_has_protected "$pg"; then
    s_skip "  protect pgid $pg: shares its group with a protected process"
    return 3
  else
    protection_rc=$?
    if [ "$protection_rc" -eq 3 ]; then
      # Already gone. The postcondition this function exists to guarantee --
      # the group is absent -- is satisfied, so this is a no-op and not a
      # failure. It was counted as one because "no members" and "ps failed"
      # shared a return code.
      s_skip "  pgid $pg had already exited — nothing to signal"
      return 6
    fi
    if [ "$protection_rc" -eq 2 ]; then
      s_skip "  could not inspect pgid $pg for protected members — skipped"
      return 1
    fi
  fi
  if ! member_proof="$(fp_members_for_pgid "$pg")"; then
    s_skip "  pgid $pg: identity unavailable before SIGTERM — not signalled"
    return 1
  fi
  if identity_moved "$pg"; then
    s_skip "  pgid $pg: identity changed or unavailable since approval — not signalled"
    record_process_outcome process_group.stop "pgid:$pg" failed "identity changed before SIGTERM"
    return 5
  fi
  if kill -TERM -"$pg" 2>/dev/null; then
    s_kill "  SIGTERM -> pgid $pg"
  fi
  s_heartbeat "waiting 2s for stragglers"
  sleep 2
  if pgid_exists "$pg"; then
    if pgid_has_protected "$pg"; then
      s_skip "  pgid $pg became protected before SIGKILL — skipped"
      record_process_outcome process_group.stop "pgid:$pg" failed "protected member detected before SIGKILL"
      return 4
    else
      protection_rc=$?
      if [ "$protection_rc" -eq 3 ]; then
        # The group drained between pgid_exists and this recheck. A signal WAS
        # delivered and absence IS confirmed, so this is the ordinary success
        # path -- it must journal and count like any other kill. Returning the
        # pre-signal "already gone" code here suppressed the receipt for work
        # that actually happened, which is the mirror image of claiming work
        # that did not. "Already gone" is only ever a PRE-signal verdict.
        s_ok "  pgid $pg exited after SIGTERM"
        record_process_outcome process_group.stop "pgid:$pg" succeeded "exited after SIGTERM" || return 7
        return 0
      fi
      if [ "$protection_rc" -eq 2 ]; then
        s_skip "  could not recheck pgid $pg before SIGKILL — skipped"
        record_process_outcome process_group.stop "pgid:$pg" failed "protection unavailable before SIGKILL"
        return 1
      fi
    fi
    if fp_group_matches "$pg" "$member_proof"; then :; else
      state_rc=$?
      if [ "$state_rc" -eq 1 ]; then
        record_process_outcome process_group.stop "pgid:$pg" succeeded "group confirmed absent" || return 7
        return 0
      fi
      s_skip "  pgid $pg: identity changed or unavailable before SIGKILL — not signalled"
      record_process_outcome process_group.stop "pgid:$pg" failed "identity changed before SIGKILL"
      return 5
    fi
    if kill -KILL -"$pg" 2>/dev/null; then
      s_kill "  SIGKILL -> pgid $pg (straggler)"
    fi
    sleep 0.1
    if pgid_exists "$pg"; then
      s_skip "  failed to stop pgid $pg"
      record_process_outcome process_group.stop "pgid:$pg" failed "group still has members"
      return 1
    else
      state_rc=$?
      if [ "$state_rc" -eq 2 ]; then
        s_skip "  could not confirm pgid $pg exited"
        record_process_outcome process_group.stop "pgid:$pg" failed "exit could not be confirmed"
        return 1
      fi
    fi
  else
    state_rc=$?
    if [ "$state_rc" -eq 2 ]; then
      s_skip "  could not confirm pgid $pg exited"
      record_process_outcome process_group.stop "pgid:$pg" failed "exit could not be confirmed"
      return 1
    fi
  fi
  record_process_outcome process_group.stop "pgid:$pg" succeeded "group confirmed absent" || return 7
  return 0
}

category_re() {
  case "$1" in
    tests) echo tests ;;
    dev) echo dev ;;
    browser) echo browser ;;
    *) echo "" ;;
  esac
}

# One JSON Lines object per matching process for a category.
json_report() {
  local cat="$1" re="$2" line pid ppid pgid cpu etime
  list_matches "$re" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # set -f: an argv containing * would otherwise glob against the CALLER's
    # cwd, replacing the command text with whatever filenames happen to sit
    # there — corrupting the field and leaking unrelated filenames into a
    # machine-readable surface. list_matches at the top of this file already
    # guards this; these two emitters were missed.
    # shellcheck disable=SC2086
    set -f; set -- $line; set +f
    [ $# -ge 6 ] || continue
    pid="$1" ppid="$2" pgid="$3" cpu="$4" etime="$5"
    shift 5
    json_row "$(json_kv section processes)" "$(json_kv category "$cat")" \
      "$(json_kvn pid "$pid")" "$(json_kvn ppid "$ppid")" "$(json_kvn pgid "$pgid")" \
      "$(json_kv cpu "$cpu")" "$(json_kv elapsed "$etime")" "$(json_kv command "$*")"
  done
}

# One JSON Lines object per localhost listener (needs lsof).
json_report_localhost() {
  [ "$LSOF_STATUS" = "ok" ] || return 0
  local line
  printf '%s\n' "$LSOF_ROWS" \
    | while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -f; set -- $line; set +f
        [ $# -ge 4 ] || continue
        json_row "$(json_kv section listeners)" "$(json_kv command "$1")" \
          "$(json_kvn pid "$2")" "$(json_kv user "$3")" "$(json_kv name "${!#}")"
      done
}

json_capability() {
  json_row "$(json_kv section capability)" "$(json_kv name "$1")" \
    "$(json_kv status "$2")" "$(json_kvz reason "${3:-}")"
}

# --- main --------------------------------------------------------------------
KILL_CATS="" KEEP="" PGID_FILTER="" JSON=0 STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    # need_value, not ${2:-}: a value-taking flag in final position left $2
    # unset, so `shift 2` failed, the loop never advanced and the process spun
    # at 100% CPU forever. Sibling scripts already use ${2:?}; these did not.
    --kill) KILL_CATS="$(need_value "$1" "${2-}")" || exit 2; shift 2 ;;
    --keep|--keep-pgid) KEEP="$(need_value "$1" "${2-}")" || exit 2; shift 2 ;;
    --pgid|--only-pgid) PGID_FILTER="$(need_value "$1" "${2-}")" || exit 2; PGID_SUPPLIED=1; shift 2 ;;
    --expect) EXPECT_MAP="$(need_value "$1" "${2-}")" || exit 2; shift 2 ;;
    --json) JSON=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Supplied-but-empty is not the same as absent. Every guard below used to hang
# off the VALUE being non-empty, so `--pgid ''` skipped the syntax check, the
# 0/1 refusal, the requires--kill check AND the narrowing itself — turning the
# flag whose entire job is to restrict a kill into one that widens it to the
# whole category.
if [ "${PGID_SUPPLIED:-0}" -eq 1 ] && [ -z "$PGID_FILTER" ]; then
  echo "--pgid was given an empty value; refusing to widen the kill" >&2
  exit 2
fi
if [ -n "$PGID_FILTER" ]; then
  case "$PGID_FILTER" in
    ,*|*,|*,,*|*[!0-9,]*) echo "--pgid wants comma-separated positive process-group IDs" >&2; exit 2 ;;
  esac
  OLD_IFS="$IFS" IFS=','
  for requested_pgid in $PGID_FILTER; do
    if [ "$requested_pgid" -le 1 ]; then
      echo "--pgid refuses process-group IDs 0 and 1" >&2
      exit 2
    fi
  done
  IFS="$OLD_IFS"
  if [ -z "$KILL_CATS" ]; then
    echo "--pgid requires --kill <tests|dev|browser>" >&2
    exit 2
  fi
fi

if [ "$JSON" -eq 1 ] && [ -n "$KILL_CATS" ]; then
  echo "--json is report-only (cannot combine with --kill)" >&2
  exit 2
fi

LSOF_ROWS=""
if [ "$LSOF_STATUS" = ok ]; then
  if listener_errors="$(mktemp)"; then
    listener_snapshot="$(lsof -nP -iTCP -sTCP:LISTEN 2>"$listener_errors")"; listener_rc=$?
    if [ -s "$listener_errors" ] || [ "$listener_rc" -gt 1 ] \
      || { [ "$listener_rc" -eq 0 ] && [ -z "$listener_snapshot" ]; }; then
      LSOF_STATUS=unavailable; LSOF_REASON="lsof could not complete the listener scan"
    elif [ -n "$listener_snapshot" ] && ! printf '%s\n' "$listener_snapshot" | awk 'NR==1 {if ($1!="COMMAND" || $2!="PID") bad=1;next} NF<9 || $2!~/^[0-9]+$/ {bad=1} END {exit bad}'; then
      LSOF_STATUS=unavailable; LSOF_REASON="lsof returned malformed listener data"
    else
      LSOF_ROWS="$(printf '%s\n' "$listener_snapshot" | awk 'NR > 1 && /127\.0\.0\.1|localhost|\[::1\]|\*:/' | match_i "$LOCALHOST_RE" | match_iv "$PROTECT_RE" || true)"
    fi
    rm -f "$listener_errors"
  else
    LSOF_STATUS=unavailable; LSOF_REASON="cannot capture listener scan diagnostics"
  fi
fi
# Reject the entire category request before any group can be signalled.
validate_ifs="$IFS"; IFS=','
for requested_category in $KILL_CATS; do
  case "$requested_category" in tests|dev|browser) : ;; *) echo "unknown category: $requested_category" >&2; exit 2 ;; esac
done
IFS="$validate_ifs"

if [ "$JSON" -eq 1 ]; then
  json_capability processes "$PS_STATUS" "$PS_REASON"
  json_capability listeners "$LSOF_STATUS" "$LSOF_REASON"
  json_report_localhost
  json_report tests tests
  json_report dev dev
  json_report browser browser
  if [ "$STRICT" -eq 1 ] && { [ "$PS_STATUS" != ok ] || [ "$LSOF_STATUS" != ok ]; }; then exit 1; fi
  exit 0
fi

# Finale cards (styled standalone runs only; the composite router owns the
# card when AFTERPARTY_TALLY is set).
print_procs_card() {
  local total=$((N_TESTS + N_DEV + N_BROWSER)) cats="" segs
  echo
  s_card_open
  if [ "$total" -gt 0 ]; then
    [ "$N_TESTS" -gt 0 ] && cats="tests"
    [ "$N_DEV" -gt 0 ] && cats="${cats:+$cats,}dev"
    [ "$N_BROWSER" -gt 0 ] && cats="${cats:+$cats,}browser"
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — processes${C_RESET}"
    segs="$(s_segments \
      "$([ "$N_TESTS" -gt 0 ] && echo "$G_ACT $N_TESTS tests")" \
      "$([ "$N_DEV" -gt 0 ] && echo "$G_ACT $N_DEV dev")" \
      "$([ "$N_BROWSER" -gt 0 ] && echo "$G_ACT $N_BROWSER browser")" \
      "$([ "$N_LISTEN" -gt 0 ] && echo "$(s_n "$N_LISTEN" 'listener' 'listeners')")")"
    s_card_line "   $segs"
    [ "$N_TESTS" -gt 0 ] && s_card_line "   $(s_n "$N_TESTS" 'test runner still running laps' 'test runners still running laps')"
    [ "$N_DEV" -gt 0 ] && s_card_line "   $(s_n "$N_DEV" 'dev server still serving' 'dev servers still serving')"
    [ "$N_BROWSER" -gt 0 ] && s_card_line "   $(s_n "$N_BROWSER" 'automation browser nobody closed' 'automation browsers nobody closed')"
    [ "$N_LISTEN" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_LISTEN" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    s_card_line
    s_card_line "   closing time: ${C_CYAN}afterparty audit --kill $cats --pgid <reviewed-pgids>${C_RESET}"
  elif [ "$N_UNAVAILABLE" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}⚠ audit incomplete — some scanners were unavailable${C_RESET}"
    s_card_line "   $N_UNAVAILABLE unavailable scanner(s); no clean bill of health issued"
    s_card_line "   run ${C_CYAN}afterparty doctor${C_RESET} after installing the missing tools"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — no stragglers, nobody hiding in the bathroom${C_RESET}"
    [ "$N_LISTEN" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_LISTEN" 'localhost listener up — likely yours' 'localhost listeners up — likely yours'))${C_RESET}"
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
}

print_procs_receipt() {
  local segs
  echo
  s_card_open
  s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty audit --kill $KILL_CATS${C_RESET}"
  segs="$(s_segments \
    "$([ "$N_KILLED" -gt 0 ] && echo "$G_OK $N_KILLED killed")" \
    "$([ "$N_PROT" -gt 0 ] && echo "$G_SKIP $N_PROT protected")" \
    "$([ "$N_IDENT" -gt 0 ] && echo "$G_SKIP $N_IDENT identity changed")" \
    "$([ "$N_GONE" -gt 0 ] && echo "$G_SKIP $N_GONE already gone")" \
    "$([ "$N_FAILED" -gt 0 ] && echo "$G_SKIP $N_FAILED failed")")"
  if [ -n "$segs" ]; then s_card_line "   $segs"; fi
  if [ "$N_KILLED" -gt 0 ]; then
    s_card_line "   $(s_n "$N_KILLED" 'process group shown the door' 'process groups shown the door')"
  elif [ "$N_FAILED" -gt 0 ]; then
    s_card_line "   nothing stopped — $N_FAILED group(s) could not be safely handled"
  elif [ "$N_PROT" -gt 0 ]; then
    s_card_line "   no group stopped — protected groups remain running"
  else
    s_card_line "   no matching group remained to stop"
  fi
  s_card_line
  s_card_line "   thanks for partying responsibly 🎉"
  s_card_close
}

if [ -z "$KILL_CATS" ]; then
  s_mode "$C_YEL" "DRY RUN" " — headcount only, nobody gets kicked out yet (use --kill <tests|dev|browser> to act)" \
    "DRY RUN — reporting stray processes (use --kill <tests|dev|browser> to act)"
  s_dim "Scope: all visible workspaces; detected processes are not necessarily idle"
  report_localhost;                                                N_LISTEN=$LAST_N
  report "Test / watch runners (review current work before stopping)" tests;  N_TESTS=$LAST_N
  report "Dev servers (keep the one you are actively using)" dev; N_DEV=$LAST_N
  report "Automation browsers (close via the browser tool first)" browser; N_BROWSER=$LAST_N
  N_UNAVAILABLE=0
  [ "$PS_STATUS" = "ok" ] || N_UNAVAILABLE=$((N_UNAVAILABLE + 1))
  [ "$LSOF_STATUS" = "ok" ] || N_UNAVAILABLE=$((N_UNAVAILABLE + 1))
  echo
  s_dim "Protected (never killed): $PROTECT_RE"
  tally_add procs.found "$((N_TESTS + N_DEV + N_BROWSER))"
  tally_add procs.listeners "$N_LISTEN"
  tally_add procs.unavailable "$N_UNAVAILABLE"
  if cards_on; then print_procs_card; fi
  if [ "$STRICT" -eq 1 ] && [ "$N_UNAVAILABLE" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

if [ "$PS_STATUS" != "ok" ]; then
  s_skip "  cannot kill process groups: $PS_REASON"
  tally_add procs.failed 1
  exit 1
fi

N_KILLED=0 N_PROT=0 N_FAILED=0 N_IDENT=0 N_GONE=0
PGID_SUPPLIED="${PGID_SUPPLIED:-0}"
AUTO_FP_MAP=""
EXPECT_MAP="${EXPECT_MAP:-}"
IFS=','
for cat in $KILL_CATS; do
  re=$(category_re "$cat")
  if [ -z "$re" ]; then echo "unknown category: $cat (use tests|dev|browser)" >&2; exit 2; fi
  s_lead "$C_RED" "Killing category '$cat' — last call (keep: ${KEEP:-none})" \
    "Killing category '$cat' (keep: ${KEEP:-none})"
  pgs=$(pgids_for "$re")
  if [ -n "$PGID_FILTER" ] && [ -n "$pgs" ]; then
    filtered_pgs=""
    while IFS= read -r pg; do
      case ",$PGID_FILTER," in
        *",$pg,"*) filtered_pgs="${filtered_pgs}${pg}"$'\n' ;;
      esac
    done <<< "$pgs"
    pgs="${filtered_pgs%$'\n'}"
  fi
  if [ -z "$pgs" ]; then s_dim "  nothing to kill"; continue; fi
  # Capture identity for every group this category selected, right now, against
  # the live process table — not against PS_SNAPSHOT, which was taken before
  # argument parsing and ages ~2s per group as the run drains. kill_group
  # re-checks this immediately before SIGTERM and again before SIGKILL, so a
  # pgid freed and recycled mid-run is refused instead of signalled on an
  # authority that was never granted for it.
  while IFS= read -r pg; do
    [ -n "$pg" ] || continue
    if sel_fp="$(fp_for_pgid "$pg" 2>/dev/null)" && [ -n "$sel_fp" ]; then
      AUTO_FP_MAP="${AUTO_FP_MAP:+$AUTO_FP_MAP,}${pg}:${sel_fp}"
    fi
  done <<< "$pgs"
  # pgids_for emits one pgid per line; the surrounding loop runs under
  # IFS=',' so word-splitting would glue them into one token — read by line.
  actionable=0
  while IFS= read -r pg; do
    [ -n "$pg" ] || continue
    case ",$KEEP," in
      *",$pg,"*)
        # Plain output historically collapsed an all-kept category to
        # "nothing to kill"; only styled mode gains the per-item decision.
        if [ "$STYLE_ON" -eq 1 ]; then
          s_skip "  keep pgid $pg: requested via --keep"
        fi
        continue
        ;;
    esac
    actionable=1
    if kill_group "$pg"; then
      N_KILLED=$((N_KILLED + 1))
    else
      kill_rc=$?
      case "$kill_rc" in
        7) N_KILLED=$((N_KILLED + 1)); N_FAILED=$((N_FAILED + 1)) ;;
        3) N_PROT=$((N_PROT + 1)) ;;
        # Already gone before we signalled: a no-op, not a failure.
        6) N_GONE=$((N_GONE + 1)) ;;
        # Identity drift is its own refusal: the group was not protected, it
        # was simply no longer the group that was approved. Counting it as
        # protected would misreport why nothing was killed.
        5)
          N_IDENT=$((N_IDENT + 1))
          N_FAILED=$((N_FAILED + 1))
          ;;
        4)
          N_PROT=$((N_PROT + 1))
          N_FAILED=$((N_FAILED + 1))
          ;;
        *) N_FAILED=$((N_FAILED + 1)) ;;
      esac
    fi
  done <<< "$pgs"
  if [ "$actionable" -eq 0 ] && [ "$STYLE_ON" -eq 0 ]; then
    s_dim "  nothing to kill"
  fi
done
unset IFS
printf '%s stopped · %s protected · %s already gone · %s failed\n' "$N_KILLED" "$N_PROT" "$N_GONE" "$N_FAILED"
s_ok "done"
tally_add procs.killed "$N_KILLED"
tally_add procs.protected "$N_PROT"
tally_add procs.failed "$N_FAILED"
if cards_on; then print_procs_receipt; fi
if [ "$N_FAILED" -gt 0 ]; then exit 1; fi
