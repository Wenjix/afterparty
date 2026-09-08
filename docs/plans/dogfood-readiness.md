# Dogfood readiness fixes

Historical implementation record for 0.11.0; current command contracts are in
[README.md](../../README.md).

Review baseline: `2e516ad` (2026-09-06). The user approved this sequence and
previously authorized committing and pushing the resulting fixes.

## 1. Require positive evidence before destructive actions

- Record process start identity with ledger ownership. Preserve unverifiable
  legacy entries and surviving groups after launcher exit. Refuse missing
  identity and failed inspection; classify executable/subcommands rather than
  arbitrary argument text. Keep TERM/KILL safe when original workers survive.
- Route artifact deletion through checked typed plans and the shared filesystem
  vetoes. Protect containing/contained nested repositories, tracked data, scope
  boundaries and occupied paths; failed scans withhold removal.
- Protect ignored worktree data except narrowly recognized rebuildable output.
  Recheck at removal so a newly created local `.env` cannot inherit approval.
- Separate history retention from caches. Require complete, stale activity
  evidence for history deletion. Disk-only cleanup must never signal processes.

## 2. Preserve truthful results through every interface

- Distinguish verified absence from unavailable process, listener and Git scans.
  Keep unattributed processes visible and label agent activity accurately.
- Validate all checked plan entries before acting, including malformed metadata,
  unsupported types, duplicate targets and mismatched displayed paths. Report
  invalid/refused/held/gone/completed/failed outcomes without false success.
- Persist report completion, section errors, timestamp and session identity;
  reminders expose age/status. Record concurrent session results separately.
- Propagate journal errors while distinguishing mutation from receipt failure.
  Normalize JSON values; give rendering modes identical exit semantics.

## 3. Make approval specific and understandable

- Start every plan item unchecked. Default to the current repository, with
  explicit `--root` and `--all` scope. Show commands, workspace, available ports,
  activity evidence and consequences before approval.
- Bind filesystem execution to the reviewed path, root and fingerprint.
  Deprecate direct artifact discovery-and-delete in favor of plan/apply.
- Require exact preview target IDs for devclean mutation. Separate orphan,
  deep-process, persistent-setting, cache and history modes; expose restoration
  instructions for persistent changes and retain withheld findings in receipts.
- Preserve reviewed scope in follow-up commands. Add useful action-history
  filters and credential redaction with configurable, explicit retention.

## 4. Verify the installed skill and integration

- Correct Claude's `${CLAUDE_SKILL_DIR}` substitution, document path resolution
  for other agents, and retain a compact, self-contained skill.
- Preserve failed audit evidence without aborting slash-command instruction
  loading. Use bounded session-end reporting and accurately describe lifecycle
  limitations instead of promising async completion.
- Exercise a copied installed bundle in a disposable workspace, partial tool
  availability, concurrent reports and hook entry points.

## Validation and delivery

Use disposable state and logging/intercepting shims for `kill`, `pgrep`,
`launchctl` and `pnpm`; HOME alone is not isolation. Add regressions that prove
the intended guard was reached and scratch-mutate critical guards to make their
tests fail. Run focused suites, Bash syntax, blocking ShellCheck, then the full
suite in an isolated checkout. Review the integrated diff, update package
metadata/documentation, commit on the existing feature branch, push without
rewriting history, and check Linux/Windows CI.

## Completion

All four stages are implemented in 0.11.0 on `feat/typed-targets`.

- Process ownership now retains member identity through launcher exit;
  unavailable scans, replacements and unverifiable historical rows are refused.
  Classification uses executable/subcommand positions and protected groups stay
  protected. Fingerprint capture precedes the final identity check before TERM.
- Worktree removal preserves ignored local configuration and unknown ignored
  data. Artifact removal uses typed checked plans, complete shared vetoes and
  fresh occupancy/identity checks. Direct artifact cleanup is report-only.
- Plans default to the current repository and all actions start unchecked.
  Scope, group members, available ports, recorded purpose and consequences are
  visible. Invalid checked entries reject the whole plan before mutation.
- Devclean requires individual target IDs. Disk, history, orphan, deep and
  persistent-setting actions have separate modes. History needs stale activity;
  JSONC edits retain backups and restoration instructions.
- Reports persist completion, failed sections and session identity, retain
  concurrent snapshots, and distinguish the last explicit audit from a bounded
  session-end marker. Journaling failures propagate separately from completed
  work. Actions filters, opt-in retention and common-credential redaction work.
- Installed skill commands use the correct substitution and a documented
  non-Claude path fallback. The skill remains 247 words and explicitly asks for
  user-approved targets before applying the checklist.

Validation:

- Isolated macOS full suite: 29 suites, 291 `ok:` checks, exit 0. The live-kill
  suite explicitly skipped because `setsid` is unavailable; native Linux CI is
  responsible for that coverage. Outer tool shims intercepted machine-level
  commands; no developer processes, services or package stores were mutated.
- Bash syntax and ShellCheck 0.11.0 `--severity=error` pass. The JSONC edit test
  also simulates Windows Python without `os.fchmod`, preserving the backup and
  successfully updating the effective setting.
- Thirty scratch guard mutations were caught by their intended regressions:
  seven process, twelve devclean, seven reporting/privacy, four filesystem/plan.
- Marketplace and plugin manifests validate. The plugin validator retains its
  existing warning that root `CLAUDE.md` is developer context, not installed
  agent context. The bundled generic skill validator predates the existing
  standard `compatibility` field; supported fields validate in a scratch copy,
  and the shipped YAML, release metadata and installed behavior are checked.
- Copied-bundle integration covers paths with spaces, incomplete reports,
  concurrent writers, credential redaction and hook invocation. An independent
  agent followed the installed skill in an isolated workspace and accurately
  reported the running process and unavailable scan evidence without mutation.

Portable identity and cwd scans are bounded observations, not atomic operating
system ownership guarantees. Redaction is best effort for recognized formats.
Session-end hooks deliberately record a marker, not a promise of a completed
exit-time audit. Existing users can regenerate saved plans for the new defaults
and register known running processes again if their legacy records lack member
identity. No migration is needed for a fresh setup; the owner's prior entries
were test fixtures.

Native Linux/Windows CI is checked after pushing and reported separately.
Both passed on `e0d3bf1` ([run 34057969681](https://github.com/Wenjix/afterparty/actions/runs/34057969681)).

The first Linux run caught a stale live-kill fixture that invented an absent
PGID and expected the old PID-recycling message. The fixture now records the
real disposable group, changes only its member-identity proof, and checks both
refusal and a successful stop with the original proof. An intercepted run
passes; removing the identity guard fails five assertions. No production
behavior changed in this CI follow-up.

Windows then exposed native-Python fixture assumptions: selecting Bash by name,
Unix/native path differences, text encoding and line endings. The fixtures now
invoke the parent Git Bash explicitly and prove scanner/signal interception.
The JSON test separately supplies successful absent-process evidence and a
failed scan, asserting `dead` and `unknown` respectively on every platform.
