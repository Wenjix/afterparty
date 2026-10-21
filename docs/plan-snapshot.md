# Plan snapshot contract

`afterparty plan --json` emits one JSON Lines stream with contract
`afterparty.plan`, `schema_version: 1`, and one shared `snapshot_id`.
The stream captures the same observations and Markdown as ordinary `plan`.
It proposes targets but does not approve them. Every item starts with
`selected: false`.

| Section | Fields and purpose |
| --- | --- |
| `plan_scope` | Physical `root`, `artifact_scope`, `process_worktree_scope`, boolean `flags` (`all`, `artifacts_only`, `caches_only`), `observed_at`, `collection_status` |
| `plan_capability` | Unique `name`, affected `target_types`, `status` (`complete` or `unavailable`), explanatory `reason` |
| `plan_item` | `item_id`, `type`, exact `target`, `scope`, `fingerprint` or null, `availability`, `reason_code`, `reason`, `selected`, `evidence`, `consequence`, `markdown` |
| `plan_document` | Exact canonical Markdown `text` and its UTF-8 `sha256`; exactly one, immediately before completion |
| `plan_complete` | `snapshot_sha256`, `counts` (`items`, `available`, `withheld`), `sections` mapping capability names to status, and `collection_status`; exactly one, last |

Items use `process-group`, `worktree`, or `artifact` as their type. Availability
is `available` or `withheld`. Availability does not guarantee that an action
will succeed. Scope remains the current repository unless the invocation
includes `--all`. Artifact scope always remains the selected repository.
Flags do not authorize execution.

Process evidence includes these fields:

- maximum observed CPU among members;
- member PID/command records;
- numeric port arrays and port inspection status;
- category, workspace, and recorded purpose or null.

The existing credential redactor attempts to remove common credentials from
display commands and purposes. Worktrees include branch and activity context.
Artifacts include kind and the existing human-readable size estimate when
available. `size_bytes` is currently null because this snapshot does not collect
exact byte totals. Unknown measurements are not zero.

Activity includes `status` (`known` or `unknown`), `last_touched` as epoch seconds
or null, `idle_seconds` or null, and provider `sources`. These transcript
observations do not prove human presence or abandonment. Filesystem
availability uses separate policy checks, independently of transcript age.

Item IDs are type-prefixed SHA-256 values. The hash input concatenates type,
exact target, and scope. Each value uses UTF-8 bytes. Its prefix is the ASCII
byte length followed by `:`. IDs support stable lookup. A replacement at the
same path can retain its ID but change its fingerprint.

Neither an ID nor a fingerprint approves the target.

`markdown.header_line` is one-based. `header_sha256` hashes the original line
without its trailing LF. Available items have `checkbox_column: 4` (one-based).
Their original header begins `- [ ]`. Withheld items have a header for
inspection and `checkbox_column: null`. Each proposal header maps to exactly
one item.

Paths and IDs never come from a terminal label.

The document digest hashes the exact UTF-8 bytes of the document. The snapshot
digest hashes the preceding records as one compact JSON array. It uses sorted
keys, ASCII JSON escapes, and separators `,` and `:`. Digests detect changes
within the captured review context. They are not signatures or proof of
operating-system ownership.

Readers reject these conditions:

- missing completion or unsupported schema;
- duplicate fields or items;
- mismatched IDs or digests;
- invalid mappings or checked source documents.

A correctly framed stream can still have `collection_status: incomplete`.
Its capability reasons remain visible. The command exits `1` for inspection
gaps, `0` for complete inspection, and `2` for usage/serialization refusal.
A truncated stream is unusable. Readers must not treat it as an empty,
successful inspection.

The guided writer binds the exact snapshot ID to a positive explicit mark
count and unique marked IDs. It checks availability and mappings. It changes
only the space in each marked checkbox. It checks the entire result with the
existing `plan_read_checked` parser. Then it compares the parsed targets with
the marked records. It publishes a private file without replacing an existing
path.

Cancellation and zero marks write no output plan. Refresh clears all marks,
even when target IDs and fingerprints stay unchanged.

The checked Markdown authorizes targets for `afterparty apply`. Apply still
collects fresh evidence and enforces every existing target policy. The snapshot
reader, terminal adapter, and save writer never invoke cleanup.
