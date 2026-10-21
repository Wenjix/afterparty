"""Public CLI, save-boundary and PTY tests; all discovery tools are intercepted."""

import copy
import codecs
import importlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
REPO = Path(sys.argv.pop(1))
BASH = sys.argv.pop(1)
if os.name == "nt" and Path(BASH + ".exe").is_file():
    BASH += ".exe"
sys.path.insert(0, str(REPO / "skills/afterparty/lib"))
import plan_data
from review_data import Review, save_review


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="afterparty-review-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "project space"
        self.root.mkdir()
        self.bundle = self.base / "installed skill"
        shutil.copytree(REPO / "skills/afterparty", self.bundle)
        self.cli = self.bundle / "bin/afterparty"
        self.shim = self.base / "shim"
        self.shim.mkdir()
        if os.name != "nt":
            (self.shim / "bash").symlink_to(Path(BASH).resolve())
        self.log = self.base / "calls"
        self.log.touch()
        self.env = dict(os.environ, PATH=str(self.shim) + os.pathsep + os.environ["PATH"],
                        HOME=str(self.base / "home"), XDG_CACHE_HOME=str(self.base / "state"),
                        AFTERPARTY_CODEX_ROOT=str(self.base / "codex"), AFTERPARTY_TRANSCRIPT_ROOT=str(self.base / "projects"),
                        AFTERPARTY_STYLE="never", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1", PYTHONIOENCODING="utf-8", TERM="xterm-256color",
                        REVIEW_FIXTURE=self.root.as_posix(), REVIEW_CALLS=str(self.log))
        Path(self.env["HOME"]).mkdir()
        self.git("init", "-q")
        (self.root / ".gitignore").write_text(".next/\n.cache/\ndist/\n", encoding="utf-8")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        for name in (".next", ".cache", "日本語 'quoted' $(no-command)/dist"):
            target = self.root / name
            target.mkdir(parents=True)
            (target / "data").write_text("generated\n")
        # A real tracked artifact exercises withheld rows, not a fake status.
        (self.root / "tracked/dist").mkdir(parents=True)
        (self.root / "tracked/dist/keep").write_text("tracked\n")
        self.git("add", "-f", "tracked/dist/keep")
        project = Path(self.env["AFTERPARTY_TRANSCRIPT_ROOT"]) / "fixture"
        project.mkdir(parents=True)
        self.transcript = project / "session.jsonl"
        self.transcript.write_text(json.dumps({"cwd": self.root.as_posix()}) + "\n")
        old = time.time() - 86400 * 30
        os.utime(self.transcript, (old, old))
        self.tool("ps", '''case "$*" in
  *pid,pgid,%cpu,command*) printf '9001 9001 0.1 npm run dev --token secret-fixture\n9002 9002 90.0 vitest --watch\n' ;;
  *pgid=,lstart=,command=*) printf '9001 Tue Aug 18 09:00:00 2026 npm run dev --token secret-fixture\n' ;;
  *pgid=,command=*) printf '9001 npm run dev --token secret-fixture\n9002 vitest --watch\n' ;;
  *) exit 1 ;;
esac''')
        self.tool("lsof", r'''REVIEW_PHYSICAL="$(cd "$REVIEW_FIXTURE" && pwd -P)"
case "$*" in
  *-d\ cwd*) printf 'p9001\nfcwd\nn%s\np9002\nfcwd\nn%s\n' "$REVIEW_PHYSICAL" "$REVIEW_PHYSICAL" ;;
  *LISTEN*) printf 'p9001\nn*:3000\n' ;;
  *) exit 1 ;;
esac''')
        for tool in ("kill", "pgrep", "launchctl", "pnpm"):
            self.tool(tool, "echo 'unexpected mutation tool' >&2\nexit 97")
        bash_env = self.base / "bash-env"
        bash_env.write_text('kill() { printf "UNEXPECTED kill %s\\n" "$*" >> "$REVIEW_CALLS"; return 97; }\n')
        self.env["BASH_ENV"] = str(bash_env)

    def tool(self, name, body):
        target = self.shim / name
        target.write_text('#!/usr/bin/env bash\nprintf "%s %s\\n" "' + name + '" "$*" >> "$REVIEW_CALLS"\n' + body + "\n")
        target.chmod(0o755)

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def cli_run(self, *args, env=None):
        return subprocess.run([BASH, str(self.cli), *args], cwd=self.root, env=env or self.env, capture_output=True)

    def snapshot(self, *args, status=0):
        result = self.cli_run("plan", "--json", "--root", str(self.root), *args)
        self.assertEqual(result.returncode, status, result.stderr.decode() + result.stdout.decode())
        return plan_data.load_snapshot(result.stdout)

    def items(self, rows):
        return [row for row in rows if row["section"] == "plan_item"]

    def selection(self, rows, ids):
        return {"snapshot_id": rows[0]["snapshot_id"], "mark_count": len(ids), "marked_ids": ids}

    def resign(self, rows):
        rows[-1]["snapshot_sha256"] = plan_data.digest(plan_data.encoded(rows[:-1]))
        return b"\n".join(plan_data.encoded(row) for row in rows) + b"\n"

    def assert_no_mutation_tools(self):
        self.assertNotRegex(self.log.read_text(), r"(?m)^(UNEXPECTED|kill|pgrep|launchctl|pnpm)\b")
        self.assertTrue((self.root / ".next/data").is_file())

    def test_one_capture_markdown_identity_and_no_second_collection(self):
        plain = self.cli_run("plan", "--root", str(self.root))
        self.assertEqual(plain.returncode, 0, plain.stderr)
        plain_calls = self.log.read_text().splitlines()
        self.log.write_text("")
        rows = self.snapshot()
        json_calls = self.log.read_text().splitlines()
        scrub = lambda text: re.sub(r"# afterparty plan — .*", "# afterparty plan — TIME", text)
        self.assertEqual(scrub(plain.stdout.decode()), scrub(rows[-2]["text"]))
        self.assertEqual(plain_calls, json_calls)
        items = self.items(rows)
        process = next(item for item in items if item["target"] == "9001")
        self.assertEqual(process["availability"], "available")
        self.assertEqual(process["evidence"]["ports"], [3000])
        self.assertIn("claude-transcript", process["evidence"]["activity"]["sources"])
        self.assertNotIn("secret-fixture", json.dumps(rows))
        self.assertIn("[REDACTED]", json.dumps(rows))
        self.assertTrue(all(item["selected"] is False for item in items))
        self.assertTrue(any("日本語" in item["target"] for item in items))
        before = self.log.read_text()
        state = Review(rows)
        state.handle("d")
        state.handle("DOWN")
        self.assertEqual(before, self.log.read_text())
        self.assert_no_mutation_tools()

    def test_incomplete_index_withholds_processes_and_preserves_filesystem_choices(self):
        self.transcript.write_text("{corrupt\n")
        rows = self.snapshot(status=1)
        self.assertEqual(rows[0]["collection_status"], "incomplete")
        self.assertTrue(any(row.get("name") == "activity" and row["status"] == "unavailable" for row in rows))
        processes = [item for item in self.items(rows) if item["type"] == "process-group"]
        self.assertTrue(processes)
        self.assertTrue(all(item["availability"] == "withheld" for item in processes))
        artifacts = [item for item in self.items(rows) if item["type"] == "artifact" and item["availability"] == "available"]
        self.assertGreater(len(artifacts), 0)
        save_review(rows, self.selection(rows, [artifacts[0]["item_id"]]), self.base / "independent.md")
        self.assert_no_mutation_tools()

    def test_invalid_member_cpu_withholds_the_entire_group(self):
        control = next(item for item in self.items(self.snapshot()) if item["target"] == "9001")
        self.assertEqual((control["availability"], control["evidence"]["cpu_max"]), ("available", 0.1))
        ps = self.shim / "ps"
        original = ps.read_text()
        lsof = self.shim / "lsof"
        lsof.write_text(lsof.read_text().replace("p9002\\nfcwd", "p9003\\nfcwd\\nn%s\\np9002\\nfcwd").replace(
            '"$REVIEW_PHYSICAL" "$REVIEW_PHYSICAL"', '"$REVIEW_PHYSICAL" "$REVIEW_PHYSICAL" "$REVIEW_PHYSICAL"'))
        for invalid in ("unavailable", "-1", "NaN", "9" * 400, ""):
            with self.subTest(cpu=invalid):
                ps.write_text(original.replace("9001 9001 0.1 npm run dev --token secret-fixture\n",
                    "9001 9001 0.1 npm run dev --token secret-fixture\n9003 9001 " + invalid + " npm run dev\n"))
                rows = self.snapshot(status=1)
                item = next(item for item in self.items(rows) if item["target"] == "9001")
                self.assertEqual((item["availability"], item["reason_code"]), ("withheld", "cpu-unavailable"))
                self.assertIsNone(item["evidence"]["cpu_max"])
                self.assertEqual([member["pid"] for member in item["evidence"]["members"]], [9001, 9003])
                self.assertTrue(any(row.get("name") == "processes" and row["status"] == "unavailable" for row in rows))
                self.assert_no_mutation_tools()

    def test_save_exact_checked_bytes_and_preserve_existing_file(self):
        rows = self.snapshot()
        chosen = [item for item in self.items(rows) if item["availability"] == "available"]
        selection = self.selection(rows, [item["item_id"] for item in chosen])
        destination = self.base / "reviewed plan 'quoted'.md"
        save_review(rows, selection, destination)
        expected = rows[-2]["text"].split("\n")
        for item in chosen:
            line = item["markdown"]["header_line"] - 1
            expected[line] = expected[line][:3] + "x" + expected[line][4:]
        self.assertEqual(destination.read_bytes(), "\n".join(expected).encode())
        if os.name != "nt":
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        original = destination.read_bytes()
        with self.assertRaisesRegex(ValueError, "output-exists"):
            save_review(rows, selection, destination)
        self.assertEqual(destination.read_bytes(), original)
        self.assert_no_mutation_tools()

    def test_explicit_marks_guard(self):
        rows = self.snapshot()
        selection = self.selection(rows, [])
        selection["focused_item_id"] = next(i["item_id"] for i in self.items(rows) if i["availability"] == "available")
        destination = self.base / "focus-only.md"
        with self.assertRaisesRegex(ValueError, "explicit-marks-required"):
            save_review(rows, selection, destination)
        self.assertFalse(destination.exists())

    def test_enter_advances_only_explicit_choices(self):
        state = Review(self.snapshot())
        focused = state.focus
        state.handle("ENTER")
        self.assertEqual(state.step, "choose")
        self.assertIn("explicit-marks-required", state.message)
        self.assertEqual(state.marked, set())
        state.handle("i")
        self.assertEqual(state.step, "evidence")
        self.assertEqual(state.focus, focused)
        state.handle("ENTER")
        self.assertEqual(state.step, "evidence")
        self.assertIn("explicit-marks-required", state.message)
        state.handle(" ")
        state.handle("ENTER")
        self.assertEqual(state.step, "review")
        state.handle("ESC")
        self.assertEqual(state.step, "choose")
        self.assertEqual(state.marked, {focused})
        state.handle("ENTER")
        self.assertEqual(state.step, "review")
        state.handle("ENTER")
        self.assertEqual(state.step, "save")
        self.assertEqual(state.handle("ENTER"), "save")
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_enter_finishes_withheld_review_without_a_plan(self):
        self.git("add", "-f", ".")
        for incomplete in (False, True):
            with self.subTest(incomplete=incomplete):
                if incomplete:
                    self.tool("lsof", 'echo "fixture occupancy unavailable" >&2; exit 1')
                terminal = TerminalHarness(self, arguments=("--artifacts-only",))
                terminal.expect("0 available")
                terminal.expect("Enter Finish review")
                self.assertFalse(terminal.destination.exists())
                os.write(terminal.master, b"\r")
                terminal.finish(1 if incomplete else 0)
                self.assertIn(b"The review finished. Afterparty did not save a plan.", terminal.transcript)
                self.assertIn(b"The scan found no available targets", terminal.transcript)
                if incomplete:
                    self.assertIn(b"The scan is incomplete. Run afterparty review again to retry the unavailable checks.", terminal.transcript)
                self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_public_save_preserves_unicode_separator_path(self):
        target = self.root / "separators \u2028 \u0085 \v/dist"
        target.mkdir(parents=True)
        (target / "data").write_text("generated\n")
        terminal = TerminalHarness(self, arguments=("--artifacts-only",))
        terminal.expect("0 marked")
        terminal.press(b"/separators\r", "/ separators")
        terminal.press(b" ", "1 marked")
        terminal.press(b"s", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        terminal.press(b"\r", "Afterparty saved the plan.")
        saved = terminal.destination.read_bytes()
        self.assertIn(("- [x] artifact path " + target.as_posix() + "\n").encode(), saved)
        self.assertEqual(saved.count(b"- [x]"), 1)
        os.write(terminal.master, b"q")
        terminal.finish(0)
        self.assert_no_mutation_tools()

    def test_process_evidence_preserves_unicode_separator_command(self):
        extra = "separators \u2028 \u0085 \v end"
        shim = self.shim / "ps"
        shim.write_text(shim.read_text().replace("npm run dev --token secret-fixture", "npm run dev " + extra))
        rows = self.snapshot()
        process = next(item for item in self.items(rows) if item["target"] == "9001")
        self.assertEqual(process["availability"], "available")
        self.assertEqual(process["evidence"]["members"], [{"pid": 9001, "command": "npm run dev " + extra}])
        destination = self.base / "unicode-command.md"
        save_review(rows, self.selection(rows, [process["item_id"]]), destination)
        self.assertIn(("member 9001: npm run dev " + extra).encode(), destination.read_bytes())
        self.assert_no_mutation_tools()

    def test_withheld_guard(self):
        rows = self.snapshot()
        withheld = next(item for item in self.items(rows) if item["reason_code"] == "tracked")
        destination = self.base / "withheld.md"
        with self.assertRaisesRegex(ValueError, "withheld-mark: " + withheld["item_id"]):
            save_review(rows, self.selection(rows, [withheld["item_id"]]), destination)
        self.assertFalse(destination.exists())

    def test_selection_binding_and_count_guards(self):
        rows = self.snapshot()
        selected = next(i for i in self.items(rows) if i["availability"] == "available")
        for field, value, reason in (("snapshot_id", "0" * 32, "selection-snapshot-mismatch"),
                                     ("mark_count", 2, "mark-count-mismatch")):
            selection = self.selection(rows, [selected["item_id"]])
            selection[field] = value
            destination = self.base / (field + ".md")
            with self.assertRaisesRegex(ValueError, reason):
                save_review(rows, selection, destination)
            self.assertFalse(destination.exists())

    def test_parsed_metadata_must_match_reviewed_target(self):
        rows = self.snapshot()
        selected = next(i for i in self.items(rows) if i["availability"] == "available")
        # Keep the document and all digests valid, but change only the actual
        # metadata consumed by apply. Rejection must reach the parser comparison.
        lines = rows[-2]["text"].split("\n")
        line = selected["markdown"]["header_line"]
        lines[line] = lines[line].replace(selected["fingerprint"], "deadbeef")
        rows[-2]["text"] = "\n".join(lines)
        rows[-2]["sha256"] = plan_data.digest(rows[-2]["text"].encode())
        self.resign(rows)
        plan_data.validate(rows)
        destination = self.base / "mismatched-metadata.md"
        with self.assertRaisesRegex(ValueError, "checked-target-mismatch"):
            save_review(rows, self.selection(rows, [selected["item_id"]]), destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.base.glob(".afterparty-plan-*")), [])

    def test_snapshot_mapping_guard(self):
        rows = self.snapshot()
        rows[-2]["text"] += "Unreviewed extra text.\n"
        self.resign(rows)
        with self.assertRaisesRegex(ValueError, "document-digest-mismatch"):
            save_review(rows, self.selection(rows, [self.items(rows)[0]["item_id"]]), self.base / "changed.md")

    def test_incomplete_stream_guard(self):
        rows = self.snapshot()
        with self.assertRaisesRegex(ValueError, "stream-incomplete"):
            plan_data.load_snapshot(b"\n".join(plan_data.encoded(row) for row in rows[:-1]))

    def test_snapshot_corruption_matrix(self):
        original = self.snapshot()
        for mode, reason in (("field", "duplicate-field"), ("item", "duplicate-item"),
                             ("snapshot", "snapshot-id-mismatch"), ("digest", "snapshot-digest-mismatch"),
                             ("header", "header-digest-mismatch"), ("completion", "duplicate-plan_complete")):
            with self.subTest(mode=mode):
                rows = copy.deepcopy(original)
                if mode == "item":
                    rows.insert(-2, copy.deepcopy(self.items(rows)[0]))
                elif mode == "snapshot":
                    self.items(rows)[0]["snapshot_id"] = "0" * 32
                elif mode == "header":
                    self.items(rows)[0]["markdown"]["header_sha256"] = "0" * 64
                elif mode == "completion":
                    rows.insert(-2, copy.deepcopy(rows[-1]))
                raw = self.resign(rows)
                if mode == "field":
                    raw = raw.replace(b'{', b'{"schema_version":1,', 1)
                elif mode == "digest":
                    raw = raw.replace(rows[-1]["snapshot_sha256"].encode(), b"0" * 64)
                with self.assertRaisesRegex(ValueError, reason):
                    plan_data.load_snapshot(raw)

    def test_bad_schema_ids_mapping_and_marks(self):
        rows = self.snapshot()
        for mode, expected in (("schema", "unsupported-schema"), ("id", "item-id-mismatch"), ("mapping", "invalid-checkbox")):
            changed = copy.deepcopy(rows)
            item = self.items(changed)[0]
            if mode == "schema":
                item["schema_version"] = 999
            elif mode == "id":
                item["item_id"] = "wrong"
            else:
                item["markdown"]["checkbox_column"] = 5
            with self.assertRaisesRegex(ValueError, expected):
                plan_data.load_snapshot(self.resign(changed))
        ident = self.items(rows)[0]["item_id"]
        for ids, expected in (([ident, ident], "duplicate-marks"), (["missing"], "unknown-mark")):
            with self.assertRaisesRegex(ValueError, expected):
                save_review(rows, self.selection(rows, ids), self.base / "bad.md")

    def test_density_guard(self):
        rows = self.snapshot()
        state = Review(rows)
        state.handle(" ")
        state.handle("DOWN")
        for step in ("choose", "review", "save", "saved"):
            state.step = step
            state.query = "9002"
            before = (state.rows, state.focus, set(state.marked), state.step, state.query, state.return_step)
            state.handle("d")
            self.assertTrue(state.expanded)
            self.assertEqual(before, (state.rows, state.focus, state.marked, state.step, state.query, state.return_step))
            self.assertIn("Details are visible", state.message)
            state.handle("d")
            self.assertFalse(state.expanded)
        state.step = "evidence"
        before = (state.rows, state.focus, set(state.marked), state.step, state.query, state.message)
        state.handle("d")
        self.assertFalse(state.expanded)
        self.assertEqual(before, (state.rows, state.focus, state.marked, state.step, state.query, state.message))
        self.assertNotIn("d", {entry["key"] for entry in state.help_keys()})
        state.step = "choose"
        state.handle("/")
        for key in "dsq":
            state.handle(key)
        self.assertEqual(state.query, "9002dsq")
        self.assertFalse(state.expanded)
        state.handle("ESC")
        self.assertEqual(state.query, "9002")
        self.assert_no_mutation_tools()

    def test_refresh_guard(self):
        rows = self.snapshot()
        state = Review(rows)
        state.handle(" ")
        self.assertEqual(len(state.marked), 1)
        state.handle("i")
        self.assertEqual(state.step, "evidence")
        state.handle("ESC")
        self.assertEqual(len(state.marked), 1)
        self.assertIsNone(state.handle("r"))
        self.assertEqual(state.step, "confirm_refresh")
        self.assertEqual(len(state.marked), 1, "confirmation must retain reviewed choices")
        self.assertEqual(state.handle("ENTER"), "refresh")
        self.assertIn("marks-cleared", state.message)
        self.assertEqual(state.marked, set())
        self.assertFalse(state.save_enabled)
        state.finish_refresh(rows)
        state.handle("s")
        self.assertIn("explicit-marks-required", state.message)
        self.assertEqual(state.marked, set())

    def test_refresh_filter_focus_guard(self):
        rows = self.snapshot()
        state = Review(rows)
        hidden_id = state.focus
        state.handle("/")
        for key in ".next":
            state.handle(key)
        state.handle("ENTER")
        visible_id = state.visible()[0]["item_id"]
        self.assertNotEqual(visible_id, hidden_id)
        self.assertEqual(state.handle("r"), "refresh")
        state.finish_refresh(rows)
        self.assertEqual(state.query, ".next")
        self.assertEqual(state.focus, visible_id)
        state.handle(" ")
        self.assertEqual(state.marked, {visible_id})
        state.focus = hidden_id
        state.handle(" ")
        self.assertIn("No target has focus", state.message)
        self.assertEqual(state.marked, {visible_id})
        state.query = "no-matching-target"
        state.begin_refresh()
        state.finish_refresh(rows)
        self.assertIsNone(state.focus)
        state.handle(" ")
        self.assertEqual(state.marked, set())

    def test_help_and_fallback_never_save_or_launch(self):
        destination = self.base / "fallback.md"
        help_result = self.cli_run("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn(b"afterparty review", help_result.stdout)
        self.assertNotIn(b"agent-hygiene.sh", help_result.stdout)
        self.assertEqual(self.log.read_text(), "")
        result = self.cli_run("review", "--artifacts-only", "--output", str(destination))
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Afterparty did not save a plan", result.stderr)
        self.assertIn(b"## Artifacts", result.stdout)
        self.assertNotIn(b"## Process groups", result.stdout)
        self.assertFalse(destination.exists())
        self.assertNotIn(b"\x1b", result.stdout)
        for option in ("--kill", "--apply", "--json"):
            result = self.cli_run("review", option)
            self.assertEqual(result.returncode, 2)
            self.assertIn(option.encode(), result.stderr)
        self.assert_no_mutation_tools()

    def test_existing_output_is_refused_before_any_collection(self):
        destination = self.base / "already reviewed.md"
        destination.write_text("unrelated existing plan\n")
        for path in (destination, self.base / "dangling.md"):
            if path != destination:
                if os.name == "nt":
                    continue
                path.symlink_to(self.base / "missing.md")
            with self.subTest(path=path):
                self.log.write_text("")
                result = self.cli_run("review", "--output", str(path))
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"--output already exists", result.stderr)
                self.assertIn(b"Choose another --output path", result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(self.log.read_text(), "", "refusal must precede collector entry")
                self.assertEqual(destination.read_text(), "unrelated existing plan\n")

    def test_command_quoting_preserves_exact_paths(self):
        import review
        for path in (r"/repo/\literal 'quoted'/plan.md", "/repo/\x1b\u202e '日本語' $(no-command)\\plan.md"):
            quoted = review.shell_word(path)
            self.assertNotIn("\x1b", quoted)
            self.assertNotIn("\u202e", quoted)
            result = subprocess.run([BASH, "-c", "printf '%s' " + quoted], env=self.env, capture_output=True, check=True)
            self.assertEqual(result.stdout, path.encode("utf-8"))

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_public_terminal_flow_and_restoration(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        scans = self.log.read_text()
        terminal.press(b"i", "Inspect")
        self.assertFalse(terminal.destination.exists())
        terminal.press(b"\x1b", "Space mark")
        terminal.press(b" ", "1 marked")
        terminal.press(b"d", "Details are visible")
        terminal.press(b"/.next\r", "Target 1 of 1")
        terminal.press(b" ", "2 marked")
        terminal.press(b"d", "Details are hidden")
        self.assertEqual(scans, self.log.read_text())
        terminal.press(b"\r", "Enter Continue to Save plan")
        terminal.press(b"d", "Details are visible")
        terminal.press(b"\x1b", "Space mark")
        terminal.press(b"\r", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        terminal.press(b"\x1b", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        self.assertFalse(terminal.destination.exists())
        terminal.press(b"\r", "Afterparty saved the plan.")
        saved = terminal.destination.read_bytes()
        parser = self.bundle / "lib/plan-format.sh"
        parsed = subprocess.run([BASH, "-c", '. "$1"; plan_read_checked "$2"', "fixture",
                                 str(parser), str(terminal.destination)], env=self.env, capture_output=True, check=True)
        targets = {tuple(line.split("\t")[:2]) for line in parsed.stdout.decode().splitlines()}
        self.assertEqual(targets, {("process-group", "9001"), ("artifact", (self.root / ".next").as_posix())})
        terminal.press(b"d", "Details are visible")
        self.assertEqual(terminal.destination.read_bytes(), saved)
        self.assertEqual(scans, self.log.read_text())
        os.write(terminal.master, b"q")
        terminal.finish(0)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_finished_command_preserves_exact_destination(self):
        self.env["TERM"] = "screen"
        destination = self.base / ("long " * 18 + "'quoted' $(no-command)\\plan.md")
        terminal = TerminalHarness(self, destination=destination)
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        terminal.press(b"s", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        terminal.press(b"\r", "Afterparty saved the plan.")
        terminal.expect("Finish the review to print the apply command.")
        self.assertNotIn(b"Apply the plan with this command:", terminal.transcript)
        saved = destination.read_bytes()
        os.write(terminal.master, b"\r")
        terminal.finish(0)
        output = bytes(terminal.transcript)
        command = [line for line in output.split(b"\x1b[?1049l", 1)[1].splitlines() if b" apply " in line]
        self.assertEqual(len(command), 1)
        self.assertGreater(output.index(command[0]), output.index(b"\x1b[?1049l"))
        self.assertRegex(output.split(b"\x1b[?1049l", 1)[1], rb"\r\r?\nPlan saved:")
        parsed = shlex.split(command[0].decode())
        self.assertEqual(parsed[1:], ["apply", str(destination)])
        self.assertEqual(parsed[0], "afterparty" if shutil.which("afterparty", path=self.env["PATH"]) else str(self.cli.resolve()))
        self.assertIn(b"Marked targets:", output)
        self.assertEqual(destination.read_bytes(), saved)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_finish_after_save_and_shrink_succeeds(self):
        for finish in (b"q", b"\r"):
            with self.subTest(finish=finish):
                terminal = TerminalHarness(self, destination=self.base / (finish.hex() + ".md"))
                terminal.expect("0 marked")
                terminal.press(b" ", "1 marked")
                terminal.press(b"s", "Enter Continue to Save plan")
                terminal.press(b"\r", "Enter Save plan")
                terminal.press(b"\r", "Afterparty saved the plan.")
                saved = terminal.destination.read_bytes()
                terminal.resize(59, 19)
                terminal.expect("Afterparty saved the plan. Press Enter or q to finish.")
                os.write(terminal.master, finish)
                terminal.finish(0)
                output = bytes(terminal.transcript).split(b"\x1b[?1049l", 1)[1]
                self.assertIn(b"Plan saved: " + str(terminal.destination).encode(), output)
                commands = [shlex.split(line.decode()) for line in output.splitlines() if b" apply " in line]
                self.assertEqual(len(commands), 1)
                self.assertEqual(commands[0][1:], ["apply", str(terminal.destination)])
                self.assertEqual(terminal.destination.read_bytes(), saved)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_small_panes_open_and_resume_after_resize(self):
        for columns, rows in ((59, 24), (80, 19)):
            terminal = TerminalHarness(self, columns, rows, arguments=("--artifacts-only",))
            terminal.expect("prefix z")
            terminal.expect("Resize to continue")
            self.assertFalse(terminal.destination.exists())
            terminal.resize(80, 24)
            terminal.expect("Scan: complete")
            terminal.expect("0 marked")
            os.write(terminal.master, b"q")
            terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_terminal_runtime_fallback(self):
        self.tool("python3", 'if [ "${1:-}" = -c ] && [[ "${2:-}" == *termios.tcgetattr* ]]; then exit 1; fi\nexec ' + shlex.quote(sys.executable) + ' "$@"')
        terminal = TerminalHarness(self, arguments=("--artifacts-only",))
        output = terminal.expect("review-exit:1", complete_line=True)
        self.assertIn(b"Terminal input is unavailable", output)
        self.assertIn(b"## Artifacts", output)
        self.assertFalse(terminal.destination.exists())
        terminal.buffer.extend(output)
        terminal.finish(1)
        (self.shim / "python3").unlink()
        with Path(self.env["BASH_ENV"]).open("a") as stream:
            stream.write('command() { if [ "$*" = "-v python3" ]; then return 1; fi; builtin command "$@"; }\n')
        terminal = TerminalHarness(self, arguments=("--artifacts-only",))
        output = terminal.expect("review-exit:1", complete_line=True)
        self.assertIn(b"Python 3 is unavailable", output)
        self.assertIn(b"## Artifacts", output)
        self.assertNotIn(b"## Process groups", output)
        self.assertNotIn(b"\x1b[?1049h", output)
        self.assertFalse(terminal.destination.exists())
        terminal.buffer.extend(output)
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_missing_framework_helper_uses_read_only_fallback(self):
        (self.bundle / "bin/afterparty-review").unlink()
        terminal = TerminalHarness(self, arguments=("--artifacts-only",))
        result = terminal.expect("review-exit:1", complete_line=True)
        self.assertIn(b"Bubble Tea helper is unavailable", result)
        self.assertIn(b"## Artifacts", result)
        self.assertNotIn(b"\x1b[?1049h", result)
        self.assertFalse(terminal.destination.exists())
        terminal.buffer.extend(result)
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_cancel_search_after_shrinking_restores_terminal(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b"/a", "Enter finish filter")
        terminal.resize(59, 19)
        terminal.expect("Press q to quit")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assertIn(b"You canceled the review. Afterparty did not save a plan.", terminal.transcript)
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_cancel_with_marks_never_publishes(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        terminal.press(b"s", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        terminal.press(b"q", "Confirm cancel")
        self.assertFalse(terminal.destination.exists())
        terminal.expect("1 marked")
        terminal.press(b"\x1b", "Enter Save plan")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"\r")
        terminal.finish(1)
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_failed_save_preserves_choices_for_retry(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.destination.write_text("unrelated fixture\n")
        terminal.press(b" ", "1 marked")
        terminal.press(b"s", "Enter Continue to Save plan")
        terminal.press(b"\r", "Enter Save plan")
        output = terminal.press(b"\r", "The output file already exists")
        self.assertIn(b"1 marked", output)
        self.assertEqual(terminal.destination.read_text(), "unrelated fixture\n")
        terminal.destination.unlink()
        terminal.press(b"\r", "Afterparty saved the plan.")
        saved = terminal.destination.read_text()
        self.assertEqual(len(re.findall(r"(?m)^- \[x\]", saved)), 1)
        self.assertRegex(saved, r"(?m)^- \[x\].* pgid 9001 ")
        os.write(terminal.master, b"q")
        terminal.finish(0)
        self.assert_no_mutation_tools()

    def gate_collection(self):
        plan = self.bundle / "lib/plan.sh"
        original = plan.read_text()
        entered, release = self.base / "collection-entered", self.base / "collection-release"
        plan.write_text("#!/usr/bin/env bash\n: > " + shlex.quote(str(entered))
                        + "\nwhile [ ! -f " + shlex.quote(str(release)) + " ]; do sleep 0.05; done\n" + original)
        return entered, release

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_keys_during_initial_collection_are_ignored(self):
        entered, release = self.gate_collection()
        terminal = TerminalHarness(self)
        terminal.expect("Afterparty scans for cleanup targets.")
        until = time.monotonic() + 5
        while not entered.exists() and time.monotonic() < until:
            time.sleep(0.02)
        self.assertTrue(entered.exists(), "fixture must enter the blocked collector")
        os.write(terminal.master, b" s\r")
        # Let the terminal consume the burst before the snapshot is released.
        time.sleep(0.2)
        release.touch()
        terminal.expect("Afterparty ignored 3 keys")
        terminal.expect("0 marked")
        self.assertFalse(terminal.destination.exists())
        terminal.press(b" ", "1 marked")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_keys_during_refresh_are_ignored(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        entered, release = self.gate_collection()
        terminal.press(b"r", "Confirm refresh")
        terminal.press(b"\r", "Afterparty scans for cleanup targets again.")
        until = time.monotonic() + 5
        while not entered.exists() and time.monotonic() < until:
            time.sleep(0.02)
        self.assertTrue(entered.exists(), "refresh must enter the blocked collector")
        os.write(terminal.master, b" s\r")
        time.sleep(0.2)
        release.touch()
        terminal.expect("Afterparty ignored 3 keys")
        terminal.expect("0 marked")
        self.assertFalse(terminal.destination.exists())
        terminal.press(b" ", "1 marked")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_page_down_then_space_reveals_before_marking(self):
        for number in range(20):
            target = self.root / f"generated/{number:02}/dist"
            target.mkdir(parents=True)
            (target / "data").write_text("generated\n")
        terminal = TerminalHarness(self, 60, 20)
        terminal.expect("0 marked")
        terminal.press(b"\x1b[6~", "Target 1 of")
        terminal.press(b" ", "The target is visible")
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_escape_followed_by_key_is_preserved(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b"i", "Inspect")
        terminal.press(b"\x1b ", "1 marked")
        terminal.expect("Choose")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "job control requires POSIX terminals")
    def test_ctrl_z_suspends_and_resumes_with_marks(self):
        import termios
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        os.write(terminal.master, b"\x1a")
        terminal.expect("\x1b[?1049l")
        until = time.monotonic() + 5
        while time.monotonic() < until:
            state = subprocess.run([shutil.which("ps"), "-o", "state=", "-p", str(terminal.cli_pid)],
                                   capture_output=True, text=True, check=True).stdout.strip()
            if "T" in state:
                break
            time.sleep(0.02)
        self.assertIn("T", state, "Ctrl+Z must stop the owned reviewer process")
        settings = termios.tcgetattr(terminal.slave)
        self.assertTrue(settings[3] & termios.ICANON, "suspension must restore canonical input")
        self.assertTrue(settings[3] & termios.ECHO, "suspension must restore terminal echo")
        self.assertFalse(terminal.destination.exists())
        revision = terminal.revision
        os.kill(terminal.cli_pid, signal.SIGCONT)
        terminal.expect("1 marked", after_revision=revision)
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_copied_rows_do_not_emit_hard_tabs(self):
        terminal = TerminalHarness(self)
        terminal.expect("PGID 9001")
        terminal.press(b" ", "1 marked")
        terminal.press(b"d", "Details are visible")
        terminal.press(b"i", "Inspect")
        terminal.expect("Member 9001:")
        terminal.press(b"q", "Choose")
        terminal.press(b"q", "Confirm cancel")
        os.write(terminal.master, b"q")
        terminal.finish(1)
        self.assertNotIn(b"\t", terminal.transcript, "renderer cursor optimization must preserve copyable spaces")
        self.assert_no_mutation_tools()

    def test_worktree_snapshot_and_stable_ids(self):
        worktree = self.base / "worktree space"
        self.git("worktree", "add", "-qb", "fixture-branch", str(worktree))
        rows = self.snapshot()
        item = next(i for i in self.items(rows) if i["type"] == "worktree" and i["target"].endswith("/worktree space"))
        self.assertEqual(item["evidence"]["branch"], "fixture-branch")
        self.assertIn("worktree space", item["target"])
        again = next(i for i in self.items(self.snapshot()) if i["item_id"] == item["item_id"])
        self.assertEqual(item["item_id"], again["item_id"])
        self.assertEqual(item["fingerprint"], again["fingerprint"])
        birth = subprocess.run([BASH, "-c", 'LC_ALL=C TZ=UTC0 stat -c "%w" -- "$1" 2>/dev/null || LC_ALL=C TZ=UTC0 stat -f "%.9FB" -- "$1"',
                                "fixture", worktree.as_posix()], env=self.env, capture_output=True)
        stamp = birth.stdout.decode().strip()
        supported = birth.returncode == 0 and stamp not in ("", "-", "?", "0", "-1") and not stamp.startswith(("0.", "-1."))
        if supported:
            self.assertEqual(item["availability"], "available", item)
            save_review(rows, self.selection(rows, [item["item_id"]]), self.base / "worktree.md")
        else:
            self.assertEqual(item["reason_code"], "identity-unavailable")

    def test_missing_python_plain_fallback_and_json_refusal(self):
        bash_env = Path(self.env["BASH_ENV"])
        with bash_env.open("a") as stream:
            stream.write('command() { if [ "$*" = "-v python3" ]; then return 1; fi; builtin command "$@"; }\n')
        result = self.cli_run("plan", "--json")
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"--json requires Python 3", result.stderr)
        self.assertEqual(result.stdout, b"")
        result = self.cli_run("plan")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"Activity: unavailable", result.stdout)
        self.assertIn(b"Afterparty cannot determine the age of recorded agent activity", result.stdout)
        self.assertIn(b"- [ ] artifact path", result.stdout)
        self.assert_no_mutation_tools()

    def test_empty_and_unavailable_are_distinct_under_forced_style(self):
        empty = self.base / "empty repository"
        subprocess.run(["git", "init", "-q", str(empty)], env=self.env, check=True)
        args = ("plan", "--json", "--root", str(empty), "--artifacts-only", "--caches-only", "--all")
        result = self.cli_run(*args, env=dict(self.env, AFTERPARTY_STYLE="always"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b"\x1b", result.stdout)
        rows = plan_data.load_snapshot(result.stdout)
        self.assertEqual(rows[-1]["counts"]["items"], 0)
        self.assertEqual(rows[0]["collection_status"], "complete")
        self.assertEqual(rows[0]["flags"], {"all": True, "artifacts_only": True, "caches_only": True})
        self.tool("lsof", "echo 'fixture cannot inspect occupancy' >&2; exit 2")
        result = self.cli_run(*args)
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = plan_data.load_snapshot(result.stdout)
        self.assertEqual(rows[-1]["counts"]["items"], 0)
        self.assertEqual(rows[0]["collection_status"], "incomplete")
        self.assertTrue(any(r.get("name") == "artifact-occupancy" and r["status"] == "unavailable" for r in rows))

    def test_atomic_no_clobber_publication(self):
        from unittest.mock import patch
        rows = self.snapshot()
        selected = next(i for i in self.items(rows) if i["availability"] == "available")
        destination = self.base / "racing.md"
        real_link = os.link
        entered = []
        def create_then_link(source, target):
            entered.append(target)
            Path(target).write_text("unrelated winner")
            return real_link(source, target)
        with patch("review_data.os.link", side_effect=create_then_link):
            with self.assertRaises(FileExistsError):
                save_review(rows, self.selection(rows, [selected["item_id"]]), destination)
        self.assertEqual(entered, [destination])
        self.assertEqual(destination.read_text(), "unrelated winner")
        self.assertEqual(list(self.base.glob(".afterparty-plan-*")), [])

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_terminal_refresh_resize_paste_and_interrupt(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        terminal.press(b" ", "1 marked")
        scans = self.log.read_text()
        terminal.resize(60, 34)
        terminal.expect("1 marked")
        terminal.press(b"d", "Details are visible")
        terminal.press(b"\x1b[200~ ss\r\r\x1b[201~", "Afterparty ignored the paste")
        self.assertEqual(scans, self.log.read_text())
        self.assertFalse(terminal.destination.exists())
        terminal.press(b"r", "Confirm refresh")
        terminal.press(b"\r", "Mark targets again")
        terminal.press(b"s", "Press Space to mark a target")
        terminal.press(b" ", "1 marked")
        plan = self.bundle / "lib/plan.sh"
        original = plan.read_bytes()
        plan.write_text("#!/usr/bin/env bash\necho 'fixture collection failure' >&2\nexit 2\n")
        terminal.press(b"r", "Confirm refresh")
        terminal.press(b"\r", "Refresh before you save the plan")
        terminal.press(b"?", "Scan status")
        terminal.press(b"\x1b[6~", "fixture collection failure")
        terminal.press(b"q", "Choose")
        terminal.press(b" ", "Refresh before you save the plan")
        terminal.expect("0 marked")
        self.assertFalse(terminal.destination.exists())
        plan.write_bytes(original)
        terminal.press(b"r", "Mark targets again")
        os.kill(terminal.cli_pid, signal.SIGTERM)
        terminal.finish(130)
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "PTY tests require POSIX terminals")
    def test_terminal_quit_restores_settings(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        os.kill(terminal.cli_pid, signal.SIGQUIT)
        terminal.finish(130)
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()

    @unittest.skipIf(os.name == "nt", "owned collector groups require POSIX process groups")
    def test_interrupted_refresh_reaps_collector_group(self):
        terminal = TerminalHarness(self)
        terminal.expect("0 marked")
        child_script = self.base / "collector-child.py"
        child_pid = self.base / "collector-child.pid"
        terminated = self.base / "collector-term"
        child_script.write_text(
            "import os, signal, time\nfrom pathlib import Path\n"
            + "signal.signal(signal.SIGTERM, lambda *_: Path(" + repr(str(terminated)) + ").write_text('received'))\n"
            + "Path(" + repr(str(child_pid)) + ").write_text(str(os.getpid()))\ntime.sleep(30)\n")
        (self.bundle / "lib/plan.sh").write_text(
            "#!/usr/bin/env bash\npython3 " + shlex.quote(str(child_script)) + "\nwait\n")
        terminal.press(b"r", "Afterparty scans for cleanup targets again.")
        until = time.monotonic() + 5
        while not child_pid.exists() and time.monotonic() < until:
            time.sleep(0.05)
        self.assertTrue(child_pid.exists(), "refresh must enter the fixture collector")
        pid = int(child_pid.read_text())
        def stop_owned_child():
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        self.addCleanup(stop_owned_child)
        os.kill(pid, 0)
        os.kill(terminal.cli_pid, signal.SIGTERM)
        terminal.finish(130)
        self.assertTrue(terminated.exists(), "the owned group must receive graceful termination first")
        until = time.monotonic() + 3
        while time.monotonic() < until:
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            time.sleep(0.05)
        else:
            self.fail("collector child survived interruption")
        self.assertFalse(terminal.destination.exists())
        self.assert_no_mutation_tools()


class TerminalHarness:
    def __init__(self, case, columns=80, rows=34, arguments=(), destination=None):
        import pty
        import pyte
        import termios
        class Screen(pyte.Screen):
            # pyte 0.8 omits CSI S/T; Bubble Tea uses these standard scroll-
            # region operations when it moves existing rows during a redraw.
            def scroll_up(self, count=1):
                original = self.cursor.y
                self.cursor.y = self.margins.bottom if self.margins else self.lines - 1
                for _ in range(count or 1):
                    self.index()
                self.cursor.y = original

            def scroll_down(self, count=1):
                original = self.cursor.y
                self.cursor.y = self.margins.top if self.margins else 0
                for _ in range(count or 1):
                    self.reverse_index()
                self.cursor.y = original

            def cursor_forward_tab(self, count=1):
                for _ in range(count or 1):
                    self.tab()

        class Stream(pyte.Stream):
            csi = dict(pyte.Stream.csi, S="scroll_up", T="scroll_down", I="cursor_forward_tab")
            events = pyte.Stream.events | {"scroll_up", "scroll_down", "cursor_forward_tab"}

        self.case = case
        self.master, self.slave = pty.openpty()
        self.screen = Screen(columns, rows)
        self.stream = Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.revision = 0
        case.addCleanup(self.close)
        self.resize(columns, rows)
        self.original = termios.tcgetattr(self.slave)
        self.destination = destination or case.base / "events.md"
        # The wrapper stays alive until settings have been inspected. Capture
        # only this fixture's CLI PID for its intentional interruption test.
        # Use a foreground child: Bash's async jobs inherit SIGQUIT ignored,
        # which would conceal a missing restoration handler in the CLI.
        # Hold it on a separate pipe so the wrapper never reads or changes the
        # terminal before the restoration assertion inspects it.
        release_read, self.release_write = os.pipe()
        command = ('import os, signal, subprocess, sys\n'
                   'signal.signal(signal.SIGQUIT, signal.SIG_DFL)\n'
                   'child = subprocess.Popen(sys.argv[1:], preexec_fn=os.setpgrp)\n'
                   'print("review-pid:" + str(child.pid), flush=True)\n'
                   'result = child.wait()\n'
                   'signal.signal(signal.SIGHUP, signal.SIG_IGN)\n'
                   'print("review-exit:" + str(result), flush=True)\n'
                   'os.read(int(os.environ["REVIEW_RELEASE_FD"]), 1)\nsys.exit(result)\n')
        self.process = subprocess.Popen([sys.executable, "-c", command, str(case.cli), "review", *arguments, "--output", str(self.destination)],
                                        cwd=case.root, env=dict(case.env, REVIEW_RELEASE_FD=str(release_read)),
                                        stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        start_new_session=True, pass_fds=(release_read,))
        os.close(release_read)
        self.buffer = bytearray()
        self.transcript = bytearray()
        first = self.expect("review-pid:", complete_line=True)
        self.cli_pid = int(re.search(rb"review-pid:([0-9]+)", first)[1])

    def close(self):
        if getattr(self, "release_write", None) is not None:
            os.close(self.release_write)
            self.release_write = None
        if hasattr(self, "process") and self.process.poll() is None:
            # A failed assertion must still let our reviewer reap its owned
            # backend and collector before the fixture wrapper disappears.
            if hasattr(self, "cli_pid"):
                try:
                    os.kill(self.cli_pid, signal.SIGCONT)
                    os.kill(self.cli_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        for fd in (self.slave, self.master):
            try: os.close(fd)
            except OSError: pass

    def resize(self, columns, rows):
        import fcntl
        import struct
        import termios
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.screen.resize(rows, columns)
        # This fixture owns a session without a controlling terminal, so the
        # kernel has no foreground group to notify as a real terminal would.
        if hasattr(self, "cli_pid"):
            os.kill(self.cli_pid, signal.SIGWINCH)

    def expect(self, text, complete_line=False, timeout=15, after_revision=None):
        import select
        wanted = text.encode()
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            screen = "\n".join(line.rstrip() for line in self.screen.display).encode()
            found = wanted in self.buffer if complete_line else (wanted in self.buffer or wanted in screen
                    or b" ".join(wanted.split()) in b" ".join(screen.split()))
            if found and (after_revision is None or self.revision > after_revision) and (not complete_line or b"\n" in self.buffer[self.buffer.index(wanted):]):
                result = bytes(self.buffer) + b"\n" + screen
                self.buffer.clear()
                return result
            if select.select([self.master], [], [], 0.1)[0]:
                data = os.read(self.master, 65536)
                self.buffer.extend(data)
                self.transcript.extend(data)
                self.stream.feed(self.decoder.decode(data))
                self.revision += 1
        self.case.fail("terminal did not show " + text + ": " + "\n".join(self.screen.display))

    def press(self, keys, expected):
        revision = self.revision
        os.write(self.master, keys)
        return self.expect(expected, after_revision=revision)

    def finish(self, status):
        import termios
        self.expect("review-exit:" + str(status))
        if b"\x1b[?1049h" in self.transcript:
            for enter, restore in ((b"\x1b[?1049h", b"\x1b[?1049l"),
                                   (b"\x1b[?25l", b"\x1b[?25h"), (b"\x1b[?2004h", b"\x1b[?2004l")):
                self.case.assertIn(enter, self.transcript)
                self.case.assertIn(restore, self.transcript)
                self.case.assertGreater(self.transcript.index(restore), self.transcript.index(enter))
        restored, expected = termios.tcgetattr(self.slave), self.original.copy()
        if sys.platform == "darwin":
            # Darwin sets this transient pending-input bit when canonical mode
            # is restored, even in a minimal cbreak/tcsetattr round trip. Every
            # actual setting (including ICANON and ECHO) must still match.
            restored[3] &= ~termios.PENDIN
            expected[3] &= ~termios.PENDIN
        self.case.assertEqual(restored, expected)
        os.write(self.release_write, b"1")
        os.close(self.release_write)
        self.release_write = None
        for fd in (self.slave, self.master):
            os.close(fd)
        self.case.assertEqual(self.process.wait(timeout=10), status)


if __name__ == "__main__":
    unittest.main()
