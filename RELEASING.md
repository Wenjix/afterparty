# Releasing Afterparty

Releases are versioned with semantic version tags in the form `vX.Y.Z`. The
canonical version is stored in `skills/afterparty/VERSION`; the plugin manifest,
skill metadata, and changelog must agree with it.

## Before tagging

1. Confirm the working tree contains only the intended release changes.
2. Update `skills/afterparty/VERSION`.
3. Synchronize the `version` field in `.claude-plugin/plugin.json` and the
   version metadata in `skills/afterparty/SKILL.md`.
4. Add the user-visible changes to `CHANGELOG.md`.
5. Run the full validation suite:

   ```bash
   bash tests/run.sh
   ```

6. Validate JSON and plugin surfaces when the host tools are available:

   ```bash
   python3 -m json.tool .claude-plugin/plugin.json >/dev/null
   python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
   python3 -m json.tool hooks/hooks.json >/dev/null
   claude plugin validate --strict .claude-plugin/marketplace.json
   claude plugin validate .claude-plugin/plugin.json
   claude plugin validate --strict skills
   claude plugin validate --strict commands
   ```

7. Run `./bin/afterparty docs --full --report` and resolve or intentionally
   defer documentation findings.
8. Review `git diff`, the generated changelog entry, and the installation paths
   in the README.

The test suite includes a metadata synchronization check for the CLI version,
plugin version, skill metadata, and changelog heading.

## Tagging and publishing

After the checks pass and the release is approved:

```bash
git add skills/afterparty/VERSION .claude-plugin/plugin.json \
  skills/afterparty/SKILL.md CHANGELOG.md
git commit -m "chore: release vX.Y.Z"
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

Create the GitHub Release from the tag with the corresponding changelog notes.
Verify the release page, the reported version, the standalone CLI, the bundled
skill, and the Claude Code plugin installation path. Pushes and releases require
explicit maintainer authorization.
