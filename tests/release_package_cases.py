"""Check release contents and copied entry points without running cleanup."""

from contextlib import redirect_stderr, redirect_stdout
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


REPO = Path(sys.argv.pop(1)).resolve()
BASH = sys.argv.pop(1)
LIB_FILES = set("""
agent-hygiene.sh apply-events.sh apply.sh apply_events.py artifact-kinds.tsv
artifact-names.sh audit-git.sh audit-processes.sh build_inventory.py builds.sh
categories.sh clean-artifacts.sh devclean-settings.py devclean.sh docs.py docs.sh
eligible.sh fingerprint.sh glance.sh journal.sh json.sh plan-capture.sh
plan-collect.sh plan-format.sh plan-render.sh plan.sh plan_data.py privacy.sh
process-ledger.sh protect.sh report.sh review.py review.sh review_data.py state.sh
style.sh terminal_text.py vetoes.sh workspace-index.py workspace.sh
""".split())
UI_FILES = set("""
THIRD_PARTY_NOTICES.txt go.mod go.sum commands.go inventory.go layout.go main.go sections.go state.go
terminal.go text.go theme.go view.go
""".split())
SKILL_FILES = {
    "SKILL.md", "docs-review.md", "VERSION", "LICENSE", "bin/afterparty", "bin/build-review",
} | {"lib/" + name for name in LIB_FILES} | {"ui/" + name for name in UI_FILES}
SOURCE_FILES = {
    "LICENSE", "CHANGELOG.md", "SECURITY.md", "bin/afterparty",
    ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
    "hooks/hooks.json", "commands/audit.md", "commands/docs.md",
} | {"skills/afterparty/" + name for name in SKILL_FILES}


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="afterparty-release-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source with spaces"
        for name in SOURCE_FILES | {"bin/package-release"}:
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, target)
        self.version = (self.source / "skills/afterparty/VERSION").read_text().strip()
        self.output = self.base / "output with spaces"
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.base / "home"), PYTHONDONTWRITEBYTECODE="1",
                        AFTERPARTY_STYLE="never")
        (self.base / "home").mkdir()

    def package(self, output=None, expect=0):
        result = subprocess.run(
            [sys.executable, str(self.source / "bin/package-release"),
             "--output-dir", str(output or self.output)],
            cwd=self.base, env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result

    def unpack(self, kind):
        archive_path = self.output / ("afterparty-" + self.version + "-" + kind + ".tar.gz")
        target = self.base / ("unpacked " + kind)
        target.mkdir()
        prefix = "afterparty-" + self.version if kind == "source" else "afterparty"
        with tarfile.open(archive_path) as archive:
            members = archive.getmembers()
            self.assertTrue(all(member.isfile() for member in members))
            self.assertTrue(all(member.name.startswith(prefix + "/") for member in members))
            expected = SOURCE_FILES if kind == "source" else SKILL_FILES
            self.assertEqual({member.name[len(prefix) + 1:] for member in members},
                             expected | {"README.md"})
            for member in members:
                relative = member.name[len(prefix) + 1:]
                executable = relative in {"bin/afterparty", "bin/build-review",
                                          "skills/afterparty/bin/afterparty",
                                          "skills/afterparty/bin/build-review"} or relative.endswith(".sh")
                expected_mode = 0o755 if executable else 0o644
                self.assertEqual(member.mode, expected_mode)
                self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 0))
            if hasattr(tarfile, "data_filter"):
                archive.extractall(target, filter="data")
            else:
                archive.extractall(target)
        return target / prefix

    def check_cli(self, cli):
        for argument, expected in (("--version", self.version),
                                   ("--help", "afterparty")):
            result = subprocess.run([BASH, str(cli), argument], cwd=self.base,
                                    env=self.env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            if argument == "--version":
                self.assertEqual(result.stdout.strip(), self.version)

    def check_readme_links(self, root):
        for target in re.findall(r"\]\(([^)]+)\)", (root / "README.md").read_text()):
            if not target.startswith(("https://", "#")):
                self.assertTrue((root / target).is_file(), target)

    def test_allowlist_covers_current_runtime_source(self):
        self.assertEqual({path.name for path in (REPO / "skills/afterparty/lib").iterdir()
                          if path.is_file() and path.suffix in (".sh", ".py", ".tsv")}, LIB_FILES)
        self.assertEqual({path.name for path in (REPO / "skills/afterparty/ui").iterdir()
                          if path.is_file() and (path.suffix == ".go" or path.name in
                             {"go.mod", "go.sum", "THIRD_PARTY_NOTICES.txt"})
                          and not path.name.endswith("_test.go")}, UI_FILES)

    def test_packages_contain_only_reviewed_inputs_and_work_when_copied(self):
        for name in (".impeccable/review.md", "docs/mockup.png", "trace.log",
                     "skills/afterparty/bin/afterparty-review", "skills/afterparty/lib/local.txt",
                     "skills/afterparty/ui/local_test.go", "skills/afterparty/ui/testdata/local.ansi"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("must not ship")
        self.package()
        source = self.unpack("source")
        skill = self.unpack("skill")
        self.check_cli(source / "bin/afterparty")
        self.check_cli(source / "skills/afterparty/bin/afterparty")
        self.check_cli(skill / "bin/afterparty")
        for root in (source, skill):
            self.check_readme_links(root)
        self.assertEqual((source / "LICENSE").read_bytes(), (skill / "LICENSE").read_bytes())
        self.assertEqual((source / "LICENSE").read_bytes(), (REPO / "LICENSE").read_bytes())
        self.assertEqual((source / "LICENSE").read_bytes(),
                         (source / "skills/afterparty/LICENSE").read_bytes())
        manifest = json.loads((source / ".claude-plugin/plugin.json").read_text())
        self.assertEqual(manifest["version"], self.version)
        hooks_path = source / manifest["hooks"]
        hooks = json.loads(hooks_path.read_text())["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "SessionEnd"})
        for entries in hooks.values():
            for entry in entries:
                for hook in entry["hooks"]:
                    self.assertEqual(hook["command"], "bash")
                    command = hook["args"][0].replace("${CLAUDE_PLUGIN_ROOT}/", "")
                    self.assertTrue((source / command).is_file(), command)
        marketplace = json.loads((source / ".claude-plugin/marketplace.json").read_text())
        for plugin in marketplace["plugins"]:
            self.assertTrue((source / plugin["source"] / ".claude-plugin/plugin.json").is_file())
        for path in (source / "commands").glob("*.md"):
            for reference in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([\w/.-]+)", path.read_text()):
                self.assertTrue((source / reference).is_file(), reference)
        skill_text = (skill / "SKILL.md").read_text()
        for reference in re.findall(r"\$\{CLAUDE_SKILL_DIR\}/([\w/.-]+)", skill_text):
            self.assertTrue((skill / reference).is_file(), reference)
        for target in re.findall(r"\]\(([^)]+)\)", skill_text):
            self.assertTrue((skill / target).is_file(), target)
        notices = (skill / "ui/THIRD_PARTY_NOTICES.txt").read_text()
        for dependency in ("charm.land/bubbletea/v2", "charm.land/lipgloss/v2"):
            self.assertIn(dependency, notices)

    def test_archives_are_reproducible(self):
        self.package()
        second = self.base / "second"
        self.package(output=second)
        for first in self.output.iterdir():
            self.assertEqual(hashlib.sha256(first.read_bytes()).digest(),
                             hashlib.sha256((second / first.name).read_bytes()).digest())

    def test_existing_archive_is_never_replaced(self):
        reference = self.base / "existing-reference"
        self.package(output=reference)
        self.output.mkdir()
        existing = self.output / ("afterparty-" + self.version + "-skill.tar.gz")
        content = (reference / existing.name).read_bytes()
        shutil.copy2(reference / existing.name, existing)
        result = self.package(expect=1)
        self.assertIn("Archive already exists", result.stderr)
        self.assertNotIn("incomplete", result.stderr)
        self.assertEqual(existing.read_bytes(), content)
        self.assertEqual(list(self.output.iterdir()), [existing])

    def test_truncated_existing_archive_is_reported_incomplete(self):
        reference = self.base / "truncated-reference"
        self.package(output=reference)
        source_name = "afterparty-" + self.version + "-source.tar.gz"
        source_bytes = (reference / source_name).read_bytes()
        for label, truncated_bytes in (("half", source_bytes[:len(source_bytes) // 2]),
                                       ("gzip trailer", source_bytes[:-8])):
            with self.subTest(truncation=label):
                output = self.base / ("truncated " + label)
                output.mkdir()
                existing = output / source_name
                existing.write_bytes(truncated_bytes)

                result = self.package(output=output, expect=1)
                self.assertIn("incomplete", result.stderr)
                self.assertIn(str(existing), result.stderr)
                self.assertEqual(existing.read_bytes(), truncated_bytes)
                self.assertEqual(list(output.iterdir()), [existing])

    def test_missing_required_input_refuses_both_archives(self):
        for name in ("skills/afterparty/lib/review_data.py", "hooks/hooks.json",
                     "skills/afterparty/ui/THIRD_PARTY_NOTICES.txt"):
            with self.subTest(name=name):
                path = self.source / name
                content = path.read_bytes()
                path.unlink()
                result = self.package(expect=1)
                self.assertIn("Required input is missing", result.stderr)
                self.assertIn(name, result.stderr)
                self.assertFalse(self.output.exists())
                path.write_bytes(content)

    def test_output_directory_must_be_selected(self):
        result = subprocess.run([sys.executable, str(self.source / "bin/package-release")],
                                cwd=self.base, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--output-dir", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.output.exists())

    def test_symlink_input_is_refused(self):
        path = self.source / "skills/afterparty/lib/review_data.py"
        saved = self.base / "outside-input.py"
        path.rename(saved)
        try:
            path.symlink_to(saved)
        except OSError as error:
            self.skipTest("This platform cannot create a symlink: " + str(error))
        result = self.package(expect=1)
        self.assertIn("Required input is a symlink", result.stderr)
        self.assertIn("lib/review_data.py", result.stderr)
        self.assertFalse(self.output.exists())

    def test_second_archive_failure_removes_first_archive(self):
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        main_globals = namespace["main"].__globals__
        original_write_archive = main_globals["write_archive"]

        def fail_second(handle, prefix, content):
            handle.write(b"partial archive")
            if prefix == "afterparty":
                self.assertFalse(any(path.name.endswith(("-source.tar.gz", "-skill.tar.gz"))
                                     for path in self.output.iterdir()))
                raise OSError("simulated storage failure")
            return original_write_archive(handle, prefix, content)

        error_output = io.StringIO()
        with mock.patch.dict(main_globals, {"write_archive": fail_second}), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]), \
                redirect_stderr(error_output):
            self.assertEqual(namespace["main"](), 1)
        self.assertIn("simulated storage failure", error_output.getvalue())
        self.assertEqual(list(self.output.iterdir()), [])

    def test_interrupted_build_leaves_no_archive(self):
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        main_globals = namespace["main"].__globals__
        original_write_archive = main_globals["write_archive"]

        for target_call, output in ((1, self.output), (2, self.base / "second-output")):
            with self.subTest(call=target_call):
                calls = [0]

                def interrupt(handle, prefix, content):
                    calls[0] += 1
                    handle.write(b"partial archive")
                    if calls[0] == target_call:
                        raise KeyboardInterrupt
                    return original_write_archive(handle, prefix, content)

                with mock.patch.dict(main_globals, {"write_archive": interrupt}), \
                        mock.patch.object(sys, "argv",
                                          ["package-release", "--output-dir", str(output)]):
                    with self.assertRaises(KeyboardInterrupt):
                        namespace["main"]()
                self.assertEqual(list(output.iterdir()), [])

                self.package(output=output)
                self.assertEqual(
                    {path.name for path in output.iterdir()},
                    {"afterparty-" + self.version + "-source.tar.gz",
                     "afterparty-" + self.version + "-skill.tar.gz"})
                umask = os.umask(0)
                os.umask(umask)
                for path in output.iterdir():
                    self.assertEqual(path.stat().st_mode & 0o777, 0o666 & ~umask, path.name)

    def test_second_archive_publish_failure_removes_first_archive(self):
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        links = [0]
        os_module = namespace.get("os", os)
        original_link = os_module.link
        racing_archive = self.output / ("afterparty-" + self.version + "-skill.tar.gz")

        def fail_second_link(source, destination, *args, **kwargs):
            links[0] += 1
            if links[0] == 2:
                Path(destination).write_bytes(b"other process")
                raise FileExistsError("simulated race")
            return original_link(source, destination, *args, **kwargs)

        error_output = io.StringIO()
        with mock.patch.object(os_module, "link", fail_second_link), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]), \
                redirect_stderr(error_output):
            self.assertEqual(namespace["main"](), 1)
        self.assertIn("Archive already exists", error_output.getvalue())
        self.assertFalse((self.output / ("afterparty-" + self.version + "-source.tar.gz")).exists())
        self.assertEqual({path.name for path in self.output.iterdir()}, {racing_archive.name})
        self.assertEqual(racing_archive.read_bytes(), b"other process")

    def test_interrupt_after_link_removes_archive(self):
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        os_module = namespace.get("os", os)
        original_link = os_module.link
        links = [0]

        def interrupt_after_first_link(source, destination, *args, **kwargs):
            links[0] += 1
            result = original_link(source, destination, *args, **kwargs)
            if links[0] == 1:
                raise KeyboardInterrupt
            return result

        with mock.patch.object(os_module, "link", interrupt_after_first_link), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]):
            with self.assertRaises(KeyboardInterrupt):
                namespace["main"]()
        self.assertEqual(list(self.output.iterdir()), [])

        self.package()
        self.assertEqual(
            {path.name for path in self.output.iterdir()},
            {"afterparty-" + self.version + "-source.tar.gz",
             "afterparty-" + self.version + "-skill.tar.gz"})

    @unittest.skipIf(os.name == "nt", "SIGINT delivery is not supported consistently on Windows")
    def test_sigint_during_publish_is_deferred(self):
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        os_module = namespace.get("os", os)
        original_link = os_module.link
        links = [0]

        def interrupt_after_first_link(source, destination, *args, **kwargs):
            links[0] += 1
            result = original_link(source, destination, *args, **kwargs)
            if links[0] == 1:
                os.kill(os.getpid(), signal.SIGINT)
            return result

        with mock.patch.object(os_module, "link", interrupt_after_first_link), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]):
            with self.assertRaises(KeyboardInterrupt):
                namespace["main"]()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_publish_without_hard_links(self):
        reference = self.base / "hard-link-reference"
        self.package(output=reference)
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        os_module = namespace.get("os", os)
        output = io.StringIO()
        umask = os.umask(0)
        os.umask(umask)

        def fail_link(source, destination, *args, **kwargs):
            raise OSError(errno.EPERM, "Operation not permitted")

        with mock.patch.object(os_module, "link", fail_link), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]), \
                redirect_stdout(output):
            self.assertEqual(namespace["main"](), 0)
        names = {"afterparty-" + self.version + "-source.tar.gz",
                 "afterparty-" + self.version + "-skill.tar.gz"}
        self.assertEqual({path.name for path in self.output.iterdir()}, names)
        for name in names:
            self.assertEqual((self.output / name).read_bytes(), (reference / name).read_bytes())
            self.assertEqual((self.output / name).stat().st_mode & 0o777, 0o666 & ~umask)

    def test_fallback_does_not_clobber_racing_archive(self):
        reference = self.base / "fallback-race-reference"
        self.package(output=reference)
        namespace = runpy.run_path(str(self.source / "bin/package-release"))
        os_module = namespace.get("os", os)
        racing_archive = self.output / ("afterparty-" + self.version + "-source.tar.gz")
        source_bytes = (reference / racing_archive.name).read_bytes()
        truncated_bytes = source_bytes[:len(source_bytes) // 2]
        error_output = io.StringIO()

        def fail_link(source, destination, *args, **kwargs):
            Path(destination).write_bytes(truncated_bytes)
            raise OSError(errno.EPERM, "Operation not permitted")

        with mock.patch.object(os_module, "link", fail_link), \
                mock.patch.object(sys, "argv", ["package-release", "--output-dir", str(self.output)]), \
                redirect_stderr(error_output):
            self.assertEqual(namespace["main"](), 1)
        self.assertIn("Archive already exists but is incomplete", error_output.getvalue())
        self.assertIn(str(racing_archive), error_output.getvalue())
        self.assertEqual({path.name for path in self.output.iterdir()}, {racing_archive.name})
        self.assertEqual(racing_archive.read_bytes(), truncated_bytes)

    def test_metadata_and_license_mismatch_refuse_packaging(self):
        for name, content, message in (
            (".claude-plugin/plugin.json", '{"version":"999.0.0"}', "Plugin version"),
            ("skills/afterparty/SKILL.md", "---\nmetadata:\n  version: \"999.0.0\"\n---\n", "Skill version"),
            ("skills/afterparty/LICENSE", "different license", "licenses differ"),
        ):
            with self.subTest(name=name):
                path = self.source / name
                original = path.read_bytes()
                path.write_text(content)
                self.assertIn(message, self.package(expect=1).stderr)
                self.assertFalse(self.output.exists())
                path.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
