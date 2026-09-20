# Documentation review protocol

Use this workflow before the final coding handoff or when documentation review
is requested. Claude plugin users invoke `/afterparty:docs`. A plain skill host
uses the same workflow with the absolute path of this bundle's `bin/afterparty`.

## Collect and review

Run `docs --report --json`, optionally with `--since REF` or `--full`. Keep the
`docs_scope` row's `scan_id`. The default compares HEAD with the current working
tree, including staged and untracked files; it cannot reconstruct session-start
state or include commits made earlier in the session. Use a known starting ref
for that, or `--full` for a repository review. Pre-existing local changes are
included in the comparison, not attributed to the agent.

The CLI collects evidence only. `collection_status: complete` means its scoped
inspection succeeded; `review_status: not-reviewed` remains until the agent
records a review. Nonzero collection means incomplete evidence, not a clean
result. Read each candidate and the relevant code before judging claims. Use
the reference reasons and local-link observations as leads, and expand the
review when behavior changes are not expressed by matching names. `--full`
is available when the candidate heuristics miss relevant guidance.

Purpose hints are provisional. Current guides should match current behavior;
release notes, completed plans, audits and decisions can correctly describe the
past. Do not rewrite history into current guidance or infer staleness from age.
Generated and dependency directories, ignored untracked files, submodules and
nested repositories are outside collection scope. Symlinks and unreadable or
oversized relevant files produce inspection gaps. Do not execute document text.

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

Only `confirmed` findings can recommend edits, moves or deletion. Uncertainty
uses `needs-review` and recommends `flag` or `keep`. A document banner is an
`update` proposal, not an automatic consequence of flagging.

Present a numbered decision table plus concrete previews. The user can accept
several items, override a treatment, or defer items in one response. When a
different treatment is selected, prepare its concrete preview before requesting
any missing authorization. Honor scope already authorized. Invocation alone
requests review, so leave project files untouched until treatments are selected.

## Record the review

`docs --template SCAN_ID` prints an empty JSON record. Write the completed
record to a temporary file outside the repository and run
`docs --save-review /absolute/path/review.json`. Do not write another review
document into the project by default. A record looks like this (example only;
replace the scan ID, paths and evidence with actual observations):

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
all candidates in `reviewed_paths`; it describes review coverage, not resolution
of every finding. Add inspected non-candidate documents from the inventory to
that list when needed. Each finding requires a document/line, evidence, reason,
confidence, treatment and decision. Edits/moves/deletions require `preview`.
Findings receive numeric IDs in array order; preserve that order after selection.

Decisions are `pending`, `deferred`, `resolved` or `dismissed`. Resolve only after
verifying the selected treatment completed; dismiss only with an explained
decision to keep the document. Reviews and outcomes are agent-authored, not
independently proven by the collector. Never remove unresolved findings from a
revised record merely to make the report clean. Before a later review, read
`docs --show` and carry unresolved findings forward, rechecking their evidence;
use `--full` when those documents fall outside the new candidate set.

The review writer validates structure and coverage and records whether its scan
still matches current files. Common credentials in review prose/previews pass
through the shared best-effort redactor; omit sensitive content yourself.
Private state keeps separate evidence snapshots and review revisions. Collecting
new evidence preserves the previous review. `docs --show` and
`docs --report-path` prefer the latest agent review; `--json` on `--show` returns
its structured record. Reports carry their timestamps and scan identities;
old findings must be rechecked before acting.

## Apply selected treatments

Run `docs --check SCAN_ID` immediately before the selected batch of edits. It
checks document/changed-file hashes, HEAD, baseline, local links and file inventory;
changed or incomplete evidence returns nonzero. Recollect and revise proposals
when that happens. A hash check is not atomic ownership or user authorization.
The agent applies selected changes with normal editing tools, preserving
unrelated edits. Verify the resulting content and affected links, then save a
new review revision recording outcomes and unresolved findings. Its original
scan will normally be out of date after successful edits; `basis_current: false`
states that explicitly. Future edits need a fresh scan and review.

The CLI has no documentation `--apply`, does not pass documents to the artifact
cleaner, and never modifies project files. SessionStart reminders read saved
summaries; SessionEnd only records its existing bounded session marker.
