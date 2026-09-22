# Contributing to Afterparty

Thanks for helping improve Afterparty. The project is maintainer-led by Wenjie
Fu and welcomes focused fixes, tests, documentation, platform improvements,
and carefully scoped features.

## Project model

Coding agents may assist with implementation, testing, reviews, and
documentation. The human maintainer reviews every change before it is merged
or released. Agents do not receive merge or release authority and must not
perform destructive cleanup without explicit approval.

Afterparty follows an evidence-before-action model:

1. deterministic collectors gather observations;
2. an agent or contributor explains what the evidence supports;
3. the maintainer selects the intended treatment;
4. the implementation checks the target again at the action boundary; and
5. the tool records the result.

## Before you start

- Read the [README](./README.md) and the relevant command or skill
  documentation.
- Check existing issues and pull requests before starting overlapping work.
- For external contributions, open an issue before proposing a broad
  architectural change. Small fixes and documentation corrections can go
  directly to a pull request.
- Never include credentials, private paths, session transcripts, or other
  sensitive material in an issue, commit, or pull request. Follow
  [SECURITY.md](./SECURITY.md) for vulnerability reports.

## Development requirements

Afterparty targets Bash 3.2+, Git, standard Unix tools, and Python 3 for its
documentation and activity workflows. Native process inspection targets macOS
and Linux; WSL provides the Unix process interface on Windows. Git Bash has
explicitly degraded process-audit support.

Run the full test suite in a disposable VM, container, or CI runner before
submitting a change. Linux live-stop coverage uses real machine-wide process
discovery and signals:

```bash
bash tests/run.sh
```

For shell-only changes, also run syntax and blocking lint checks:

```bash
for script in bin/afterparty skills/afterparty/bin/afterparty skills/afterparty/lib/*.sh tests/*.sh; do
  bash -n "$script" || exit 1
done
shellcheck --severity=error skills/afterparty/lib/*.sh
```

When documentation or command behavior changes, run the relevant documentation
review and update user-facing examples. Before a release, follow
[RELEASING.md](./RELEASING.md).

## Workflow

1. Create one branch or worktree for the task.
2. Keep the change focused and preserve unrelated local work.
3. Add or update tests for behavior changes, including safety and refusal
   paths.
4. Update documentation, changelog entries, and metadata when the user-visible
   contract changes.
5. Run the validation commands above and inspect the final diff.
6. Open a pull request with the completed checklist below.

Use lowercase conventional commit prefixes such as `feat:`, `fix:`, `docs:`,
or `test:`. Keep the first line concise and describe the resulting behavior.

## Agent-assisted changes

Agents are welcome to prepare code, tests, and documentation. The submitting
human remains responsible for understanding the diff and its consequences.

- Review every agent-generated change before merging it.
- Do not give an agent credentials, merge authority, or release authority.
- Do not let an agent kill processes, remove worktrees or artifacts, delete
  documents, or rewrite history without an explicit, reviewable approval.
- If an agent made substantial changes, summarize the assistance and the
  validation performed in the pull request.

## Pull requests

Please include:

- a short description of the user-visible result;
- the scope and any known limitations;
- tests and validation commands run, including skipped checks and why;
- documentation or changelog updates, when applicable; and
- safety or compatibility considerations for process, filesystem, Git, and
  transcript operations.

Keep pull requests small enough to review. Contributions that only improve
documentation, tests, examples, or platform support are valuable.

## Support and decisions

Support is best effort. Use a GitHub issue for ordinary questions, bugs, and
feature proposals. Keep substantive design decisions in public issues or pull
requests so future contributors can find the reasoning. Security concerns and
conduct reports use the private channels described in [SECURITY.md](./SECURITY.md)
and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).
