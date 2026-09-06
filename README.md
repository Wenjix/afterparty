<p align="center">
  <img src="./assets/afterparty-logo.svg" alt="Afterparty confetti logo" width="132" height="132">
</p>

<h1 align="center">Afterparty</h1>

<p align="center">
  Cleanup for the mess coding agents leave behind.
</p>

<p align="center">
  <img src="./assets/afterparty-terminal.svg" alt="Afterparty dry-run audit ending in the damage-report card" width="860">
</p>

An agent session ends and leaves things behind: a dev server still bound to
`localhost:3000`, a Vitest watcher no one is watching, a headless Chrome with
no owner, worktrees and `claude/*` branches no one will return to, and a
gigabyte of `.next` and `node_modules/.cache`.

Afterparty inventories these leftovers, reports what it could inspect, and
requires specific approval before cleanup. Missing evidence withholds actions.

## Why Afterparty

- **One toolkit, the whole mess.** Processes, ports, watchers, automation
  browsers, git session litter, rebuildable artifacts, and dev caches share
  one dry-run-first command surface and safety model.
- **It reports to the next agent, not just to you.** Versioned `--json` output emits JSON
  Lines, and `audit --report` persists a Markdown report — so the next
  session starts by reading what the last one left running instead of
  starting yet another server on `localhost:3000`.
- **Dry-run isn't a mode, it's the default.** Every mutation hides behind an
  approval — checked plan items, reviewed process groups, or devclean target
  IDs. `git --clean` and `artifacts --clean` are report-only compatibility flags.
- **Group cleanup protects the live session.** Ledger and audit kills refuse
  any process group containing an editor, interactive shell, running agent
  (Claude Code, Codex), or shared MCP process. Devclean uses a separate,
  identity-checked orphan-PID path.
- **Receipts describe outcomes, not attempts.** A delivered signal or an
  `rm` invocation is not counted as success until Afterparty confirms the
  process exited or the path disappeared. Partial failures return nonzero and
  are written to a private local action journal.
- **No prompt rituals, no guessing from `ps` output.** Cleanup is a script
  you can read, with a dry run you can inspect, not a wall of instructions
  the agent half-remembers.
- **Tested where it counts.** CI runs the suite on Linux and Windows, and the
  kill paths are exercised against live processes — not mocks.

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
- `/afterparty:afterparty` runs the audit on demand; `clean` requests reviewed
  cleanup. A failing audit stays visible without aborting the instructions.

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
For Claude Code:

```bash
cp -r skills/afterparty ~/.claude/skills/
```

OpenCode, Goose, Amp, Cursor, Gemini CLI, and other Agent Skills-compatible
tools install the same way: drop `skills/afterparty/` into that agent's
skills directory. (claude.ai web sessions load the skill's instructions but
cannot execute the bundled scripts.)

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

Every command reports first. The right-hand column is the only way anything
gets touched.

| Command | Reports | Acts with |
| --- | --- | --- |
| `afterparty glance` | every workspace holding processes, sorted by how long it has been left alone | *(reports only)* |
| `afterparty plan` | unchecked process, worktree, and artifact checklist for the current repository | *(proposes only)* |
| `afterparty apply <plan>` | executes the boxes you checked, refusing anything that moved | *(acts on approved targets)* |
| `afterparty audit` | recorded processes, dev servers, watchers, browsers, git litter | `--kill tests\|dev\|browser` |
| `afterparty stop` | ledger-recorded process groups | `--kill` |
| `afterparty git` | stale worktrees, agent branches, lock files, conflict litter | worktrees through `plan` / `apply`; `--clean` is report-only |
| `afterparty artifacts` | rebuildable build/cache output | checked `plan` / `apply` items |
| `afterparty devclean` | orphan candidates; separate `--deep`, `--optimize`, `--disk`, `--history` modes | `--apply --target <reviewed-id>` |

The bookkeeping commands — `list`, `add`, `prune` — only ever touch
Afterparty's own ledger, never your system. `doctor` combines the default read-only diagnostics. `doctor --strict` returns
nonzero for unavailable audit capabilities; it does not authorize cleanup or
replace the fresh checks at each mutation boundary.

```bash
afterparty audit                   # full dry-run report
afterparty audit --json            # same findings, as JSON Lines
afterparty audit --report          # persist the report for the next session
afterparty report --show           # read this workspace's persisted report
afterparty audit --kill dev --pgid 12345 # act only on a reviewed group
afterparty add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
afterparty list --json             # the ledger, for machines
afterparty stop --kill             # stop this repo's recorded groups
afterparty prune                   # drop this repo's dead ledger entries
afterparty git                     # report git leftovers
afterparty plan > cleanup-plan.md  # save the checklist, then review its boxes
afterparty apply cleanup-plan.md   # apply the checked items
afterparty plan --artifacts-only   # preview unchecked artifact removals
afterparty devclean --disk         # report disk-heavy targets
afterparty doctor                  # every dry-run report in one pass
afterparty doctor --strict         # fail if the audit is degraded
afterparty actions                 # this workspace's JSONL mutation history
afterparty actions --all --since 2026-09-01 # filter global history
afterparty --version               # installed package version
```

The ledger commands (`list`, `stop`, `prune`) scope to the current repo by
default; pass `--all` to cover every repo, or `--root <dir>` for another
(`plan`, `git` and `artifacts` accept `--root` too). `list` and `stop` can also
filter by `--kind`.

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
  explicit audit also gets its own session snapshot, so concurrent sessions
  retain their reports. Status, failed sections, timestamp, and session ID stay
  in the saved report; `report --show` returns nonzero for an incomplete report.

One rule ties them together: `--json` is strictly report-only. It refuses to
combine with `--kill`, and `audit --report` and `--json` are mutually
exclusive.

## The ledger

`afterparty add` records long-running processes in
`~/.cache/agent-processes/ledger.tsv` — timestamp, repo root, cwd, PID,
PGID, kind, port, purpose, command, and observed process-member identities. The result: the next agent can see
what is running *and why* before spinning up a duplicate.

Ledger state is private (`0700` directory, `0600` file where the platform
supports POSIX modes). `add` and `prune` use a portable advisory lock so a
concurrent prune cannot overwrite a newly recorded process. Legacy entries
without identity remain visible as unverified and cannot authorize stopping a
process. Prune retains records when inspection fails or workers still survive.

## The audit

`afterparty audit` reports:

- processes recorded in the ledger
- localhost listeners that look like dev servers
- test/watch runners such as Vitest, Jest, and pytest
- frontend/backend dev servers such as Next, Vite, Turbo, Bun, Uvicorn, and
  Rails
- automation browsers
- git session litter: stale worktrees, agent branches, conflict files, stashes
- protected processes it will refuse to kill

### Coming back to the machine

`afterparty glance` answers the question you actually arrive with: what was I
doing, and what is still running from it? It is machine-wide, grouped by
workspace, with unindexed or unattributed processes kept visible. Agent
transcript activity is an observation, not proof of recent human use.
`--oneline` fits a tmux status line; `--json` emits JSON Lines.

Severity in the glance is **magnitude** — cpu, count, how long since anyone
looked. That is what makes you look up. Consequence is weighed elsewhere.

Glance never acts. There is no `--kill`, and a test pins that so a future flag
cannot quietly turn it into a mutation surface.

**How it knows a workspace was left alone.** Last-touched comes from the agent
transcript, which records its own working directory, so no directory-name
decoding is involved. A workspace with no transcript has no last-touched time
at all — that reads as *cannot tell*, never as *forgotten*. Process liveness is
deliberately not the signal: a finished agent leaves its dev server running
long after you stopped caring, and a long tool call goes quiet while very much
still working. Thresholds are `AFTERPARTY_IDLE_HOURS` (default 4) and
`AFTERPARTY_STALE_HOURS` (default 24).

### Approving a cleanup

`afterparty plan > cleanup-plan.md` saves a checklist for the current repository.
Use `--root DIR` for another repository; `--all` widens process and worktree
discovery to indexed workspaces across the machine. Artifact scope stays the
explicit repository printed in its section. `--artifacts-only` narrows the
proposal, and `--caches-only` omits build and test outputs.

Every actionable item starts **unchecked**. Process rows show members, recorded
purpose, available listener ports, workspace, activity evidence and group-wide
consequences. In-use, busy, unknown, protected, mixed-workspace and unsupported
items are withheld with their reasons. Unknown activity cannot establish
abandonment. Worktree discovery does not require a Claude transcript.

Edit the boxes, then `afterparty apply cleanup-plan.md`. Every approved item is
re-checked before anything happens: a **moved fingerprint** means a recycled
process group now holds something you never reviewed, and it is refused rather
than re-targeted. The checkbox is the authority — unchecking a box makes it
inert regardless of what else the line says. Apply validates every checked
entry before mutation; malformed metadata, mismatched paths, unsupported
schemas, and duplicate targets reject the entire plan. Refused or held approved
actions return nonzero. Filesystem plans use absolute paths and reject control
characters. Regenerate existing plans to get the current scope and defaults.

`apply` never signals a process itself. It hands approved groups to the same
gated `audit --kill` path, so the protect list, group semantics, and
postcondition receipts apply exactly as they do everywhere else.

The protect list covers editors, interactive shells, running agent sessions
(Claude Code, Codex), and shared MCP servers such as `playwright-mcp` and
`chrome-devtools-mcp`. Agent entries are anchored on the executable, so a
session is protected while the shells it spawns — which carry an agent path
in their arguments — stay killable. This guard applies to ledger and audit
kills. Devclean additionally requires reviewed PID identity and conservative
owner/parent/activity evidence; active or protected agents are withheld.

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
usable creation identity; otherwise removal is withheld. Regenerate worktree
plans created before 0.10.0. Branches, lock files, conflict litter, and stashes
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
filesystem/configuration target. Changed, unknown, or withheld targets stay
visible and make apply return nonzero. Add `--orphans` explicitly to combine
orphan inspection with another mode. PPID 1 and a matching name alone do not
prove abandonment; activity and identity must pass conservative checks too.

`--optimize` separates deletions from persistent settings and launch-agent
changes. Each requires its own target ID; settings changes use effective JSONC
values, retain a backup, and show restoration instructions. JSONC editing needs
Python 3; unavailable parsing withholds that target.

`--history` permanently deletes resume/diagnostic history only after a complete
activity scan establishes age beyond `CODEX_SESSION_AGE_DAYS` (default 30).
An old folder name does not override a recent write. `--disk` keeps the shared
pnpm store intact and uses `pnpm store prune` for unreferenced packages.
Scope the roaming project report with `--documents-root DIR` and
`--project-maxdepth N`; it remains report-only. `--no-repo-artifacts` omits the
current repository artifact inventory. Repository artifacts use plan/apply.

## Local state and action history

Afterparty keeps reports, the ledger, locks, and `actions.jsonl` under
`${XDG_CACHE_HOME:-~/.cache}/agent-processes/` unless you override the ledger
path. Files containing session or mutation details are created with private
permissions where supported. `afterparty actions` prints this workspace's
versioned history. Use `--all`, `--workspace DIR`, and `--since YYYY-MM-DD` to
change its scope; `--path` prints the journal location. History is retained by
default. A positive `AFTERPARTY_RETENTION_DAYS` opts into trimming old action
receipts on writes; 0 preserves them. Session report archives are retained.

Common credential arguments, assignments and URL credentials are redacted in
persisted display text. This is best effort; avoid secrets in command arguments
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
slow scans and kill waits. Styling is strictly additive: pipes, `--json`, and `report.md`
always get byte-stable plain text, `NO_COLOR` is honored, and
`AFTERPARTY_STYLE=always|never|auto` overrides everything (precedence:
`AFTERPARTY_STYLE` > `NO_COLOR` > tty detection).

## Safety model

- Dry-run by default; mutations only behind explicit flags.
- Two kill disciplines, both deliberate. Ledger and audit kills go by process
  group — SIGTERM first, SIGKILL only for stragglers — and skip any group
  containing a protected process. Devclean's orphan cleanup signals
  individual PIDs instead, because orphans can share a group with unrelated
  processes, and group-kill would take those out too.
- Ledger and audit group kills check the protect list before every signal.
  Devclean deliberately targets individual PIDs instead; it rechecks the PID's
  parent, start time, and command immediately before SIGTERM and SIGKILL.
- Process discovery and protected-group inspection fail closed. A scanner
  outage is reported as unavailable and can never produce a spotless claim.
- Mutation success requires a verified postcondition. Partial failures are
  visible in output, return a nonzero status, and are locally journaled.
- Artifacts: only checked typed targets in a Git repository can be removed.
  Tracked paths, nested repositories, incomplete scans and filesystem/home
  roots are hard vetoes. Direct `--clean` never deletes.
- Global cache and optimize paths are physically resolved beneath `HOME`;
  symlink parents cannot redirect a mutation outside the reviewed scope.
- Git: only checked worktrees are removed, after fresh identity, occupancy,
  and structural checks. Other Git cleanup stays report-only.

## Requirements

- Bash 3.2+ in a macOS or Linux terminal. On Windows, WSL provides the full
  Unix process interface; Git Bash supports Git/filesystem commands and
  explicit degraded process reports. macOS support means invoking the CLI
  through terminal calls; Afterparty does not require or claim native macOS
  application integration.
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for process
  matching; the audit falls back to `grep -E` when it is missing.
- `lsof` for listener reports and filesystem occupancy checks. Reports expose
  missing tools; worktree and artifact removal require a successful scan.
- Python 3 for effective JSONC configuration edits; missing support withholds
  those optimize targets.
- macOS-only devclean steps (`launchctl` agents, Xcode caches, iOS
  simulators) are skipped on other platforms.

## Development

```bash
bash -n bin/afterparty     # syntax check
bash tests/run.sh          # test suite
claude plugin validate --strict . # plugin manifests and skill metadata
```

CI runs the suite on Ubuntu and Windows. The Ubuntu job exercises the kill
paths against live processes (`tests/test-kill.sh`), and shellcheck runs at
`--severity=error`.

Release metadata is single-sourced from `skills/afterparty/VERSION`; keep the
plugin manifest and skill metadata synchronized and record user-visible
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
