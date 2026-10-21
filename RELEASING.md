# Releasing Afterparty

Releases use semantic version tags in the form `vX.Y.Z`.
`skills/afterparty/VERSION` contains the canonical version. The plugin manifest,
skill metadata, and changelog must agree with it.

## Before tagging

1. Check that the working tree contains only the intended release changes.
2. Update `skills/afterparty/VERSION`.
3. Synchronize the `version` field in `.claude-plugin/plugin.json` and the
   version metadata in `skills/afterparty/SKILL.md`.
4. Add the user-visible changes to `CHANGELOG.md`.
5. Run the full validation suite inside a disposable VM, container, or CI runner:

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

7. Run `./bin/afterparty docs --full --report`. Resolve or explicitly defer
   documentation findings.
8. Review `git diff`, the generated changelog entry, and the installation paths
   in the README.

The test suite includes a metadata synchronization check for the CLI version,
plugin version, skill metadata, and changelog heading.

## Source release packages

Build both archives from the reviewed checkout:

```bash
python3 bin/package-release --output-dir /tmp/afterparty-release
bash tests/test-release-package.sh
```

The output directory must be explicit. Choose a directory outside the checkout.
The command refuses existing archive paths. It checks required inputs, version
agreement, and matching license copies before creating packages.

| Archive | Contents |
| --- | --- |
| `afterparty-X.Y.Z-source.tar.gz` | Standalone CLI and Claude Code plugin with required sources and notices |
| `afterparty-X.Y.Z-skill.tar.gz` | Self-contained `afterparty/` skill folder with required sources and notices |

Both archives use explicit file lists. Tests, fixtures, development records,
local state, and built executables stay outside them. Each archive has a short
installation README. Update the file lists when adding runtime modules.
Package tests inspect archive contents and run the copied CLI without cleanup.

The source bundle includes the optional review helper's Go module, pinned
dependencies, build script, and dependency license notices. For a source install,
run `skills/afterparty/bin/build-review` explicitly with Go 1.26+.
Git ignores the resulting `bin/afterparty-review`. A source-only release does
not include this binary. A copied built bundle supports its OS/architecture
only.

For a binary release, build and test each claimed platform. Include the
dependency notices. Check that review works from a copied bundle. Hooks never
build or launch the reviewer. Prebuilt release distribution is not implemented
yet.

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
Build the source packages from that tagged checkout. Attach both tested
archives to the release. GitHub's automatic source downloads remain repository
snapshots and can include contributor files that the install packages omit.
Check the release page and reported version. Check the standalone CLI, bundled
skill, and Claude Code plugin installation path. Pushes and releases require
explicit maintainer authorization.
