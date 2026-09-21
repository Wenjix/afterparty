<p align="center">
  <img src="./assets/afterparty-logo.svg" alt="Afterparty confetti logo" width="132" height="132">
</p>

<h1 align="center">Afterparty</h1>

<p align="center">
  Cleanup for the mess coding agents leave behind.
</p>

Afterparty is a Bash and Python toolkit for the work that remains after an
agent session: development servers, test watchers, automation browsers,
worktrees, build caches, stale session history, and documentation that no
longer describes the code. It can run as a Claude Code plugin, a standalone
Agent Skill, or a local CLI.

Afterparty collects evidence first. Cleanup needs an explicit, reviewable
request, and each target is checked again immediately before it changes
anything. Documentation review is a separate agent-led workflow: the
collector finds evidence and the agent decides whether a document should be
updated, retained, archived, or otherwise treated.

## Quick start

Choose the installation that matches where you want Afterparty to run.

### Claude Code plugin

```text
/plugin marketplace add Wenjix/afterparty
/plugin install afterparty@afterparty
```

Then, from a repository:

```text
/afterparty:audit
/afterparty:docs
```

`/afterparty:audit` reports processes, listeners, ledger entries, and Git
leftovers. `/afterparty:docs` reviews documentation affected by the current
changes. Both are report-first; neither silently deletes project data.

The plugin also provides the general `/afterparty:afterparty` skill. Its
lifecycle hooks are deliberately small:

- `SessionStart` shows the last explicit audit, the bounded session-end marker,
  and saved documentation-review summaries. It does not run a machine-wide
  audit.
- `SessionEnd` records the session ID and end time. It does not run an audit or
  cleanup after the agent exits.

### Standalone CLI

```bash
git clone https://github.com/Wenjix/afterparty.git
cd afterparty
./bin/afterparty audit
```

To invoke it from any directory in the current shell:

```bash
export PATH="$PWD/bin:$PATH"
afterparty audit
```

The standalone CLI has no plugin hooks. Use `afterparty audit --report` when
you want a durable snapshot for the next session.

### Agent Skill

The `skills/afterparty` directory follows the [Agent Skills](https://agentskills.io)
standard and contains the skill instructions, version, license, executable,
and every library file it uses. Copy the directory into the skill location
for the host you use:

```bash
# Claude Code
mkdir -p ~/.claude/skills
cp -r skills/afterparty ~/.claude/skills/

# Codex
mkdir -p ~/.agents/skills
cp -r skills/afterparty ~/.agents/skills/
```

Claude substitutes `${CLAUDE_SKILL_DIR}` when it runs a skill. Other agents
must resolve the absolute directory containing `SKILL.md` and invoke its
`bin/afterparty`; `${CLAUDE_SKILL_DIR}` is not a universal environment
variable. Installing a skill does not put `afterparty` on your terminal
`PATH`.

See the host instructions for [Claude skills](https://code.claude.com/docs/en/skills#where-skills-live)
and [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
for host-specific loading behavior.

Other Agent Skills-compatible hosts can use the same folder when they support
local shell execution. Hosted environments such as Claude.ai run scripts in
their own environment and cannot inspect or clean processes on your local
machine.

## What it does

| Surface | Purpose | Default behavior |
| --- | --- | --- |
| `afterparty glance` | Show visible processes grouped by workspace, with unknown attribution kept visible | Read-only |
| `afterparty docs` | Collect documentation evidence and local-link observations for agent review | No project-file edits |
| `afterparty audit` | Report recorded processes, listeners, test/watch runners, dev servers, automation browsers, and Git litter | Report-only; `--kill` acts on a requested category |
| `afterparty list`, `add`, `prune`, `stop` | Record and inspect long-running process groups | `add`/`prune` write the private ledger; `stop` needs `--kill` |
| `afterparty plan` and `apply` | Propose and execute a checked process, worktree, or artifact checklist | `plan` proposes; `apply` acts only on checked items |
| `afterparty git` | Find stale worktrees, agent branches, lock files, conflict litter, and stashes | Report-only; worktree removal uses `plan`/`apply` |
| `afterparty artifacts` | Find rebuildable build, cache, and test output | Report-only; removal uses `plan`/`apply` |
| `afterparty devclean` | Review orphan processes, machine caches, settings, and old agent history | Preview; mutation needs exact target IDs |
| `afterparty doctor` | Run the main diagnostics together | Reports by default; `--strict` fails on unavailable process/listener evidence |
| `afterparty report` and `actions` | Read the latest audit and confirmed mutation history | Read-only except for report/session bookkeeping |

The commands target different kinds of leftovers on purpose. A process-group
approval does not authorize a worktree deletion, and a documentation review
does not authorize cleanup.

## The first post-session workflow

1. **See what is left.** Run `afterparty audit` for a repository and machine
   snapshot, or `afterparty glance` when you want a workspace-grouped view of
   visible processes.
2. **Review documentation drift.** Before handing code to another agent, run
   `afterparty docs --report --json` or `/afterparty:docs`. Use `--since REF`
   when you know the commit where the work began; use `--full` for a complete
   repository documentation pass.
3. **Choose cleanup targets.** Run `afterparty plan > cleanup-plan.md`, inspect
   every proposed item, and check only the items you approve. For a narrow
   process action, review the reported process group and use its exact PGID.
4. **Apply the reviewed choice.** Run `afterparty apply cleanup-plan.md`, or
   use a target-specific command such as
   `afterparty audit --kill dev --pgid <reviewed-pgid>` or
   `afterparty devclean --disk --apply --target <reviewed-id>`.
5. **Leave a handoff.** Run `afterparty audit --report` to save the current
   snapshot. The next session can read it with `afterparty report --show` or
   locate it with `afterparty report-path`.

Angle-bracket values in examples are placeholders. Replace them before
running a command. A dry run, report, or review is not an approval to mutate
anything.

## Command examples

```bash
# Inspect the current machine and repository.
afterparty audit
afterparty glance --oneline

# Save a durable audit and read it later.
afterparty audit --report
afterparty report --show

afterparty report-path

# Collect documentation evidence for agent review.
afterparty docs --report --json
afterparty docs --since <git-ref> --report

afterparty docs --full --report

# Track an existing process; the text after -- is a display label.
afterparty add --pid <PID> --kind dev --port <PORT> \
  --purpose "verify the local app" -- pnpm dev

afterparty list --json
afterparty stop --kill

afterparty prune

# Propose, review, and apply typed cleanup targets.
afterparty plan > cleanup-plan.md
# Edit cleanup-plan.md and check only approved items.
afterparty apply cleanup-plan.md

afterparty plan --artifacts-only > artifact-plan.md

# Review explicit devclean targets before applying them.
afterparty devclean --disk
afterparty devclean --disk --apply --target <reviewed-id>

# Machine-readable output and action history.
afterparty audit --json
afterparty list --json
afterparty git --json
afterparty docs --report --json
afterparty actions --all --since 2026-09-01
afterparty --version
```

`afterparty add` registers a process that already exists. It does not launch
the command after `--`, and it attributes the record to the caller's current
workspace rather than reading the target process's working directory. Run it
from the repository that owns the process.

`afterparty stop --kill` acts on matching groups already in the ledger. It has
no idle or CPU gate, so review the list and scope first. `afterparty audit
--kill tests|dev|browser` handles unrecorded machine-wide groups; add reviewed
`--pgid` values to narrow the action. `--keep <pgid>` spares a known group.

`list`, `stop`, and `prune` default to the current Git repository. Pass
`--all` to cover every recorded repository, `--root DIR` to select another
repository, and `--kind KIND` to filter `list` or `stop`.

## Documentation review

The documentation pass has two responsibilities:

1. The deterministic collector (`afterparty docs`) gathers changed paths,
   related documents, purpose hints, symbols and flags from the diff, and
   conservative local Markdown-link observations.
2. The invoking agent reads the implementation and documents, decides what is
   still true, prepares concrete previews, and applies only the treatments the
   user selects.

The collector never edits project documents, executes commands copied from a
document, fetches remote links, or decides that age alone makes a document
stale. A finding is evidence for review, not an automatic deletion.

### Scope and reports

```bash
afterparty docs                           # HEAD versus staged/unstaged/untracked files
afterparty docs --since <git-ref> --report --json
                                           # include changes since a known ref
afterparty docs --full --report            # all documentation in the repository
afterparty docs --template <scan-id>      # review JSON template
afterparty docs --save-review <file.json> # save an agent-authored review
afterparty docs --check <scan-id>         # verify evidence before editing
afterparty docs --show                    # latest review, or evidence if none
afterparty docs --report-path             # path to the latest docs report
```

The default scope compares `HEAD` with staged, unstaged, and untracked files;
it includes pre-existing local changes and does not infer a session-start
baseline. `--since REF` makes that baseline explicit. `--full` includes all
recognized documentation under the selected repository. `--root DIR` selects a
different repository.

Evidence and agent reviews are stored separately in private workspace state.
A new scan does not overwrite the last review. `--show` prefers the latest
review and returns nonzero for partial coverage; the invoking agent carries
unresolved findings into a later review. Complete collection and complete
review are separate statuses; a complete review can still contain unresolved
findings.

### Treatments

A review can recommend **update**, **mark historical**, **consolidate**,
**archive**, **delete**, **flag for review**, or **keep**. The agent should
show the evidence, reason, alternatives, and exact patch or move/delete
preview before asking for a selection. Uncertain findings should stay flagged
or kept. Marking a document historical preserves its release or decision
context; it does not mean that the document is wrong.

Before applying selected edits, run `afterparty docs --check <scan-id>`.
Changed or incomplete evidence requires a fresh collection and revised
proposal. Saving a review records the agent's decisions; it does not apply the
edits or independently verify them. See the bundled
[review protocol and JSON format](skills/afterparty/docs-review.md).

Discovery covers Markdown/MDX, reStructuredText, AsciiDoc, text documents, and
known extensionless README or changelog files that are tracked or untracked
and not ignored. Common dependency/build directories, symlinks, submodules,
nested repositories, unreadable files, non-UTF-8 files, relevant files over
2 MiB, and oversized diffs produce explicit exclusions or gaps. Local-link
checks cover simple Markdown inline and reference destinations with file
extensions. They do not fetch remote links, resolve anchors or website routes,
or parse every Markdown construct. Incomplete collection cannot support a
complete review.

## Auditing processes and listeners

`afterparty audit` combines three reports:

- ledger entries for groups Afterparty knows about;
- likely development listeners on loopback or wildcard bindings, test/watch
  runners, frontend/backend dev servers, and automation browsers; and
- Git session litter such as stale worktrees, agent branches, lock files,
  conflict files, and stashes.

The process classifier uses executable and subcommand evidence. It is a
heuristic inventory, not proof that a process belongs to an agent or is safe
to stop. Listener reports exclude other bindings and protected command matches.
Use `afterparty audit --strict` when unavailable process or listener evidence
must make the command fail. `doctor` runs the normal ledger, process, Git,
artifact, and default orphan reports; it does not run every devclean mode.

### Returning to a machine

`afterparty glance` is a read-only, machine-wide view grouped by workspace. It
keeps unattributed processes visible and can render a status-line form with
`--oneline` or JSON Lines with `--json`. It has no kill or apply flag.

Activity comes from existing agent transcripts:

| Provider | Files inspected |
| --- | --- |
| Claude | Every `*.jsonl` file in immediate project directories under `${AFTERPARTY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}` |
| Codex | JSONL files below `sessions` and `archived_sessions` in `${AFTERPARTY_CODEX_ROOT:-${CODEX_HOME:-$HOME/.codex}}` |

Workspace identity comes from recorded cwd paths, normalized across providers.
The activity timestamp is the newest contributing transcript-file mtime, not a
human-presence signal or an exact visit time. Codex session and turn records
can name multiple workspaces; a changed file conservatively refreshes every
workspace it names. Activity from an indexed ancestor also contributes to a
descendant while rows remain distinct.

Indexing is read-only and requires no registration or lifecycle hook. Missing
optional directories are empty sources. A corrupt, unreadable, incomplete, or
oversized record, or missing Python 3, makes the entire activity index
unavailable; partial timestamps cannot authorize process cleanup. A workspace
with no indexed activity has no last-touched time and is treated as “cannot
tell,” never as “forgotten.” Process liveness alone is not a staleness signal.

`AFTERPARTY_IDLE_HOURS` sets the positive whole-hour activity threshold for
process-plan eligibility (default `4`). `AFTERPARTY_BUSY_CPU` sets the per-process
CPU threshold (default `20`). These are eligibility inputs, not proof of
abandonment.

## Approving cleanup with plan/apply

`afterparty plan` writes an editable checklist for the current repository.
Every actionable item starts unchecked. Use `--root DIR` for another
repository; `--all` widens process and worktree discovery to other visible Git
workspaces and transcript-indexed repositories. Artifact scope remains the
selected repository. `--artifacts-only` and `--caches-only` narrow the proposal.

Process rows include members, purpose, workspace, listener ports, activity
evidence, and group-wide consequences. Busy, in-use, unknown, protected,
mixed-workspace, unsupported, and no-category groups are withheld with a
reason. Worktrees and artifacts use filesystem, occupancy, nested-repository,
and identity checks rather than transcript age.

Edit the checkboxes, then run `afterparty apply <plan>`. Apply validates every
checked entry before any mutation. It refuses malformed metadata, duplicate or
unsupported targets, changed fingerprints, path mismatches, unsafe scope,
tracked data, symlink escapes, repository roots, nested repositories, occupied
paths, or incomplete scans. The checkbox is the authority: an unchecked item
is inert even if another field says it is eligible.

`apply` never signals a process directly. It delegates approved process groups
to the same gated `audit --kill` path, so group semantics, protection checks,
identity checks, and postcondition receipts are shared. Process and filesystem
observations are not atomic operating-system ownership guarantees; review the
actual target and consequence immediately before applying.

## Git cleanup

`afterparty git` reports worktrees, agent-named branches, old index locks,
conflict litter, and stashes. `--age <days>` changes the discovery threshold;
`--root DIR` selects a repository; `--json` emits JSON Lines. `git --clean` is
a report-only compatibility flag and exits 2. Branch, lock, conflict-file,
and stash deletion is not supported by that command.

Worktree removal is available only through a checked `plan` item and
`afterparty apply`. Before removal, Afterparty refreshes occupancy, physical
path and Git administrative identity, and scans for nested repositories
(including ignored ones). Dirty or occupied worktrees, symlinks, unknown
ignored data, current/main worktrees, failed scans, and unavailable identity
are withheld. Removal uses `git worktree remove` without `--force` and confirms
that the target disappeared.

## Artifacts

`afterparty artifacts` reports known rebuildable output:

- **Caches:** `.turbo`, `.vite`, `.cache`, `.parcel-cache`, `.rollup.cache`,
  `node_modules/.cache`, `*.tsbuildinfo`, and `.eslintcache`.
- **Build output:** `.next`, `dist`, `build`, `out`, `.output`, `.svelte-kit`,
  `.astro`, and `storybook-static`.
- **Test output:** `coverage`, `.nyc_output`, `test-results`,
  `playwright-report`, `.playwright-mcp`, and `.vitest`.

Use `afterparty plan --artifacts-only --root <repo>` to create an unchecked
proposal, review it, and apply it with `afterparty apply`. `artifacts --clean`
is report-only and exits 2. Tracked paths, symlinks, nested repositories,
occupied targets, failed inspections, scope escapes, and unavailable identity
withhold deletion. Entire dependency installations such as `node_modules` are
not selected, although their cache directories may be.

## Devclean

Devclean has separate modes because an orphan process, a cache, a persistent
setting, and old agent history have different consequences. Preview first;
`--apply` alone is refused, and every mutation needs an ID copied from a
preview with the same mode and scope.

```bash
afterparty devclean            # orphan-process candidates
afterparty devclean --deep     # daemon and simulator candidates
afterparty devclean --optimize # dumps, settings, and launch-agent targets
afterparty devclean --disk     # rebuildable caches; never signals processes
afterparty devclean --history  # stale Codex/Gemini history targets

afterparty devclean --disk --apply --target <reviewed-id>
```

`--target` can be repeated for multiple explicit approvals. Target identity is
rechecked at the action boundary; a changed or uninspectable target remains
visible and fails the command. Directory IDs identify the reviewed directory,
not an immutable recursive snapshot of its future contents.

`--optimize` separates deletion from persistent settings and launch-agent
changes. Settings edits use effective JSONC values, retain a backup, and show
restoration instructions; Python 3 is required for JSONC parsing.

`--history` considers Codex session day directories, `~/.codex/log`, and
`~/.gemini/antigravity/browser_recordings`; it does not clean Claude
transcripts. The paths remain under `HOME`, exclude archived Codex sessions,
and require a complete scan whose newest regular-file mtime is older than
`CODEX_SESSION_AGE_DAYS` (default `30`). A selected directory must occupy at
least 1024 KiB. `--disk` keeps the shared pnpm store intact and uses `pnpm store
prune` for unreferenced packages. Roaming project scans under
`--documents-root DIR` are report-only; repository artifacts still use
plan/apply.

## Reports, state, and history

Private state normally lives under
`${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/`:

- `ledger.tsv` records process ownership and observed member identities;
- workspace-keyed reports store the latest audit and documentation evidence;
- session archives preserve concurrent audit snapshots and bounded session-end
  markers; and
- `actions.jsonl` records confirmed mutation outcomes.

`AGENT_PROCESS_LEDGER` overrides only the ledger path and its adjacent lock.
`afterparty report-path` and `afterparty actions-path` print canonical paths.
Use `afterparty actions --all --workspace DIR --since YYYY-MM-DD` to filter
history. A positive `AFTERPARTY_RETENTION_DAYS` opts into trimming old action
receipts on writes; `0` preserves them. Session report archives are retained.
State directories are private (`0700`) and state files are private (`0600`)
where the platform supports those POSIX modes.

An audit report can be written to `report.md` in the repository only when that
name is already ignored and no unrelated file owns it. Otherwise it is written
to a workspace-keyed cache path. `report --show` returns nonzero for an
incomplete report. JSON output is versioned JSON Lines and never authorizes
cleanup. `audit --json` and `audit --report` are mutually exclusive; `docs`
may combine `--json` and `--report` for evidence collection.

Saved report bodies, ledger labels, and journal target/detail fields apply
best-effort redaction to common credential arguments, assignments, and URL
credentials. Paths and hashes remain, arbitrary secret formats are not fully
covered, and free-form command arguments should not contain secrets. A
confirmed mutation with a failed receipt is reported separately and returns
nonzero. Early refusals may exist only in console output. Set
`AFTERPARTY_JOURNAL=0` to opt out of the action journal.

## Safety model

- Discovery is read-only by default. Explicit `--kill`, checked `apply`, and
  selected devclean target IDs are the mutation surfaces.
- Ledger and audit cleanup operate on process groups, send `SIGTERM` before
  `SIGKILL`, and refuse groups containing a protected process. Devclean signals
  individual orphan PIDs because an orphan can share a group with unrelated
  processes.
- Required process, protection, occupancy, identity, and nested-repository
  scans fail closed. A missing or unknown signal cannot become an approval.
- Filesystem and signal mutations require a verified postcondition. Native
  maintenance uses the underlying tool's result, such as `pnpm store prune` or
  a `launchctl` probe.
- Git, artifact, and home-cache scopes are physically checked. Symlink parents
  cannot redirect named home-cache actions outside `HOME`; the configured pnpm
  store is a separate native-tool target and may be outside `HOME`.
- Protection patterns cover selected editors, shells, Claude/Codex agents, and
  MCP servers such as `playwright-mcp` and `chrome-devtools-mcp`. They are
  heuristics, not exhaustive process identification.

Afterparty reports observations, not an atomic guarantee about what another
process will do after a check. Review the actual target and consequences.

## Requirements and platform support

- Bash 3.2 or newer, Git, and standard Unix tools including `ps`, `awk`,
  `find`, `stat`, `du`, and a hashing utility.
- `rg` for process matching; audit falls back to `grep -E` when it is absent.
- `lsof` for listener and filesystem-occupancy reports. Worktree and artifact
  removal require a successful occupancy scan.
- Python 3 for documentation evidence and review storage, Claude/Codex
  activity indexing, effective JSONC edits, and macOS simulator inspection.
  Missing Python makes activity unavailable and withholds dependent cleanup and
  Python-backed optimize/simulator targets.
- macOS or Linux is the native target. WSL provides the Unix process interface
  on Windows. Git Bash supports Git/filesystem commands and explicitly degraded
  process reports; its live-kill coverage is skipped where the required tools
  are unavailable.
- macOS-only `launchctl`, Xcode-cache, and iOS-simulator checks are skipped on
  other platforms.

## Development and validation

Check shell syntax and blocking lint errors:

```bash
for script in bin/afterparty skills/afterparty/bin/afterparty skills/afterparty/lib/*.sh tests/*.sh; do
  bash -n "$script" || exit 1
done
shellcheck --severity=error skills/afterparty/lib/*.sh
claude plugin validate --strict .claude-plugin/marketplace.json
claude plugin validate .claude-plugin/plugin.json
claude plugin validate --strict skills
claude plugin validate --strict commands
```

Marketplace validation does not inspect every skill, command, or hook file;
validate those directories explicitly. The plugin validator may warn that the
root `CLAUDE.md` is developer context rather than installed agent context.
The bundled `SKILL.md` supplies the installed context.

Run `bash tests/run.sh` in a disposable VM, container, or CI runner. Linux
live-stop tests perform machine-wide discovery and real signals; changing
`HOME` alone does not isolate them. Other mutation fixtures intercept machine
tools and signals. CI runs the suite on Ubuntu and Windows, with ShellCheck
at `--severity=error`.

The [documentation accuracy audit](docs/reviews/documentation-audit.md) records
an earlier contract review and its implementation limits. Historical plans in
`docs/plans/` describe the releases that introduced the current safety model;
the current command contract is this README plus command help.

The CLI reads its version from `skills/afterparty/VERSION`. Keep the plugin
manifest and skill metadata synchronized with it, bundle the root license, and
record user-visible changes in [CHANGELOG.md](./CHANGELOG.md).

## Lineage

The first iteration of Afterparty combined my own agent cleanup skills and
methods with [Agent-Broom](https://github.com/Kevin-Liu-01/Agent-Broom) by Kevin
Liu. The LICENSE retains Kevin Liu's copyright line.

## License

MIT — see [LICENSE](./LICENSE).
