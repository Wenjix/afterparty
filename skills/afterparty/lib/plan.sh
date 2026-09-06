#!/usr/bin/env bash
# plan.sh - write a proposal for what could be cleaned, one checkbox per
# process group, for a person to edit.
#
# A proposal, not a decision. Only items that pass the two-signal gate arrive
# checked; in-use, still-working, and no-signal items are listed unchecked with
# the reason stated, so the withholding is visible rather than silent. Every
# checked line carries a fingerprint, which is what lets apply refuse an item
# that moved between planning and applying.
#
# Usage:
#   plan.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"
. "$DIR/fingerprint.sh"
. "$DIR/categories.sh"
. "$DIR/vetoes.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "plan: unknown option: $1" >&2
       echo "plan proposes; 'apply' is what acts on it." >&2
       exit 2 ;;
  esac
done

NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

ws_index > "$T/ws" 2>/dev/null || : > "$T/ws"
ws_pid_cwd > "$T/cwd" 2>/dev/null || : > "$T/cwd"
ps -Ao pid,pgid,%cpu,command 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {
  pid = $1; pg = $2; cpu = $3
  $1 = ""; $2 = ""; $3 = ""; sub(/^[ \t]+/, "")
  print pid "\t" pg "\t" cpu "\t" $0
}' > "$T/ps" || : > "$T/ps"

# Aggregate to the unit that actually gets killed: the process group.
{
  sed 's/^/W\t/' "$T/ws"
  sed 's/^/C\t/' "$T/cwd"
  sed 's/^/P\t/' "$T/ps"
} | awk -F'\t' '
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
    pid = $2; pg = $3; cpu = $4 + 0; cmd = $5
    dir = cwd[pid]; if (dir == "") next
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
    } else if (owner[pg] != resolved) {
      mixed[pg] = 1
    }
    procs[pg]++
    if (cpu > maxcpu[pg]) maxcpu[pg] = cpu
    # busiest member of the group supplies the command the category comes from
    if (cpu >= topcpu[pg] || !(pg in leader)) { topcpu[pg] = cpu; leader[pg] = cmd }
  }
  END {
    # "-" rather than "" for an unknown last-touched: tab is IFS-whitespace, so
    # bash read collapses consecutive tabs and an empty middle field shifts
    # every later column left. That is how a no-transcript workspace ended up
    # parsed as eligible. Same hazard test-review-fixes C6 pins for the ledger.
    for (pg in procs)
      printf "%s\t%s\t%s\t%d\t%.1f\t%s\t%s\n", pg, owner[pg],
             (known[pg] == "" ? "-" : known[pg]), procs[pg], maxcpu[pg],
             (pg in mixed ? "mixed" : "-"), leader[pg]
  }
' | sort -n > "$T/groups"

printf '# afterparty plan — %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '# Check a box to approve it. apply refuses any item whose fingerprint moved,\n'
printf '# and re-checks eligibility, so a plan cannot outlive what it described.\n'
echo
echo '## Process groups'
echo

emit_process_groups() {
if [ ! -s "$T/groups" ]; then
  echo '(nothing attributed to a workspace)'
  return 0
fi

awk -F'\t' '{print $2}' "$T/groups" | ws_unique_labels > "$T/labels" 2>/dev/null || : > "$T/labels"
while IFS=$'\t' read -r pg owner touched procs cpu span cmd; do
  [ -n "$pg" ] || continue
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
  detail="$name · $(s_n "$procs" proc procs) · $age · cpu $cpu"
  # An approved item is executed by delegating to `audit --kill <category>
  # --pgid`, and that flag narrows WITHIN a category. A group matching no
  # category would therefore be approved and then silently not killed, so it is
  # never offered in the first place.
  # A group whose members live in different workspaces cannot be judged by one
  # workspace's staleness, so it is never offered.
  if [ "$span" = "mixed" ]; then
    printf -- '- [⊘] %-8s pgid %s  %s\n' "mixed" "$pg" "$detail"
    printf -- '      not offered: this group spans more than one workspace, so no single staleness applies\n'
    continue
  fi
  category="$(cat_for_command "$cmd" 2>/dev/null)" || category=""
  if [ "$verdict" = "eligible" ] && [ -n "$category" ]; then
    fp="$(fp_for_pgid "$pg" 2>/dev/null)" || fp=""
    if [ -n "$fp" ]; then
      printf -- '- [x] eligible  pgid %s  %s\n' "$pg" "$detail"
      printf -- '      category: %s  fingerprint: %s\n' "$category" "$fp"
      continue
    fi
  fi
  if [ "$verdict" = "eligible" ] && [ -z "$category" ]; then
    printf -- '- [⊘] %-8s pgid %s  %s\n' "no-rule" "$pg" "$detail"
    printf -- '      not offered: no kill discipline for this command — stop it yourself\n'
    continue
  fi
  printf -- '- [⊘] %-8s pgid %s  %s\n' "$verdict" "$pg" "$detail"
  case "$verdict" in
    in-use)  printf -- '      not offered: that workspace was touched recently\n' ;;
    working) printf -- '      not offered: quiet transcript but cpu %s — a long task, not an abandoned one\n' "$cpu" ;;
    unknown) printf -- '      not offered: no transcript, so there is no staleness signal to trust\n' ;;
    *)       printf -- '      not offered: the group vanished before it could be fingerprinted\n' ;;
  esac
done < "$T/groups"
}

emit_process_groups

# --- worktrees ---------------------------------------------------------------
#
# `git --clean` discovered worktrees and removed them in one step, from a
# staleness signal that could not carry the weight, and became report-only in
# 0.9.0. This is where removal comes back: as a typed target, surfaced for a
# person and executed only through apply.
#
# Filesystem items are ALWAYS unchecked. Restarting a dev server and deleting a
# worktree are not the same consequence, and a default that treats them alike
# is a default that will eventually be wrong in the expensive direction.
echo
echo '## Worktrees'
echo

# Filesystem decisions need a complete scan. Process reporting above keeps its
# best-effort attribution, but a failed strict scan must not look unoccupied.
ws_pid_cwd --strict > "$T/wt-cwd" 2>/dev/null || rm -f "$T/wt-cwd"
WT_ROWS="$T/wt-rows"; : > "$WT_ROWS"
# Discovery does not require a staleness signal. A standalone or Codex session
# may have no Claude history, but its current repository still has worktrees.
printf '%s\n' "$(pwd -P)" > "$T/repo-candidates"
awk -F'\t' '{ print $2 }' "$T/ws" >> "$T/repo-candidates"
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
  listing="$(git -C "$wsdir" worktree list --porcelain 2>/dev/null)" || continue
  [ -n "$listing" ] || continue
  printf '%s\n' "$common" >> "$T/seen-repos"
  repo_root="$(printf '%s\n' "${listing%%$'\n'*}" | sed -n 's/^worktree //p')"
  printf '%s\n' "$listing" \
    | awk -v repo="$repo_root" '
        /^worktree / { if (p != "") print p "\t" b "\t" repo; p = substr($0, 10); b = "(detached)"; next }
        /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
        END { if (p != "") print p "\t" b "\t" repo }' >> "$WT_ROWS"
done < "$T/repo-candidates"

if [ ! -s "$WT_ROWS" ]; then
  echo '(no worktrees in the current repository or indexed workspaces)'
else
  while IFS=$'\t' read -r wtpath branch repo; do
    [ -n "$wtpath" ] || continue
    reason="$(veto_for worktree "$wtpath" "$repo" "$T/wt-cwd")"
    # Staleness: the worktree's own transcript if it has one, else the repo's.
    # A worktree is part of the work someone does in that repo, so the repo
    # being fresh is a reason to leave its worktrees alone.
    touched="$(awk -F'\t' -v w="$wtpath" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($2,w) { print $1; exit }' "$T/ws")"
    [ -n "$touched" ] || touched="$(awk -F'\t' -v w="$repo" 'function samepath(a,b){return (length(a)==length(b) && index(a,b)==1)} samepath($2,w) { print $1; exit }' "$T/ws")"
    if [ -n "$touched" ]; then
      age="idle $(ws_human_age "$((NOW - touched))")"
    else
      age="no transcript"
    fi
    detail="$branch · $age"
    if [ -n "$reason" ]; then
      # main-worktree is structural noise, not a decision a person needs to
      # read: every repo has exactly one and it is never a candidate.
      [ "$reason" = "main-worktree" ] && continue
      printf -- '- [⊘] %-8s path %s  %s\n' "$reason" "$wtpath" "$detail"
      case "$reason" in
        dirty)    printf -- '      not offered: dirty — uncommitted work inside it; commit or stash, then re-plan\n' ;;
        occupied) printf -- '      not offered: occupied — a live process is running in it\n' ;;
        occupancy-unavailable) printf -- '      not offered: occupancy-unavailable — cannot complete the process cwd scan\n' ;;
        current)  printf -- '      not offered: current — you are standing in it\n' ;;
        *)        printf -- '      not offered: %s\n' "$reason" ;;
      esac
      continue
    fi
    verdict="$(elig_verdict "$touched" 0 "$NOW")"
    fp="$(fp_for_worktree "$wtpath" 2>/dev/null)" || fp=""
    if [ -z "$fp" ]; then
      if [ -d "$wtpath" ]; then
        printf -- '- [⊘] %-8s path %s  %s\n' "identity-unavailable" "$wtpath" "$detail"
        printf -- '      not offered: identity-unavailable — cannot establish filesystem creation identity\n'
      else
        printf -- '- [⊘] %-8s path %s  %s\n' "gone" "$wtpath" "$detail"
        printf -- '      not offered: it vanished before it could be fingerprinted\n'
      fi
      continue
    fi
    printf -- '- [ ] %-8s path %s  %s\n' "$verdict" "$wtpath" "$detail"
    # path LAST, and prefixed with 'path:' rather than positional: a worktree
    # path may contain spaces, and every other field is a fixed token, so
    # 'everything after path:' is the one parse that cannot be ambiguous. The
    # repo is not recorded because apply derives it from the worktree itself --
    # a field a person could edit into disagreeing with the target is a field
    # worth not having.
    printf -- '      type: worktree  fingerprint: %s  path: %s\n' "$fp" "$wtpath"
  done < "$WT_ROWS"
fi

echo
echo '## Why'
echo '> (free text; apply records this with the receipt)'
