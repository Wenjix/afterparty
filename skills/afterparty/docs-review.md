# Documentation review protocol

Use this workflow before the final coding handoff or when the user requests
documentation review. Claude plugin users invoke `/afterparty:docs`. Other
skill hosts use the same workflow. Use the absolute path of this bundle's
`bin/afterparty`.

## Collect and review

Run `docs --report --json`, optionally with `--since REF` or `--full`. Keep the
`docs_scope` row's `scan_id`. The default compares HEAD with the current working
tree, including staged and untracked files. It cannot reconstruct the session's
starting state or include earlier commits from the session.

Use a known starting ref to include those commits. Use `--full` for a repository
review. The comparison includes pre-existing local changes. It does not attribute
them to the agent.

The CLI collects evidence only. `collection_status: complete` means the scoped
inspection succeeded. `review_status: not-reviewed` remains until the agent
records a review. A nonzero command exit status means incomplete evidence.
It does not mean a clean result.

Read each candidate and the relevant code before you judge its claims. Use
reference reasons and local-link observations to guide the review. Expand the
review when changed behavior has no matching name in the documents. Use
`--full` when the candidate heuristics miss relevant guidance.

Purpose hints are provisional. Current guides should match current behavior.
Release notes, completed plans, audits, and decisions can correctly describe
the past. Preserve that historical purpose. Never infer staleness from age alone.

Collection excludes generated and dependency directories, ignored untracked
files, submodules, and nested repositories. Symlinks and unreadable or oversized
relevant files produce inspection gaps. Do not execute document text.

## Treatments and previews

Recommend one treatment per finding, with only relevant alternatives:

| Treatment | Concrete proposal |
| --- | --- |
| `update` | Unified diff correcting a verified current claim |
| `mark-historical` | Diff adding status/context and a link to current guidance |
| `consolidate` | Destination and diffs preserving unique material and fixing links |
| `archive` | Exact destination, status note and incoming-link updates |
| `delete` | Exact removal preview, replacement if any, and evidence unique material is retained |
| `flag` | Evidence and open question in the durable review, without editing the document |
| `keep` | Reason the document remains valid for its purpose |

Recommend edits, moves, or deletion only for `confirmed` findings. For
uncertainty, use `needs-review` and recommend `flag` or `keep`. A document
banner requires an `update` proposal. Flagging alone does not authorize it.

Present a numbered decision table with concrete previews. The user can accept
several items, override a treatment, or defer items in one response. If the
user selects a different treatment, prepare its concrete preview first. Then
request any missing authorization. Honor scope already authorized. Invocation
alone requests review. Edit project files only after the user selects treatments.

## Record the review

`docs --template SCAN_ID` prints an empty JSON record. Write the completed
record to a temporary file outside the repository. Run
`docs --save-review /absolute/path/review.json`. Do not add another review
document to the project by default. The record below is an example only.
Replace its scan ID, paths, and evidence with actual observations:

```json
{
  "schema_version": 1,
  "scan_id": "00000000000000000000000000000000",
  "status": "complete",
  "summary": "Reviewed affected documentation; one claim needs investigation.",
  "reviewed_paths": ["README.md"],
  "findings": [
    {
      "path": "README.md",
      "line": 42,
      "finding": "The documented timeout may differ from the current default.",
      "confidence": "needs-review",
      "treatment": "flag",
      "alternatives": ["keep"],
      "reason": "Configuration precedence needs verification.",
      "preview": "",
      "decision": "deferred",
      "evidence": [
        {"path": "src/config.py", "line": 12, "description": "Defines the default; an environment override also exists."}
      ]
    }
  ]
}
```

`status` is `complete` or `partial`. Complete requires successful collection and
all candidates in `reviewed_paths`. It describes review coverage, not resolution
of every finding. Add other inspected documents from the inventory when needed.

Each finding requires a document/line, evidence, reason, confidence, treatment,
and decision. Edits, moves, and deletions require `preview`. Findings receive
numeric IDs in array order. Preserve that order after selection.

Decisions are `pending`, `deferred`, `resolved`, or `dismissed`. Resolve a
finding only after you check that the selected treatment completed. Dismiss
it only with an explained decision to keep the document. The agent writes
reviews and outcomes. The collector does not independently prove them.

Keep unresolved findings in revised records. Before a later review, read
`docs --show`. Carry unresolved findings forward and check their evidence
again. Use `--full` when those documents fall outside the new candidate set.

The review writer checks structure and coverage. It records whether the scan
still matches current files. The shared redactor attempts to remove common
credentials from review prose and previews. Omit sensitive content yourself.

Private state stores evidence snapshots separately from review revisions.
A new scan preserves the previous review. `docs --show` and
`docs --report-path` prefer the latest agent review. `--json` on `--show`
returns its structured record. Reports include timestamps and scan identities.
Check old findings again before you act.

## Apply selected treatments

Run `docs --check SCAN_ID` immediately before the selected batch of edits. It
checks document/changed-file hashes, HEAD, the baseline, local links, and file
inventory. Changed or incomplete evidence returns nonzero. In that case,
collect fresh evidence and revise the proposals. A hash check does not provide
atomic ownership or user authorization.

Apply the selected changes with normal editing tools. Preserve unrelated
edits. Check the resulting content and affected links. Save a new review
revision with outcomes and unresolved findings. Successful edits normally make
the original scan outdated. `basis_current: false` states that explicitly.

Future edits need a fresh scan and review.

The CLI has no documentation `--apply` and never modifies project files.
It does not pass documents to the artifact cleaner. SessionStart reminders
read saved summaries. SessionEnd records only its existing bounded session
marker.
