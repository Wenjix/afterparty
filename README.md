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

Afterparty finds all of it, reports exactly what it found, and changes
nothing until you approve.

## Why Afterparty

- **One toolkit, the whole mess.** Processes, ports, watchers, automation
  browsers, git session litter, rebuildable artifacts, and dev caches share
  one dry-run-first command surface and safety model.
- **It reports to the next agent, not just to you.** Versioned `--json` output emits JSON
  Lines, and `audit --report` persists a Markdown report — so the next
  session starts by reading what the last one left running instead of
  starting yet another server on `localhost:3000`.
- **Dry-run isn't a mode, it's the default.** Every mutation hides behind an
  explicit flag — `--kill`, `--clean`, `--apply` — scoped to exactly what the
  dry run showed you.
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

- an asynchronous `SessionEnd` hook runs `afterparty audit --report` when a session ends,
  so the leftovers report is already on disk when the next session starts;
- a lightweight `SessionStart` hook points at that prior report without
  rerunning the audit or delaying startup;
- a `/afterparty` slash command runs the audit on demand
  (`/afterparty clean` walks the gated cleanup paths).

### As a plain agent skill

Afterparty follows the [Agent Skills](https://agentskills.io) standard, and
the skill folder is self-contained — `SKILL.md`, `VERSION`, `LICENSE`, plus every script it runs,
with commands anchored to `${CLAUDE_SKILL_DIR}` so they work from whatever
project the agent happens to be in. Copying the folder is the whole install.
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
| `afterparty plan` | an editable checklist of process groups and linked worktrees | *(proposes only)* |
| `afterparty apply <plan>` | executes the boxes you checked, refusing anything that moved | *(acts on approved targets)* |
| `afterparty audit` | recorded processes, dev servers, watchers, browsers, git litter | `--kill tests\|dev\|browser` |
| `afterparty stop` | ledger-recorded process groups | `--kill` |
| `afterparty git` | stale worktrees, agent branches, lock files, conflict litter | worktrees through `plan` / `apply`; `--clean` is report-only |
| `afterparty artifacts` | rebuildable build/cache output | `--clean` |
| `afterparty devclean` | orphans, plus `--deep` / `--optimize` / `--disk` targets | `--apply` |

The bookkeeping commands — `list`, `add`, `prune` — only ever touch
Afterparty's own ledger, never your system. `doctor` runs every dry-run
report in one pass and changes nothing. `doctor --strict` also returns
nonzero when any audit capability is unavailable.

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
afterparty artifacts --clean       # delete rebuildable artifacts
afterparty devclean --disk         # report disk-heavy targets
afterparty doctor                  # every dry-run report in one pass
afterparty doctor --strict         # fail if the audit is degraded
afterparty actions                 # local JSONL mutation history
afterparty --version               # installed package version
```

The ledger commands (`list`, `stop`, `prune`) scope to the current repo by
default; pass `--all` to cover every repo, or `--root <dir>` for another
(`git` and `artifacts` accept `--root` too). `list` and `stop` can also
filter by `--kind`.

There are two kill paths, and they answer different questions. `stop --kill`
stops what Afterparty *recorded*: process groups from the ledger, where
ownership is already established. `audit --kill <tests|dev|browser>` handles
the strays nobody recorded, matched by category pattern. Both accept
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
  plugin's `SessionEnd` hook leans on this. `afterparty report-path` prints
  the canonical location.

One rule ties them together: `--json` is strictly report-only. It refuses to
combine with `--kill`, and `audit --report` and `--json` are mutually
exclusive.

## The ledger

`afterparty add` records long-running processes in
`~/.cache/agent-processes/ledger.tsv` — timestamp, repo root, cwd, PID,
PGID, kind, port, purpose, and command. The result: the next agent can see
what is running *and why* before spinning up a duplicate.

Ledger state is private (`0700` directory, `0600` file where the platform
supports POSIX modes). `add` and `prune` use a portable advisory lock so a
concurrent prune cannot overwrite a newly recorded process.

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
workspace, and sorted so the workspaces nobody has touched sink to the bottom.
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

`afterparty plan > cleanup-plan.md` saves a checklist of process groups and
linked worktrees. Each process box represents an entire group:

- Only items that pass the two-signal gate arrive **checked**.
- Everything else is listed **unchecked with the reason stated**, so withholding
  is visible rather than silent: `in-use` (you touched that workspace recently),
  `working` (quiet transcript but the cpu says a long task is running),
  `unknown` (no transcript, so no staleness signal to trust), and `no-rule`
  (no kill discipline exists for that command — stop it yourself).

Worktrees in the current repository are discovered even without Claude history;
repositories found in Claude transcripts are included too. Worktree boxes always
start unchecked, and missing transcript history reads as unknown staleness.

Edit the boxes, then `afterparty apply cleanup-plan.md`. Every approved item is
re-checked before anything happens: a **moved fingerprint** means a recycled
process group now holds something you never reviewed, and it is refused rather
than re-targeted. The checkbox is the authority — unchecking a box makes it
inert regardless of what else the line says.

`apply` never signals a process itself. It hands approved groups to the same
gated `audit --kill` path, so the protect list, group semantics, and
postcondition receipts apply exactly as they do everywhere else.

The protect list covers editors, interactive shells, running agent sessions
(Claude Code, Codex), and shared MCP servers such as `playwright-mcp` and
`chrome-devtools-mcp`. Agent entries are anchored on the executable, so a
session is protected while the shells it spawns — which carry an agent path
in their arguments — stay killable. This guard applies to ledger and audit
kills; devclean's orphan cleanup deliberately still targets *orphaned* agent
and MCP processes.

## Git cleanup

`afterparty git` reports stale worktrees, agent branches, lock files, conflict
litter, and stashes. `--clean` also reports and exits 2. Worktree removal goes
through the checklist in `plan` and the checked items in `apply`.

Before removing a worktree, apply refreshes its occupancy scan and checks its
identity and structure. Dirty or occupied worktrees, nested repositories
(including those under ignored directories), symlinks, and unavailable scans
are refused. The current and main worktrees are protected. Removal uses
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

It skips git-tracked paths and nested git repositories, and never descends
into a matched directory. `--caches-only` keeps build outputs; `--root <dir>`
points it at another repo.

## Devclean

`afterparty devclean` borrows its shape from the `devclean` utility: safe
orphan cleanup by default, with explicit escalation modes.

```bash
afterparty devclean            # safe orphan cleanup
afterparty devclean --deep     # heavy daemon audit
afterparty devclean --optimize # crashpad files, crash-reporter settings
afterparty devclean --disk     # disk-heavy caches and artifacts
```

`--disk` covers global dev caches (npm, pnpm, Gradle, pub, CocoaPods —
plus Xcode caches on macOS), Codex sessions and logs, project artifacts
under `--documents-root`, and the current repo's artifact pass. `--apply`
also answers to `--kill` and `--clean` — whichever mutation verb you reach
for works — and `--dry-run` forces the default.

It is conservative on purpose. It does not treat every `crashpad_handler` as
a safe orphan — active apps on macOS use those helpers — so crashpad cleanup
lives behind `--optimize`, where you review the exact targets first. Codex
session transcripts are age-gated: only date folders older than 30 days
(override with the `CODEX_SESSION_AGE_DAYS` environment variable) are
eligible, because transcripts
power resume and are the audit trail of what your agents actually did. The
shared pnpm store is pruned (`pnpm store prune`, unreferenced packages
only), never deleted outright — other projects still link into it. Scope
the `--disk` project scan with `--documents-root DIR` and
`--project-maxdepth N`, and skip the current-repo artifact pass with
`--no-repo-artifacts`. Applied scans reject filesystem roots, `HOME`, and
any ancestor of `HOME` by default; `--allow-broad-documents-root` is the
explicit escape hatch after reviewing that scope.

## Local state and action history

Afterparty keeps reports, the ledger, locks, and `actions.jsonl` under
`${XDG_CACHE_HOME:-~/.cache}/agent-processes/` unless you override the ledger
path. Files containing session or mutation details are created with private
permissions where supported. `afterparty actions` prints the append-only,
versioned history of confirmed and failed mutations; `actions --path` prints
its location. Set `AFTERPARTY_JOURNAL=0` only when local action history is not
appropriate for the environment.

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
- Artifacts: delete only known rebuildable output, skipping git-tracked paths
  and nested repos. Destructive cleanup requires a Git repository unless
  `--allow-non-repo-root` is explicit, and filesystem/home roots are rejected.
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
- `lsof` for the localhost listener report and worktree occupancy checks.
  Reports can run without it; worktree removal requires a successful scan.
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
