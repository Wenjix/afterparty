#!/usr/bin/env bash
# audit-git.sh — report (and optionally clean) the git mess agent sessions
# leave behind: stale worktrees, agent-named branches, an abandoned
# .git/index.lock, merge-conflict litter, and stash pileup. Default is a
# DRY-RUN report. --clean applies only the safe subset: worktree prune,
# removal of CLEAN stale worktrees (never --force), deletion of MERGED
# agent branches (-d, never -D), an index.lock past the age gate, and
# UNTRACKED conflict litter. Unmerged branches, dirty worktrees, and
# stashes are report-only, always.
#
# Usage:
#   audit-git.sh                    # dry-run report for the repo at cwd
#   audit-git.sh --clean            # apply the safe subset
#   audit-git.sh --age 14           # staleness threshold in days (default 7)
#   audit-git.sh --root DIR         # operate on the repo containing DIR
#   audit-git.sh --json             # JSON Lines output (one object per finding)
#
# Not a git repo: prints a note and exits 0 (safe for hooks in any cwd).
# Exit codes: 0 ok (even with findings) · 1 partial cleanup failure · 2 usage.
set -uo pipefail

# --- constants ---------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# JSON Lines helpers (json_escape / json_kv* / json_row), shared with the
# other audits.
. "$DIR/json.sh"
# TTY-gated styling + finale cards (plain passthrough on pipes).
. "$DIR/style.sh"
# Private local record of confirmed mutation outcomes.
. "$DIR/journal.sh"

# Branch names owned by coding agents. Extend here to cover more tools.
AGENT_BRANCH_RE='^(claude|codex|cursor|copilot|aider|agent)[/-]'
LOCK_AGE_MIN=60   # an index.lock younger than this may belong to a live git

# --- args --------------------------------------------------------------------
ROOT="$PWD" AGE_DAYS=7 DO_CLEAN=0 JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) DO_CLEAN=1; shift ;;
    --age) AGE_DAYS="${2:?}"; shift 2 ;;
    --root) ROOT="${2:?}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$AGE_DAYS" in ''|*[!0-9]*) echo "--age wants a whole number of days" >&2; exit 2 ;; esac

# --- repo gate + facts ---------------------------------------------------------
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  [ "$JSON" -eq 1 ] || echo "not a git repository: $ROOT (nothing to do)"
  exit 0
fi

g() { git -C "$ROOT" "$@"; }

IS_BARE="$(g rev-parse --is-bare-repository 2>/dev/null)"
# Normalize to the worktree top-level so paths compare against git-emitted
# paths (on Windows git says C:/... while $PWD says /c/... — never mix them).
[ "$IS_BARE" = "true" ] || ROOT="$(g rev-parse --show-toplevel)"
AFTERPARTY_JOURNAL_WORKSPACE="$ROOT"
AFTERPARTY_JOURNAL_WORKSPACE_INITIALIZED=1
GIT_DIR="$(g rev-parse --absolute-git-dir)"
COMMON_DIR="$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$GIT_DIR")"
HAS_COMMITS=0
g rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 && HAS_COMMITS=1
NOW="$(date +%s)"

# --- helpers -------------------------------------------------------------------
# Human-line helpers gate on $JSON; the s_* styling is plain passthrough when
# stdout is not a TTY, so plain output stays byte-identical to legacy.
say()       { [ "$JSON" -eq 1 ] || echo "$@"; }
say_would() { [ "$JSON" -eq 1 ] || s_would "$@"; }
say_ok()    { [ "$JSON" -eq 1 ] || s_ok "$@"; }
say_dim()   { [ "$JSON" -eq 1 ] || s_dim "$@"; }
say_skip()  { [ "$JSON" -eq 1 ] || s_skip "$@"; }
hdr()       { [ "$JSON" -eq 1 ] || s_hdr "$1"; }
warn()      { s_warn "$*"; }

# GNU stat first (Linux, Git Bash), BSD fallback (macOS).
mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

age_days_of() {
  local t="${1:-}" d
  [ -n "$t" ] || t="$NOW"
  d=$(( (NOW - t) / 86400 ))
  [ "$d" -lt 0 ] && d=0
  echo "$d"
}

age_mins_of() {
  local t="${1:-}" m
  [ -n "$t" ] || t="$NOW"
  m=$(( (NOW - t) / 60 ))
  [ "$m" -lt 0 ] && m=0
  echo "$m"
}

# "applied":bool plus an optional trailing "error" pair, for rows that
# describe a mutation.
applied_kv() {
  local ok="$1" err="${2:-}"
  if [ -n "$err" ]; then
    printf '%s,%s' "$(json_kvb applied "$ok")" "$(json_kv error "$err")"
  else
    json_kvb applied "$ok"
  fi
}

CHECKED_OUT_BRANCHES=""
# Branches whose worktrees this run removes or prunes (or, in dry run, would).
# audit_branches treats them as no longer checked out — worktrees are handled
# first, so --clean converges in one pass; if a removal actually failed the
# branch is not freed, and `git branch -d` backstops regardless.
FREED_BRANCHES=""
N_PRUNABLE=0 N_WT=0 N_BRANCH=0 N_LOCK=0 N_LITTER=0 LITTER_BYTES=0 N_STASH=0 N_FAILED=0

# --- worktrees -----------------------------------------------------------------
wt_row() {  # path branch head main state dirty age_days action [applied [error]]
  [ "$JSON" -eq 1 ] || return 0
  if [ $# -ge 9 ]; then
    json_row "$(json_kv section git.worktree)" "$(json_kv path "$1")" \
      "$(json_kvz branch "$2")" "$(json_kvz head "$3")" "$(json_kvb main "$4")" \
      "$(json_kv state "$5")" "$(json_kvb dirty "$6")" "$(json_kvn age_days "$7")" \
      "$(json_kv action "$8")" "$(applied_kv "$9" "${10:-}")"
  else
    json_row "$(json_kv section git.worktree)" "$(json_kv path "$1")" \
      "$(json_kvz branch "$2")" "$(json_kvz head "$3")" "$(json_kvb main "$4")" \
      "$(json_kv state "$5")" "$(json_kvb dirty "$6")" "$(json_kvn age_days "$7")" \
      "$(json_kv action "$8")"
  fi
}

audit_worktrees() {
  hdr "Worktrees"
  local line wt_path="" wt_head="" wt_branch="" wt_locked=0 wt_prunable=0 seen_main=0
  local prune_list="" remove_err

  flush_wt() {
    [ -n "$wt_path" ] || return 0
    local path="$wt_path" head="$wt_head" branch="$wt_branch" locked="$wt_locked" prunable="$wt_prunable"
    wt_path="" wt_head="" wt_branch="" wt_locked=0 wt_prunable=0

    [ -n "$branch" ] && CHECKED_OUT_BRANCHES="$CHECKED_OUT_BRANCHES $branch"

    # The first block from `git worktree list` is always the main worktree.
    if [ "$seen_main" -eq 0 ]; then
      seen_main=1
      say_dim "  main: $path (${branch:-detached}) — never pruned or removed"
      wt_row "$path" "$branch" "$head" 1 active "" "" keep
      return 0
    fi

    [ -e "$path" ] || prunable=1   # fallback for git without the porcelain attr
    if [ "$prunable" -eq 1 ]; then
      N_PRUNABLE=$((N_PRUNABLE + 1))
      if [ "$DO_CLEAN" -eq 1 ]; then
        prune_list="${prune_list}${path}"$'\t'"${branch}"$'\n'
      else
        say_would "  would prune $path (directory gone; admin data only)"
        wt_row "$path" "$branch" "$head" 0 prunable "" "" prune 0
        [ -n "$branch" ] && FREED_BRANCHES="$FREED_BRANCHES $branch"
      fi
      return 0
    fi

    if [ "$locked" -eq 1 ]; then
      say_skip "  locked: $path — left alone"
      wt_row "$path" "$branch" "$head" 0 locked "" "" report
      return 0
    fi

    if [ "$path" = "$ROOT" ]; then
      say_skip "  current: $path — not a removal candidate"
      wt_row "$path" "$branch" "$head" 0 current "" "" report
      return 0
    fi

    local commit_ts dir_ts activity="" age dirty=1 st
    commit_ts="$(g show -s --format=%ct "$head" 2>/dev/null)" || commit_ts=""
    dir_ts="$(mtime_epoch "$path")" || dir_ts=""
    [ -n "$commit_ts" ] && activity="$commit_ts"
    if [ -n "$dir_ts" ] && { [ -z "$activity" ] || [ "$dir_ts" -gt "$activity" ]; }; then
      activity="$dir_ts"
    fi
    age="$(age_days_of "$activity")"

    if st="$(git -C "$path" status --porcelain 2>/dev/null)"; then
      dirty=0
      [ -n "$st" ] && dirty=1
    else
      dirty=1   # cannot prove clean — treat as dirty
    fi

    if [ "$age" -le "$AGE_DAYS" ]; then
      say_skip "  active: $path (${branch:-detached}, idle ${age}d) — keeping"
      wt_row "$path" "$branch" "$head" 0 active "$dirty" "$age" keep
      return 0
    fi

    if [ "$dirty" -eq 1 ]; then
      say_would "  stale but DIRTY: $path (idle ${age}d) — commit or stash inside it, then: git worktree remove $path"
      wt_row "$path" "$branch" "$head" 0 stale 1 "$age" report
      return 0
    fi

    if [ "$DO_CLEAN" -eq 1 ]; then
      # Never --force: git itself refuses dirty/locked worktrees, which is the
      # final guard against races between our check and the remove.
      if remove_err="$(g worktree remove "$path" 2>&1)" && [ ! -e "$path" ]; then
        N_WT=$((N_WT + 1))
        say_ok "  removed $path (clean, idle ${age}d)"
        wt_row "$path" "$branch" "$head" 0 stale 0 "$age" remove 1
        journal_action git.worktree.remove "$path" succeeded "idle_days=$age"
        [ -n "$branch" ] && FREED_BRANCHES="$FREED_BRANCHES $branch"
      else
        N_FAILED=$((N_FAILED + 1))
        warn "worktree remove failed for $path: $remove_err (files may be open — close them and re-run)"
        wt_row "$path" "$branch" "$head" 0 stale 0 "$age" remove 0 "$remove_err"
        journal_action git.worktree.remove "$path" failed "${remove_err:-target still exists}"
      fi
    else
      N_WT=$((N_WT + 1))
      say_would "  would remove $path (clean, idle ${age}d, ${branch:-detached})"
      wt_row "$path" "$branch" "$head" 0 stale 0 "$age" remove 0
      [ -n "$branch" ] && FREED_BRANCHES="$FREED_BRANCHES $branch"
    fi
    return 0
  }

  while IFS= read -r line; do
    case "$line" in
      "worktree "*) flush_wt; wt_path="${line#worktree }" ;;
      "HEAD "*) wt_head="${line#HEAD }" ;;
      "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
      locked*) wt_locked=1 ;;
      prunable*) wt_prunable=1 ;;
    esac
  done < <(g worktree list --porcelain 2>/dev/null)
  flush_wt

  if [ "$seen_main" -eq 0 ]; then
    say_dim "  (no worktrees listed)"
    return 0
  fi

  if [ "$DO_CLEAN" -eq 1 ] && [ "$N_PRUNABLE" -gt 0 ]; then
    # prune only touches admin data under .git/worktrees whose directories
    # are gone — always safe.
    local prune_ok=1 prune_err="" p pruned_branch after_prune=""
    if ! prune_err="$(g worktree prune 2>&1)"; then
      prune_ok=0
      warn "worktree prune failed: $prune_err"
    elif ! after_prune="$(g worktree list --porcelain 2>/dev/null)"; then
      prune_ok=0
      prune_err="could not verify worktree admin data after prune"
      warn "$prune_err"
    fi
    N_PRUNABLE=0
    while IFS=$'\t' read -r p pruned_branch; do
      [ -n "$p" ] || continue
      if [ "$prune_ok" -eq 1 ] \
          && ! printf '%s\n' "$after_prune" | grep -Fqx -- "worktree $p"; then
        N_PRUNABLE=$((N_PRUNABLE + 1))
        say_ok "  pruned $p (admin data)"
        wt_row "$p" "$pruned_branch" "" 0 prunable "" "" prune 1
        journal_action git.worktree.prune "$p" succeeded "admin data removed"
        [ -z "$pruned_branch" ] || FREED_BRANCHES="$FREED_BRANCHES $pruned_branch"
      else
        N_FAILED=$((N_FAILED + 1))
        [ -n "$prune_err" ] || prune_err="worktree entry still present after prune"
        wt_row "$p" "$pruned_branch" "" 0 prunable "" "" prune 0 "$prune_err"
        journal_action git.worktree.prune "$p" failed "$prune_err"
      fi
    done <<< "$prune_list"
  fi
}

# --- agent branches --------------------------------------------------------------
br_row() {  # name merged checked_out age_days ahead action [applied [error]]
  [ "$JSON" -eq 1 ] || return 0
  if [ $# -ge 7 ]; then
    json_row "$(json_kv section git.branch)" "$(json_kv name "$1")" \
      "$(json_kvb merged "$2")" "$(json_kvb checked_out "$3")" \
      "$(json_kvn age_days "$4")" "$(json_kvn ahead "$5")" \
      "$(json_kv action "$6")" "$(applied_kv "$7" "${8:-}")"
  else
    json_row "$(json_kv section git.branch)" "$(json_kv name "$1")" \
      "$(json_kvb merged "$2")" "$(json_kvb checked_out "$3")" \
      "$(json_kvn age_days "$4")" "$(json_kvn ahead "$5")" \
      "$(json_kv action "$6")"
  fi
}

audit_branches() {
  hdr "Agent branches ($AGENT_BRANCH_RE)"
  if [ "$HAS_COMMITS" -eq 0 ]; then
    say_dim "  (no commits yet — skipping)"
    return 0
  fi
  local merged_list name cts merged checked_out age ahead found=0 del_err ref_rc delete_ok
  merged_list="$(g for-each-ref refs/heads --merged HEAD --format='%(refname:short)' 2>/dev/null)"

  while read -r name cts; do
    [ -n "$name" ] || continue
    found=1
    merged=0
    printf '%s\n' "$merged_list" | grep -Fqx -- "$name" && merged=1
    checked_out=0
    case " $CHECKED_OUT_BRANCHES " in *" $name "*) checked_out=1 ;; esac
    if [ "$checked_out" -eq 1 ]; then
      case " $FREED_BRANCHES " in *" $name "*) checked_out=0 ;; esac
    fi
    age="$(age_days_of "$cts")"

    if [ "$merged" -eq 0 ]; then
      ahead="$(g rev-list --count "HEAD..$name" 2>/dev/null)" || ahead=""
      say_would "  unmerged: $name (${ahead:-?} commit(s) not in HEAD, last commit ${age}d ago) — review with: git log HEAD..$name"
      br_row "$name" 0 "$checked_out" "$age" "$ahead" report
      continue
    fi

    if [ "$checked_out" -eq 1 ]; then
      say_would "  merged but checked out: $name — remove that worktree first"
      br_row "$name" 1 1 "$age" "" report
      continue
    fi

    if [ "$DO_CLEAN" -eq 1 ]; then
      # -d only, never -D: git refuses if the branch is not fully merged or
      # is checked out somewhere, which backstops our own checks.
      delete_ok=0
      if del_err="$(g branch -d "$name" 2>&1)"; then
        g show-ref --verify --quiet "refs/heads/$name"
        ref_rc=$?
        case "$ref_rc" in
          1) delete_ok=1 ;;
          0) del_err="branch still exists after git branch -d" ;;
          *) del_err="could not verify branch deletion (show-ref exit $ref_rc)" ;;
        esac
      fi
      if [ "$delete_ok" -eq 1 ]; then
        N_BRANCH=$((N_BRANCH + 1))
        say_ok "  deleted branch $name (merged, last commit ${age}d ago)"
        br_row "$name" 1 0 "$age" "" delete 1
        journal_action git.branch.delete "$name" succeeded "merged; age_days=$age"
      else
        N_FAILED=$((N_FAILED + 1))
        warn "branch -d failed for $name: $del_err"
        br_row "$name" 1 0 "$age" "" delete 0 "$del_err"
        journal_action git.branch.delete "$name" failed "$del_err"
      fi
    else
      N_BRANCH=$((N_BRANCH + 1))
      say_would "  would delete branch $name (merged into HEAD, last commit ${age}d ago)"
      br_row "$name" 1 0 "$age" "" delete 0
    fi
  done < <(g for-each-ref refs/heads --format='%(refname:short) %(committerdate:unix)' 2>/dev/null | grep -E -- "$AGENT_BRANCH_RE")

  [ "$found" -eq 1 ] || say_dim "  (none)"
}

# --- index.lock -------------------------------------------------------------------
lk_row() {  # path age_min action [applied [error]]
  [ "$JSON" -eq 1 ] || return 0
  if [ $# -ge 4 ]; then
    json_row "$(json_kv section git.lock)" "$(json_kv path "$1")" \
      "$(json_kvn age_min "$2")" "$(json_kv action "$3")" "$(applied_kv "$4" "${5:-}")"
  else
    json_row "$(json_kv section git.lock)" "$(json_kv path "$1")" \
      "$(json_kvn age_min "$2")" "$(json_kv action "$3")"
  fi
}

audit_lock() {
  hdr "index.lock"
  local locks="$GIT_DIR/index.lock" lock ts m found=0
  # From a linked worktree, also check the main repo's lock.
  [ "$COMMON_DIR" != "$GIT_DIR" ] && locks="$locks
$COMMON_DIR/index.lock"

  while IFS= read -r lock; do
    [ -n "$lock" ] && [ -e "$lock" ] || continue
    found=1
    ts="$(mtime_epoch "$lock")"
    m="$(age_mins_of "$ts")"
    if [ "$m" -lt "$LOCK_AGE_MIN" ]; then
      say_skip "  left alone: $lock (${m}m old — a git process may still be running)"
      lk_row "$lock" "$m" keep
      continue
    fi
    if [ "$DO_CLEAN" -eq 1 ]; then
      if rm -f -- "$lock" 2>/dev/null && [ ! -e "$lock" ]; then
        N_LOCK=$((N_LOCK + 1))
        say_ok "  removed $lock (${m}m old, gate ${LOCK_AGE_MIN}m)"
        lk_row "$lock" "$m" remove 1
        journal_action git.lock.remove "$lock" succeeded "age_minutes=$m"
      else
        N_FAILED=$((N_FAILED + 1))
        warn "could not remove $lock"
        lk_row "$lock" "$m" remove 0 "rm failed"
        journal_action git.lock.remove "$lock" failed "target still exists"
      fi
    else
      N_LOCK=$((N_LOCK + 1))
      say_would "  would remove $lock (${m}m old, gate ${LOCK_AGE_MIN}m)"
      lk_row "$lock" "$m" remove 0
    fi
  done <<< "$locks"
  [ "$found" -eq 1 ] || say_dim "  (none)"
}

# --- conflict litter ---------------------------------------------------------------
lt_row() {  # path bytes action [applied [error]]
  [ "$JSON" -eq 1 ] || return 0
  if [ $# -ge 4 ]; then
    json_row "$(json_kv section git.conflict)" "$(json_kv path "$1")" \
      "$(json_kvn bytes "$2")" "$(json_kv action "$3")" "$(applied_kv "$4" "${5:-}")"
  else
    json_row "$(json_kv section git.conflict)" "$(json_kv path "$1")" \
      "$(json_kvn bytes "$2")" "$(json_kv action "$3")"
  fi
}

audit_conflict_litter() {
  hdr "Conflict litter (*.orig *.rej *.BACKUP.* *.BASE.* *.LOCAL.* *.REMOTE.*)"
  if [ "$IS_BARE" = "true" ]; then
    say_dim "  (bare repo — no working tree)"
    return 0
  fi
  local f base bytes found=0
  # --others --exclude-standard = untracked only: a tracked foo.orig is
  # deliberate and can never appear here; gitignored litter is user business.
  while IFS= read -r -d '' f; do
    base="${f##*/}"
    case "$base" in
      *.orig|*.rej|*.BACKUP.*|*.BASE.*|*.LOCAL.*|*.REMOTE.*) ;;
      *) continue ;;
    esac
    found=1
    bytes="$(wc -c < "$ROOT/$f" 2>/dev/null | tr -d '[:space:]')"
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    if [ "$DO_CLEAN" -eq 1 ]; then
      if rm -f -- "$ROOT/$f" 2>/dev/null && [ ! -e "$ROOT/$f" ]; then
        N_LITTER=$((N_LITTER + 1)); LITTER_BYTES=$((LITTER_BYTES + bytes))
        say_ok "  removed $f (${bytes} B)"
        lt_row "$f" "$bytes" delete 1
        journal_action git.litter.delete "$ROOT/$f" succeeded "bytes=$bytes"
      else
        N_FAILED=$((N_FAILED + 1))
        warn "could not remove $f"
        lt_row "$f" "$bytes" delete 0 "rm failed"
        journal_action git.litter.delete "$ROOT/$f" failed "target still exists"
      fi
    else
      N_LITTER=$((N_LITTER + 1)); LITTER_BYTES=$((LITTER_BYTES + bytes))
      say_would "  would remove $f (${bytes} B)"
      lt_row "$f" "$bytes" delete 0
    fi
  done < <(g ls-files --others --exclude-standard -z 2>/dev/null)
  if [ "$found" -eq 1 ]; then
    say "  total: $N_LITTER file(s), $LITTER_BYTES B"
  else
    say_dim "  (none)"
  fi
}

# --- stashes -------------------------------------------------------------------------
audit_stashes() {
  hdr "Stashes (report only)"
  local ts ref subj age
  while IFS=$'\t' read -r ts ref subj; do
    [ -n "$ref" ] || continue
    N_STASH=$((N_STASH + 1))
    age="$(age_days_of "$ts")"
    say "  $ref  ${age}d old  $subj"
    if [ "$JSON" -eq 1 ]; then
      json_row "$(json_kv section git.stash)" "$(json_kv ref "$ref")" \
        "$(json_kvn age_days "$age")" "$(json_kv subject "$subj")" "$(json_kv action report)"
    fi
  done < <(g stash list --format='%ct%x09%gd%x09%gs' 2>/dev/null)
  if [ "$N_STASH" -eq 0 ]; then
    say_dim "  (none)"
  else
    say_dim "  stashes are user data — never auto-dropped; review then: git stash drop <ref>"
  fi
}

# --- finale card (styled standalone runs only) ---------------------------------------
print_git_card() {
  local total=$((N_PRUNABLE + N_WT + N_BRANCH + N_LOCK + N_LITTER)) segs
  echo
  s_card_open
  if [ "$DO_CLEAN" -eq 1 ]; then
    s_card_line "${C_BOLD}${C_CYAN}🧾 receipt — afterparty git --clean${C_RESET}"
    segs="$(s_segments \
      "$([ "$total" -gt 0 ] && echo "$G_OK $total cleaned")" \
      "$([ "$N_STASH" -gt 0 ] && echo "$(s_n "$N_STASH" 'stash' 'stashes')")" \
      "$([ "$N_FAILED" -gt 0 ] && echo "$G_SKIP $N_FAILED failed")")"
    if [ -n "$segs" ]; then s_card_line "   $segs"; fi
    if [ "$total" -eq 0 ] && [ "$N_FAILED" -eq 0 ]; then
      s_card_line "   nothing needed doing — already spotless ✨"
    else
      [ "$N_PRUNABLE" -gt 0 ] && s_card_line "   pruned $(s_n "$N_PRUNABLE" 'worktree entry' 'worktree entries')"
      [ "$N_WT" -gt 0 ] && s_card_line "   removed $(s_n "$N_WT" 'worktree' 'worktrees')"
      [ "$N_BRANCH" -gt 0 ] && s_card_line "   deleted $(s_n "$N_BRANCH" 'branch' 'branches')"
      [ "$N_LOCK" -gt 0 ] && s_card_line "   removed $(s_n "$N_LOCK" 'index.lock' 'index.locks')"
      [ "$N_LITTER" -gt 0 ] && s_card_line "   swept $(s_n "$N_LITTER" 'litter file' 'litter files') (${LITTER_BYTES} B)"
      [ "$N_FAILED" -gt 0 ] && s_card_line "   $N_FAILED cleanup action(s) could not be confirmed"
      s_card_line
      s_card_line "   thanks for partying responsibly 🎉"
    fi
  elif [ "$total" -gt 0 ]; then
    s_card_line "${C_BOLD}${C_YEL}🧹 the damage — git${C_RESET}"
    segs="$(s_segments \
      "$G_ACT $total would-clean" \
      "$([ "$N_STASH" -gt 0 ] && echo "$(s_n "$N_STASH" 'stash' 'stashes')")")"
    s_card_line "   $segs"
    [ "$N_PRUNABLE" -gt 0 ] && s_card_line "   $(s_n "$N_PRUNABLE" 'prunable worktree entry' 'prunable worktree entries')"
    [ "$N_WT" -gt 0 ] && s_card_line "   $(s_n "$N_WT" 'stale worktree ready to go' 'stale worktrees ready to go')"
    [ "$N_BRANCH" -gt 0 ] && s_card_line "   $(s_n "$N_BRANCH" 'merged agent branch to delete' 'merged agent branches to delete')"
    [ "$N_LOCK" -gt 0 ] && s_card_line "   $(s_n "$N_LOCK" 'stale index.lock' 'stale index.locks')"
    [ "$N_LITTER" -gt 0 ] && s_card_line "   $(s_n "$N_LITTER" 'litter file' 'litter files') (${LITTER_BYTES} B)"
    [ "$N_STASH" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_STASH" 'stash on the shelf — your call' 'stashes on the shelf — your call'))${C_RESET}"
    s_card_line
    s_card_line "   closing time: ${C_CYAN}afterparty git --clean${C_RESET}"
  else
    s_card_line "${C_BOLD}${C_GRN}✨ spotless — no git mess left behind${C_RESET}"
    [ "$N_STASH" -gt 0 ] && s_card_line "${C_DIM}   ($(s_n "$N_STASH" 'stash on the shelf — your call' 'stashes on the shelf — your call'))${C_RESET}"
    s_card_line "   see you next session 🎉"
  fi
  s_card_close
}

# --- main ----------------------------------------------------------------------------
if [ "$JSON" -eq 0 ]; then
  if [ "$DO_CLEAN" -eq 1 ]; then
    s_mode "$C_RED" "CLEAN" " — sweeping up the git leftovers in $ROOT (safe subset only)" \
      "CLEAN — applying safe git cleanup in $ROOT"
  else
    s_mode "$C_YEL" "DRY RUN" " — checking what the party did to $ROOT (--clean applies the safe subset)" \
      "DRY RUN — reporting git leftovers in $ROOT (use --clean to apply the safe subset)"
  fi
fi

audit_worktrees
audit_branches
audit_lock
audit_conflict_litter
audit_stashes

if [ "$JSON" -eq 0 ]; then
  verb="removable"; verb_br="deletable"
  [ "$DO_CLEAN" -eq 1 ] && { verb="removed"; verb_br="deleted"; }
  echo
  printf 'Summary: %s prunable, %s %s worktree(s), %s %s branch(es), %s stale lock(s), %s litter file(s) (%s B), %s stash(es) (report only)' \
    "$N_PRUNABLE" "$N_WT" "$verb" "$N_BRANCH" "$verb_br" "$N_LOCK" "$N_LITTER" "$LITTER_BYTES" "$N_STASH"
  [ "$N_FAILED" -eq 0 ] || printf ', %s failed' "$N_FAILED"
  printf '\n'
  [ "$DO_CLEAN" -eq 1 ] || echo "Nothing was changed."
  tally_add git.findings "$((N_PRUNABLE + N_WT + N_BRANCH + N_LOCK + N_LITTER))"
  tally_add git.litter_bytes "$LITTER_BYTES"
  tally_add git.stashes "$N_STASH"
  tally_add git.failed "$N_FAILED"
  if cards_on; then print_git_card; fi
fi
if [ "$DO_CLEAN" -eq 1 ] && [ "$N_FAILED" -gt 0 ]; then exit 1; fi
exit 0
