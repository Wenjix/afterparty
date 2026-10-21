# shellcheck shell=bash
# Capture policy observations and canonical fragments together, once per stage.
plan_collect() {
WS_STATUS=ok
ws_index --sources > "$T/ws-sources" 2> "$T/ws.err" || { : > "$T/ws-sources"; WS_STATUS=unavailable; }
cut -f1,2 "$T/ws-sources" > "$T/ws"
plan_capability activity process-group "$([ "$WS_STATUS" = ok ] && echo complete || echo unavailable)" "$(cat "$T/ws.err")"
CWD_STATUS=complete
if ! command -v lsof >/dev/null 2>&1 || ! ws_pid_cwd > "$T/cwd" 2>/dev/null; then
  : > "$T/cwd"; CWD_STATUS=unavailable
fi
[ -s "$T/cwd" ] || CWD_STATUS=unavailable
plan_capability attribution process-group "$CWD_STATUS" "Match processes to their working directories"
PS_STATUS=complete
ps -Ao pid,pgid,%cpu,command 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {
  pid = $1; pg = $2; cpu = $3
  $1 = ""; $2 = ""; $3 = ""; sub(/^[ \t]+/, "")
  print pid "\t" pg "\t" cpu "\t" $0
}' > "$T/ps" || { : > "$T/ps"; PS_STATUS=unavailable; }
[ -s "$T/ps" ] || PS_STATUS=unavailable
plan_capability processes process-group "$PS_STATUS" 'Process table inspection'

PORT_STATUS=none
if lsof -nP -iTCP -sTCP:LISTEN -Fpn > "$T/listeners" 2> "$T/listeners.err"; then port_rc=0; else port_rc=$?; fi
if [ "$port_rc" -gt 1 ] || [ -s "$T/listeners.err" ]; then PORT_STATUS=unavailable; fi
plan_capability listeners process-group "$([ "$PORT_STATUS" = unavailable ] && echo unavailable || echo complete)" "Listening-port inspection"
awk '/^p[0-9]+$/ {pid=substr($0,2)} /^n.*:[0-9]+$/ {port=$0; sub(/^.*:/,"",port); print pid "\t" port}' "$T/listeners" > "$T/ports"

# Aggregate to the unit that actually gets killed: the process group.
{
  sed 's/^/W\t/' "$T/ws"
  sed 's/^/C\t/' "$T/cwd"
  sed 's/^/P\t/' "$T/ps"
} | LC_ALL=C awk -F'\t' '
    # macOS awk (20200816) compares strings via locale collation, and reports
    # two DIFFERENT multibyte paths as equal: "/w/プロジェクト/web" == "/w/別
    # プロジェクト/web" evaluates TRUE, and so does the substr form. index() is
    # byte-exact, so equality is length-plus-index. Without this a process is
    # attributed to the WRONG workspace and two workspaces merge into one row —
    # on the surface a person approves kills from.
    function samepath(a, b) { return (length(a) == length(b) && index(a, b) == 1) }
  $1 == "W" { wsts[$3] = $2; next }
  $1 == "C" { cwd[$2] = $3; next }
  $1 == "P" {
    pid = $2; pg = $3; cmd = $5
    cpu = $4 + 0
    if ($4 !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ || tolower(sprintf("%g", cpu)) ~ /inf|nan/)
      badcpu[pg] = 1
    dir = cwd[pid]; if (dir == "") { mixed[pg] = 1; next }
    best = ""
    for (w in wsts) if (samepath(dir, w) || index(dir, w "/") == 1)
      if (length(w) > length(best)) best = w
    # First member seen fixes the group owner; a later member resolving
    # elsewhere marks the group mixed. Assigning per member would let the LAST
    # row decide the whole group, so a group with one foot in a stale workspace
    # and one in an active one could be offered off the stale member.
    resolved = (best != "" ? best : dir)
    if (!(pg in owner)) {
      owner[pg] = resolved
      known[pg] = (best != "" ? wsts[best] : "")
    } else if (!samepath(owner[pg], resolved)) {
      mixed[pg] = 1
    }
    procs[pg]++
    if (!(pg in maxraw) || cpu > maxcpu[pg]) { maxcpu[pg] = cpu; maxraw[pg] = $4 }
    # busiest member of the group supplies the command the category comes from
    if (cpu >= topcpu[pg] || !(pg in leader)) { topcpu[pg] = cpu; leader[pg] = cmd }
  }
  END {
    # "-" rather than "" for an unknown last-touched: tab is IFS-whitespace, so
    # bash read collapses consecutive tabs and an empty middle field shifts
    # every later column left. That is how a no-transcript workspace ended up
    # parsed as eligible. Same hazard test-review-fixes C6 pins for the ledger.
    for (pg in procs)
      printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\n", pg, owner[pg],
             (known[pg] == "" ? "-" : known[pg]), procs[pg],
             (pg in badcpu ? "-" : maxraw[pg]),
             (pg in mixed ? "mixed" : "-"), leader[pg]
  }
' | sort -n > "$T/groups"

printf '# afterparty plan schema: 1\n'
printf '# afterparty plan — %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '# Check a box to approve it. apply refuses any item whose fingerprint changed.\n'
printf '# It repeats the process or filesystem safety checks for each target.\n'
echo
printf 'Scope: %s; process/worktree discovery: %s. All actions start unchecked.\n' "$ROOT" "$([ "$ALL" -eq 1 ] && echo machine-wide || echo current-repository)"
if [ "$WS_STATUS" != ok ]; then
  printf 'Activity: unavailable; process proposals are withheld.\n'
  [ ! -s "$T/ws.err" ] || head -n 1 "$T/ws.err"
fi
echo '## Process groups'
echo

emit_process_groups() {
if [ ! -s "$T/groups" ]; then
  echo '(nothing attributed to a workspace)'
  return 0
fi

awk -F'\t' '{print $2}' "$T/groups" | ws_unique_labels > "$T/labels" 2>/dev/null || : > "$T/labels"
cpu_unavailable=0
while IFS=$'\t' read -r pg owner touched procs cpu span cmd; do
  [ -n "$pg" ] || continue
  if [ "$ALL" -eq 0 ]; then
    case "$owner" in "$ROOT"|"$ROOT"/*) : ;; *) continue ;; esac
  fi
  [ "$touched" = "-" ] && touched=""
  # Scope: a group belongs in the plan only if it sits in a workspace. With no
  # transcript the fallback test is "is this a git repo" -- that catches a
  # hand-driven project, which genuinely has no staleness signal and is worth
  # showing as unknown, while excluding the system daemons that all root at "/".
  if [ -z "$touched" ] && ! git -C "$owner" rev-parse --show-toplevel >/dev/null 2>&1; then
    continue
  fi
  verdict="$(elig_verdict "$touched" "$cpu" "$NOW")"
  name="$(awk -F'\t' -v p="$owner" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($1,p) { print $2; exit }' "$T/labels")"
  [ -n "$name" ] || name="$(ws_label "$owner")"
  if [ -n "$touched" ]; then
    age="idle $(ws_human_age "$((NOW - touched))")"
  else
    age="no transcript"
  fi
  if [ "$cpu" = "-" ]; then
    cpu_label=unknown
  else
    cpu_label="$(LC_ALL=C printf '%.1f' "$cpu")"
  fi
  detail="$name · $(s_n "$procs" proc procs) · $age · cpu $cpu_label"
  # An approved item is executed by delegating to `audit --kill <category>
  # --pgid`, and that flag narrows WITHIN a category. A group matching no
  # category would therefore be approved and then silently not killed, so it is
  # never offered in the first place.
  # A group whose members live in different workspaces cannot be judged by one
  # workspace's staleness, so it is never offered.
  fp="" category=""
  if [ "$cpu" = "-" ]; then
    cpu_unavailable=1
    plan_process_record withheld cpu-unavailable 'Afterparty could not inspect CPU use for every group member. Refresh to try again.'
    printf -- '- [⊘] cpu-unavailable pgid %s  %s\n' "$pg" "$detail"
    printf -- '      not offered: CPU evidence is unavailable for one or more group members.\n'
    continue
  fi
  if [ "$span" = "mixed" ]; then
    plan_process_record withheld mixed "Afterparty cannot attribute all group members to one workspace."
    printf -- '- [⊘] %-8s pgid %s  %s\n' "mixed" "$pg" "$detail"
    printf -- '      not offered: Afterparty cannot attribute all group members to one workspace.\n'
    continue
  fi
  category="$(cat_for_command "$cmd" 2>/dev/null)" || category=""
  if [ "$verdict" = "eligible" ] && [ -n "$category" ]; then
    pgid_has_protected "$pg"; protection_rc=$?
    if [ "$protection_rc" -ne 1 ]; then
      case "$protection_rc" in 0) protection_reason=protected ;; 3) protection_reason=gone ;; *) protection_reason=inspection-unavailable ;; esac
      plan_process_record withheld "$protection_reason" "Group protection check: $protection_reason"
      printf -- '- [⊘] %s pgid %s  %s\n      not offered: group protection check %s\n' "$protection_reason" "$pg" "$detail" "$protection_reason"
      continue
    fi
    fp="$(fp_for_pgid "$pg" 2>/dev/null)" || fp=""
    if [ -n "$fp" ]; then
      plan_process_record available eligible "Recorded agent activity is old. Observed CPU use is at or below the limit."
      printf -- '- [ ] eligible  pgid %s  %s\n' "$pg" "$detail"
      printf -- '      category: %s  fingerprint: %s\n' "$category" "$fp"
      printf '      workspace: %s\n' "$owner"
      awk -F'\t' -v pg="$pg" '$2 == pg {printf "      member %s: %s\n", $1, $4}' "$T/ps" | privacy_redact
      ports="$(awk -F'\t' -v pg="$pg" 'NR == FNR { if ($2 == pg) p[$1]=1; next } $1 in p {printf "%s ", $2}' "$T/ps" "$T/ports")"
      printf '      listening ports: %s\n' "${ports:-$PORT_STATUS}"
      ledger="$(state_ledger_path)"
      purpose=""
      if [ -r "$ledger" ]; then purpose="$(awk -F'\t' -v pg="$pg" '$5 == pg {print $8}' "$ledger" | privacy_redact)"; fi
      plan_evidence recorded_purpose "$purpose"
      printf '      recorded purpose: %s\n' "${purpose:-not recorded}"
      printf '      consequence: stop every member of pgid %s. Afterparty sends TERM, then KILL if needed. Restart services manually.\n' "$pg"
      continue
    fi
  fi
  if [ "$verdict" = "eligible" ] && [ -z "$category" ]; then
    plan_process_record withheld no-rule "No stop category matches this command. Use another tool to stop this group."
    printf -- '- [⊘] %-8s pgid %s  %s\n' "no-rule" "$pg" "$detail"
    printf -- '      not offered: no stop category matches this command. Use another tool to stop this group.\n'
    continue
  fi
  case "$verdict" in
    in-use) reason="Agent transcript files for this workspace changed recently." ;;
    working) reason="Recorded agent activity is old. CPU use exceeds the limit." ;;
    unknown) reason="Afterparty cannot determine the age of recorded agent activity." ;;
    *) reason="Afterparty could not check the group identity." ;;
  esac
  if [ "$verdict" = eligible ]; then
    plan_process_record withheld identity-unavailable "$reason"
  else
    plan_process_record withheld "$verdict" "$reason"
  fi
  printf -- '- [⊘] %-8s pgid %s  %s\n' "$verdict" "$pg" "$detail"
  case "$verdict" in
    in-use)  printf -- '      not offered: agent transcript files for this workspace changed recently.\n' ;;
    working) printf -- '      not offered: CPU use (%s) exceeds the limit.\n' "$cpu_label" ;;
    unknown) printf -- '      not offered: Afterparty cannot determine the age of recorded agent activity.\n' ;;
    *)       printf -- '      not offered: Afterparty could not check the group identity.\n' ;;
  esac
done < "$T/groups"
if [ "$cpu_unavailable" -eq 1 ]; then
  plan_capability processes process-group unavailable 'CPU evidence is unavailable for one or more process-group members.'
fi
}

emit_process_groups

# --- worktrees ---------------------------------------------------------------
#
# `git --clean` discovered worktrees and removed them in one step, from a
# staleness signal that could not carry the weight, and became report-only in
# 0.9.0. This is where removal comes back: as a typed target, surfaced for a
# person and executed only through apply.
#
# Filesystem items, like process groups, are unchecked. Worktree activity labels
# give review context; only structural, identity and occupancy checks withhold
# these proposals. A checked worktree does not require a stale transcript.
echo
echo '## Worktrees'
echo

# Filesystem decisions need a complete scan. Process reporting above keeps its
# best-effort attribution, but a failed strict scan must not look unoccupied.
ws_pid_cwd --strict > "$T/wt-cwd" 2>/dev/null || rm -f "$T/wt-cwd"
plan_capability worktree-occupancy worktree "$([ -f "$T/wt-cwd" ] && echo complete || echo unavailable)" 'Strict process working-directory inspection'
WT_STATUS=complete
WT_ROWS="$T/wt-rows"; : > "$WT_ROWS"
# Discovery does not require a staleness signal. A standalone session may have
# no agent history, but its current repository still has worktrees.
printf '%s\n' "$ROOT" > "$T/repo-candidates"
[ "$ALL" -eq 0 ] || awk -F'\t' '{ print $2 }' "$T/ws" >> "$T/repo-candidates"
: > "$T/seen-repos"
while IFS= read -r wsdir; do
  [ -n "$wsdir" ] || continue
  [ -d "$wsdir" ] || continue
  common="$(git -C "$wsdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || common="$(git -C "$wsdir" rev-parse --git-common-dir 2>/dev/null)" || continue
  [ -n "$common" ] || continue
  case "$common" in
    /*|[a-zA-Z]:/*) : ;;
    *) common="$wsdir/$common" ;;
  esac
  common="$(veto_phys "$common")" || continue
  # Full lines keep repositories containing spaces distinct. The current cwd
  # and several transcripts may all refer to different worktrees of one repo.
  grep -Fxq -- "$common" "$T/seen-repos" && continue
  listing="$(git -C "$wsdir" worktree list --porcelain 2>/dev/null)" || { WT_STATUS=unavailable; continue; }
  [ -n "$listing" ] || continue
  printf '%s\n' "$common" >> "$T/seen-repos"
  repo_root="$(printf '%s\n' "${listing%%$'\n'*}" | sed -n 's/^worktree //p')"
  printf '%s\n' "$listing" \
    | awk -v repo="$repo_root" '
        /^worktree / { if (p != "") print p "\t" b "\t" repo; p = substr($0, 10); b = "(detached)"; next }
        /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
        END { if (p != "") print p "\t" b "\t" repo }' >> "$WT_ROWS"
done < "$T/repo-candidates"

plan_capability worktrees worktree "$WT_STATUS" "Git worktree discovery"
if [ ! -s "$WT_ROWS" ]; then
  echo '(no worktrees in the current repository or indexed workspaces)'
else
  while IFS=$'\t' read -r wtpath branch repo; do
    [ -n "$wtpath" ] || continue
    reason="$(veto_for worktree "$wtpath" "$repo" "$T/wt-cwd")"
    # Staleness: the worktree's own transcript if it has one, else the repo's.
    # This is review context: a recent repository transcript may be a reason
    # for the reviewer to leave the worktree alone, but is not a removal veto.
    touched="$(awk -F'\t' -v w="$wtpath" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($2,w) { print $1; exit }' "$T/ws")"
    [ -n "$touched" ] || touched="$(awk -F'\t' -v w="$repo" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($2,w) { print $1; exit }' "$T/ws")"
    if [ -n "$touched" ]; then
      age="idle $(ws_human_age "$((NOW - touched))")"
    else
      age="no transcript"
    fi
    detail="$branch · $age"
    fp=""
    if [ -n "$reason" ]; then
      # main-worktree is structural noise, not a decision a person needs to
      # read: every repo has exactly one and it is never a candidate.
      [ "$reason" = "main-worktree" ] && continue
      plan_worktree_record withheld "$reason" "$reason"
      printf -- '- [⊘] %-8s path %s  %s\n' "$reason" "$wtpath" "$detail"
      case "$reason" in
        ignored-local-data) printf -- '      not offered: ignored local files remain. Preserve them before removal.\n' ;;
        dirty)    printf -- '      not offered: Afterparty cannot confirm that this worktree has no uncommitted changes. Check Git status.\n' ;;
        occupied) printf -- '      not offered: a process uses this worktree as its working directory.\n' ;;
        occupancy-unavailable) printf -- '      not offered: Afterparty could not check all process working directories.\n' ;;
        current)  printf -- '      not offered: this is the current worktree.\n' ;;
        *)        printf -- '      not offered: %s\n' "$reason" ;;
      esac
      continue
    fi
    verdict="$(elig_verdict "$touched" 0 "$NOW")"
    fp="$(fp_for_worktree "$wtpath" 2>/dev/null)" || fp=""
    if [ -z "$fp" ]; then
      if [ -d "$wtpath" ]; then
        plan_worktree_record withheld identity-unavailable "Afterparty could not check when the filesystem object was created."
        printf -- '- [⊘] %-8s path %s  %s\n' "identity-unavailable" "$wtpath" "$detail"
        printf -- '      not offered: Afterparty could not check when the filesystem object was created.\n'
      else
        plan_worktree_record withheld gone "The directory no longer exists."
        printf -- '- [⊘] %-8s path %s  %s\n' "gone" "$wtpath" "$detail"
        printf -- '      not offered: the directory no longer exists.\n'
      fi
      continue
    fi
    plan_worktree_record available filesystem-checks "The filesystem, identity, and process working-directory checks passed."
    printf -- '- [ ] %-8s path %s  %s\n' "$verdict" "$wtpath" "$detail"
    # path LAST, and prefixed with 'path:' rather than positional: a worktree
    # path may contain spaces, and every other field is a fixed token, so
    # 'everything after path:' is the one parse that cannot be ambiguous. The
    # repo is not recorded because apply derives it from the worktree itself --
    # a field a person could edit into disagreeing with the target is a field
    # worth not having.
    printf -- '      type: worktree  fingerprint: %s  path: %s\n' "$fp" "$wtpath"
    printf '      consequence: delete this directory and its rebuildable ignored output. Other local data prevents removal.\n'
  done < "$WT_ROWS"
fi

echo
plan_collect_artifacts
ARTIFACT_RC=$?
echo '## Why'
echo '> Add your reason here. The apply command records it with the result.'
return "$ARTIFACT_RC"
}

plan_collect_artifacts() {
  local artifact_rc=0
  artifact_args=(--plan --root "$ROOT")
  [ "$CACHES_ONLY" -eq 0 ] || artifact_args+=(--caches-only)
  wc -l < "$PLAN_DOCUMENT" > "$PLAN_CAPTURE/artifact-offset"
  AFTERPARTY_PLAN_CAPTURE="$PLAN_CAPTURE/artifacts" "$DIR/clean-artifacts.sh" "${artifact_args[@]}" || artifact_rc=$?
  return "$artifact_rc"
}
