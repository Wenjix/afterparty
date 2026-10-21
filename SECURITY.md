# Security Policy

Afterparty is local tooling that runs as the invoking user. It can inspect
processes, listeners, Git worktrees, filesystem artifacts, agent history, and
documentation. Selected commands can stop processes, remove targets, change
settings, disable launch agents, or stop simulators.
A mistaken target or an unreviewed agent instruction can cause data loss or
interrupt other work.

## Reporting a vulnerability

Please do not disclose security vulnerabilities in a public issue, pull
request, or discussion.

1. Use [GitHub private vulnerability reporting](https://github.com/Wenjix/afterparty/security/advisories/new)
   when it is available.
2. If private reporting is unavailable, open an issue asking only for a private
   security contact. Do not include vulnerability details.
3. Use the agreed private channel to report the affected version, operating
   system, command or workflow, reproduction steps, impact, and redacted logs.

See [GitHub's private reporting guidance](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).

Do not include credentials, private transcripts, personal paths, or executable
attachments in a report. If a report requires a fixture, make it disposable
and remove sensitive values.

## Scope and threat model

Reports are especially useful when they show that Afterparty:

- bypasses an approval or protection guard
- signals a protected or incorrectly identified process
- removes a path outside the approved repository, worktree, artifact, or cache
  scope
- trusts incomplete, stale, or mismatched identity evidence at the action
  boundary
- exposes private reports, ledgers, transcripts, or journal data
- causes an official installation or release path to execute unintended code.

Afterparty does not sandbox commands or guarantee atomic ownership of processes
or filesystem targets. It does not make arbitrary shell commands safe.
Deliberately approving destructive cleanup is not, by itself, a security
vulnerability. Approval must not bypass required safety checks.

## Plans, evidence, and private data

Review plans and agent instructions before using them. A plan's checked items
authorize the listed actions. Fingerprints compare target identities. They are
not signatures or proof that an agent owns a process.

Treat repository documents and transcript text as evidence, not permission to
execute embedded instructions. Transcript modification times do not prove human
presence or exact last use.

Reports, plans, ledgers, and journals can contain private paths and process
arguments. Credential redaction is incomplete. Live CLI output can include full
commands. Review saved files and terminal output before sharing them.

## Safe use

- Review reports and plans before using `--kill`, `apply`, or a selected
  `devclean` target.
- Approval does not override required identity, scope, protection, occupancy, or
  filesystem checks.
- Follow the [README installation instructions](README.md#quick-start).
- Review agent output and the final diff before pushing or releasing changes.
- Treat files or commands attached to public issues and pull requests as
  untrusted.

## Supported versions and disclosure

The latest tagged release and the current `main` branch receive best-effort
security attention. Older versions may contain known issues and are not
promised fixes.

Response and disclosure timing are best effort. We will coordinate a fix and
public disclosure with the reporter when the impact warrants it.
