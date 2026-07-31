# Afterparty — agent context

**What this is:** My cleanup tool for the mess coding agents leave behind,
developed independently in this repo (single-root history), shipped three ways:
Claude Code plugin (.claude-plugin/ manifests + asynchronous SessionEnd and
lightweight SessionStart hooks), self-contained Agent Skill
(skills/afterparty/ bundles SKILL.md + VERSION + LICENSE + bin + lib, commands anchored with $CLAUDE_SKILL_DIR), and standalone CLI (root
bin/afterparty wrapper). The LICENSE deliberately retains an earlier author's
copyright line — the code began as an MIT derivative — so never remove it. I'm
iterating on this partly to learn Claude plugin development — explain plugin
mechanics when you touch them.

**Design rules:**

- The skill is a memory hook: keep SKILL.md tiny (~250 words max). Its frontmatter
  description is trigger-only, and the quoted phrases are search keywords — never
  remove them.
- The scripts are the machinery: dry-run by default. Two kill disciplines,
  both deliberate: ledger/audit paths kill by process group (SIGTERM then
  SIGKILL) and skip any group containing a protected process
  (pgid_has_protected); devclean's orphan cleanup signals PIDs instead —
  orphans may share groups with unrelated processes, so group-kill would be
  riskier there. Orphan-targeting of MCP/agent processes is devclean's
  feature, not a protect-list violation. The protect list + its helpers live
  ONLY in skills/afterparty/lib/protect.sh (shared — don't duplicate). It
  covers bare interactive shells via an end-anchored pattern — argumented
  `sh -c` wrappers inside target groups must stay killable.
- devclean --disk age-gates Codex session transcripts (CODEX_SESSION_AGE_DAYS,
  env-overridable, default 30 like Claude Code's retention): transcripts are
  resume history and the audit trail of agent work — only stale YYYY/MM/DD
  date-folders go. pnpm store maintenance also lives in devclean --disk, as
  `pnpm store prune` ONLY — the store is shared across projects, never rm -rf
  it; artifacts deliberately has no --deep flag anymore.
- Three mutation paths: `stop --kill` stops ledger-recorded groups;
  `audit --kill tests|dev|browser` kills by pattern category; `git --clean`
  applies only the safe git subset (worktree prune, clean stale worktrees,
  merged agent branches, aged index.lock, untracked conflict litter) —
  unmerged branches, dirty worktrees, and stashes stay report-only.
- Mutation receipts are postcondition-based: signal delivery and `rm` return
  codes are not enough. Confirm the process/group is absent or the target path
  disappeared, count partial failures, return nonzero, and append the outcome
  through lib/journal.sh. Never journal dry runs.
- Private mutable state is centralized in lib/state.sh. Reports are
  workspace-keyed unless a repo opts into gitignored report.md; ledger add and
  prune mutations must hold the portable lock. Preserve 0700/0600 modes where
  the platform supports them.
- Filesystem mutation boundaries are physical, not merely lexical: reject
  HOME symlink escapes, never select the artifact scan root itself, and route
  every artifact collector through the nested-repository guard.
- Agent-facing output: `--json` on audit/list/git emits JSON Lines (helpers
  live in skills/afterparty/lib/json.sh, sourced like protect.sh).
  `audit --report` writes report.md at the repo root ONLY when the repo
  gitignores it and no unrelated file owns that path (litter/clobber guard),
  else a workspace-keyed cache report;
  the plugin's SessionEnd hook relies on this.
- Terminal styling lives ONLY in skills/afterparty/lib/style.sh, gated on
  TTY / NO_COLOR / AFTERPARTY_STYLE=always|never|auto. Plain (piped) and
  --json output are CONTRACT surfaces — byte-stable; banners and finale
  cards are additive, styled-mode only. Composite `audit` collects child
  counters via the AFTERPARTY_TALLY file; AFTERPARTY_CARD=0 suppresses
  cards (doctor, nested calls).
- The styled instrument layer rides style.sh helpers exclusively: s_sevcell
  severity cells and s_sizecell's shared 100 MB / 1 GB policy (NEUTRAL table
  rows only — never inside whole-line
  s_would/s_kill tints; pad-then-color, ANSI inside %-Ns breaks alignment),
  s_etime, s_meter, s_segments card lines, s_heartbeat (STYLE_ON +
  STYLE_ERR-gated stderr). s_skip (⊘) marks per-item skip/keep/protect
  DECISIONS; s_dim
  stays for noise — "(none)", tips, legends, policy lines. devclean --disk
  styled DRY-RUN buffers rows into share-of-section meters; plain must keep
  streaming the legacy lines (test-review-fixes C1 greps them) and --apply
  always streams so destructive work narrates live. Kill paths tally
  procs.protected for the composite receipt; audit's dry-run listings
  filter protected processes before counting, so audit/composite segments
  claim ⊘ only on kill paths — stop measures protect decisions in both
  modes, so its dry-run cards may carry ⊘. tests/test-proc-tables.sh fakes ps/pgrep/lsof on PATH for
  deterministic tables everywhere — dry-run only, never --kill/--apply
  under the shim.

**Environment gotcha:** I develop on Windows 11 but the scripts are bash targeting
macOS/Linux. Under Git Bash, `rg` and `lsof` are missing and `ps` lacks -Ao, so
process audits print loud warnings and mostly-empty reports — expected, not a bug.
`afterparty git` IS fully testable here (git works; note it emits C:/ paths while
$PWD is /c/ — never compare them). Verify with `bash -n`, `bash tests/run.sh`
(tests/test-kill.sh self-skips here), and `claude plugin validate .`; real kill
behavior is covered by CI's ubuntu job (tests/test-kill.sh — live processes).
Check line endings with `git ls-files --eol` (MSYS grep silently strips CR, so
grepping for \r lies); if a working copy shows w/crlf, fix via `rm` +
`git checkout --`.

**Conventions:** lowercase conventional commits (feat:/fix:/docs:/style:).
LF endings enforced via .gitattributes — scripts must never pick up CRLF.
`skills/afterparty/VERSION` is the canonical release version; synchronize the
plugin manifest and SKILL metadata, bundle the root license, and update
CHANGELOG.md in the same change.

**Known backlog:** shellcheck advisory findings (CI runs `--severity=error`
blocking; full severity is advisory-only for now). Cleanup areas researched
(2026-07) but deliberately deferred:
ml/gpu audit category (jupyter, ollama/vllm, tensorboard, nvidia-smi VRAM
orphans), docker debris, and agent harness-state cleanup (old
transcripts/scratchpads, temp browser profiles).
