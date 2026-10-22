<p align="center">
  <img src="./assets/afterparty-logo.svg" alt="Afterparty confetti logo" width="132" height="132">
</p>

<h1 align="center">Afterparty</h1>

<p align="center">
  Cleanup for the mess coding agents leave behind.
</p>

Afterparty helps you review processes, worktrees, generated files, and caches
that remain after coding sessions. It also collects evidence for documentation
review. Use it as a standalone CLI, Claude Code plugin, or Agent Skill.

Reports describe what Afterparty can inspect. You choose what to stop or
remove. Cleanup checks each target again before acting. Reports can write
private state, but they do not authorize cleanup.

[Quick start](#quick-start) · [Commands](#what-it-does) ·
[Requirements](#requirements-and-platform-support) ·
[Cleanup review](#approving-cleanup-with-planapply) ·
[Build inventory](#build-output-across-projects) · [License and credits](#license)

## Quick start

Install the [requirements](#requirements-and-platform-support), then clone the
repository:

```bash
git clone https://github.com/Wenjix/afterparty.git
cd afterparty
export PATH="$PWD/bin:$PATH"
```

The PATH setting lasts for this shell. Add the checkout's absolute `bin` path
to your shell configuration to keep it. Check the installed version with
`afterparty --version`.

Change to the project you want to inspect. Then choose a workflow:

Use an unused filename for a manual plan. Shell redirection with `>` replaces
an existing file.

| Goal | Start here |
| --- | --- |
| See processes by workspace | `afterparty glance` |
| Report processes, listeners, and Git findings | `afterparty audit --strict` |
| Find build output across projects | `afterparty builds --projects-root "$HOME/projects" --plain` |
| Review cleanup interactively | `afterparty review` after the [optional helper build](#optional-terminal-helper) |
| Review cleanup without the helper | `afterparty plan > cleanup-plan.md` |
| Collect documentation evidence | `afterparty docs --report --json` |

Replace example paths with your own. Values such as `<PID>` and `<saved-plan>`
are placeholders. Do not enter the angle brackets in a shell command.

For cleanup, inspect the proposals and mark only the targets you approve.
Interactive review prints a saved plan path. For a manual plan, edit the
checkboxes in `cleanup-plan.md`. Then run Apply with that file:

```bash
afterparty apply cleanup-plan.md
```

Use the saved path instead when you used interactive review. Plan and review
never execute cleanup. Apply acts only on checked items.

To leave a report for the next session:

```bash
afterparty audit --report
afterparty report --show
```

### Claude Code plugin

```text
/plugin marketplace add Wenjix/afterparty
/plugin install afterparty@afterparty
```

From a project, use `/afterparty:audit` for cleanup reports or
`/afterparty:docs` for agent-led documentation review. The plugin also provides
the general `/afterparty:afterparty` skill.

Plugin hooks perform only small bookkeeping tasks:

- `SessionStart` shows the last explicit audit, session-end marker, and saved
  documentation-review summaries.
- `SessionEnd` records the session ID and end time.

Hooks do not scan the machine, run cleanup, build the helper, or open the
terminal UI. Run `audit --report` explicitly to save an audit. Plugin
installation does not put the CLI on your shell's PATH.

### Agent Skill

The self-contained `skills/afterparty` folder includes instructions, scripts,
version metadata, and the license. Copy it from the checkout to your host's
skill directory:

```bash
# Claude Code
mkdir -p ~/.claude/skills
cp -r skills/afterparty ~/.claude/skills/

# Codex
mkdir -p ~/.agents/skills
cp -r skills/afterparty ~/.agents/skills/
```

Claude substitutes `${CLAUDE_SKILL_DIR}` in skill instructions. Other hosts
must locate `SKILL.md` and use that folder's absolute `bin/afterparty` path.
Installing the skill does not add the command to PATH or install plugin hooks.

See the [Agent Skills standard](https://agentskills.io),
[Claude skill locations](https://code.claude.com/docs/en/skills#choose-where-skills-load),
and [Codex skill locations](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills).
A host needs local shell execution to inspect this machine. A hosted session
can inspect only its own environment.

## What it does

| Command | Purpose and scope |
| --- | --- |
| `glance` | Read-only workspace view of visible processes and recorded activity |
| `audit` | Ledger, machine process/listener, and current-repository Git reports |
| `list` | Recorded process groups for the current workspace |
| `add` | Record an existing process in the private ledger |
| `stop` | Preview recorded groups. `--kill` stops matching groups. |
| `prune` | Remove ledger records for groups confirmed absent |
| `git` | Report worktrees, agent branches, locks, conflict files, and stashes |
| `artifacts` | Report known build, cache, and test output |
| `builds` | Read-only project inventory with sizes and growth history |
| `plan` | Create an unchecked cleanup checklist |
| `review` | Mark targets interactively and save a checked plan |
| `apply` | Check targets again and execute checked plan items |
| `devclean` | Preview machine cleanup. Changes require selected target IDs. |
| `docs` | Collect documentation evidence and store agent-authored reviews |
| `doctor` | Combine ledger, process, Git, artifact, and default orphan diagnostics |
| `report`, `report-path` | Read or locate the saved workspace audit |
| `actions`, `actions-path` | Read or locate cleanup receipts |
| `--version` | Print the installed version |

A **target** is one proposed process group, worktree, or artifact. A process
group contains related processes and has a process group ID (**PGID**).
A worktree is a Git working directory. An artifact is generated output, such
as a build directory or test report. A **mark** selects a target for a plan.

Use `afterparty --help` for the command overview. Most operational commands
also accept `--help` for their options.

## Auditing processes and listeners

`afterparty audit` reports recorded groups, likely development processes and
listeners, and Git findings. Process classification uses executable and
subcommand evidence. A match does not prove agent ownership or permission to
stop a process. Listener reports include likely development listeners on
loopback or wildcard bindings and exclude protected matches.

Use `audit --strict` when unavailable process or listener evidence must cause
a nonzero exit. `doctor --strict` adds that requirement to combined diagnostics.
Doctor does not run every devclean mode.

### Process ledger and direct stopping

```bash
afterparty add --pid <PID> --kind dev --port <PORT> \
  --purpose "verify the local app" -- pnpm dev
afterparty list
afterparty stop
```

`add` records a process that already exists. The text after `--` is a display
label, not a command to launch. Attribution uses the caller's workspace, not
the target process's working directory. Run it from the owning project.

`list`, `stop`, and `prune` default to the current Git repository or directory.
Use `--root DIR` for another workspace or `--all` for all recorded workspaces.
`list` and `stop` also support `--kind KIND`.

After reviewing all matching groups, choose the appropriate action:

```bash
# Stop matching groups already recorded in this workspace.
afterparty stop --kill

# Stop one reviewed development group, including an unrecorded group.
afterparty audit --kill dev --pgid <reviewed-pgid>

# Remove records for groups confirmed absent.
afterparty prune
```

Direct stop commands do not require old activity or low CPU use. Unrestricted
`audit --kill` searches the machine. Use `--pgid` to narrow it to reviewed groups.
Categories are `tests`, `dev`, and `browser`, or a comma-separated combination.
`--keep <pgid>` preserves a specified group.

Signals affect every current member of the selected process group, including
members outside the matched category. Descendants in other process groups
remain. Review the full group and consequence before stopping it.

### Workspace activity

`afterparty glance` groups visible processes by workspace. It keeps unknown
attributions visible and accepts `--oneline` or `--json`. It has no cleanup flag.

Activity indexing reads existing Claude and Codex transcripts:

| Provider | Default source |
| --- | --- |
| Claude | Immediate project directories under `~/.claude/projects` |
| Codex | `sessions` and `archived_sessions` under `${CODEX_HOME:-$HOME/.codex}` |

Identity comes from normalized recorded working directories, not directory
names. Activity uses the newest contributing transcript modification time.
It does not prove human presence or an exact visit time. Activity from a newer
or equally recent indexed ancestor can contribute to descendants. Codex files
that name several workspaces conservatively refresh all of them when the file
changes.

Missing optional directories count as empty sources. Corrupt, incomplete,
unreadable, or oversized records make the whole index unavailable. A workspace
without usable activity stays unknown. Process liveness alone does not prove
that work is abandoned. See [configuration](#configuration) for source overrides.

## Approving cleanup with plan/apply

Plan defaults to the selected repository. `--root DIR` selects another one.
`--all` includes other visible Git workspaces for process discovery and indexed
repositories for worktree discovery. Artifact scope stays within the selected
repository. `--artifacts-only` excludes processes and worktrees. Add
`--caches-only` to limit artifact proposals to caches.

Process proposals require old recorded activity and low observed CPU use.
The default limits are four hours and 20 percent per member. Every member
needs usable CPU evidence. Unknown activity, invalid CPU, mixed workspaces,
protected groups, and unsupported categories withhold the group.

Filesystem targets use separate identity, occupancy, and scope checks.
Transcript age is not required to remove a checked worktree or artifact.

### Optional terminal helper

The optional `afterparty-review` executable provides the terminal UI for
`review` and interactive `builds`. It uses Bubble Tea and Lip Gloss with a
Python backend. Build it explicitly on macOS or Linux with Go 1.26 or newer:

```bash
./skills/afterparty/bin/build-review
```

Run this from the source checkout. An installed skill can run its own
`bin/build-review`. The build downloads pinned Go dependencies and places
`afterparty-review` beside the bundled CLI. The binary is specific to its OS
and architecture. Go is not needed at runtime. Ordinary commands never build
or download the helper. Rebuild after updating the UI source.
[Dependency notices](skills/afterparty/ui/THIRD_PARTY_NOTICES.txt)
ship with the source bundle.

### Interactive review

Run `afterparty review` from the project. The steps are **Choose**, **Review
choices**, **Save plan**, and **Finish**. Choose uses compact rows and a bounded
focus strip. Inspection shows full identities, consequences, and group members.
A step indicator tracks Choose, Review choices, and Save plan. At 100 columns
by 24 rows, focused evidence appears beside the list. Smaller layouts keep a
bounded panel below it.

| Key | Action |
| --- | --- |
| Arrows or `j`/`k` | Move focus |
| PgUp/PgDn | Scroll without changing target focus |
| Space | Mark or unmark an available target. In Review, unmark it. |
| `i` | Inspect the focused target from Choose |
| `d` | Show or hide focused details in Choose. Toggle optional evidence in Review. |
| `/` | Filter in Choose. Hidden marks still count. |
| Enter | Advance to review or save. Finish after saving. |
| Esc | Return while keeping choices |
| `r` | Refresh. Confirm before clearing marks. |
| `q` | Quit. Confirm before discarding marks. Close help or inspection first. |
| `?` | Show mode-specific keys, scope, and scan status |
| Ctrl+P | Search the available commands |
| Ctrl+Z | Suspend. Use `fg` to resume. |
| Ctrl+C | Exit immediately. A previously saved plan remains saved. |

The on-screen legend lists primary controls for the current mode. Help lists
all keys. Ctrl+P opens Commands outside Help, filtering, and confirmations.
Type to find a command. Use arrows to choose it. Enter runs an available
command, and Esc returns without changing the target filter or marks.
Unavailable commands explain why they cannot run. Apply remains separate.

Choose expands only the focused target. Inspection shows full evidence.
Panels count hidden detail lines. Review always lists each process-group
member. Brief mark confirmations disappear after four seconds. Help retains
the latest message. Refusals and save receipts remain visible.

Space first reveals a focused target hidden by paging. Keys typed during collection cannot
mark an older snapshot or advance it. A failed refresh disables saving until
another refresh succeeds.

Saving needs at least one explicit mark. `--output FILE` selects a destination
and refuses an existing path before scanning. Without it, review uses a unique
filename in private workspace state. Finish the review to print the saved path,
choices, and a shell-quoted apply command. Run that command separately.

Below 60 columns by 20 rows, review shows a size notice and keeps marks.
Resize to continue marking or saving. In tmux, use `prefix z` to zoom.
If the helper, Python 3, or terminal is unavailable, review prints an unchecked
plain plan and exits nonzero. That fallback does not save a plan.

### Manual plans and Apply

Choose an unused filename. Shell redirection with `>` overwrites an existing
file before Afterparty starts.

```bash
afterparty plan > cleanup-plan.md
# Edit the file. Check only the targets you approve.
afterparty apply cleanup-plan.md
```

An unchecked item never authorizes cleanup. Apply validates the plan before
actions start and checks each target again immediately before acting.
It refuses changed identities, unsafe scopes, tracked data, nested repositories,
occupied paths, and unavailable required evidence.

Apply delegates process signals to the existing audit handler. It removes
worktrees with `git worktree remove` without `--force`. Main, current, dirty,
occupied, or uninspectable worktrees remain withheld. Unknown ignored data
also prevents removal. Apply confirms target absence after filesystem removal
or process stopping. A failed removal command still returns failure even if
the target is absent.

These checks are observations, not atomic operating-system ownership guarantees.
A later refusal does not reverse earlier completed cleanup.

## Build output across projects

```bash
afterparty builds --projects-root "$HOME/projects"
afterparty builds --projects-root "$HOME/projects" --projects-root "$HOME/work"
afterparty builds --projects-root "$HOME/projects" --json
```

Builds inventories known generated output across Git repositories and worktrees.
It changes no project files and writes only private inventory history.
Repeat `--projects-root` for more roots. Without it, discovery uses the current
repository or directory. `--max-depth N` limits repository discovery to 1–64
levels, with a default of 6. That depth does not limit artifact measurement
inside each repository.

Discovery stays within the selected physical roots and skips directory symlinks.
Linked worktrees outside those roots are not added. Worktrees inside the roots
keep separate inventories. Overlapping roots do not duplicate repositories.

Rows sort by measured allocated size. Growth compares the previous complete
scan with matching roots, discovery depth, and artifact definitions. The first
complete scan establishes a baseline. New paths have no comparison yet.
Incomplete scans do not replace that baseline.

Size estimates do not promise freed space. File modification times do not show
last use. Unknown sizes and scan failures remain visible. Rust `target/`, Go
build caches, Docker caches, and entire dependency installations are outside
this inventory.

In the terminal, use arrows or `j`/`k`, `/`, `i`, `d`, `r`, and `?` to navigate
and inspect. Enter leaves the inventory and opens a fresh artifact review for
one repository. That review starts without marks. Saving and Apply remain
separate actions.

At 80 columns, bars compare each path with the known allocated-byte total.
Filtering keeps that scale. Unknown sizes remain unknown. These bars do not
estimate reclaimable space. Wide layouts show focused evidence and the
repository's known subtotal beside the list. Incomplete subtotals say partial.

`--plain` prints a readable report. Piped output also uses plain text.
`--json` emits one report object. These modes require Python 3 but not the
terminal helper. Missing terminal support falls back to plain output.
Native Windows can lack allocated-size evidence and private history locking.
Unknown measurements and unavailable history produce a nonzero result.
See the [inventory contract](docs/build-inventory.md) for details.

## Git cleanup and artifacts

`afterparty git` reports worktrees, agent-named branches, old index locks,
conflict files, and stashes. Use `--age DAYS`, `--root DIR`, or `--json` to
adjust the report. It does not delete those findings.

`afterparty artifacts` reports these known output families:

| Kind | Names and patterns |
| --- | --- |
| Cache | `.turbo`, `.vite`, `.cache`, `.parcel-cache`, `.rollup.cache`, `node_modules/.cache`, `*.tsbuildinfo`, `.eslintcache` |
| Build | `.next`, `dist`, `build`, `out`, `.output`, `.svelte-kit`, `.astro`, `storybook-static` |
| Test | `coverage`, `.nyc_output`, `test-results`, `playwright-report`, `.playwright-mcp`, `.vitest` |

Use `artifacts --caches-only` to report caches. Use
`plan --artifacts-only --caches-only` for a cache-only plan. Afterparty does not
select entire `node_modules` installations.
Git-tracked paths, repository roots, nested repositories, symlinks, scope
escapes, occupied targets, and failed inspections prevent artifact deletion.

Both `git --clean` and `artifacts --clean` are report-only compatibility flags
and exit `2`. Worktree and artifact removal require a checked plan and Apply.

## Devclean

Devclean uses preview target IDs, separate from repository plan checkboxes.
Preview the modes you need:

| Command | Preview |
| --- | --- |
| `afterparty devclean` | Orphan process candidates |
| `afterparty devclean --deep` | Daemon processes and simulator shutdowns |
| `afterparty devclean --optimize` | Dumps, crash-reporter settings, and launch agents |
| `afterparty devclean --disk` | Named caches and native store maintenance. No process stopping. |
| `afterparty devclean --history` | Old Codex sessions/logs and Gemini browser recordings |

After reviewing a target, repeat the mode and scope with its exact ID:

```bash
afterparty devclean --disk --apply --target <reviewed-id>
```

Repeat `--target` for several choices. Afterparty refuses `--apply` alone. It
checks identity again before each action. An ID identifies the reviewed target
and action. It does not freeze future directory contents.

Named cache cleanup stays physically under HOME. The pnpm store is a separate
native-tool target and can be elsewhere. Afterparty uses only `pnpm store prune`
for that shared store. Roaming project scans under `--documents-root DIR`
remain report-only. Repository artifacts require plan/apply.

Optimize can change persistent settings or disable launch agents. Effective
JSONC settings checks require Python 3. Afterparty keeps a settings backup and
prints restoration instructions.

History targets are Codex session day directories, `~/.codex/log`, and
`~/.gemini/antigravity/browser_recordings`. Each selected directory must occupy
at least 1024 KiB. A complete scan must show every regular file older than
`CODEX_SESSION_AGE_DAYS`, which defaults to 30 days.

Recent or uninspectable history stays withheld. Cleanup excludes Claude
transcripts, archived Codex sessions, physical aliases of those archives, and
directories that contain them. Activity-source overrides do not redirect these
deletion paths. Removing history can remove resume information and records of
agent work.

## Documentation review

`afterparty docs` collects evidence. The invoking agent reads that evidence,
checks document claims against the implementation, and proposes treatments.
The collector never calls an LLM, edits project files, or executes document text.

```bash
afterparty docs --report --json
afterparty docs --since <git-ref> --report --json
afterparty docs --full --report
```

The default compares HEAD with staged, unstaged, and untracked files, including
pre-existing changes. It does not infer the session's starting commit.
`--since REF` selects a known baseline. `--full` includes all recognized
repository documentation. `--root DIR` selects another repository.

Discovery includes tracked documents and nonignored untracked documents.
It recognizes Markdown/MDX, reStructuredText, AsciiDoc, text, and known
extensionless README/changelog files. Discovery excludes dependency and generated
directories, submodules, and nested repositories. Relevant symlinks, unreadable
files, non-UTF-8 files, oversized files, or diffs can make collection incomplete.
Local-link checks cover simple file destinations. They do not validate remote
links, anchors, website routes, or every Markdown construct.

The agent can recommend update, mark historical, consolidate, archive, delete,
flag, or keep. It shows evidence, reasons, and concrete previews before edits.
Only approved treatments proceed. Age alone does not make a document wrong.
Historical records retain their original purpose.

| Command | Use |
| --- | --- |
| `docs --template <scan-id>` | Create a JSON template for the agent's review |
| `docs --save-review <file.json>` | Store the completed review record |
| `docs --check <scan-id>` | Refuse changed or incomplete evidence before approved edits |
| `docs --show` | Read the latest review, or evidence when no review exists |
| `docs --report-path` | Locate that report |

Evidence and agent reviews have separate private storage. A new scan preserves
the previous review. Collection completion, review coverage, and unresolved
findings are separate facts. A complete review can have unresolved findings.
`--show` returns nonzero for partial coverage.

Run `docs --check` immediately before approved edits. Changed evidence requires
a new scan and revised proposals. Saving a review records the agent's judgments.
It does not apply or independently validate the edits.
See the [review protocol and record format](skills/afterparty/docs-review.md).

## Structured output and exit status

| Interface | Output |
| --- | --- |
| `audit --json`, `list --json`, `git --json`, `glance --json` | JSON Lines reports |
| `plan --json` | Versioned JSON Lines snapshot with canonical Markdown and integrity records |
| `apply --json PLAN` | Versioned JSON Lines execution receipts |
| `builds --json` | One versioned JSON report object |
| `docs --json` | Versioned JSON Lines evidence |
| `docs --template <scan-id>` | One formatted JSON review template |
| `actions` | JSON Lines from the action journal |

JSON Lines means one JSON object per line. Output has no terminal styling.
`audit --json` is report-only and refuses `--kill`. Audit cannot combine
`--json` with `--report`. Documentation collection can combine both flags.
Documentation read/check modes emit the requested evidence, review, or check
record with `--json`. `docs --report-path` always prints a plain path.

Check each command's status fields as well as its exit code. Ordinary audit
or glance can return `0` with unavailable capabilities. Use strict audit when
that must fail. For plan, `0` means complete collection, `1` means inspection
gaps, and `2` means a usage or snapshot refusal. Builds returns `1` for
incomplete collection or unavailable comparison history.

Apply JSON reports each target's outcome, attempted action, confirmed absence,
and receipt status. A malformed plan exits `2` before cleanup. Incomplete
results exit `1`. Earlier cleanup can succeed even when the run fails later.
A journal failure does not reverse a confirmed action and makes the run fail.

Consumers must check schema versions, capability/status fields, and the
command's exit rules. Plan/apply streams also require valid completion records.
Missing completion in those streams never means success. Full contracts:
[plan snapshots](docs/plan-snapshot.md), [apply receipts](docs/apply-events.md),
and [build inventory](docs/build-inventory.md).

## Reports, state, and history

Private state normally uses `${XDG_CACHE_HOME:-$HOME/.cache}/agent-processes/`:

| State | Contents |
| --- | --- |
| `ledger.tsv` | Recorded processes and reviewed member identities |
| Workspace reports | Explicit audits and separate documentation evidence/reviews |
| Session archives | Audit snapshots and bounded session-end markers |
| `reviews/` | Saved cleanup plans keyed by workspace |
| `builds/` | Complete inventory baselines keyed by scope |
| `actions.jsonl` | Cleanup outcomes |

Directories use mode `0700` and files use `0600` where POSIX permissions apply.
Afterparty writes repository `report.md` only when Git ignores it and no
unrelated file owns the path. Otherwise, it uses workspace-keyed cache storage.
`report --show` returns nonzero for an incomplete report.

```bash
afterparty report-path
afterparty actions-path
afterparty actions --workspace /path/to/project --since 2026-10-01
afterparty actions --all --since 2026-10-01
```

Actions defaults to the current workspace. `--all` disables workspace filtering.
Saved output attempts to redact common credential arguments, assignments, and
URL credentials. Paths and hashes remain visible. Redaction is incomplete.
Keep secrets out of command labels and arguments.

### Configuration

| Variable | Purpose and default |
| --- | --- |
| `AFTERPARTY_TRANSCRIPT_ROOT` | Claude transcript source. Default: `~/.claude/projects`. |
| `AFTERPARTY_CODEX_ROOT` | Codex activity source. Default: `${CODEX_HOME:-$HOME/.codex}`. |
| `AFTERPARTY_IDLE_HOURS` | Positive whole-hour process-plan threshold. Default: `4`. |
| `AFTERPARTY_BUSY_CPU` | Maximum observed CPU per member for process-plan eligibility. Default: `20`. |
| `CODEX_SESSION_AGE_DAYS` | Positive whole-day history threshold. Default: `30`. |
| `XDG_CACHE_HOME` | Parent of private state. Default: `$HOME/.cache`. |
| `AGENT_PROCESS_LEDGER` | Custom ledger path and adjacent lock |
| `AFTERPARTY_JOURNAL` | Set to `0` to disable action receipts. Default: enabled. |
| `AFTERPARTY_RETENTION_DAYS` | Positive values age out journal entries during writes. Default: `0` retains them. |
| `AFTERPARTY_STYLE` | `auto`, `always`, or `never`. Default: `auto`. |
| `AFTERPARTY_CARD` | Set to `0` to suppress terminal summary cards |

Hour and day limits use decimal notation, including leading zeros. Afterparty
refuses zero or invalid day limits. An idle limit beyond the supported interval
withholds process cleanup. Observed CPU values must be finite numbers zero or
greater. One member with missing or invalid CPU evidence withholds the group.
Invalid `AFTERPARTY_IDLE_HOURS` or `AFTERPARTY_BUSY_CPU` syntax uses the default
and prints a warning.

### Terminal display

Terminal reports adapt to width. Narrow reports stack fields. Paths and
commands retain copyable detail lines. Piped reports keep their plain format.
`NO_COLOR` and `TERM=dumb` disable automatic color. `AFTERPARTY_STYLE=always`
or `never` overrides automatic selection. The review UI keeps bold and reverse
focus under `NO_COLOR`. `--ascii` escapes non-ASCII display text in review/builds.
Without Python 3, wrapped CLI details use escaped ASCII bytes.

## Safety model

- Discovery suggests candidates. A report, fingerprint, focus, or mark alone
  never executes cleanup.
- Ledger/audit stop whole process groups. They send SIGTERM, then SIGKILL if
  needed. Devclean stops individual orphan PIDs because their groups can contain
  unrelated processes.
- Shared protection patterns cover selected editors, shells, agents, and MCP
  servers. These patterns are heuristics and cannot identify every application.
- Required identity, protection, activity, occupancy, scope, and nested-repository
  checks remain authoritative after approval. Unknown required evidence withholds
  the action.
- Filesystem boundaries use physical paths. Symlink parents cannot redirect
  named home-cache deletion outside HOME.
- Process and filesystem actions require confirmed absence. Native maintenance
  uses the tool's result. Receipt failures remain visible and return nonzero.

No check guarantees that another process cannot change the target afterward.
Review the target and consequence immediately before applying cleanup.

## Requirements and platform support

| Requirement | Used for |
| --- | --- |
| Bash 3.2+, Git, standard Unix tools | Core CLI. Tools include `ps`, `awk`, `find`, `stat`, `du`, and hashing. |
| `lsof` | Listener reports and occupancy evidence. Worktree/artifact removal requires a successful occupancy scan. |
| `rg` | Process matching. The audit uses `grep -E` when ripgrep is absent. |
| Python 3.8+ | Builds, interactive review, plan/apply JSON, activity indexing, documentation collection/review, JSONC edits, and simulator inspection |
| Go 1.26+ | Explicit build of the optional terminal helper. Not required at runtime. |

macOS and Linux are native targets. WSL supplies the Unix process interface
on Windows. Git Bash has limited process support. Missing tools produce
unavailable evidence and prevent cleanup that needs those checks. Native
Windows can lack build-size evidence and history locking. The optional
terminal helper targets macOS and Linux.

Launch-agent, Xcode-cache, and iOS-simulator checks are macOS-specific.
Missing Python makes activity unavailable and withholds Python-backed settings
and simulator targets. Plain reports and manual Markdown plans do not need
the terminal helper.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| The shell cannot find `afterparty` | Add the checkout's `bin` directory to PATH, or use the bundle's absolute CLI path. |
| Review prints a plain plan | Check Python 3 and terminal support. Build the optional helper. |
| The pane shows a size notice | Resize to at least 60×20. In tmux, press `prefix z`. |
| A required scan is unavailable | Read the reported reason. Check the required tools with `afterparty doctor --strict`. |
| Apply refuses an old plan | Review the refusal. Collect a fresh plan after the underlying condition changes. |

## Development and validation

Run syntax, blocking lint, and packaging checks:

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

Marketplace validation alone does not inspect skill, command, and hook contents.
Validate them explicitly. For terminal tests on macOS/Linux, install Go and the
Python test dependency in an isolated environment:

```bash
python3 -m venv /tmp/afterparty-tests
/tmp/afterparty-tests/bin/pip install -r tests/requirements.txt
PATH="/tmp/afterparty-tests/bin:$PATH" bash tests/test-review.sh
```

Review tests build the helper, check frames, and drive the CLI in a
pseudo-terminal. Build-inventory tests use disposable repositories and private
state. `pyte` is a test dependency only.

Build source release archives into a directory outside the checkout:

```bash
python3 bin/package-release --output-dir /tmp/afterparty-release
bash tests/test-release-package.sh
```

The command creates separate source/plugin and Agent Skill archives from
explicit file lists. It includes runtime scripts, optional TUI source, version
metadata, and licenses. It excludes built executables, tests, development
records, and local state. Existing archives cause a refusal. A refusal names an
incomplete archive left by an interrupted copy so it can be removed before rerunning.
See [RELEASING.md](RELEASING.md) for publication steps.

Run the full suite **inside a disposable VM, container, or CI runner**:

```bash
PATH="/tmp/afterparty-tests/bin:$PATH" bash tests/run.sh
```

Linux live-stop tests discover machine processes and send real signals.
Changing HOME alone does not isolate them. Other mutation fixtures intercept
machine tools and signals. CI defines Ubuntu and Windows jobs.

The canonical version is `skills/afterparty/VERSION`. Keep plugin and skill
metadata synchronized. Preserve the bundled license and update
[CHANGELOG.md](./CHANGELOG.md) for user-visible changes.
Read the [architecture guide](docs/architecture.md) before changing module
boundaries. Interface contracts remain in `docs/`. Personal working notes and
completed development records belong outside the public source tree.

## License

Afterparty uses the [MIT license](./LICENSE). The license retains copyright
notices for Kevin Liu and Wenjie Fu. The bundled skill includes the same license.

### Credits and lineage

- **Wenjie Fu** created Afterparty and developed its workspace activity model,
  cleanup approval workflow, and safety checks. He also added build inventories,
  documentation review, structured reports, the terminal interface, and
  plugin/skill packaging.
- **Kevin Liu**, author of [Agent-Broom](https://github.com/Kevin-Liu-01/Agent-Broom),
  provided the original foundation for the process ledger, audit/stop workflow,
  and report-first defaults. Afterparty retains his MIT copyright notice.
- **DevClean by ImL1s** (`ImL1s/devclean`) inspired the orphan, deep, optimize,
  and disk mode structure. Agent-Broom records that influence in its
  [original acknowledgment](https://github.com/Kevin-Liu-01/Agent-Broom/blob/1bab484c38a3061826cbb93cec591c5d786a48db/README.md#devclean-mode).
- **[Bubble Tea](https://github.com/charmbracelet/bubbletea)** and
  **[Lip Gloss](https://github.com/charmbracelet/lipgloss)** are libraries by
  Charmbracelet. Bubble Tea provides the terminal application framework.
  Lip Gloss provides terminal layout and styling.

The bundle includes terminal dependency licenses in
[THIRD_PARTY_NOTICES.txt](skills/afterparty/ui/THIRD_PARTY_NOTICES.txt).
