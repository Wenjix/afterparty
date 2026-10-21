<p align="center">
  <img src="./assets/afterparty-logo.svg" alt="Afterparty confetti logo" width="132" height="132">
</p>

<h1 align="center">Afterparty</h1>

<p align="center">
  Cleanup for the mess coding agents leave behind.
</p>

Afterparty is a Bash and Python toolkit for cleanup after an agent session.
It reports development servers, test watchers, automation browsers, worktrees,
build caches, and stale session history. It also helps agents review
documentation that no longer describes the code. It runs as a Claude Code
plugin, a standalone Agent Skill, or a local CLI.

Afterparty collects evidence first. A scan gathers current information. A
check evaluates a condition. Cleanup requires an explicit request that the
user can review. Afterparty checks each target again immediately before
cleanup.

Documentation review is a separate workflow. The collector gathers evidence.
The agent recommends whether to update, retain, archive, or otherwise treat a
document.

Wenjie Fu maintains Afterparty with coding-agent assistance. A human reviews
changes before merge or release. Destructive operations require explicit
approval. See the [contribution guide](./CONTRIBUTING.md),
[security policy](./SECURITY.md), [code of conduct](./CODE_OF_CONDUCT.md), and
[release checklist](./RELEASING.md) for project policies. Repository-wide agent
instructions live in [AGENTS.md](./AGENTS.md).

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
standard. It contains the skill instructions, version, license, executable,
and all required library files. Copy the directory into your host's skill
location:

```bash
# Claude Code
mkdir -p ~/.claude/skills
cp -r skills/afterparty ~/.claude/skills/

# Codex
mkdir -p ~/.agents/skills
cp -r skills/afterparty ~/.agents/skills/
```

Claude substitutes `${CLAUDE_SKILL_DIR}` when it runs a skill. Other agents
must find the absolute directory that contains `SKILL.md`. They must invoke
`bin/afterparty` in that directory. `${CLAUDE_SKILL_DIR}` is not a universal
environment variable. Installing a skill does not put `afterparty` on your
terminal `PATH`.

See the host instructions for [Claude skills](https://code.claude.com/docs/en/skills#where-skills-live)
and [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
for host-specific loading behavior.

Other hosts that support Agent Skills and local shell execution can use the
same folder. Hosted environments such as Claude.ai run scripts in their own
environment. They cannot inspect or clean processes on your local machine.

## What it does

| Surface | Purpose | Default behavior |
| --- | --- | --- |
| `afterparty glance` | Show visible processes grouped by workspace, with unknown attribution kept visible | Read-only |
| `afterparty docs` | Collect documentation evidence and local-link observations for agent review | No project-file edits |
| `afterparty audit` | Report recorded processes, listeners, test/watch runners, dev servers, automation browsers, and Git litter | Report-only; `--kill` acts on a requested category |
| `afterparty list`, `add`, `prune`, `stop` | Record and inspect long-running process groups | `add`/`prune` write the private ledger; `stop` needs `--kill` |
| `afterparty plan` and `apply` | Propose and execute a checked process, worktree, or artifact checklist | `plan` proposes; `apply` acts only on checked items |
| `afterparty review` | Choose targets interactively and save a checked plan | Saves choices only; execution remains separate |
| `afterparty git` | Find stale worktrees, agent branches, lock files, conflict litter, and stashes | Report-only; worktree removal uses `plan`/`apply` |
| `afterparty artifacts` | Find rebuildable build, cache, and test output | Report-only; removal uses `plan`/`apply` |
| `afterparty builds` | Compare generated output across project directories | Read-only inventory; Enter opens a separate repository review |
| `afterparty devclean` | Review orphan processes, machine caches, settings, and old agent history | Preview; mutation needs exact target IDs |
| `afterparty doctor` | Run the main diagnostics together | Reports by default; `--strict` fails on unavailable process/listener evidence |
| `afterparty report` and `actions` | Read the latest audit and confirmed mutation history | Read-only except for report/session bookkeeping |

A target is one process group, worktree, or artifact proposed for cleanup.
A process group contains related processes. Its process group ID is the PGID.
A worktree is a Git working directory. An artifact is rebuildable output,
such as a cache or test report.

A mark selects a target in interactive review. A plan is a Markdown checklist
of reviewed cleanup choices. Approval for a process group does not authorize
worktree deletion. Documentation review does not authorize cleanup.

## The first post-session workflow

1. **See what is left.** Run `afterparty audit` for a snapshot of the repository
   and machine. Use `afterparty glance` for visible processes grouped by
   workspace.
2. **Review documentation.** Run `afterparty docs --report --json` or
   `/afterparty:docs` before the next agent takes over. Use `--since REF` when
   you know the starting commit. Use `--full` to review all repository
   documentation.
3. **Choose cleanup targets.** Run `afterparty review` in a terminal. Keep the
   saved path it prints. Alternatively, run `afterparty plan > cleanup-plan.md`
   to create a manual checklist. Inspect every proposed target. Mark only the
   targets you approve.

   For a specific process action, review the reported
   process group. Use its exact PGID.
4. **Apply the reviewed choices.** Run `afterparty apply <saved-plan>` with the
   saved path or manual checklist. Alternatively, use a command for a specific
   target, such as `afterparty audit --kill dev --pgid <reviewed-pgid>` or
   `afterparty devclean --disk --apply --target <reviewed-id>`.
5. **Save a report for the next session.** Run `afterparty audit --report` to
   save the current snapshot. The next session can read it with
   `afterparty report --show`. Use `afterparty report-path` to locate it.

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

# Propose, review, and save typed cleanup targets.
afterparty review
# Run the apply command printed after review.
# Or use the manual workflow:
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

`afterparty add` records a process that already exists. It does not launch
the command after `--`. It assigns the record to the caller's current
workspace. It does not read the target process's working directory. Run it
from the repository that owns the process.

`afterparty stop --kill` stops matching groups already in the ledger. It does
not check idle time or CPU use. Review the list and scope first.
`afterparty audit --kill tests|dev|browser` handles unrecorded groups across the
machine. Add reviewed `--pgid` values to restrict the action.
`--keep <pgid>` preserves a known group.

`list`, `stop`, and `prune` default to the current Git repository. Pass
`--all` to include every recorded repository. Pass `--root DIR` to select
another repository. Use `--kind KIND` to filter `list` or `stop`.

Human reports use styled layouts in a terminal. Below 80 columns, workspace
and process views stack their fields. Wider views align numbers and wrap
complete paths and commands into detail rows. Afterparty reads the output
terminal's width first. Otherwise, it uses a valid `COLUMNS` value or defaults
to 80.

Quoted next-step commands and target IDs stay on one logical line for copying.
Python 3 supplies Unicode width handling. Without Python 3, wrapped detail
uses escaped ASCII bytes.

Piped reports keep their plain format, and JSON is always free of styling.
`NO_COLOR` or `TERM=dumb` selects plain output in automatic mode. Explicit
`AFTERPARTY_STYLE=always` or `never` overrides automatic selection;
`AFTERPARTY_CARD=0` suppresses finale cards.

## Documentation review

The documentation pass has two responsibilities:

1. The deterministic collector (`afterparty docs`) gathers evidence from the
   diff and local Markdown links. Evidence includes changed paths, related
   documents, purpose hints, symbols, and flags. Its link checks are conservative.
2. The invoking agent reads the implementation and documents. It checks which
   claims remain true and prepares concrete previews. It applies only the
   treatments the user selects.

The collector never edits project documents or executes commands copied from
them. It does not fetch remote links or infer staleness from age alone.
A finding supplies evidence for review. It does not authorize deletion.

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

The default scope compares `HEAD` with staged, unstaged, and untracked files.
It includes pre-existing local changes. It does not infer a baseline for the
session start. `--since REF` selects an explicit baseline. `--full` includes
all recognized documentation in the selected repository. `--root DIR` selects
a different repository.

Afterparty stores evidence and agent reviews separately in private workspace
state. A new scan does not overwrite the last review. `--show` prefers the
latest review. It returns nonzero for partial coverage. The invoking agent
carries unresolved findings into later reviews.

Collection and review have separate completion statuses. A complete review can
still contain unresolved findings.

### Treatments

A review can recommend **update**, **mark historical**, **consolidate**,
**archive**, **delete**, **flag for review**, or **keep**. Before requesting a
selection, the agent shows evidence, reasons, alternatives, and an exact preview.
The preview shows the patch, move, or deletion. Uncertain findings remain
flagged or kept. Historical status preserves a document's release or decision
context. It does not mean the document is wrong.

Run `afterparty docs --check <scan-id>` immediately before the selected edits.
Changed or incomplete evidence requires a fresh scan and revised proposal.
Saving a review records the agent's decisions. It does not apply or
independently check the edits. See the bundled
[review protocol and JSON format](skills/afterparty/docs-review.md).

Discovery covers these tracked or untracked documents unless Git ignores them:

- Markdown/MDX, reStructuredText, AsciiDoc, and text documents;
- known extensionless README and changelog files.

Common dependency/build directories, symlinks, submodules, and nested repositories
produce explicit exclusions or gaps. So do unreadable files, non-UTF-8 files,
relevant files over 2 MiB, and oversized diffs.

Local-link checks cover simple Markdown inline and reference destinations with
file extensions. They do not fetch remote links, resolve anchors or website
routes, or parse every Markdown construct. Incomplete collection cannot support
a complete review.

## Auditing processes and listeners

`afterparty audit` combines three reports:

- ledger entries for groups Afterparty knows about;
- likely development listeners on loopback or wildcard bindings, test/watch
  runners, frontend/backend dev servers, and automation browsers; and
- Git session litter such as stale worktrees, agent branches, lock files,
  conflict files, and stashes.

The process classifier uses executable and subcommand evidence. Its heuristic
report does not prove that a process belongs to an agent or is safe to stop.
Listener reports exclude other bindings and protected command matches.
Use `afterparty audit --strict` to fail when process or listener evidence is
unavailable. `doctor` runs the normal ledger, process, Git, artifact, and default
orphan reports. It does not run every devclean mode.

### Returning to a machine

`afterparty glance` is a read-only view of the machine, grouped by workspace.
It keeps processes with unknown workspaces visible. Use `--oneline` for a
status-line form or `--json` for JSON Lines. It has no kill or apply flag.

Activity comes from existing agent transcripts:

| Provider | Files inspected |
| --- | --- |
| Claude | Every `*.jsonl` file in immediate project directories under `${AFTERPARTY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}` |
| Codex | JSONL files below `sessions` and `archived_sessions` in `${AFTERPARTY_CODEX_ROOT:-${CODEX_HOME:-$HOME/.codex}}` |

Workspace identity comes from recorded working-directory (`cwd`) paths,
normalized across providers. The activity timestamp uses the newest modification
time (`mtime`) among contributing transcript files. It does not prove human
presence or give an exact visit time. Codex session and turn records can name
multiple workspaces. A changed transcript conservatively refreshes every
workspace it names.

Activity from an indexed ancestor also contributes to a descendant. The
workspaces keep distinct rows.

Indexing is read-only and requires no registration or lifecycle hook. Missing
optional directories count as empty sources. A corrupt, unreadable, incomplete,
or oversized record makes the entire activity index unavailable. Missing
Python 3 has the same effect. Partial timestamps cannot authorize process
cleanup.

A workspace without indexed activity has no last-touched time. Afterparty treats
it as “cannot tell,” never as “forgotten.” A running process alone does not
indicate staleness.

`AFTERPARTY_IDLE_HOURS` sets the positive whole-hour activity threshold for
process-plan eligibility (default `4`). `AFTERPARTY_BUSY_CPU` sets the per-process
CPU threshold (default `20`). These are eligibility inputs, not proof of
abandonment.

## Approving cleanup with plan/apply

`afterparty plan` writes an editable checklist for the current repository.
Every actionable item starts unchecked. Use `--root DIR` for another
repository. `--all` also scans other visible Git workspaces and repositories
in the transcript index for processes and worktrees. Artifact scope remains
the selected repository. `--artifacts-only` and `--caches-only` restrict the
proposal.

For a guided terminal review, run:

```bash
afterparty review
```

The reviewer starts in **Choose**, with compact evidence and one row per
target. A fixed strip previews the consequence for the focused target.
Arrow keys or `j`/`k` move focus. `Space` marks an available target.
`i` inspects the target.

If you page away from the focused target, Space reveals it before you can
mark it. The position line and mark message name the target. `d` expands or
compacts evidence. `/` filters targets. Hidden marks still count. You can
inspect withheld targets.

The strip uses at most four rows. Press `i` for full details when a
consequence needs more space.

`Enter` advances through **Review choices → Save plan → Finish**. The legend
shows the active keys for each mode. `s` also opens Review choices. Review
starts with a three-row summary. It shows the full identity and consequence
of each selected target. Every process-group member remains listed.

In Review, Space unmarks a target. `d` adds evidence checks. `Esc` goes back
and keeps choices. With marks set, `r` requests confirmation before a refresh.
`q` requests confirmation before cancellation. In help or inspection, `q`
closes that view.

Ctrl+Z suspends the reviewer and keeps choices. A scan shows elapsed time and
ignores review keys. Keys from an older scan cannot mark targets or advance.
If refresh fails, saving stays disabled until a valid refresh.

Saving requires at least one explicit mark. It never overwrites an existing
file. Plans use a unique filename in the workspace's private review directory
under the cache root. Pass `--output NEW-PATH` to choose a destination. If that
path exists, review refuses before the scan. Choose another filename or omit
`--output` to use the private directory.

After you save the plan, press `Enter` or `q` to finish. Review restores the
terminal and lists your choices and saved path. It prints an exact apply
command, with shell quoting, alone on one logical line. If `afterparty` is
absent from PATH, the command uses the bundled CLI's absolute path.

Opening, inspecting, and marking targets do not execute cleanup. Resizing,
filtering, and toggling details do not start a new scan.

If the snapshot has no available targets, `Enter` finishes without saving a
plan. Incomplete evidence stays visible and produces a nonzero result. When
targets are available, mark a choice before you advance or save. Focus alone
does not select a target.

Interactive review uses **Bubble Tea 2.1.0 and Lip Gloss 2.0.0**. Its Python 3
backend uses the standard library to manage evidence, choices, and saved plans.
Build the optional helper from the source checkout on macOS/Linux. The build
requires Go 1.26+:

```bash
./skills/afterparty/bin/build-review
```

This explicit build downloads the pinned Go dependencies. It puts
`afterparty-review` beside the bundled CLI. An installed skill copy can run its
own `bin/build-review`. A copied built bundle includes the helper for that OS
and architecture. Go is not needed at runtime. Ordinary commands and plugin
hooks never build or download the helper.

Dependency licenses ship in
[THIRD_PARTY_NOTICES.txt](skills/afterparty/ui/THIRD_PARTY_NOTICES.txt).

The reviewer needs a supported input/output terminal. Below 60 columns by
20 rows, it shows a size notice and keeps marks. You must enlarge the pane
before you can mark targets or save. In tmux, use `prefix z` to zoom.
`--ascii` escapes non-ASCII display text.

`NO_COLOR` removes hues but keeps bold and reverse focus. `AFTERPARTY_STYLE`
follows the shared CLI styling rules. If the helper, supported terminal, or
Python 3 is unavailable, review prints an unchecked plain plan. It reports that
no plan was saved and exits nonzero. Use the manual plan workflow for pipes,
Git Bash, or a stable linear text view.

Plugin hooks never launch the reviewer. A human must explicitly invoke this
CLI command from the bundle.

`afterparty plan --json` emits a versioned JSON Lines snapshot. It includes
exact target identities, evidence capabilities, unchecked items, canonical
Markdown, and integrity/completion records. It requires Python 3. Ordinary
Markdown planning does not.

Exit `0` means complete inspection. Exit `1` means inspection gaps. Exit `2`
means a usage or snapshot-format refusal. A complete stream can describe
incomplete evidence. Targets that need missing evidence remain withheld.
See the [snapshot contract](docs/plan-snapshot.md) for reader and writer
requirements.

Process rows include members, purpose, workspace, listener ports, activity
evidence, and group-wide consequences. Busy, in-use, unknown, protected,
mixed-workspace, unsupported, and no-category groups are withheld with a
reason. Worktrees and artifacts use filesystem, occupancy, nested-repository,
and identity checks rather than transcript age.

Edit the checkboxes. Then run `afterparty apply <plan>`. Apply checks every
checked entry before any cleanup. It refuses targets with any of these
conditions:

- malformed metadata, duplicate targets, or unsupported targets;
- changed fingerprints or mismatched paths;
- unsafe scope, tracked data, or symlink escapes;
- repository roots, nested repositories, or occupied paths;
- incomplete scans.

The checkbox authorizes the target. An unchecked item stays inactive even if
another field says it is eligible.

`apply` never signals a process directly. It delegates approved process groups
to the same `audit --kill` handler. This handler shares group behavior,
protection checks, identity checks, and receipts based on confirmed results.
Process and filesystem observations do not guarantee atomic operating-system
ownership. Review the actual target and consequence immediately before you
apply the plan.

Use `afterparty apply --json cleanup-plan.md` for versioned JSON Lines receipts.
This requires Python 3. It applies the same checked targets with fresh safety
checks. Each target reports its outcome, attempted action, confirmed absence,
and journal receipt status. A confirmed cleanup remains applied if the journal
write fails. The command returns nonzero in that case.

Missing delegated evidence appears as unavailable. Afterparty never infers it
from prose. Malformed plans exit `2` before cleanup. Incomplete results exit
`1`. Consumers must check the final completion record and exit status before
they display a finished result. See the [apply receipt contract](docs/apply-events.md).

## Git cleanup

`afterparty git` reports worktrees, agent-named branches, old index locks,
conflict files, and stashes. `--age <days>` changes the discovery threshold.
`--root DIR` selects a repository. `--json` emits JSON Lines. `git --clean`
is a report-only compatibility flag and exits 2. The command does not delete
branches, locks, conflict files, or stashes.

Worktree removal requires a checked `plan` item and `afterparty apply`.
Before removal, Afterparty checks current occupancy, the physical path, and
Git administrative identity. It scans for nested repositories, including
ignored ones. It withholds targets with any of these conditions:

- dirty or occupied worktrees;
- symlinks or unknown ignored data;
- the current or main worktree;
- failed scans or unavailable identity.

Removal uses `git worktree remove` without `--force`. Afterparty then checks
that the target disappeared.

## Build output across projects

Use `builds` to find known build output, caches, and test reports across Git
repositories and worktrees:

```bash
afterparty builds --projects-root "$HOME/orca"
afterparty builds --projects-root "$HOME/orca" --projects-root "$HOME/Documents/projects"
afterparty builds --projects-root "$HOME/orca" --json
```

Repeat `--projects-root` to select more directories. Without it, Afterparty
inspects the current repository or directory. Repository discovery stops at
six directory levels by default. Use `--max-depth N` to choose 1 through 64.
The scan stays within the selected roots. It does not follow directory
symlinks or add linked worktrees outside those roots. Worktrees within the
roots retain separate output inventories.

In a supported terminal, the command uses the existing Bubble Tea helper.
The list sorts paths by measured size. Each row names the repository and
output path. The header shows scan coverage, estimated allocated bytes, and
growth since the previous complete scan of the same scope.

Use arrows or `j`/`k` to move, `/` to filter, `i` to inspect, and `d` for
inline details. Use `r` to refresh and `?` for scope and scan errors.
Press `q` to exit. Press Enter to open
`review --artifacts-only` for the focused repository. That review collects
fresh evidence and starts with no marks. Saving a plan still requires a
separate Apply command to execute cleanup.

The inventory has no cleanup checkboxes. Size and modification time do not
prove that files are unused or safe to delete. Unknown measurements and failed
inspections remain visible. Incomplete scans do not replace the previous
complete baseline. New paths have no growth comparison until the next scan.

`--plain` prints the report without the terminal interface. Piped output also
uses plain text. `--json` prints one versioned JSON report. These modes require
Python 3 but do not require the terminal helper or Go. The command falls back
to plain output when the helper or a supported terminal is unavailable.
`NO_COLOR` and `--ascii` retain the reviewer's existing display behavior.
Native Windows can lack allocated-size evidence and private history locking.
In that case, reports show unknown measurements and return a nonzero status.

This inventory covers the artifact names listed below. It does not include
Rust `target/`, Go build caches, Docker caches, or whole dependency installations.
It does not widen artifact scope for `plan --all` or `review --all`.
See [the inventory contract](docs/build-inventory.md) for scope, measurements,
history, and failure semantics.

## Artifacts

`afterparty artifacts` reports known rebuildable output:

- **Caches:** `.turbo`, `.vite`, `.cache`, `.parcel-cache`, `.rollup.cache`,
  `node_modules/.cache`, `*.tsbuildinfo`, and `.eslintcache`.
- **Build output:** `.next`, `dist`, `build`, `out`, `.output`, `.svelte-kit`,
  `.astro`, and `storybook-static`.
- **Test output:** `coverage`, `.nyc_output`, `test-results`,
  `playwright-report`, `.playwright-mcp`, and `.vitest`.

Use `afterparty plan --artifacts-only --root <repo>` to create an unchecked
proposal. Review it before you run `afterparty apply`. `artifacts --clean`
is report-only and exits 2. Afterparty withholds deletion for tracked paths,
symlinks, nested repositories, and occupied targets. Failed inspections, scope
escapes, and unavailable identity also prevent deletion. It does not select
entire dependency installations such as `node_modules`, but can select their
cache directories.

## Devclean

Devclean has separate modes for orphan processes, caches, persistent settings,
and old agent history. These targets have different consequences. Preview the
targets first. Devclean refuses `--apply` alone. Every change needs a target ID
from a preview with the same mode and scope.

```bash
afterparty devclean            # orphan-process candidates
afterparty devclean --deep     # daemon and simulator candidates
afterparty devclean --optimize # dumps, settings, and launch-agent targets
afterparty devclean --disk     # rebuildable caches; never signals processes
afterparty devclean --history  # stale Codex/Gemini history targets

afterparty devclean --disk --apply --target <reviewed-id>
```

Repeat `--target` to approve multiple targets explicitly. Afterparty checks
each target's identity again immediately before the action. A changed or
uninspectable target remains visible and fails the command. A directory ID
identifies the reviewed directory. It does not freeze the directory's future
contents.

`--optimize` separates deletion from persistent settings and launch-agent
changes. Settings edits use effective JSONC values. Afterparty retains a
backup and shows restoration instructions. JSONC parsing requires Python 3.

`--history` considers Codex session day directories, `~/.codex/log`, and
`~/.gemini/antigravity/browser_recordings`. It does not clean Claude transcripts.
These paths stay under `HOME` and exclude archived Codex sessions. The scan
must be complete. Its newest regular-file mtime must be older than
`CODEX_SESSION_AGE_DAYS` (default `30` days). A selected directory must occupy
at least 1024 KiB.

`--disk` keeps the shared pnpm store intact. It uses `pnpm store prune` to
remove unreferenced packages. Project scans under `--documents-root DIR` only
report targets. Repository artifacts still require plan/apply.

## Reports, state, and history

Private state normally lives under
`${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/`:

- `ledger.tsv` records process ownership and observed member identities;
- workspace-keyed reports store the latest audit and documentation evidence;
- session archives preserve concurrent audit snapshots and bounded session-end
  markers;
- `builds/` stores complete inventory baselines for each selected scope; and
- `actions.jsonl` records confirmed mutation outcomes.

`AGENT_PROCESS_LEDGER` overrides only the ledger path and its adjacent lock.
`afterparty report-path` and `afterparty actions-path` print canonical paths.
Use `afterparty actions --all --workspace DIR --since YYYY-MM-DD` to filter
history. A positive `AFTERPARTY_RETENTION_DAYS` enables removal of old action
receipts during writes. `0` preserves them. Afterparty retains session report
archives.

State directories use private mode `0700`. State files use private mode `0600`.
These modes apply where the platform supports POSIX permissions.

Afterparty writes an audit to repository `report.md` only if Git already
ignores that path and no unrelated file owns it. Otherwise, it uses a cache
path keyed by workspace. `report --show` returns nonzero for an incomplete
report. `builds --json` returns one versioned JSON object. Other JSON commands
use versioned JSON Lines. JSON output never authorizes cleanup.
`audit --json` and `audit --report` are mutually exclusive. `docs` can combine
`--json` and `--report` to collect evidence.

Afterparty attempts to redact common credentials from saved report bodies,
ledger labels, and journal target/detail fields. This covers common credential
arguments, assignments, and URL credentials. Paths and hashes remain visible.
Redaction does not cover all secret formats. Keep secrets out of free-form
command arguments.

Afterparty reports a confirmed cleanup with a failed receipt separately and
returns nonzero. Some early refusals appear only in console output. Set
`AFTERPARTY_JOURNAL=0` to disable the action journal.

## Safety model

- Discovery is read-only by default. Explicit `--kill`, checked `apply`, and
  selected devclean target IDs are the mutation surfaces.
- Ledger and audit cleanup signal process groups. They send `SIGTERM` before
  `SIGKILL` and refuse groups that contain a protected process. Devclean signals
  individual orphan PIDs. An orphan can share a group with unrelated processes.
- Cleanup requires complete process, protection, occupancy, identity, and
  nested-repository scans. Missing or unknown evidence cannot authorize cleanup.
- Filesystem deletion requires a check that the path disappeared. Signals
  require a check that the process or group disappeared. Native maintenance
  uses the tool's result, such as `pnpm store prune` or a `launchctl` probe.
- Afterparty checks physical Git, artifact, and home-cache scopes. Symlink
  parents cannot redirect named home-cache actions outside `HOME`. The
  configured pnpm store is a separate native-tool target. It can be outside
  `HOME`.
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
- Python 3 for guided review, plan/apply JSON, documentation evidence and review
  storage, activity indexing, effective JSONC edits, and macOS simulator
  inspection. Missing Python makes activity unavailable. It withholds cleanup
  that requires activity evidence and Python-backed optimize/simulator targets.
- The compiled Bubble Tea/Lip Gloss helper for interactive review. The source
  build requires Go 1.26+; other CLI commands do not require Go or this helper.
- macOS or Linux is the native target. WSL provides the Unix process interface
  on Windows. Git Bash supports Git/filesystem commands with limited process
  reports. Live-kill tests skip platforms without the required tools.
- macOS-only `launchctl`, Xcode-cache, and iOS-simulator checks are skipped on
  other platforms.

## Development and validation

Check shell syntax and blocking lint errors:

```bash
for script in bin/afterparty skills/afterparty/bin/afterparty skills/afterparty/bin/build-review skills/afterparty/lib/*.sh tests/*.sh; do
  bash -n "$script" || exit 1
done
shellcheck --severity=error skills/afterparty/lib/*.sh
claude plugin validate --strict .claude-plugin/marketplace.json
claude plugin validate .claude-plugin/plugin.json
claude plugin validate --strict skills
claude plugin validate --strict commands
```

Marketplace validation does not inspect every skill, command, or hook file.
Validate those directories explicitly. The root `AGENTS.md` supplies context
for agents in this repository. The bundled `SKILL.md` supplies context for the
installed skill.

On macOS/Linux, install Go 1.26+ and the terminal test dependency in a Python
environment before running the reviewer tests:

```bash
python3 -m venv /tmp/afterparty-tests
/tmp/afterparty-tests/bin/pip install -r tests/requirements.txt
PATH="/tmp/afterparty-tests/bin:$PATH" bash tests/test-review.sh
```

The review suite builds the helper explicitly. It runs Go layout and
whole-frame snapshot tests. It also drives the public CLI in a
pseudo-terminal. Fixtures cover 60×20 and 80×24 layouts in color and monochrome.
They test input during collection and refresh, paging before marking, and
confirmation before choices are discarded. `pyte` is a test dependency only.

Run `bash tests/run.sh` with that environment in a disposable VM, container, or
CI runner. Linux live-stop tests discover processes across the machine and
send real signals. Changing `HOME` alone does not isolate them. Other mutation
fixtures intercept machine tools and signals. CI runs the suite on Ubuntu and
Windows. ShellCheck uses `--severity=error`.

The [documentation accuracy audit](docs/reviews/documentation-audit.md) records
an earlier contract review and its implementation limits. Historical plans in
`docs/plans/` describe the releases that introduced the current safety model.
This README and command help define the current command contract.

The CLI reads its version from `skills/afterparty/VERSION`. Keep the plugin
manifest and skill metadata synchronized with it. Bundle the root license.
Record user-visible changes in [CHANGELOG.md](./CHANGELOG.md).

## Lineage

The first iteration of Afterparty combined my own agent cleanup skills and
methods with [Agent-Broom](https://github.com/Kevin-Liu-01/Agent-Broom) by Kevin
Liu. The LICENSE retains Kevin Liu's copyright line.

## License

MIT — see [LICENSE](./LICENSE).
