"""Disposable inventory, history, discovery and protocol tests; no live cache scans."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
REPO = Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "skills/afterparty/lib"))
import build_inventory as inventory

MEASURABLE = hasattr(os.stat(__file__), "st_blocks")
HISTORY = os.name == "posix" and hasattr(os, "O_NOFOLLOW")


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="afterparty-builds-backend-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.projects = self.base / "project scopes"
        self.projects.mkdir()
        self.state = self.base / "private history"
        self.state.mkdir(mode=0o700)
        self.git_binary = shutil.which("git")
        self.repository = self.make_repo(self.projects / "first project")
        self.output = self.artifact(self.repository / ".next", 8192)

    def git(self, root, *args):
        result = subprocess.run([self.git_binary, "-C", str(root), *args], capture_output=True,
                                env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1"))
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        return result

    def make_repo(self, path):
        path.mkdir(parents=True)
        self.git(path, "init", "-q")
        (path / "tracked.txt").write_text("preserved tracked contents\n")
        self.git(path, "add", "tracked.txt")
        self.git(path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        return path

    def artifact(self, path, size=8192):
        path.mkdir(parents=True)
        (path / "data").write_bytes(b"a" * size)
        return path

    def collect(self, roots=None, max_depth=6):
        return inventory.collect([str(root) for root in (roots or [self.projects])], max_depth, str(self.state))

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_positive_inventory_is_sorted_read_only_and_uses_no_index_refresh(self):
        second = self.artifact(self.repository / "nested" / ".cache", 1024 * 1024)
        dependency = self.artifact(self.repository / "node_modules" / ".cache", 16384)
        (self.repository / "compile.tsbuildinfo").write_bytes(b"compiler cache")
        index = self.repository / ".git" / "index"
        before = index.read_bytes(), index.stat().st_mtime_ns
        calls, real_run = [], subprocess.run
        def record(command, **kwargs):
            calls.append((command, kwargs["env"].get("GIT_OPTIONAL_LOCKS")))
            return real_run(command, **kwargs)
        with patch.object(inventory.subprocess, "run", side_effect=record):
            report = self.collect()
        self.assertEqual(report["collection_status"], "complete", report)
        self.assertEqual(len(report["items"]), 4)
        self.assertEqual(report["items"][0]["path"], str(second))
        self.assertIn(str(dependency), {item["path"] for item in report["items"]})
        self.assertTrue(all(command[0] == "git" and command[-2:] == ["rev-parse", "--show-toplevel"] and locks == "0" for command, locks in calls))
        self.assertTrue(calls, "Git inspection must run before asserting absence of mutation commands")
        self.assertEqual((index.read_bytes(), index.stat().st_mtime_ns), before)
        self.assertEqual((self.repository / "tracked.txt").read_text(), "preserved tracked contents\n")
        self.assertTrue((self.output / "data").exists())
        self.assertEqual(report["total_bytes"], sum(item["size_bytes"] for item in report["items"]))
        self.assertEqual(report["history_status"], "first")
        self.assertIsNone(report["delta_bytes"])
        self.assertTrue(all(item["delta_bytes"] is None for item in report["items"]))
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in self.state.iterdir()))

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_growth_new_paths_deletion_and_matching_scope_history(self):
        first = self.collect()
        old_size = first["total_bytes"]
        (self.output / "data").write_bytes(b"b" * (1024 * 1024))
        second = self.collect()
        self.assertEqual(second["history_status"], "compared")
        self.assertEqual(second["previous_observed_at"], first["observed_at"])
        self.assertEqual(second["delta_bytes"], second["total_bytes"] - old_size)
        self.assertGreater(second["delta_bytes"], 0)
        self.assertEqual(second["items"][0]["delta_bytes"], second["delta_bytes"])
        extra = self.artifact(self.repository / "dist", 8192)
        third = self.collect()
        self.assertIsNone(next(item for item in third["items"] if item["path"] == str(extra))["delta_bytes"])
        shutil.rmtree(self.output)
        fourth = self.collect()
        self.assertEqual(fourth["delta_bytes"], fourth["total_bytes"] - third["total_bytes"])
        self.assertLess(fourth["delta_bytes"], 0)
        different_scope = self.collect([self.repository])
        self.assertEqual(different_scope["history_status"], "first")
        self.assertIsNone(different_scope["previous_observed_at"])

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_incomplete_measurement_never_replaces_complete_baseline(self):
        first = self.collect()
        saved = next(self.state.glob("inventory-*.json"))
        original = saved.read_bytes()
        real_scandir = os.scandir
        entered = []
        def deny(path):
            if os.fspath(path) == str(self.output):
                entered.append(path)
                raise PermissionError("fixture denied artifact inspection")
            return real_scandir(path)
        with patch.object(inventory.os, "scandir", side_effect=deny):
            incomplete = self.collect()
        self.assertTrue(entered, "The measurement failure must be entered")
        self.assertEqual(incomplete["collection_status"], "incomplete")
        self.assertEqual(incomplete["items"][0]["status"], "unavailable")
        self.assertIsNone(incomplete["items"][0]["size_bytes"])
        self.assertIsNone(incomplete["delta_bytes"])
        self.assertEqual(saved.read_bytes(), original)
        (self.output / "data").write_bytes(b"c" * (1024 * 1024))
        recovered = self.collect()
        self.assertEqual(recovered["previous_observed_at"], first["observed_at"])
        self.assertEqual(recovered["delta_bytes"], recovered["total_bytes"] - first["total_bytes"])

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_corrupt_baseline_is_visible_and_preserved_with_recovery(self):
        self.collect()
        saved = next(self.state.glob("inventory-*.json"))
        saved.write_text('{"schema_version": 1, corrupt\n')
        original = saved.read_bytes()
        report = self.collect()
        self.assertEqual(report["collection_status"], "complete")
        self.assertEqual(report["history_status"], "unavailable")
        self.assertEqual(inventory.exit_status(report), 1)
        self.assertTrue(any(issue["path"] == str(saved) and "Move the listed history snapshot aside" in issue["message"] for issue in report["issues"]))
        self.assertEqual(saved.read_bytes(), original)
        self.assertIsNone(report["delta_bytes"])

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_baseline_semantics_are_validated_beyond_its_digest(self):
        self.collect()
        saved = next(self.state.glob("inventory-*.json"))
        value = json.loads(saved.read_text())
        value["snapshot"]["items"][0]["size_bytes"] = -1
        value["sha256"] = inventory.hashlib.sha256(inventory.encoded(value["snapshot"])).hexdigest()
        saved.write_bytes(inventory.encoded(value))
        report = self.collect()
        self.assertEqual(report["history_status"], "unavailable")
        self.assertTrue(any("measurement is invalid" in issue["message"] for issue in report["issues"]))

    @unittest.skipUnless(MEASURABLE and HISTORY, "Requires allocated-byte and safe history evidence")
    def test_busy_history_does_not_overwrite_state_or_hide_inventory(self):
        self.collect()
        saved = next(self.state.glob("inventory-*.json"))
        before = saved.read_bytes()
        _, _, digest = inventory.load_registry()
        issues = []
        with inventory.History(str(self.state), [str(self.projects)], 6, digest, issues):
            report = self.collect()
        self.assertEqual(report["history_status"], "unavailable")
        self.assertGreater(len(report["items"]), 0)
        self.assertTrue(any("History unavailable" in issue["message"] for issue in report["issues"]))
        self.assertEqual(saved.read_bytes(), before)

    @unittest.skipUnless(os.name == "posix", "Symlink fixtures require POSIX permissions")
    def test_alias_roots_and_overlapping_scopes_have_distinct_output_rows(self):
        alias = self.base / "alias"
        alias.symlink_to(self.projects, target_is_directory=True)
        report = self.collect([self.projects, alias, self.repository])
        self.assertEqual(report["roots"], sorted([str(self.projects), str(self.repository)]))
        self.assertEqual(len(report["repositories"]), 1)
        self.assertEqual([item["path"] for item in report["items"]], [str(self.output)])

    def test_repository_labels_are_the_shortest_distinct_suffix(self):
        other = self.make_repo(self.projects / "nested" / self.repository.name)
        self.artifact(other / "dist")
        report = self.collect()
        labels = {repository["root"]: repository["label"] for repository in report["repositories"]}
        self.assertEqual(len(set(labels.values())), 2)
        self.assertEqual(labels[str(other)], str(Path("nested", self.repository.name)))
        self.assertEqual(labels[str(self.repository)], str(Path(self.projects.name, self.repository.name)))
        self.assertEqual(inventory.repository_labels([str(other)]), {str(other): other.name})

    def test_discovery_depth_is_bounded_and_failures_are_not_empty_success(self):
        deep = self.make_repo(self.projects / "one" / "two" / "deep")
        self.artifact(deep / "dist")
        shallow = self.collect(max_depth=1)
        self.assertEqual({item["repository"] for item in shallow["items"]}, {str(self.repository)})
        deeper = self.collect(max_depth=3)
        self.assertIn(str(deep), {item["repository"] for item in deeper["items"]})
        missing = self.projects / "missing"
        report = self.collect([missing])
        self.assertEqual(report["collection_status"], "incomplete")
        self.assertTrue(any(issue["path"] == str(missing) and "Project root unavailable" in issue["message"] for issue in report["issues"]))

    def test_pruned_and_symlinked_discovery_never_enters_hidden_repositories(self):
        for name in ("node_modules", ".venv", "target", "vendor", ".next", "dist"):
            self.make_repo(self.projects / name / "hidden")
        outside = self.make_repo(self.base / "outside")
        if os.name == "posix":
            (self.projects / "linked repo").symlink_to(outside, target_is_directory=True)
        directories, _, _ = inventory.load_registry()
        issues = []
        discovered = inventory.discover_repositories([str(self.projects)], 6, directories, issues)
        self.assertEqual(discovered, [str(self.repository)])
        self.assertEqual(issues, [])
        direct = self.make_repo(self.base / "build")
        self.assertEqual(inventory.discover_repositories([str(direct)], 6, directories, []), [str(direct)])

    def test_linked_worktrees_are_separate_roots_without_following_outside_scope(self):
        linked = self.projects / "linked worktree"
        external = self.base / "external worktree"
        self.git(self.repository, "worktree", "add", "-qb", "linked", str(linked))
        self.git(self.repository, "worktree", "add", "-qb", "external", str(external))
        self.artifact(linked / ".cache")
        self.artifact(external / "dist")
        report = self.collect()
        self.assertEqual({repository["root"] for repository in report["repositories"]}, {str(self.repository), str(linked)})
        self.assertEqual({item["repository"] for item in report["items"]}, {str(self.repository), str(linked)})
        self.assertTrue((linked / ".git").is_file())

    @unittest.skipUnless(MEASURABLE, "Requires allocated-byte evidence")
    def test_parent_outputs_suppress_descendants_and_symlinks_are_not_followed(self):
        nested = self.output / "dist"
        nested.mkdir()
        (nested / "compile.tsbuildinfo").write_bytes(b"data")
        external = self.base / "outside data"
        external.mkdir()
        (external / "large").write_bytes(b"z" * (1024 * 1024))
        if os.name == "posix":
            (self.output / "external link").symlink_to(external, target_is_directory=True)
        report = self.collect()
        self.assertEqual([item["path"] for item in report["items"]], [str(self.output)])
        self.assertLess(report["total_bytes"], 1024 * 1024)

    @unittest.skipUnless(MEASURABLE, "Requires allocated-byte evidence")
    def test_nested_repository_cannot_be_counted_as_outer_output(self):
        nested = self.make_repo(self.output / "nested repo")
        nested_output = self.artifact(nested / "dist")
        report = self.collect([self.projects, nested])
        outer = next(item for item in report["items"] if item["path"] == str(self.output))
        inner = next(item for item in report["items"] if item["path"] == str(nested_output))
        self.assertIsNone(outer["size_bytes"])
        self.assertEqual(outer["status"], "unavailable")
        self.assertIsInstance(inner["size_bytes"], int)
        self.assertEqual(report["total_bytes"], inner["size_bytes"])
        self.assertTrue(any("repository boundary" in issue["message"] for issue in report["issues"]))

    @unittest.skipUnless(MEASURABLE, "Requires allocated-byte evidence")
    def test_modification_time_is_newest_observed_entry_without_last_use_inference(self):
        deep = self.output / "cache" / "bundle"
        deep.mkdir(parents=True)
        file = deep / "compiled"
        file.write_bytes(b"source")
        old, recent = 1577836800, 1700000000
        for path in (self.output, self.output / "cache", deep, self.output / "data"):
            os.utime(path, (old, old))
        os.utime(file, (recent, recent))
        report = self.collect()
        self.assertEqual(report["items"][0]["modified_at"], inventory.stamp(recent))
        self.assertEqual(self.output.stat().st_mtime, old)
        text = "\n".join(inventory.plain_lines(report))
        self.assertIn("not last use", text)

    def test_git_failure_is_an_incomplete_inventory_with_positive_diagnostic(self):
        with patch.object(inventory.subprocess, "run", side_effect=OSError("fixture git unavailable")) as inspect:
            report = self.collect()
        self.assertTrue(inspect.called)
        self.assertEqual(report["collection_status"], "incomplete")
        self.assertEqual(report["items"], [])
        self.assertTrue(any("fixture git unavailable" in issue["message"] for issue in report["issues"]))

    def test_registry_malformed_entries_refuse_collection(self):
        original = (inventory.LIB / "artifact-kinds.tsv").read_bytes()
        for invalid in (b"directory\t*wildcard\tbuild\n", b"file\t.eslintcache\tcache\n"):
            with self.subTest(invalid=invalid), patch.object(Path, "read_bytes", return_value=original + invalid):
                report = self.collect()
            self.assertEqual(report["collection_status"], "incomplete")
            self.assertTrue(any("Artifact definitions unavailable" in issue["message"] for issue in report["issues"]))
            self.assertEqual(report["items"], [])

    def test_plain_output_escapes_terminal_control_paths_and_ascii_mode(self):
        report = self.collect()
        report["roots"] = ["/project/escape\x1b[31m\tline\n"]
        text = "\n".join(inventory.plain_lines(report, True))
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\t", text)
        self.assertIn("\\x1b[31m\\x09line\\x0a", text)
        self.assertTrue(text.isascii())

    @unittest.skipUnless(os.name == "posix", "POSIX control-character path fixture")
    def test_json_preserves_raw_control_paths_and_plain_remains_safe(self):
        odd = self.make_repo(self.projects / "odd\tproject\n")
        self.artifact(odd / "dist")
        report = self.collect()
        self.assertIn(str(odd), {repository["root"] for repository in report["repositories"]})
        serialized = inventory.encoded(report)
        self.assertIn(b"odd\\tproject\\n", serialized)
        plain = "\n".join(inventory.plain_lines(report))
        self.assertIn("odd\\x09project\\x0a", plain)
        self.assertNotIn("odd\tproject", plain)

    def test_protocol_forbids_marks_and_stale_handoff_but_allows_navigation(self):
        second = self.make_repo(self.projects / "second")
        self.artifact(second / "dist")
        state = inventory.InventoryView(self.collect())
        original = copy.deepcopy(state.report)
        requests = lambda key, generation=1, **kw: {"key": key, "generation": generation, **kw}
        for key in (" ", "s"):
            self.assertIsNone(state.handle(requests(key)))
            self.assertIn("no marks or save action", state.message)
        self.assertIsNone(state.handle(requests("ENTER", 0)))
        self.assertEqual(state.ignored_keys, 1)
        before = state.focus
        state.handle(requests("j", 0))
        self.assertNotEqual(state.focus, before)
        state.handle(requests("ENTER", focus_visible=False))
        self.assertIn("Focused output revealed", state.message)
        self.assertIsNone(state.handle(requests("ENTER", 0)))
        self.assertEqual(state.handle(requests("ENTER")), "review")
        self.assertEqual(state.report, original)
        for key, step in (("i", "inventory_inspect"), ("?", "inventory_help")):
            state.handle(requests(key))
            self.assertEqual(state.step, step)
            self.assertIsNone(state.handle(requests("q")))
            self.assertEqual(state.step, "inventory")
        state.handle(requests("/"))
        for char in "[literal]":
            state.handle(requests(char))
        self.assertEqual(state.visible(), [])
        state.handle(requests("BACKSPACE"))
        self.assertEqual(state.query, "[literal")
        state.handle(requests("ESC"))
        self.assertEqual(state.query, "")
        self.assertEqual(state.handle(requests("q")), "done")

    def test_serve_envelope_and_fresh_handoff_use_exact_focused_repository(self):
        report = self.collect()
        options = type("Options", (), {"projects_root": [str(self.projects)], "max_depth": 6, "state_dir": str(self.state)})()
        output = io.StringIO()
        requests = [{"key": "ENTER", "generation": 0}, {"key": "IGNORED", "generation": 1, "ignored_keys": 3},
                    {"key": "ENTER", "generation": 1}]
        with patch.object(sys, "stdin", io.StringIO("\n".join(map(json.dumps, requests)) + "\n")), contextlib.redirect_stdout(output), \
                patch.object(inventory, "collect", return_value=report):
            self.assertEqual(inventory.serve(options), 0)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[0]["event"], "scan")
        self.assertEqual(events[1]["mode"], "builds")
        self.assertEqual(events[1]["step"], "inventory")
        self.assertEqual(events[-2]["ignored_keys"], 4)
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["review_root"], str(self.repository))
        self.assertIn("No cleanup was run", events[-1]["lines"][0])


if __name__ == "__main__":
    unittest.main()
