# Contributing to Afterparty

Thanks for helping improve Afterparty. Wenjie Fu maintains Afterparty.
Contributions can include focused fixes,
tests, documentation, platform improvements, and carefully scoped features.

## Project model

Coding agents can assist with implementation, tests, reviews, and
documentation. The human maintainer reviews every change before merge or
release. Agents do not receive merge or release authority. Destructive cleanup
requires explicit approval.

Afterparty follows an evidence-before-action model:

1. Deterministic collectors gather observations.
2. An agent or contributor explains what the evidence supports.
3. The maintainer selects the intended treatment.
4. The implementation checks the target again immediately before the action.
5. The tool records the result.

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

Afterparty targets Bash 3.2+, Git, and standard Unix tools. Documentation and
activity workflows require Python 3. Native process inspection targets macOS
and Linux. WSL provides the Unix process interface on Windows. Git Bash has
limited support for process audits.

The optional macOS/Linux reviewer uses Bubble Tea and Lip Gloss. Its build
requires Go 1.26+. `skills/afterparty/bin/build-review` creates the bundled helper.
The pseudo-terminal (PTY) tests also need Python packages. Install them in a
Python environment with `python3 -m pip install -r tests/requirements.txt`.

`tests/test-review.sh` builds the helper explicitly and runs the Go and Python
tests. Ordinary CLI commands do not require these packages. See the
[README setup commands](README.md#development-and-validation).

`tests/test-builds.sh` checks cross-project discovery, inventory history,
read-only CLI behavior, and the terminal inventory. It uses disposable
repositories and private state. It builds the helper on macOS/Linux when Go
is available.
Inventory fixtures must prove that supported output was found as well as
asserting that no cleanup occurred.

Run the full test suite in a disposable VM, container, or CI runner before
submitting a change. Linux live-stop tests discover real processes across the
machine and send real signals:

```bash
bash tests/run.sh
```

For shell-only changes, also run syntax and blocking lint checks:

```bash
for script in bin/afterparty skills/afterparty/bin/afterparty skills/afterparty/bin/build-review skills/afterparty/lib/*.sh tests/*.sh; do
  bash -n "$script" || exit 1
done
shellcheck --severity=error skills/afterparty/lib/*.sh
```

When documentation or command behavior changes, run the relevant documentation
review. Update user-facing examples. Before a release, follow
[RELEASING.md](./RELEASING.md).

## Workflow

1. Create one branch or worktree for the task.
2. Keep the change focused and preserve unrelated local work.
3. Add or update tests for behavior changes, including safety and refusal
   paths.
4. Update documentation, changelog entries, and metadata when the user-visible
   contract changes.
5. Run the validation commands above. Inspect the final diff.
6. Open a pull request with the completed checklist below.

Use lowercase conventional commit prefixes such as `feat:`, `fix:`, `docs:`,
or `test:`. Keep the first line concise and describe the resulting behavior.

## Agent-assisted changes

Agents are welcome to prepare code, tests, and documentation. The submitting
human remains responsible for understanding the diff and its consequences.

- Review every agent-generated change before merging it.
- Do not give an agent credentials, merge authority, or release authority.
- Require explicit approval that names the targets before an agent stops
  processes, removes worktrees/artifacts, deletes documents, or rewrites history.
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
feature proposals. Record substantive design decisions in public issues or
pull requests. This lets future contributors find the reasoning. For security
concerns and conduct reports, use the private channels in
[SECURITY.md](./SECURITY.md) and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).
