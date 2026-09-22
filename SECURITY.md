# Security Policy

Afterparty is local tooling that runs as the invoking user. It can inspect
processes, listeners, Git worktrees, filesystem artifacts, agent history, and
documentation. Selected commands can signal process groups or remove approved
targets. A mistaken target or an unreviewed agent instruction can therefore
cause data loss or interrupt other work.

## Reporting a vulnerability

Please do not disclose security vulnerabilities in a public issue, pull
request, or discussion.

1. Use [GitHub private vulnerability reporting](https://github.com/Wenjix/afterparty/security/advisories/new)
   when it is available.
2. If private reporting is unavailable, contact [@Wenjix](https://github.com/Wenjix)
   through the private contact method on the maintainer profile before sharing
   details publicly.
3. Include the affected version, operating system, command or workflow, safe
   reproduction steps, impact, and any redacted logs needed to verify it.

Do not include credentials, private transcripts, personal paths, or executable
attachments in a report. If a report requires a fixture, make it disposable
and remove sensitive values.

## Scope and threat model

Reports are especially useful when they show that Afterparty:

- bypasses an approval or protection guard;
- signals a protected or incorrectly identified process;
- removes a path outside the approved repository, worktree, artifact, or cache
  scope;
- trusts incomplete, stale, or mismatched identity evidence at the action
  boundary;
- exposes private reports, ledgers, transcripts, or journal data; or
- causes an official installation or release path to execute unintended code.

Afterparty does not sandbox the commands it runs, guarantee atomic ownership of
an operating-system process, or make arbitrary user-provided shell commands
safe. A user deliberately approving a destructive command is not, by itself, a
security vulnerability.

## Safe use

- Review reports and plans before using `--kill`, `apply`, or a selected
  `devclean` target.
- Use only the installation and release instructions documented in this
  repository and the [GitHub Releases](https://github.com/Wenjix/afterparty/releases)
  page.
- Review agent output and the final diff before pushing or releasing changes.
- Treat files or commands attached to public issues and pull requests as
  untrusted.

## Supported versions and disclosure

The latest tagged release and the current `main` branch receive best-effort
security attention. Older versions may contain known issues and are not
promised fixes.

Response and disclosure timing are best effort. We will coordinate a fix and
public disclosure with the reporter when the impact warrants it.
