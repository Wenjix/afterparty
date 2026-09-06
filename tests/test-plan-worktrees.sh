#!/usr/bin/env bash
# The worktree section of the plan. `git --clean` became report-only in 0.9.0
# because it discovered candidates and destroyed them in one step; this is
# where removal comes back, as a typed target a person approves.
#
# The rule this file exists to pin: filesystem items are NEVER pre-checked.
# Restarting a dev server and deleting a worktree are not the same consequence,
# so the tool proposes processes and merely SURFACES filesystem targets.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

age() { touch -d "$1" "$3" 2>/dev/null || touch -t "$(date -v "$2" +%Y%m%d%H%M)" "$3"; }

# --- a real repo with real worktrees; git is NOT shimmed here -------------
W="$T/proj"
git init -qb main "$W"
git -C "$W" config user.email t@t.local
git -C "$W" config user.name tester
git -C "$W" commit -q --allow-empty -m one
git -C "$W" worktree add -q "$T/wt-clean" -b agent/clean HEAD
git -C "$W" worktree add -q "$T/wt-halfdone" -b agent/dirty HEAD
printf 'uncommitted\n' > "$T/wt-halfdone/scratch.txt"
git -C "$W" worktree add -q "$T/wt-busy"  -b agent/busy HEAD

# --- transcripts: the repo is stale; wt-busy has a process living in it ---
R="$T/projects"; mkdir -p "$R/proj"
# The transcript's recorded cwd is physical too (Node's process.cwd() resolves
# symlinks), and workspace attribution compares it byte-exactly against lsof's
# output. A fixture that mixed the two forms would make every process look
# unattributable -- which is also the real failure mode if the two ever diverge.
printf '{"cwd":"%s"}\n' "$(cd "$W" && pwd -P)" > "$R/proj/a.jsonl"
age '300 days ago' -300d "$R/proj/a.jsonl"

SHIM="$T/shim"; mkdir -p "$SHIM"
# One dev process, idle, sitting in the stale repo -- so the run also produces
# a CHECKED process item. Without that positive control, "no [x] on a worktree"
# would pass just as well on a run that produced no checkable items at all.
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,command=*) printf '9001 npm run dev\n9002 vitest --watch\n9003 next dev\n' ;;
  *pgid=,lstart=,command=*) printf '9001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu,command*)  printf '9001 9001  0.0 npm run dev\n'
                            printf '9002 9002  0.0 node watcher.js\n' ;;
  *pgid=,command=*)         printf '9001 npm run dev\n' ;;
  *) exit 1 ;;
esac
PS
# lsof reports the PHYSICAL path -- verified on this platform: a process whose
# cwd is /var/folders/.../sub is reported as /private/var/folders/.../sub. The
# shim must emit the same form, because `git worktree list` also emits physical
# paths, and a shim that emitted the /var form would make the occupancy veto
# look broken when the mismatch was the fixture's.
PW="$(cd "$W" && pwd -P)"
PBUSY="$(cd "$T/wt-busy" && pwd -P)"
cat > "$SHIM/lsof" <<LS
#!/usr/bin/env bash
[ "\${PLAN_LSOF_EMPTY:-0}" = 1 ] && exit 0
case "\$*" in
  *-d\ cwd*) printf 'p9001\nfcwd\nn%s\n' "$PW"
             printf 'p9002\nfcwd\nn%s\n' "$PBUSY" ;;
  *) exit 1 ;;
esac
LS
chmod +x "$SHIM/ps" "$SHIM/lsof"

# Extract one "## Name" section. Every assertion below is scoped through this:
# the process and worktree sections both mention the same paths, so an
# unscoped grep silently reads the wrong section and reports on rows the case
# was never about.
section() { awk -v want="## $1" '$0 == want { on = 1; next } on && /^## / { exit } on { print }'; }

run_plan() { PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" AFTERPARTY_STYLE=never \
  bash "$LIB/plan.sh" --all 2>/dev/null; }
WT_ID_AVAILABLE=1
# Probe the host capability independently. Choosing expectations from the
# fingerprint function itself would let a broken fingerprint skip its test.
WT_BIRTH="$(LC_ALL=C TZ=UTC0 stat -c '%w' -- "$T/wt-clean" 2>/dev/null \
  || LC_ALL=C TZ=UTC0 stat -f '%.9FB' -- "$T/wt-clean" 2>/dev/null)" || WT_BIRTH=""
case "$WT_BIRTH" in ''|'-'|'?'|0|0.*|-1|-1.*) WT_ID_AVAILABLE=0 ;; esac
OUT="$(cd "$T" && run_plan)"
WT="$(printf '%s\n' "$OUT" | section Worktrees)"
PR="$(printf '%s\n' "$OUT" | section "Process groups")"

# ---------- PW1: a clean stale worktree is surfaced, typed, fingerprinted ----------
_b=$FAILS
printf '%s\n' "$OUT" | grep -q '^## Worktrees$' || fail "PW1: no Worktrees section"
printf '%s\n' "$WT" | grep -q 'wt-clean' || fail "PW1: the clean stale worktree was not listed at all"
if [ "$WT_ID_AVAILABLE" -eq 1 ]; then
  printf '%s\n' "$WT" | grep -A1 'wt-clean' | grep -q 'type: worktree' \
    || fail "PW1: wt-clean carries no type"
  printf '%s\n' "$WT" | grep -A1 'wt-clean' | grep -Eq 'fingerprint: [0-9a-f]{12}' \
    || fail "PW1: wt-clean carries no fingerprint: $(printf '%s\n' "$WT" | grep -A1 wt-clean | tr '\n' '|')"
else
  printf '%s\n' "$WT" | grep -q '^- \[⊘\] identity-unavailable .*path .*/wt-clean  ' \
    || fail "PW1: unavailable creation identity did not withhold wt-clean: $WT"
fi
[ "$FAILS" -eq "$_b" ] && pass "PW1: a clean worktree is surfaced with identity or its explicit unavailability"

# ---------- PW2: filesystem items arrive UNCHECKED, processes may not ----------
_b=$FAILS
if [ "$WT_ID_AVAILABLE" -eq 1 ]; then
  printf '%s\n' "$WT" | grep 'wt-clean' | grep -q '^- \[ \]' \
    || fail "PW2: wt-clean was not offered unchecked: $(printf '%s\n' "$WT" | grep wt-clean)"
else
  printf '%s\n' "$WT" | grep -q '^- \[⊘\] identity-unavailable .*path .*/wt-clean  ' \
    || fail "PW2: wt-clean with unavailable identity was not withheld"
fi
# positive control: this same run DID pre-check something, so the absence above
# is the filesystem rule and not an empty plan
printf '%s\n' "$PR" | grep -q '^- \[ \].*pgid 9001' \
  || fail "PW2: control — the run offered no process, so the empty state would make this vacuous"
[ "$FAILS" -eq "$_b" ] && pass "PW2: worktrees arrive unchecked and eligible processes both arrive unchecked"

# ---------- PW3: a dirty worktree is withheld, and says why ----------
_b=$FAILS
printf '%s\n' "$WT" | grep -q 'wt-halfdone' || fail "PW3: the dirty worktree was not reported at all"
printf '%s\n' "$WT" | grep 'wt-halfdone' | grep -q '^- \[⊘\]' \
  || fail "PW3: wt-halfdone was offered rather than withheld: $(printf '%s\n' "$WT" | grep wt-halfdone)"
# Anchored on the verdict COLUMN and on the reason line, so neither can be
# satisfied by the path. The fixture is no longer named 'dirty' either, but a
# test should not depend on a fixture name to stay honest.
printf '%s\n' "$WT" | grep -q '^- \[⊘\] dirty .*wt-halfdone' \
  || fail "PW3: the verdict column does not read dirty: $(printf '%s\n' "$WT" | grep wt-halfdone)"
printf '%s\n' "$WT" | grep -A1 'wt-halfdone' | grep -q '^ *not offered: dirty' \
  || fail "PW3: the reason line does not name dirty: $(printf '%s\n' "$WT" | grep -A1 wt-halfdone | tr '\n' '|')"
printf '%s\n' "$WT" | grep -A1 'wt-halfdone' | grep -q 'fingerprint:' \
  && fail "PW3: a withheld item carries a fingerprint, which apply could act on"
[ "$FAILS" -eq "$_b" ] && pass "PW3: uncommitted work withholds the worktree and names the reason"

# ---------- PW4: the main worktree is never a target ----------
_b=$FAILS
# The physical form: `git worktree list` emits resolved paths, so an assertion
# written against the unresolved $W matches nothing and passes whatever the
# code does. That is why this case stayed green while the main worktree was
# being classified by a veto that could not identify it.
WPHYS="$(cd "$W" && pwd -P)"
# positive control FIRST: without it this case passes on a run that produced
# no worktree section whatsoever, which is exactly how it passed while the
# feature was unimplemented.
[ -n "$WT" ] || fail "PW4: control — the worktree section is empty, so nothing is being classified"
printf '%s\n' "$WT" | grep -q 'wt-clean' \
  || fail "PW4: control — no linked worktree was classified, so the absence below proves nothing"
printf '%s\n' "$WT" | grep -E "^- \\[[ x]\\].*path $WPHYS([[:space:]]|\$)" \
  && fail "PW4: the main worktree was offered as a removable target"
printf '%s\n' "$WT" | grep -Eq "path $WPHYS([[:space:]]|\$)" \
  && fail "PW4: the main worktree appears in the worktree section at all"
[ "$FAILS" -eq "$_b" ] && pass "PW4: the repo's main worktree is never offered for removal"

# ---------- PW5: a worktree with a live process in it reads in-use ----------
_b=$FAILS
printf '%s\n' "$WT" | grep -q 'wt-busy' || fail "PW5: the occupied worktree was not reported"
printf '%s\n' "$WT" | grep 'wt-busy' | grep -q '\[⊘\]' \
  || fail "PW5: wt-busy was offered despite a live process inside it"
printf '%s\n' "$WT" | grep -A1 'wt-busy' | grep -q 'occupied' \
  || fail "PW5: wt-busy is not marked occupied: $(printf '%s\n' "$WT" | grep -A1 wt-busy | tr '\n' '|')"
[ "$FAILS" -eq "$_b" ] && pass "PW5: a worktree hosting a live process is withheld as in-use"

# ---------- PW6: the caller's own worktree is withheld ----------
_b=$FAILS
WT2="$(cd "$T/wt-clean" && run_plan | section Worktrees)"
printf '%s\n' "$WT2" | grep 'wt-clean' | grep -q '\[⊘\]' \
  || fail "PW6: standing inside wt-clean still offered it: $(printf '%s\n' "$WT2" | grep wt-clean)"
printf '%s\n' "$WT2" | grep -A1 'wt-clean' | grep -q 'current' \
  || fail "PW6: the reason is not 'current'"
[ "$FAILS" -eq "$_b" ] && pass "PW6: the worktree the caller occupies is withheld"

# ---------- PW7: the current repo needs no Claude transcript to be found ----------
_b=$FAILS
mkdir -p "$W/subdir"
WT3="$(cd "$W/subdir" && R="$T/no-projects" run_plan | section Worktrees)"
if [ "$WT_ID_AVAILABLE" -eq 1 ]; then
  printf '%s\n' "$WT3" | grep -Eq '^- \[ \] unknown[[:space:]]+path .*/wt-clean  .*no transcript' \
    || fail "PW7: a current-repo worktree without a transcript was not offered unchecked as unknown: $WT3"
  printf '%s\n' "$WT3" | grep -A1 'path .*/wt-clean  ' | grep -Eq 'type: worktree  fingerprint: [0-9a-f]{12}' \
    || fail "PW7: the discovered worktree has no executable target metadata"
else
  printf '%s\n' "$WT3" | grep -q '^- \[⊘\] identity-unavailable .*path .*/wt-clean  .*no transcript' \
    || fail "PW7: the current-repo worktree was not discovered with its unavailable identity: $WT3"
fi
[ "$FAILS" -eq "$_b" ] && pass "PW7: current-repo worktrees are discoverable without Claude history"

# ---------- PW8: current and transcript discovery share one repo listing ----------
_b=$FAILS
mkdir -p "$R/linked"
printf '{"cwd":"%s"}\n' "$(cd "$T/wt-clean" && pwd -P)" > "$R/linked/session.jsonl"
WT4="$(cd "$W/subdir" && run_plan | section Worktrees)"
N_CLEAN="$(printf '%s\n' "$WT4" | grep -cE '^- \[[^]]*\].*path .*/wt-clean  ')"
[ "$N_CLEAN" -eq 1 ] \
  || fail "PW8: current repo and its transcripts produced $N_CLEAN copies of wt-clean: $WT4"
[ "$FAILS" -eq "$_b" ] && pass "PW8: a repository found through multiple workspaces is listed once"

# ---------- PW9: an empty global scan cannot approve an unoccupied worktree ----------
_b=$FAILS
WT5="$(cd "$W" && PLAN_LSOF_EMPTY=1 run_plan | section Worktrees)"
printf '%s\n' "$WT5" | grep -q '^- \[⊘\] occupancy-unavailable .*path .*/wt-clean  ' \
  || fail "PW9: an empty cwd scan did not withhold the discovered worktree: $WT5"
printf '%s\n' "$WT5" | grep -A1 'path .*/wt-clean  ' | grep -q 'fingerprint:' \
  && fail "PW9: a worktree with unknown occupancy carries actionable metadata"
[ "$FAILS" -eq "$_b" ] && pass "PW9: unavailable occupancy is visible and cannot be approved"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
