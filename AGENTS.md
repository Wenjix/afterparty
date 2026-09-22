# Afterparty — agent context

This is the canonical repository-wide agent context. Host-specific instruction
files should defer here instead of duplicating project rules.

**What this is:** My cleanup tool for the mess coding agents leave behind,
developed independently in this repo (single-root history), shipped three ways:
Claude Code plugin (.claude-plugin/ manifests + bounded synchronous SessionEnd and
lightweight SessionStart hooks), self-contained Agent Skill
(skills/afterparty/ bundles SKILL.md + VERSION + LICENSE + bin + lib, commands anchored with ${CLAUDE_SKILL_DIR}), and standalone CLI (root
bin/afterparty wrapper). The LICENSE deliberately retains an earlier author's
copyright line — the code began as an MIT derivative — so never remove it. I'm
iterating on this partly to learn Claude plugin development — explain plugin
mechanics when you touch them.

**Design rules:**

- Documentation review separates deterministic evidence (`lib/docs.py`, via
  `docs.sh`) from agent judgment (`commands/docs.md` and the bundled
  `docs-review.md` protocol). Collection never edits project files or calls an
  LLM. Current guidance and historical records have different purposes; age
  alone is not a stale verdict. Store evidence and agent reviews separately in
  `state_docs_dir`; new scans must not erase unresolved reviews. Scope and
  collection/review completion are explicit. `docs --check` refuses changed or
  incomplete evidence before the agent's selected edits. Keep documentation
  out of artifact deletion. Tests cross the public CLI in disposable repos.
- The skill is a memory hook: keep SKILL.md tiny (~250 words max). Its frontmatter
  description is trigger-only, and the quoted phrases are search keywords — never
  remove them.
- The scripts are the machinery: dry-run by default. Two kill disciplines,
  both deliberate: ledger/audit paths kill by process group (SIGTERM then
  SIGKILL) and skip any group containing a protected process
  (pgid_has_protected); devclean's orphan cleanup signals PIDs instead —
  orphans may share groups with unrelated processes, so group-kill would be
  riskier there. Devclean also checks the shared protection patterns and
  withholds matching PIDs. The protect list + its helpers live
  ONLY in skills/afterparty/lib/protect.sh (shared — don't duplicate). It
  covers bare interactive shells via an end-anchored pattern — argumented
  `sh -c` wrappers inside target groups must stay killable — and running
  agent sessions (claude, Codex) via token/path boundaries: a bare
  substring would match the `.claude/...` path in the argv of every shell
  Claude Code spawns, so pgid_has_protected would refuse the dev-server
  groups this tool exists to clean. These patterns are heuristic and do not
  cover every editor, shell invocation, or MCP server. Category patterns face the same hazard
  from the opposite side: an agent's whole prompt lives in its argv, so no
  pattern may span a space with `.*` or it will match ordinary prose.
- `glance` is the return surface and is READ-ONLY by construction: no --kill,
  no --apply, and tests/test-glance.sh pins the rejection so a later flag
  cannot make it mutate. Its severity axis is MAGNITUDE (cpu, count, idle
  time); reversibility belongs to the approval surface, not here. Workspace
  identity and staleness are shared through skills/afterparty/lib/workspace.sh
  and its Python 3 transcript reader (don't duplicate). Index every Claude
  immediate-project JSONL file under AFTERPARTY_TRANSCRIPT_ROOT (default
  $HOME/.claude/projects), plus Codex sessions and archived_sessions under
  AFTERPARTY_CODEX_ROOT (default ${CODEX_HOME:-$HOME/.codex}). Indexed identity
  comes from normalized recorded cwd paths, never directory slugs. Use the
  latest contributing file mtime across providers and retain source provenance.
  A newer or equally recent indexed ancestor contributes activity and provider
  provenance to descendants; keep their workspace rows distinct.
  A Codex session_meta or turn_context can introduce another cwd: subsequent
  file activity conservatively refreshes every cwd recorded in that file.
  This is neither human-presence evidence nor exact per-workspace visit time.
  Indexing only reads existing files; it needs no registration or new hook.
  An absent optional directory is an empty source. Failed, corrupt or incomplete
  inspection, including missing Python 3, invalidates the entire activity index;
  never keep partial timestamps as cleanup evidence. JSONL records over 32 MiB
  including any trailing newline are unavailable; the exact limit is accepted.
  A workspace with no
  transcript has NO last-touched time - treat unknown as "cannot tell", never
  "forgotten". Visible processes without indexed activity remain visible through cwd attribution.
  Attribution is one `lsof -d cwd` call for the whole machine; per-pid would
  be ~500 forks. Never key staleness on process liveness alone.
- `plan` proposes and `apply` disposes, and apply NEVER signals: it delegates to
  audit --kill --pgid so there is exactly one kill discipline. Two rules hold
  it together. Kill categories live ONLY in lib/categories.sh (shared with
  audit-processes.sh - don't duplicate); `--pgid` narrows WITHIN a category, so
  plan must withhold any group matching no category or it would approve an
  action that silently never happens. And the checkbox is the authority, not
  the fingerprint - the fingerprint (pgid + start time + command, lib/
  fingerprint.sh) compares observed identity with the reviewed group. These
  checks are not atomic OS ownership guarantees. Process eligibility is the
  two-signal rule in lib/eligible.sh; `unknown` is never eligible for a process
  plan. Worktrees/artifacts instead require their filesystem, occupancy and
  identity checks; stale transcript evidence is not required for their removal.
- TSV rows written for `read` must never carry an empty middle field: tab is
  IFS-whitespace, so consecutive tabs collapse and every later column shifts
  left. Emit a sentinel ("-"). test-review-fixes C6 pins this for the ledger;
  plan.sh reintroduced it once already.
- devclean --history age-gates Codex session transcripts (CODEX_SESSION_AGE_DAYS,
  env-overridable, default 30): transcripts are
  resume history and the audit trail of agent work — date-folder selection is followed by a complete last-modification scan.
  Recent or uninspectable history is withheld. pnpm store maintenance also lives in devclean --disk, as
  `pnpm store prune` ONLY — the store is shared across projects, never rm -rf
  it; its configured store may be outside HOME. History also covers whole
  Codex log and Gemini browser-recording directories, not Claude transcripts.
  These cleanup paths remain under HOME and exclude archived_sessions;
  activity-index overrides must not widen or redirect deletion scope.
  artifacts deliberately has no --deep flag anymore.
- Discovery may be heuristic; DESTRUCTION requires fresh, positive proof. Three surfaces are now REPORT-ONLY: `git --clean`, `artifacts --clean`
  (both exit 2), and devclean's roaming `clean_find`
  project scan (reports, withholds). The cut is roaming-vs-named, not
  apply-vs-report: `clean_dir` targets an exact allowlisted cache path and
  still deletes; `clean_find` walks $DOCUMENTS_ROOT hunting a NAME with no
  liveness, git-tracked, or age gate. Repository removal uses plan/apply as
  typed targets (process-group, worktree, artifact), each with its own
  fingerprint and apply-time policy. Approval does NOT replace safety checks:
  tracked target, symlink or scope escape, repo root, nested repo, and
  incomplete scans stay hard vetoes even when a human ticks the box, and every plan item starts unchecked. Plan defaults to the current repo;
  --all includes other visible Git workspaces for processes and additional
  transcript-indexed repositories for worktrees. Artifact scope stays the
  selected repository. Devclean requires
  individual preview target IDs; --disk never implies process stopping.
- `stop --kill` stops ledger-recorded groups; `audit --kill
  tests|dev|browser` kills by pattern category. Worktree removal requires a
  checked plan item and `apply`; `git --clean` remains report-only. Worktree
  fingerprints include physical directory and Git administrative creation
  identity, so replacements cannot inherit approval. Unsupported identity is
  a refusal. Filesystem occupancy uses `ws_pid_cwd --strict`; remove the map
  on discovery failure, and refresh it after process cleanup for each worktree.
  A nested-repository scan excludes only the worktree's own root `.git` entry;
  ignored nested repositories and scan failures still veto removal.
- Mutation receipts are postcondition-based: signal delivery and `rm` return
  codes are not enough for signals and path deletion. Confirm the process/group
  is absent or the target path disappeared; native-tool operations such as pnpm
  maintenance use that tool's result. Count failures, return nonzero, and append
  mutation outcomes through lib/journal.sh. Some pre-mutation refusals are only
  printed. Never journal dry runs; receipt failure must not erase a confirmed
  mutation from counts or return a successful overall status.
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
  the plugin's SessionEnd hook writes a separate bounded session marker,
  with no audit. Explicit reports retain session archives and completion status.
- Terminal styling lives ONLY in skills/afterparty/lib/style.sh, gated on
  TTY / NO_COLOR / AFTERPARTY_STYLE=always|never|auto. Plain (piped) and
  --json output are CONTRACT surfaces — stable data contracts; intentional safety/status changes need regression coverage. Banners and finale
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
- A test that asserts an effect is ABSENT proves nothing unless it also proves
  the code path was ENTERED. Assert a positive signal alongside the absence:
  the rejection message must name the flag, the withheld item must carry its
  verdict token, the refusal line must name the pgid. Five assertions here were
  found unable to fail — a trailing positional satisfied a rejection check, a
  substring matched the wrong column, a fixture's decoy sorted the same way as
  the correct answer, an item was withheld by an earlier rule than the one under
  test, and a receipt hardcoded the words the assertion searched for. Verify a
  new guard by mutating the production code in a scratch copy and confirming the
  test goes red.
- Test isolation requires intercepted tools/signals and disposable state, not
  just HOME. Orphan discovery reaches the real process table and launch-agent
  operations reach launchctl gui/<uid>/<label>. pnpm resolves a configured
  store that may be independent of HOME. Any fixture reaching --apply MUST
  intercept kill, pgrep, launchctl AND pnpm before entering production code.
  ORPHAN_PATTERNS includes agent names, but shared protection still vetoes them.
  Verify with a logging shim on
  PATH: nothing from an --apply path should reach the real binaries.
  The Linux live-kill suite intentionally uses real processes and broad category
  discovery; run the full suite in a disposable VM/container or CI runner.
  Fixtures that age files need the GNU-then-BSD touch fallback (touch -d,
  else touch -t with date -v) — the suite must pass on macOS too.

**Platform notes:** The scripts target macOS/Linux Bash. Under stock Git Bash,
`rg` and `lsof` may be missing and `ps` lacks the required detailed table;
process audits must report unavailable evidence. Git reports work, but worktree
and artifact deletion still require complete occupancy and identity evidence.
Git may emit C:/ paths while $PWD is /c/ — normalize before comparing. Use
`bash -n` for syntax; the full suite belongs in an isolated runner and the
live-kill suite self-skips on unsupported platforms. Validate the marketplace,
plugin manifest, skills and commands explicitly as described in README.md;
marketplace validation alone does not inspect skill/command/hook contents.
Check line endings with `git ls-files --eol` (MSYS grep silently strips CR, so
grepping for \r lies). Normalize line endings without discarding local edits.

**Conventions:** lowercase conventional commits (feat:/fix:/docs:/style:).
LF endings enforced via .gitattributes — scripts must never pick up CRLF.
`skills/afterparty/VERSION` is the canonical release version; synchronize the
plugin manifest and SKILL metadata, bundle the root license, and update
CHANGELOG.md in the same change.

**Session completion:** before ending an authorized task, inspect `git status`,
run the relevant tests, run the documentation review when the user-facing
contract changed, and summarize unresolved work. Commit, push, merge, and
release only when the task explicitly authorizes that action. Never describe a
change as complete while required work remains uncommitted or unverified.

**Known backlog:** shellcheck advisory findings (CI runs `--severity=error`
blocking; full severity is advisory-only for now). Cleanup areas researched
(2026-07) but deliberately deferred:
ml/gpu audit category (jupyter, ollama/vllm, tensorboard, nvidia-smi VRAM
orphans), docker debris, and additional agent harness-state cleanup
(scratchpads and temporary browser profiles). Codex history and Gemini browser
recordings already have the explicit devclean --history mode.
