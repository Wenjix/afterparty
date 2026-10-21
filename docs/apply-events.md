# Apply receipt contract

`afterparty apply --json PLAN` executes the same checked Markdown plan as plain
apply. It emits UTF-8 JSON Lines on stdout. It requires Python 3 and uses only
the standard library. Human diagnostics, including delegated audit narration,
go to stderr. Forced styling never puts terminal controls into JSON stdout.

The stream describes observations and results. It does not approve another
action. The checked plan remains the authority. Every identity, activity,
occupancy, and filesystem veto still applies at execution. Apply delegates
process signals to the existing audit handler. Ordinary `audit --json` stays
report-only.

## Records

Every record contains `contract: "afterparty.apply"`, `schema_version: 1`, a
unique 32-character hexadecimal `run_id`, and a `section` discriminator.
Readers must refuse unknown versions. Record order is:

1. One `apply_start`, with `plan_sha256` and `checked_count`. `plan_sha256` is the
   SHA-256 digest of the exact plan bytes checked for this invocation.
2. One `apply_target` per checked target, after its fresh checks and possible
   action finish. Unchecked targets never appear. Results can arrive in
   execution order rather than plan order.
3. One `apply_summary`, followed by one `apply_complete`.

If plan checks fail before execution, the first record is `apply_rejection`
with `reason_code` and `detail`. Summary and completion follow with exit status
`2`. There are no target results. Missing serialization support can prevent
even this rejection stream. A diagnostic alone is not a valid receipt.

Target records carry the zero-based checked-plan `target_index`, `type`, exact
`target`, reviewed `fingerprint`, `category`, and `scope` (null when inapplicable).
JSON escaping preserves strings without loss, including Unicode and control
characters. Readers must never evaluate them as shell commands or terminal
escape sequences.

| Result field | Meaning |
| --- | --- |
| `outcome` | `applied`, `gone`, `held`, `vetoed`, `drift`, `survived`, or `failed` |
| `reason_code` | Machine-readable reason such as `identity-changed`, `tracked`, `group-survived`, `postcondition-confirmed`, `removal-failed`, or `child-evidence-unavailable` |
| `detail` | Explanatory prose; readers must not parse it for decisions |
| `mutation_attempted` | True when an operation was attempted, false when it was not, null when child evidence is unavailable |
| `postcondition_confirmed` | Whether the parent confirmed target absence; signal delivery alone never proves this |
| `receipt_status` | `recorded`, `failed`, `not-attempted`, or null when unavailable |
| `delegation_exit_code` | Child exit status for delegated process targets, otherwise null |

The outcomes have these meanings:

- `applied`: the operation was attempted and the parent confirmed absence.
- `gone`: the parent confirmed absence without an attempted operation.
- `held`: current activity or workspace membership prevents cleanup.
- `drift`: the reviewed identity changed.
- `vetoed`: a fresh policy check refused cleanup.
- `survived`: the target remains after delegated execution or worktree removal.
- `failed`: the operation failed or another result is unavailable or unconfirmed; path absence may still be confirmed.

A filesystem removal command error does not count as an applied result, even
when the parent confirms that the target path is absent. It is reported as
`failed` with `reason_code: "removal-failed"` and a confirmed postcondition.

A journal failure does not undo a confirmed effect. That target remains
`applied`, with `receipt_status: "failed"`. The run fails. With
`AFTERPARTY_JOURNAL=0`, journaling is deliberately `not-attempted`. Early
refusals without a journal entry also use `not-attempted`.

Missing or invalid child evidence makes attempted mutation and journal status
null. The parent still reports its own absence check. The overall result is
nonzero.

## Completion and exit status

`apply_summary.counts` contains final target counts for every outcome.
`legacy_counters` preserves the existing plain aggregate counters. Delegation
errors and prepared groups historically affect those counters. They are not
interchangeable with target counts. Use `counts` for target results.

`invocation_errors` counts failed or unavailable delegated invocations.
`journal_failures` includes target and plan-level journal failures. Both summary
and completion carry `exit_status`.

- `0`: all checked targets were applied or already gone, with no required
  journal or delegation failure. An empty checked plan requires no action and
  is valid.
- `1`: a held, drifted, vetoed, surviving, failed, unrecorded, or unavailable
  result. A later refusal does not reverse earlier completed cleanup.
- `2`: invalid invocation or plan, or unavailable structured-output setup.

`apply_complete.event_count` counts all preceding records. `target_count`
counts target records. `events_sha256` is the SHA-256 of the preceding canonical
JSON records, each followed by LF. Canonical JSON uses sorted keys, compact
separators, and ASCII escapes. The digest excludes the completion record itself.
A complete stream ends with LF.

Readers must check the shared context, unique target indexes, target counts,
digest, framing, and exit status. The bundled `apply_events.read_stream`
implements these checks.

Missing completion, a broken pipe, an interrupted writer, or invalid framing
makes the complete result unavailable. Earlier actions may have completed.
Do not infer an empty successful receipt or retry cleanup automatically.
An event-write failure does not erase an independently confirmed action.

## Private delegated evidence

Before any mutation, Afterparty prepares serialization and a private run
directory keyed by workspace. The directory holds the frozen plan and temporary
event channel. It uses mode 0700, with mode 0600 files where the platform
supports those modes. Normal exit removes the directory. An abrupt termination
can leave private temporary files. Durable action history remains in the
existing journal.

Each process-category request binds the child channel to the invocation's
`run_id`, exact requested group IDs, categories, and reviewed fingerprints.
The child checks that binding before it sends signals. It writes explicit
decisions, attempt/confirmation flags, and journal status. The parent accepts
exactly one valid result for every requested group. It independently checks
that each group is absent. It never infers child results from prose, styling
counters, or journal contents.

These files and hashes check consistency. They do not guarantee atomic OS
ownership or protect against another program that runs as the same user.
