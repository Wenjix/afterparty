<p align="center">
  <img src="./assets/afterparty-logo.svg" alt="Afterparty confetti logo" width="132" height="132">
</p>

<h1 align="center">Afterparty</h1>

<p align="center">
  Cleanup for the mess coding agents leave behind.
</p>

An agent session ends and leaves things behind: a dev server still bound to
`localhost:3000`, a Vitest watcher no one is watching, a headless Chrome with
no owner, worktrees and `claude/*` branches no one will return to, and a
gigabyte of `.next` and `node_modules/.cache`.

Afterparty inventories these leftovers, reports what it could inspect, and
requires specific approval before cleanup. Missing evidence required by a
target's checks withholds that action.

## Why Afterparty

- **One toolkit, the whole mess.** Processes, ports, watchers, automation
  browsers, git session litter, rebuildable artifacts, and dev caches share
  one CLI, with separate approval and safety checks for each target type.
- **It reports to the next agent, not just to you.** Versioned `--json` output emits JSON
  Lines, and `audit --report` persists a Markdown report — so the next
  session starts by reading what the last one left running instead of
  starting yet another server on `localhost:3000`.
- **Cleanup requires an explicit request.** Cleanup uses
  checked plan items, process-stop flags, or devclean target
  IDs. `git --clean` and `artifacts --clean` are report-only compatibility flags.
- **Group cleanup checks a shared protect list.** Ledger and audit kills refuse
  groups containing a process that matches the bundled protection patterns.
  Devclean checks the same patterns when reviewing individual orphan PIDs.
- **Receipts describe outcomes, not attempts.** A delivered signal or an
  `rm` invocation is not counted as success until Afterparty confirms the
  process exited or the path disappeared. Cleanup failures return nonzero;
  mutation outcomes are written to a private local action journal. Some
  refusals before mutation are reported only in the command output.
- **No prompt rituals, no guessing from `ps` output.** Cleanup is a script
  you can read, with a dry run you can inspect, not a wall of instructions
  the agent half-remembers.
- **Tested where it counts.** CI runs the suite on Linux and Windows. Linux
  includes live process-group stop tests; intercepted fixtures cover additional
  failure and refusal paths. Unsupported platform checks explicitly skip.

## Install

### As a Claude Code plugin

```text
/plugin marketplace add Wenjix/afterparty
/plugin install afterparty@afterparty
```

The plugin adds lifecycle wiring around the same terminal CLI:

- a bounded synchronous `SessionEnd` hook records the session ID and end time;
  it performs no audit or cleanup;
- a lightweight `SessionStart` hook shows the last explicit audit's age and
  completion status, plus the session-end marker;
- `/afterparty:audit` runs the audit on demand; `clean` requests cleanup within
  the user's approved scope. A failing audit stays visible without aborting
  the instructions. `/afterparty:afterparty` loads the general cleanup skill.

Run `afterparty audit --report` when you need a durable current snapshot. The
session-end marker explicitly says no exit-time scan occurred; it does not
promise that background work finishes after Claude exits.

### As a plain agent skill

Afterparty follows the [Agent Skills](https://agentskills.io) standard, and
the skill folder is self-contained — `SKILL.md`, `VERSION`, `LICENSE`, plus every script it runs,
with commands anchored to Claude's literal `${CLAUDE_SKILL_DIR}` substitution.
In another agent, resolve the absolute directory of the loaded `SKILL.md` and
run its `bin/afterparty`; this Claude substitution is not a universal environment
variable. Copying the folder supplies the CLI and supporting files.
From the repository checkout, for Claude Code:

```bash
mkdir -p ~/.claude/skills
cp -r skills/afterparty ~/.claude/skills/
```

For Codex's user skill directory:

```bash
mkdir -p ~/.agents/skills
cp -r skills/afterparty ~/.agents/skills/
```

See the host instructions for [Claude skills](https://code.claude.com/docs/en/skills#where-skills-live)
and [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills).

Other Agent Skills-compatible tools can use the same folder when they support
local shell execution; use the skill installation location documented by that
host. Installing a skill or plugin does not put `afterparty` on your terminal's
`PATH`: the agent invokes the bundled executable by its absolute path.
Hosted environments such as Claude.ai may execute skill scripts in their own
runtime, but they cannot inspect or clean processes on your local machine.
Claude's hosted script support is described in its
[custom skills guide](https://support.claude.com/en/articles/12512198-how-to-create-custom-skills#add-scripts).

The skill itself stays tiny by design. It is the *when* — a memory hook that
reminds the agent cleanup is due. The scripts are the *how*, and they are the
only thing that ever acts.

### As a standalone CLI

```bash
git clone https://github.com/Wenjix/afterparty.git
cd afterparty
bin/afterparty audit
```

Or put `bin` on your path:

```bash
export PATH="$PWD/bin:$PATH"
afterparty audit
```

## Commands

Cleanup discovery commands report by default. `apply` executes an already
reviewed checklist immediately. Ledger bookkeeping and report commands also
write local state, as described below.

| Command | Reports | Acts with |
| --- | --- | --- |
| `afterparty glance` | processes visible to the scanner, grouped by workspace with unknown attribution retained | *(reports only)* |
| `afterparty plan` | unchecked process, worktree, and artifact checklist for the current repository | *(proposes only)* |
| `afterparty apply <plan>` | executes the boxes you checked, refusing anything that moved | *(acts on approved targets)* |
| `afterparty audit` | recorded processes, dev servers, watchers, browsers, git litter | `--kill tests\|dev\|browser` |
| `afterparty stop` | ledger-recorded process groups | `--kill` |
| `afterparty git` | stale worktrees, agent branches, lock files, conflict litter | worktrees through `plan` / `apply`; `--clean` is report-only |
| `afterparty artifacts` | rebuildable build/cache output | checked `plan` / `apply` items |
| `afterparty devclean` | orphan candidates; separate `--deep`, `--optimize`, `--disk`, `--history` modes | `--apply --target <reviewed-id>` |

`list` reads the ledger and may initialize its file; `add` records a running
process; `prune` removes records for confirmed absent groups. These commands
do not stop processes. `doctor` combines ledger, process, Git, artifact and
default orphan reports. `doctor --strict` additionally makes unavailable
process/listener capabilities an error; it is not a complete check of every
devclean mode or a prerequisite that replaces cleanup-time checks.

```bash
afterparty audit                   # ledger, machine processes/listeners, and current Git repo
afterparty audit --json            # same findings, as JSON Lines
afterparty audit --report          # persist the report for the next session
afterparty report --show           # read this workspace's persisted report
afterparty audit --kill dev --pgid <reviewed-pgid> # act only on a reviewed group
afterparty add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
afterparty list --json             # the ledger, for machines
afterparty stop --kill             # stop this repo's recorded groups
afterparty prune                   # drop this repo's dead ledger entries
afterparty git                     # report git leftovers
afterparty plan > cleanup-plan.md  # save the checklist, then review its boxes
afterparty apply cleanup-plan.md   # apply the checked items
afterparty plan --artifacts-only   # preview unchecked artifact removals
afterparty devclean --disk         # report disk-heavy targets
afterparty doctor                  # combined diagnostics; no deep/disk/history/optimize modes
afterparty doctor --strict         # also fail on unavailable process/listener capabilities
afterparty actions                 # this workspace's JSONL mutation history
afterparty actions --all --since 2026-09-01 # filter global history
afterparty --version               # installed package version
```

The ledger commands (`list`, `stop`, `prune`) scope to the current repo by
default; pass `--all` to cover every repo, or `--root <dir>` for another
(`plan`, `git` and `artifacts` accept `--root` too). `list` and `stop` can also
filter by `--kind`.

Angle-bracket values in examples are placeholders to replace before running
the command. `add` does not launch the trailing command: it is an optional
display label. Run `add` from the intended workspace, because the recorded
workspace and cwd come from the caller, not from the PID's working directory.

There are two kill paths, and they answer different questions. `stop --kill`
stops what Afterparty *recorded*: process groups from the ledger, where
current member identities must still match the recorded ownership. `audit --kill <tests|dev|browser>` handles
the strays nobody recorded, classified by executable and supported subcommand. Audit discovery is
machine-wide; use reviewed `--pgid` values to narrow mutation. Both accept
`--keep <pgid>` to spare a group. Category cleanup additionally accepts
`--pgid <id[,id...]>`, which restricts mutation to the exact groups you
reviewed.

## Reports that outlive the session

The post-session report is the point, so it comes in three shapes:

- **Styled**, on an interactive terminal — for you (see [Style](#style)).
- **JSON Lines**, via `--json` on `audit`, `list`, and `git` — one
  `schema_version: 1` object per finding, for agents and scripts.
- **Persisted**, via `audit --report` — written to `report.md` at the repo
  root *only* when the repo already gitignores that name (a cleanup tool must
  not litter your repos) and no unrelated file already owns the path,
  otherwise to a workspace-keyed path under
  `~/.cache/agent-processes/reports/` (or `$XDG_CACHE_HOME`).
  Add `report.md` to a repo's `.gitignore` to opt in to per-repo reports. The
  `afterparty report-path` prints the canonical latest-audit location. Each
  `audit --report` invocation also gets its own session snapshot, so concurrent sessions
  retain their reports. Status, failed sections, timestamp, and session ID stay
  in the saved report; `report --show` returns nonzero for an incomplete report.

`--json` does not authorize cleanup and cannot combine with process `--kill`.
`audit --report` and `--json` are mutually exclusive. A plain `audit` may report
unavailable process capabilities while returning 0; use `audit --strict` or
`audit --report` when that must be an error. A saved report is marked complete
when all invoked audit sections return success; it does not cover every
Afterparty capability or prove that the
machine has no other processes.

## The ledger

`afterparty add` records long-running processes in
`~/.cache/agent-processes/ledger.tsv` — timestamp, repo root, cwd, PID,
PGID, kind, port, purpose, command, and observed process-member identities. The result: the next agent can see
what is running *and why* before spinning up a duplicate.

Ledger state is private (`0700` directory, `0600` file where the platform
supports POSIX modes). `add` and `prune` use a portable advisory lock so a
concurrent prune cannot overwrite a newly recorded process. Older records
without member identity cannot authorize stopping a process. Listings
distinguish a verified live group, confirmed absence (`dead`), failed inspection
(`unknown`), and missing or changed identity (`unverified`). Prune retains
records when inspection fails or workers still survive.

## The audit

`afterparty audit` reports:

- processes recorded in the ledger
- likely development TCP listeners on loopback or wildcard bindings;
  other bindings and protected command matches are filtered out
- test/watch runners such as Vitest, Jest, and pytest
- frontend/backend dev servers such as Next, Vite, Turbo, Bun, Uvicorn, and
  Rails
- automation browsers
- git session litter: stale worktrees, agent branches, conflict files, stashes

Human audit output also shows the protection patterns used to withhold
category cleanup. It does not list every protected process.

### Coming back to the machine

`afterparty glance` answers the question you actually arrive with: what was I
doing, and what is still running from it? It is machine-wide, grouped by
workspace, with unindexed or unattributed processes kept visible. Agent
transcript activity is an observation, not proof of recent human use.
`--oneline` fits a tmux status line; `--json` emits JSON Lines.

Severity in the glance combines observed CPU, process count and time since
Claude or Codex transcript activity. It does not measure when a person last looked.

Glance never acts. There is no `--kill`, and a test pins that so a future flag
cannot quietly turn it into a mutation surface.

**Where activity evidence comes from.** The shared index reads existing Claude
and Codex JSONL transcripts automatically:

| Provider | Files inspected |
| --- | --- |
| Claude | Every `*.jsonl` file in immediate project directories under `${AFTERPARTY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}` |
| Codex | JSONL files under `sessions` and `archived_sessions` in `${AFTERPARTY_CODEX_ROOT:-${CODEX_HOME:-$HOME/.codex}}` |

Codex discovery includes nested session directories. Workspace identity comes
from recorded cwd paths, normalized across both providers; activity time is the
newest contributing transcript-file mtime. Glance identifies the providers
contributing evidence. Codex `session_meta` and `turn_context` records can name
multiple workspaces. When that file changes, every recorded workspace receives
its new mtime conservatively, including when an old session resumes. This is
file activity, not proof of human presence or a precise per-workspace visit time.
Activity from an indexed ancestor also contributes to descendant workspaces.
For example, recent Codex activity in `/repo` keeps an indexed `/repo/subdir`
from appearing stale solely because its Claude transcript is old. The workspace
rows stay distinct, with the contributing provider provenance preserved.

Indexing is read-only and discovers existing files without registration,
migration, or a lifecycle hook. Missing optional transcript directories are
valid empty sources. A corrupt or unreadable file, incomplete directory scan,
or missing Python 3 makes the entire activity index unavailable; partial
timestamps cannot authorize process cleanup. A JSONL record larger than 32 MiB,
including its trailing newline when present, also makes indexing unavailable;
records exactly at that limit are accepted. Files and directories are rechecked
before results are emitted. Concurrent transcript writes can temporarily make
activity unavailable; retry when the files have stopped changing.

A workspace with no recorded
activity has no last-touched time — it reads as *cannot tell*, never as
*forgotten*. Process liveness is deliberately not the signal: a finished agent
can leave its dev server running, and a long tool call can go quiet while still
working. Set `AFTERPARTY_IDLE_HOURS` to a positive whole number of hours
(default 4). Process plan eligibility
also uses `AFTERPARTY_BUSY_CPU` (default 20 percent per process).

### Approving a cleanup

`afterparty plan > cleanup-plan.md` saves a checklist for the current repository.
Use `--root DIR` for another repository. `--all` includes visible processes
attributable to other Git workspaces and discovers worktrees in additional
transcript-indexed repositories. Artifact scope stays the
repository printed in its section. `--artifacts-only` narrows the
proposal, and `--caches-only` omits build and test outputs.

Every actionable item starts **unchecked**. Eligible process rows show members, recorded
purpose, available listener ports, workspace, activity evidence and group-wide
consequences. In-use, busy, unknown, protected, mixed-workspace and unsupported
process groups are withheld with their reasons. Unknown activity cannot
establish process abandonment. Worktrees and artifacts use filesystem,
occupancy and identity checks; they do not require stale transcript evidence.
Worktree activity labels are informational, and discovery in the selected
repository does not require a transcript from either provider.

Edit the boxes, then `afterparty apply cleanup-plan.md`. Every approved item is
re-checked at its action boundary. A changed fingerprint may indicate replacement
or another identity change; it invalidates that approval. The checkbox is the
authority — unchecking a box makes it
inert regardless of what else the line says. Apply validates every checked
entry before mutation; malformed metadata, mismatched paths, unsupported
schemas, and duplicate targets reject the entire plan. Refused or held approved
actions return nonzero. Filesystem plans use absolute paths and reject control
characters. If you have saved older plans, regenerating them picks up the new
scope and unchecked defaults; compatible older process/worktree formats still
load. A fresh installation has no migration step.

`apply` never signals a process itself. It hands approved groups to the same
gated `audit --kill` path, so the protect list, group semantics, and
postcondition receipts apply exactly as they do everywhere else.

The protect list uses command patterns for selected editors (including
Cursor/Code/Electron), bare interactive shells, Claude/Codex tokens, and selected
MCP servers such as `playwright-mcp` and `chrome-devtools-mcp`. It is heuristic,
not exhaustive coverage of every editor, agent, or MCP server. Agent patterns
use token/path boundaries to reduce incidental matches in arguments; they are
not a full executable parser. Matching groups are refused by ledger and audit
cleanup. Devclean additionally checks the individual PID's identity, owner,
parent and activity evidence.

## Git cleanup

`afterparty git` reports stale worktrees, agent branches, lock files, conflict
litter, and stashes. `--clean` also reports and exits 2. Worktree removal goes
through the checklist in `plan` and the checked items in `apply`.

Before removing a worktree, apply refreshes its occupancy scan and checks its
identity and structure. Dirty or occupied worktrees, nested repositories
(including those under ignored directories), symlinks, and unavailable scans
are refused. Ignored local configuration, databases and unknown ignored data
also block removal. Recognized rebuildable caches such as `.next` may remain;
`.env`, database and key files are still protected. The current and main
worktrees are protected. Removal uses
`git worktree remove` without `--force` and confirms that the target disappeared.

Worktree identity includes the physical directory and its owning Git metadata,
so replacing a worktree invalidates its old approval. The filesystem must expose
usable creation identity; otherwise removal is withheld. If you retained
worktree plans from before 0.10.0, regenerate them before use. Branches, lock
files, conflict litter, and stashes
remain report-only.

## Artifacts

`afterparty artifacts` reports rebuildable repo output, grouped the way the
report prints it:

- **Caches** — `.turbo`, `.vite`, `.cache`, `.parcel-cache`,
  `.rollup.cache`, `node_modules/.cache`, `*.tsbuildinfo`, `.eslintcache`
- **Build outputs** — `.next`, `dist`, `build`, `out`, `.output`,
  `.svelte-kit`, `.astro`, `storybook-static`
- **Test artifacts** — `coverage`, `.nyc_output`, `test-results`,
  `playwright-report`, `.playwright-mcp`, `.vitest`

Use `afterparty plan --artifacts-only --root <repo>` to create a proposal,
review its boxes, then `afterparty apply <plan>`. `artifacts --clean` reports and
exits 2. Only typed, checked artifact targets can be deleted. Failed Git or
filesystem inspection, tracked content, nested repositories in either
containment direction, unavailable occupancy, occupied target directories,
symlinks and scope escapes withhold removal. Identity is checked at the removal
boundary. The cwd check detects processes inside the target; it cannot establish
that a process elsewhere will never read or rebuild those files.

`--caches-only` omits build and test outputs. Entire dependency installations
such as `node_modules` are not selected; their `.cache` directories may be.
Roaming reports of other directories require manual investigation.

## Devclean

Devclean previews one or more explicitly selected modes. Mutation requires IDs
copied from that preview; `--apply` alone is refused.

```bash
afterparty devclean            # orphan candidates, read-only
afterparty devclean --deep     # global daemon/simulator candidates
afterparty devclean --optimize # individual dump/configuration/startup targets
afterparty devclean --disk     # rebuildable caches; no process stopping
afterparty devclean --history  # stale transcripts/logs/recordings
# Review the exact target and consequence, then preserve the same mode/scope:
afterparty devclean --disk --apply --target <reviewed-id>
```

Repeat `--target` for multiple approvals. IDs bind process identity or the named
filesystem/configuration target. Directory IDs do not freeze recursive contents;
fresh target-specific checks still apply. Identity-changed, unknown, or withheld targets stay
visible and make apply return nonzero. Add `--orphans` explicitly to combine
orphan inspection with another mode. PPID 1 and a matching name alone do not
prove abandonment; activity and identity must pass conservative checks too.

`--optimize` separates deletions from persistent settings and launch-agent
changes. Each requires its own target ID; settings changes use effective JSONC
values, retain a backup, and show restoration instructions. JSONC editing needs
Python 3; unavailable parsing withholds that target.

`--history` considers Codex session day directories, `~/.codex/log`, and
`~/.gemini/antigravity/browser_recordings`; it does not clean Claude transcripts.
Its cleanup paths remain under `HOME`; the activity-index root overrides above
do not redirect history deletion, and archived Codex sessions are not selected.
It removes a selected directory only when its newest regular-file mtime is
older than `CODEX_SESSION_AGE_DAYS` (default 30) and the scan completes. An old
folder name does not override a recent write. Directory cleanup candidates
must occupy at least 1024 KiB. `--disk` keeps the shared
pnpm store directory intact and uses `pnpm store prune` for unreferenced packages.
Scope the roaming project report with `--documents-root DIR` and
`--project-maxdepth N`; it remains report-only. `--no-repo-artifacts` omits the
current repository artifact inventory. Repository artifacts use plan/apply.

Native maintenance uses the underlying tool's result: pnpm pruning counts a
successful pnpm exit, and launch-agent confirmation treats a failed
`launchctl print` probe as an absent registration. Those checks do not independently
verify reclaimed bytes or distinguish every launchctl failure from absence.

## Local state and action history

Afterparty normally keeps reports, the ledger, locks, and `actions.jsonl` under
`${XDG_CACHE_HOME:-~/.cache}/agent-processes/`. `AGENT_PROCESS_LEDGER` overrides
only the ledger path and its adjacent lock. Reports may instead use an opted-in
repo-root `report.md`; session archives and markers still use the cache.
Files containing session or mutation details are created with private
permissions where supported. `afterparty actions` prints this workspace's
versioned history. Use `--all`, `--workspace DIR`, and `--since YYYY-MM-DD` to
change its scope; `--path` prints the journal location. History is retained by
default. A positive `AFTERPARTY_RETENTION_DAYS` opts into trimming old action
receipts on writes; 0 preserves them. Session report archives are retained.

Common credential arguments, assignments and URL credentials are redacted in
saved report bodies, ledger labels, and journal target/detail fields. Paths,
workspace fields and arbitrary secret formats are not comprehensively redacted.
This is best effort; avoid secrets in command arguments
and free-form reasons. Identity checks use original identity evidence, not
redacted display strings. A successful mutation with a failed receipt is
reported distinctly and returns nonzero. `AFTERPARTY_JOURNAL=0` explicitly
opts out of recording.

## Style

On an interactive terminal, audits end with color, glyph headers, and a
finale card — a **damage report** when leftovers exist, **confetti** when
nothing is left, a **receipt** after a cleanup. Styled mode also carries an
instrument layer: severity tints on CPU/RSS/size cells (green → yellow →
red), humanized elapsed times (`1d 2h`, not `1-02:03:04`), `▸`/`✓`/`⊘`
state glyphs on pending/done/skipped lines, share-of-total meters in
`artifacts` runs and `devclean --disk` dry runs, a one-line `│`-joined segment
summary in every finale card, and dim `◐` heartbeat lines on stderr before
slow scans and kill waits. In automatic mode, pipes get plain text. JSON output
and saved reports suppress styling. `NO_COLOR` is honored, and
`AFTERPARTY_STYLE=always|never|auto` overrides everything (precedence:
`AFTERPARTY_STYLE` > `NO_COLOR` > tty detection).

## Safety model

- Cleanup discovery is read-only by default. Checked `apply` files and explicit
  stop/devclean flags authorize cleanup; reports and ledger bookkeeping write
  their own local state.
- Two kill disciplines, both deliberate. Ledger and audit kills go by process
  group — SIGTERM first, SIGKILL only for stragglers — and skip any group
  containing a protected process. Devclean's orphan cleanup signals
  individual PIDs instead, because orphans can share a group with unrelated
  processes, and group-kill would take those out too.
- Ledger and audit group kills check the protect list before every signal.
  Devclean deliberately targets individual PIDs instead; it rechecks the PID's
  parent, start time, and command immediately before SIGTERM and SIGKILL.
- Required process discovery and protected-group inspection fail closed.
  Detected failures in those scans are reported as unavailable and block the
  corresponding cleanup; optional native-tool probes have the limitations above.
- Signals and filesystem deletions require a verified postcondition; native
  maintenance relies on the tool results described above. Cleanup failures return
  nonzero. Mutation receipts are journaled unless recording is disabled;
  some refusals before mutation appear only in console output.
- Artifacts: only checked typed targets in a Git repository can be removed.
  Tracked paths, nested repositories, incomplete scans and filesystem/home
  roots are hard vetoes. Direct `--clean` never deletes.
- Named home-cache and optimize paths are physically resolved beneath `HOME`;
  symlink parents cannot redirect those actions outside that scope. The pnpm
  store is a separate target at the configured `pnpm store path`, which may be
  outside `HOME`; maintenance uses pnpm itself.
- Git: only checked worktrees are removed, after fresh identity, occupancy,
  and structural checks. Other Git cleanup stays report-only.

Process identities, cwd scans and filesystem metadata are observations taken
before actions, not atomic operating-system ownership guarantees. Review the
actual targets and consequences even when their checks pass.

## Requirements

- Bash 3.2+ in a macOS or Linux terminal. On Windows, WSL provides the full
  Unix process interface; Git Bash supports Git/filesystem commands and
  explicit degraded process reports. macOS support means invoking the CLI
  through terminal calls; Afterparty does not require or claim native macOS
  application integration.
- Git and standard Unix tools (`ps`, `awk`, `find`, `stat`, `du`, and hashing
  utilities). Process mutation needs a usable detailed `ps` table.
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for process
  matching; the audit falls back to `grep -E` when it is missing.
- `lsof` for listener reports and filesystem occupancy checks. Reports expose
  missing tools; worktree and artifact removal require a successful scan.
- Python 3 for Claude/Codex activity indexing, effective JSONC configuration
  edits, and macOS simulator inspection. Missing support makes transcript
  activity unavailable and withholds dependent process cleanup and those
  optimize/simulator targets. Other CLI capabilities keep their own checks.
- macOS-only devclean steps (`launchctl` agents, Xcode caches, iOS
  simulators) are skipped on other platforms.

## Development

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

The manifest commands validate packaging; the directory commands inspect skill
and command metadata. Marketplace validation alone does not inspect those
components or execute hooks. See [validation scope](https://code.claude.com/docs/en/plugin-marketplaces#validate-a-plugin-or-a-directory-without-a-manifest).
Plugin validation may warn that root `CLAUDE.md` is not loaded as
installed agent context; the bundled `SKILL.md` supplies that context.

Run `bash tests/run.sh` inside a disposable VM/container or CI runner. Linux
live-stop tests perform machine-wide category discovery and real signals;
changing `HOME` alone does not isolate those tests. Other mutation fixtures
intercept machine tools and signals.

CI runs the suite on Ubuntu and Windows. The Ubuntu job exercises the kill
paths against live processes (`tests/test-kill.sh`), and shellcheck runs at
`--severity=error`.

The [documentation audit](docs/reviews/documentation-audit.md) records the
0.11.1 contract corrections, validation, and remaining implementation limits.

The CLI reads its version from `skills/afterparty/VERSION`; the plugin manifest
and skill metadata contain separate copies that must be synchronized manually.
Record user-visible
changes in [CHANGELOG.md](./CHANGELOG.md).

## Lineage

Afterparty combines my own cleanup skills and methods with
[Agent-Broom](https://github.com/Kevin-Liu-01/Agent-Broom) by Kevin Liu.
The project began as a fork of Agent-Broom, which contributed the
foundation — the process ledger, the audit/stop split, and the dry-run-first
discipline — and the LICENSE retains Kevin Liu's copyright line. On that
base I built out my own methods: the git session cleanup, the devclean
policies, the agent-facing JSON and report output, the plugin packaging,
the styling layer, and the test suite. The devclean mode borrows its shape
from the `devclean` utility.

## License

MIT — see [LICENSE](./LICENSE).
