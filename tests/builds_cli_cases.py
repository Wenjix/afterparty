"""Public build-inventory tests in disposable repositories and private state."""

import codecs
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
REPO = Path(sys.argv.pop(1)).resolve()
BASH = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else shutil.which("bash")
if os.name == "nt" and Path(BASH + ".exe").is_file():
    BASH += ".exe"
PTY_AVAILABLE = os.name != "nt" and importlib.util.find_spec("pyte") is not None


class BuildsCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="afterparty-builds-cli-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bundle = self.base / "installed skill"
        shutil.copytree(REPO / "skills/afterparty", self.bundle)
        self.cli = self.bundle / "bin/afterparty"
        self.shim = self.base / "shim"
        self.shim.mkdir()
        self.calls = self.base / "calls"
        self.calls.touch()
        self.home = self.base / "home"
        self.home.mkdir()
        self.env = dict(os.environ, PATH=str(self.shim) + os.pathsep + os.environ["PATH"],
                        HOME=str(self.home), XDG_CACHE_HOME=str(self.base / "cache"),
                        XDG_STATE_HOME=str(self.base / "state"),
                        AFTERPARTY_CODEX_ROOT=str(self.base / "codex"),
                        AFTERPARTY_TRANSCRIPT_ROOT=str(self.base / "transcripts"),
                        AGENT_PROCESS_LEDGER=str(self.base / "ledger"),
                        AFTERPARTY_STYLE="never", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1", PYTHONIOENCODING="utf-8",
                        TERM="xterm-256color", BUILDS_CALLS=str(self.calls))
        self.real_git = shutil.which("git")
        if os.name != "nt":
            (self.shim / "bash").symlink_to(Path(BASH).resolve())
        for name in ("kill", "pgrep", "launchctl", "pnpm"):
            self.tool(name, "exit 97")
        self.tool("ps", "exit 1")
        self.tool("lsof", "printf 'p9001\\nfcwd\\nn%s\\n' \"$BUILDS_OCCUPANT\"")
        bash_env = self.base / "bash-env"
        bash_env.write_text('kill() { printf "UNEXPECTED kill %s\\n" "$*" >> "$BUILDS_CALLS"; return 97; }\n')
        self.env["BASH_ENV"] = str(bash_env)
        self.projects = self.base / "projects with spaces $(do-not-run)"
        self.projects.mkdir()
        self.other_projects = self.base / "other projects"
        self.other_projects.mkdir()
        self.alpha = self.repository(self.projects / "alpha site")
        self.beta = self.repository(self.other_projects / "beta app")
        self.root = self.alpha
        self.env["BUILDS_OCCUPANT"] = str(self.root)
        self.outputs = {self.alpha / ".next" / "output": b"a" * 16384,
                        self.beta / ".cache" / "output": b"b" * 32768}
        for path, content in self.outputs.items():
            path.parent.mkdir(parents=True)
            path.write_bytes(content)
        (self.alpha / "target" / "debug").mkdir(parents=True)
        (self.alpha / "target" / "debug" / "keep").write_text("unsupported Rust output\n")
        self.addCleanup(self.assert_no_cleanup)

    def tool(self, name, body):
        target = self.shim / name
        target.write_text('#!/usr/bin/env bash\nprintf "%s %s\\n" "' + name + '" "$*" >> "$BUILDS_CALLS"\n' + body + "\n")
        target.chmod(0o755)

    def repository(self, path):
        path.mkdir(parents=True)
        result = subprocess.run([self.real_git, "init", "-q", str(path)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        (path / ".gitignore").write_text(".next/\n.cache/\ntarget/\n", encoding="utf-8")
        return path.resolve()

    def run_cli(self, *arguments, cwd=None, env=None):
        return subprocess.run([BASH, str(self.cli), *arguments], cwd=cwd or self.root,
                              env=env or self.env, capture_output=True, timeout=30)

    def report(self, *arguments, cwd=None):
        if os.name == "nt":
            self.skipTest("complete allocated-size comparisons require POSIX filesystem evidence")
        result = self.run_cli("builds", "--json", *arguments, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        self.assertNotIn(b"\x1b", result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(value["collection_status"], "complete")
        return value

    def assert_no_cleanup(self):
        self.assertNotRegex(self.calls.read_text(), r"(?m)^(UNEXPECTED|kill|pgrep|launchctl|pnpm)\b")
        for path, content in self.outputs.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual((self.alpha / "target/debug/keep").read_text(), "unsupported Rust output\n")
        for directory in (self.home, self.base / "cache", self.base / "state", self.alpha, self.beta):
            self.assertFalse(list(directory.rglob("*.md")), "inventory must not save cleanup plans")

    def test_json_combines_explicit_roots_with_spaces_and_preserves_scope(self):
        report = self.report("--projects-root", str(self.projects), "--projects-root", str(self.other_projects))
        items = {(item["repository"], item["relative_path"]): item for item in report["items"]}
        for repository, relative, kind in ((self.alpha, ".next", "build"), (self.beta, ".cache", "cache")):
            item = items[(str(repository), relative)]
            self.assertEqual(item["kind"], kind)
            self.assertGreater(item["size_bytes"], 0)
            self.assertEqual(item["status"], "complete")
        self.assertEqual(set(report["roots"]), {str(self.projects), str(self.other_projects)})
        self.assertEqual({item["repository"] for item in report["items"]}, {str(self.alpha), str(self.beta)})
        self.assertFalse(any("target" in Path(item["path"]).parts for item in report["items"]))

    def test_default_scope_is_current_repository(self):
        report = self.report()
        self.assertTrue(report["items"], "the current repository must contribute a positive inventory row")
        self.assertEqual({item["repository"] for item in report["items"]}, {str(self.alpha)})
        self.assertEqual(report["roots"], [str(self.alpha)])

    @unittest.skipIf(os.name == "nt", "Windows paths cannot contain a trailing newline")
    def test_default_scope_preserves_a_trailing_newline_in_the_repository_name(self):
        root = self.repository(self.alpha.with_name(self.alpha.name + "\n"))
        output = root / ".next" / "output"
        output.parent.mkdir()
        self.outputs[output] = b"distinct scoped output" * 1024
        output.write_bytes(self.outputs[output])
        report = self.report(cwd=root)
        self.assertTrue(report["items"], "the selected repository must contribute observed output")
        self.assertEqual(report["roots"], [str(root)])
        self.assertEqual({item["repository"] for item in report["items"]}, {str(root)})

    def test_json_reports_growth_after_a_complete_scan(self):
        first = self.report()
        self.assertEqual(first["history_status"], "first")
        self.assertIsNone(first["delta_bytes"])
        unchanged = self.report()
        self.assertEqual(unchanged["history_status"], "compared")
        self.assertEqual(unchanged["delta_bytes"], 0)
        path = self.alpha / ".next/output"
        self.outputs[path] += b"c" * 131072
        path.write_bytes(self.outputs[path])
        changed = self.report()
        self.assertGreater(changed["delta_bytes"], 0)
        item = next(item for item in changed["items"] if item["relative_path"] == ".next")
        self.assertGreater(item["delta_bytes"], 0)
        self.assertGreater(changed["total_bytes"], first["total_bytes"])

    def test_non_terminal_defaults_to_plain_inventory(self):
        result = self.run_cli("builds")
        self.assertEqual(result.returncode, 1 if os.name == "nt" else 0, result.stderr)
        self.assertIn(b".next", result.stdout)
        self.assertIn(str(self.alpha).encode(), result.stdout)
        self.assertRegex(result.stdout.lower(), rb"read.only|does not delete|no cleanup|deletes nothing")
        self.assertNotIn(b"\x1b[?1049h", result.stdout)
        explicit = self.run_cli("builds", "--plain", "--ascii")
        self.assertEqual(explicit.returncode, 1 if os.name == "nt" else 0, explicit.stderr)
        self.assertIn(b".next", explicit.stdout)

    def assert_rejected(self, *arguments):
        result = self.run_cli("builds", *arguments)
        self.assertEqual(result.returncode, 2, result.stdout.decode() + result.stderr.decode())
        self.assertIn(arguments[0].encode(), result.stderr)
        return result

    def test_flags_cannot_enable_cleanup_or_expand_scope(self):
        for flag in ("--all", "--apply", "--clean", "--kill", "--output"):
            with self.subTest(flag=flag):
                self.assert_rejected(flag)
        self.assertEqual(self.calls.read_text(), "", "flag rejection must precede collection")

    def test_invalid_depth_and_conflicting_output_modes_name_the_option(self):
        for value in ("0", "65", "-1", "1.5", "bad", "9999999999999999999999"):
            with self.subTest(value=value):
                self.assert_rejected("--max-depth", value)
        self.assert_rejected("--max-depth")
        self.assert_rejected("--projects-root")
        result = self.assert_rejected("--json", "--plain")
        self.assertIn(b"--plain", result.stderr)

    def test_existing_artifact_commands_still_require_separate_approval(self):
        tracked = self.alpha / "tracked/dist/keep"
        tracked.parent.mkdir(parents=True)
        self.outputs[tracked] = b"tracked project data\n"
        tracked.write_bytes(self.outputs[tracked])
        staged = subprocess.run([self.real_git, "-C", str(self.alpha), "add", "-f", "tracked/dist/keep"],
                                env=self.env, capture_output=True)
        self.assertEqual(staged.returncode, 0, staged.stderr)
        inventory = self.run_cli("builds", "--json")
        self.assertIn("tracked/dist", {item["relative_path"] for item in json.loads(inventory.stdout)["items"]},
                      "inventory may report tracked output without approving deletion")
        preview = self.run_cli("artifacts", "--clean")
        self.assertEqual(preview.returncode, 2, preview.stderr)
        self.assertIn(b".next", preview.stdout)
        self.assertIn(b"report-only", preview.stderr)
        plan = self.run_cli("plan", "--artifacts-only")
        self.assertEqual(plan.returncode, 0, plan.stdout.decode() + plan.stderr.decode())
        self.assertIn(("- [ ] artifact path " + str(self.alpha / ".next")).encode(), plan.stdout)
        self.assertIn(("- [⊘] tracked path " + str(tracked.parent)).encode(), plan.stdout)
        self.assertNotIn(b"- [x]", plan.stdout)

    def test_rejection_assertion_detects_a_dispatcher_that_accepts_apply(self):
        launcher = self.bundle / "lib/builds.sh"
        original = launcher.read_text()
        mutated, count = re.subn(r"(?m)^(\s*)--json\|--plain\)", r"\1--apply) shift ;;\n\1--json|--plain)", original, count=1)
        self.assertEqual(count, 1, "the scratch mutation must alter the public option dispatcher")
        launcher.write_text(mutated)
        mutant = self.run_cli("builds", "--apply")
        self.assertEqual(mutant.returncode, 1 if os.name == "nt" else 0, mutant.stdout + mutant.stderr)
        self.assertIn(b".next", mutant.stdout, "the mutant must enter the inventory path")
        with self.assertRaises(AssertionError):
            self.assert_rejected("--apply")

    def assert_legacy_names(self, library):
        kinds = {"cache": (".turbo", ".vite", ".cache", ".parcel-cache", ".rollup.cache", ".eslintcache", "app.tsbuildinfo"),
                 "build": (".next", "dist", "build", "out", ".output", ".svelte-kit", ".astro", "storybook-static"),
                 "test": ("coverage", ".nyc_output", "test-results", "playwright-report", ".playwright-mcp", ".vitest")}
        cases = [(name, kind) for kind, names in kinds.items() for name in names]
        cases += [(name, "refused") for name in (".env", "node_modules", "target", ".gradle", "__pycache__", "my-build", "dist.old")]
        command = '. "$1/artifact-names.sh" || exit; . "$1/vetoes.sh" || exit; shift\nfor name in "$@"; do\n  if veto_artifact_name "/repo/$name"; then artifact_kind_for_name "$name"; else printf "refused\\n"; fi\ndone'
        result = subprocess.run([BASH, "-u", "-c", command, "_", str(library), *(name for name, _ in cases)],
                                env=dict(self.env, PATH=str(self.shim)), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines(), [kind for _, kind in cases])

    def test_shared_registry_preserves_the_existing_apply_allowlist_without_python(self):
        self.assert_legacy_names(self.bundle / "lib")
        registry = self.bundle / "lib/artifact-kinds.tsv"
        original = registry.read_text()
        self.assertIn("directory\t.cache\tcache", original)
        registry.write_text(original.replace("directory\t.cache\tcache", "directory\t.env\tcache", 1))
        with self.assertRaises(AssertionError):
            self.assert_legacy_names(self.bundle / "lib")

    def test_missing_or_malformed_registry_refuses_artifacts_without_disabling_other_vetoes(self):
        registry = self.bundle / "lib/artifact-kinds.tsv"
        original = registry.read_text()
        for broken in (None, original + "directory\t.env\tinvalid\n", original + "directory\t*\tcache\n",
                       original + "directory\t.env\tcache\ninvalid", original + "directory\t.en\0v\tcache\n"):
            with self.subTest(broken=broken is None and "missing" or "malformed"):
                if broken is None:
                    registry.unlink()
                else:
                    registry.write_text(broken)
                command = ('. "$1/vetoes.sh"\n'
                           'declare -F veto_for >/dev/null || exit 90\n'
                           'printf "veto-functions-present\\n"\n'
                           'for name in .cache .env; do\n'
                           '  if veto_artifact_name "$name"; then printf "accepted %s\\n" "$name"; '
                           'else printf "refused %s\\n" "$name"; fi\ndone')
                result = subprocess.run([BASH, "-u", "-c", command, "_", str(self.bundle / "lib")],
                                        env=self.env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [b"veto-functions-present", b"refused .cache", b"refused .env"])
                collector = self.run_cli("artifacts", "--plan")
                self.assertEqual(collector.returncode, 1, collector.stdout + collector.stderr)
                self.assertIn(b"artifact name registry is unavailable", collector.stderr)
                self.assertNotIn(b"- [ ]", collector.stdout)

    @unittest.skipUnless(PTY_AVAILABLE, "PTY tests require a Unix terminal and pyte")
    def test_terminal_without_helper_falls_back_to_a_readable_inventory(self):
        (self.bundle / "bin/afterparty-review").unlink(missing_ok=True)
        terminal = BuildsTerminal(self)
        terminal.expect("terminal helper is unavailable")
        terminal.expect(".next")
        terminal.finish(0)
        self.assertNotIn(b"\x1b[?1049h", terminal.transcript)

    def require_helper(self):
        if not (self.bundle / "bin/afterparty-review").is_file():
            self.skipTest("build-review must build the optional terminal helper")

    @unittest.skipUnless(PTY_AVAILABLE, "PTY tests require a Unix terminal and pyte")
    def test_inventory_keys_never_mark_or_save_and_refresh_shows_growth(self):
        self.require_helper()
        self.report()
        terminal = BuildsTerminal(self)
        terminal.expect("BUILD OUTPUT")
        terminal.expect("Scan: complete")
        terminal.expect("Known total:")
        terminal.expect("Growth: 0 B since previous complete scan")
        terminal.press(b"s", "no marks or save action")
        path = self.alpha / ".next/output"
        self.outputs[path] += b"c" * 131072
        path.write_bytes(self.outputs[path])
        terminal.press(b"r", "Inventory refreshed")
        terminal.expect("Growth: +")
        terminal.press(b" ", "no marks or save action")
        terminal.press(b"q", "builds-exit:0")
        terminal.finish(0)
        self.assertIn(b"\x1b[?1049h", terminal.transcript)
        self.assertNotIn(b"Save plan", terminal.transcript)

    @unittest.skipUnless(PTY_AVAILABLE, "PTY tests require a Unix terminal and pyte")
    def test_filter_inspect_and_enter_open_only_the_chosen_repository_review(self):
        self.require_helper()
        handoff = self.base / "handoff-arguments"
        review = self.bundle / "lib/review.sh"
        original = self.bundle / "lib/review-original.sh"
        review.rename(original)
        review.write_text('#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$BUILDS_HANDOFF"\nexec "$BUILDS_REVIEW_REAL" "$@"\n')
        review.chmod(0o755)
        self.env.update(BUILDS_HANDOFF=str(handoff), BUILDS_REVIEW_REAL=str(original))
        terminal = BuildsTerminal(self, ("--projects-root", str(self.projects), "--projects-root", str(self.other_projects)))
        terminal.expect("Scan: complete | 2 repos")
        terminal.press(b"/", "finish search")
        terminal.press(b"beta", "/ beta_")
        terminal.press(b"\r", "Ctrl+P commands")
        terminal.expect("Path 1 of 1:")
        terminal.press(b"i", "Enter opens repository review.")
        terminal.expect(str(self.beta / ".cache"), compact=True)
        terminal.press(b"\r", "REVIEW")
        terminal.expect("Choose")
        self.assertEqual(handoff.read_bytes().split(b"\0")[:-1],
                         [b"--artifacts-only", b"--root", str(self.beta).encode()])
        terminal.press(b"q", "builds-exit:1")
        terminal.finish(1)
        self.assertGreaterEqual(terminal.transcript.count(b"\x1b[?1049h"), 2)
        self.assertGreaterEqual(terminal.transcript.count(b"\x1b[?1049l"), 2)

    @unittest.skipUnless(PTY_AVAILABLE, "PTY tests require a Unix terminal and pyte")
    def test_inventory_commands_open_only_a_fresh_review_for_the_focused_repository(self):
        self.require_helper()
        handoff = self.base / "command-handoff"
        review = self.bundle / "lib/review.sh"
        original = self.bundle / "lib/review-original.sh"
        review.rename(original)
        review.write_text('#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$BUILDS_HANDOFF"\nexec "$BUILDS_REVIEW_REAL" "$@"\n')
        review.chmod(0o755)
        self.env.update(BUILDS_HANDOFF=str(handoff), BUILDS_REVIEW_REAL=str(original))
        terminal = BuildsTerminal(self, ("--projects-root", str(self.projects), "--projects-root", str(self.other_projects)))
        terminal.expect("Scan: complete | 2 repos")
        terminal.press(b"\x10", "Commands")
        for query, forbidden in ((b"mark", "Mark target"), (b"save", "Save plan"), (b"apply", "Apply")):
            terminal.press(b"\x15" + query, "Find: " + query.decode())
            self.assertNotRegex("\n".join(terminal.screen.display),
                                r"(?m)^\s*[>-]?\s*" + re.escape(forbidden) + r" {2,}")
        terminal.press(b"\x10", "BUILD OUTPUT")
        terminal.press(b"/beta", "/ beta_")
        terminal.press(b"\r", "Ctrl+P commands")
        terminal.expect("Path 1 of 1:")
        terminal.press(b"\x10", "Commands")
        terminal.press(b"Review repository", "Find: Review repository")
        terminal.press(b"\r", "REVIEW")
        terminal.expect("0 marked")
        self.assertEqual(handoff.read_bytes().split(b"\0")[:-1],
                         [b"--artifacts-only", b"--root", str(self.beta).encode()])
        terminal.press(b"q", "builds-exit:1")
        terminal.finish(1)
        self.assertGreaterEqual(terminal.transcript.count(b"\x1b[?1049h"), 2)
        self.assertGreaterEqual(terminal.transcript.count(b"\x1b[?1049l"), 2)

    @unittest.skipUnless(PTY_AVAILABLE, "PTY tests require a Unix terminal and pyte")
    def test_dumb_terminal_uses_plain_inventory(self):
        terminal = BuildsTerminal(self, env=dict(self.env, TERM="dumb"))
        terminal.expect("This terminal does not support the TUI")
        terminal.expect(".next")
        terminal.finish(0)
        self.assertNotIn(b"\x1b[?1049h", terminal.transcript)

    @unittest.skipUnless(os.name == "nt", "Windows-specific unavailable filesystem evidence")
    def test_windows_keeps_unknown_sizes_visible(self):
        result = self.run_cli("builds", "--json")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["collection_status"], "incomplete")
        output = next(item for item in report["items"] if item["relative_path"] == ".next")
        self.assertEqual(output["status"], "unavailable")
        self.assertIsNone(output["size_bytes"])
        self.assertTrue(report["issues"], "unavailable measurements must include a positive diagnostic")


class BuildsTerminal:
    def __init__(self, case, arguments=(), columns=100, rows=30, env=None):
        import fcntl
        import pty
        import pyte
        import struct
        import termios

        self.case = case
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.original = termios.tcgetattr(self.slave)
        class Screen(pyte.Screen):
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

        self.screen = Screen(columns, rows)
        self.stream = Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.transcript = bytearray()
        self.buffer = bytearray()
        release_read, self.release_write = os.pipe()
        wrapper = ('import os, signal, subprocess, sys\n'
                   'child = subprocess.Popen(sys.argv[1:], preexec_fn=os.setpgrp)\n'
                   'print("builds-pid:" + str(child.pid), flush=True)\n'
                   'result = child.wait()\n'
                   'signal.signal(signal.SIGHUP, signal.SIG_IGN)\n'
                   'print("builds-exit:" + str(result), flush=True)\n'
                   'os.read(int(os.environ["BUILDS_RELEASE_FD"]), 1)\nsys.exit(result)\n')
        self.process = subprocess.Popen([sys.executable, "-c", wrapper, BASH, str(case.cli), "builds", *arguments],
                                        cwd=case.root, env=dict(env or case.env, BUILDS_RELEASE_FD=str(release_read)),
                                        stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        start_new_session=True, pass_fds=(release_read,))
        os.close(release_read)
        case.addCleanup(self.close)
        first = self.expect("builds-pid:")
        self.cli_pid = int(re.search(rb"builds-pid:([0-9]+)", first)[1])

    def expect(self, text, timeout=20, compact=False):
        import select
        wanted = text.encode()
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            visible = "\n".join(line.rstrip() for line in self.screen.display).encode()
            found = wanted in self.buffer or b" ".join(wanted.split()) in b" ".join(visible.split())
            if compact:
                found = found or b"".join(wanted.split()) in b"".join(visible.split())
            if found:
                output = bytes(self.buffer) + b"\n" + visible
                self.buffer.clear()
                return output
            if select.select([self.master], [], [], 0.1)[0]:
                data = os.read(self.master, 65536)
                self.transcript.extend(data)
                self.buffer.extend(data)
                self.stream.feed(self.decoder.decode(data))
        self.case.fail("terminal did not show " + text + ": " + "\n".join(self.screen.display))

    def press(self, keys, text):
        self.buffer.clear()
        os.write(self.master, keys)
        return self.expect(text)

    def finish(self, status):
        import termios
        self.expect("builds-exit:" + str(status))
        restored, expected = termios.tcgetattr(self.slave), self.original.copy()
        if sys.platform == "darwin":
            restored[3] &= ~termios.PENDIN
            expected[3] &= ~termios.PENDIN
        self.case.assertEqual(restored, expected)
        if b"\x1b[?1049h" in self.transcript:
            for enter, restore in ((b"\x1b[?1049h", b"\x1b[?1049l"), (b"\x1b[?25l", b"\x1b[?25h")):
                self.case.assertIn(restore, self.transcript)
                self.case.assertGreater(self.transcript.index(restore), self.transcript.index(enter))
        os.write(self.release_write, b"1")
        os.close(self.release_write)
        self.release_write = None
        self.case.assertEqual(self.process.wait(timeout=10), status)

    def close(self):
        if getattr(self, "release_write", None) is not None:
            os.close(self.release_write)
            self.release_write = None
        if self.process.poll() is None:
            try:
                os.kill(self.cli_pid, signal.SIGTERM)
                self.process.wait(timeout=5)
            except (AttributeError, ProcessLookupError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        for descriptor in (self.master, self.slave):
            try:
                os.close(descriptor)
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
