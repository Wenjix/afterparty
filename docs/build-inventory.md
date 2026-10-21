# Build-output inventory

`afterparty builds` reports known generated output across selected project
directories. It does not delete files, stop processes, or approve cleanup.
It writes only private inventory history. No plugin hook runs this scan.

## Scope and discovery

Repeat `--projects-root DIR` to select project directories. Without a root,
the launcher selects the current Git repository or the current directory.
`--max-depth` limits repository discovery to 1 through 64 directory levels.
The default is 6. Artifact measurement inside each discovered repository is
not limited to that discovery depth.

Discovery stays inside the selected physical roots. It does not follow
directory symlinks. It skips Git metadata, dependency directories, and known
generated-output directories while searching for repositories. A repository
that itself has an output-like name remains a repository.

Linked worktrees inside the roots remain separate repositories for this
inventory. Worktrees outside the selected roots are not added. Physical
aliases and overlapping roots do not duplicate a repository. An agent
transcript is not required for filesystem discovery.

The shared artifact-name registry defines the supported directory names and
file patterns. The existing artifact collector and apply-time name checks use
the same definitions. This release adds no Rust, Go, or Docker cache cleanup.

## Measurements and history

Rows sort by numeric allocated size, largest first. An unknown size remains
unknown. Size estimates do not promise how much storage deletion would free.
Shared storage, hard links, and filesystem behavior can affect that amount.

`modified_at` describes the newest observed filesystem modification time for
the measured target. It is not a last-use time. Neither this timestamp nor
size proves that output is unnecessary.

The private `builds/` state directory stores a complete baseline for each
matching scope. Scope includes the physical roots, discovery depth, and
artifact registry. Writes use private permissions and atomic publication.
Concurrent history access uses a lock.

The first complete scan establishes a baseline. A later matching scan compares
measured bytes with that baseline. A newly discovered path has no per-path
delta. The aggregate delta can include paths that disappeared between complete
scans. Incomplete scans do not replace a complete baseline.

History failures remain separate from filesystem scan failures. The report
shows unavailable history instead of inventing a growth value.

## Terminal and plain reports

The terminal helper shows scan coverage, estimated size, growth, and a focused
list. `i` opens full details. `d` toggles inline details. `/` filters.
`?` shows scope and errors. `r`
collects a new inventory. `q` exits, or closes inspection and Help.

Enter leaves the inventory and opens the bundled review command for the
focused repository with `--artifacts-only`. Arguments use a fixed command and
separate values. Displayed paths are not executed as shell text. The review
collects fresh evidence and starts without marks. Apply remains separate.

The inventory ignores Space and `s`. Keys typed during collection cannot
select cleanup or open review from an older generation. Focus alone is not
approval. The terminal supports the existing minimum 60-by-20 layout,
monochrome attributes, ASCII escaping, suspension, and terminal restoration.

`--plain` prints a readable report. Nonterminal output also uses plain text.
`--json` prints one report object. Neither mode requires the optional terminal
helper. Missing terminal support falls back to a plain inventory.
Platforms without allocated-size evidence or private history locking retain
unknown measurements and report unavailable capabilities.

## JSON report version 1

The report is one JSON object, rather than the plan snapshot's JSON Lines.
It is evidence for an inventory, not an executable plan or approval.

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1`. |
| `observed_at` | Scan observation timestamp. |
| `roots` | Selected physical project roots. |
| `max_depth` | Repository discovery depth. |
| `collection_status` | `complete` or `incomplete` filesystem collection. |
| `history_status` | `first`, `compared`, or `unavailable`. |
| `previous_observed_at` | Previous comparison timestamp, or null. |
| `repositories` | Repository roots, labels, and collection status. |
| `items` | Output paths and their measured evidence. |
| `issues` | Paths and explanations for failed inspections or history. |
| `total_bytes` | Sum of known allocated-size estimates. Partial when collection is incomplete. |
| `delta_bytes` | Aggregate comparison with the previous complete matching scope, or null. |

Each item has `item_id`, `repository`, `path`, `relative_path`, `kind`,
`size_bytes`, `delta_bytes`, `modified_at`, and `status`. Kind is `cache`,
`build`, or `test`. Unavailable measurements use null. Raw JSON paths retain
their exact strings. Terminal and plain displays escape control characters.

Exit status is 0 for a complete report with usable history, 1 for incomplete
collection or unavailable history, and 2 for invalid command options.
The first scan counts as usable history. If Enter opens cleanup review, the
command returns that review's exit status.
