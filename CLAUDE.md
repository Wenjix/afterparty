# Afterparty — agent context

**What this is:** My cleanup tool for the mess coding agents leave behind,
developed independently in this repo (single-root history), shipped three ways:
Claude Code plugin (.claude-plugin/ manifests + hooks/hooks.json SessionEnd
hook), self-contained Agent Skill (skills/afterparty/ bundles SKILL.md + bin +
lib, commands anchored with $CLAUDE_SKILL_DIR), and standalone CLI (root
bin/afterparty wrapper). The LICENSE deliberately retains an earlier author's
copyright line — the code began as an MIT derivative — so never remove it. I'm
iterating on this partly to learn Claude plugin development — explain plugin
mechanics when you touch them.

**Design rules:**

- The skill is a memory hook: keep SKILL.md tiny (~250 words max). Its frontmatter
  description is trigger-only, and the quoted phrases are search keywords — never
  remove them.
- The scripts are the machinery: dry-run by default, kill by process group
  (SIGTERM then SIGKILL), protect-list lives ONLY in
  skills/afterparty/lib/protect.sh (shared — don't duplicate it).
- Three mutation paths: `stop --kill` stops ledger-recorded groups;
  `audit --kill tests|dev|browser` kills by pattern category; `git --clean`
  applies only the safe git subset (worktree prune, clean stale worktrees,
  merged agent branches, aged index.lock, untracked conflict litter) —
  unmerged branches, dirty worktrees, and stashes stay report-only.
- Agent-facing output: `--json` on audit/list/git emits JSON Lines (helpers
  live in skills/afterparty/lib/json.sh, sourced like protect.sh).
  `audit --report` writes report.md at the repo root ONLY when the repo
  gitignores it (litter guard), else `~/.cache/agent-processes/report.md`;
  the plugin's SessionEnd hook relies on this.

**Environment gotcha:** I develop on Windows 11 but the scripts are bash targeting
macOS/Linux. Under Git Bash, `rg` and `lsof` are missing and `ps` lacks -Ao, so
process audits print loud warnings and mostly-empty reports — expected, not a bug.
`afterparty git` IS fully testable here (git works; note it emits C:/ paths while
$PWD is /c/ — never compare them). Verify with `bash -n`, dry runs, and
`claude plugin validate .`; real kill behavior is only testable on macOS/Linux.
Check line endings with `git ls-files --eol` (MSYS grep silently strips CR, so
grepping for \r lies); if a working copy shows w/crlf, fix via `rm` +
`git checkout --`.

**Conventions:** lowercase conventional commits (feat:/fix:/docs:/style:).
LF endings enforced via .gitattributes — scripts must never pick up CRLF.

**Known backlog:** ledger pgid-recycling defense; logo is still the old broom
mark (party-themed redesign pending); no CI (shellcheck would be a good
addition). Cleanup areas researched (2026-07) but deliberately deferred: ml/gpu
audit category (jupyter, ollama/vllm, tensorboard, nvidia-smi VRAM orphans),
docker debris, and agent harness-state cleanup (old transcripts/scratchpads,
temp browser profiles).
