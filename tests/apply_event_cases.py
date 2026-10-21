"""Public apply receipts: disposable Git/files and intercepted discovery/signals."""

import copy
import json
import os
from pathlib import Path
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
if os.name == "nt":
    print("SKIP: apply receipt fixtures require POSIX signal and process isolation; run on macOS/Linux")
    sys.exit(0)
sys.path.insert(0, str(REPO / "skills/afterparty/lib"))
from apply_events import read_stream
from plan_data import digest, encoded


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="afterparty-apply-events-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "project space 日本語"
        self.root.mkdir()
        self.bundle = self.base / "installed skill"
        shutil.copytree(REPO / "skills/afterparty", self.bundle)
        self.cli = self.bundle / "bin/afterparty"
        self.lib = self.bundle / "lib"
        self.shim = self.base / "shim"
        self.shim.mkdir()
        (self.shim / "bash").symlink_to(Path(BASH).resolve())
        self.log = self.base / "calls"
        self.log.touch()
        self.present = self.base / "group-present"
        self.present.touch()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("AFTERPARTY_")}
        self.env.update(PATH=str(self.shim) + os.pathsep + os.environ["PATH"], HOME=str(self.base / "home"),
                        XDG_CACHE_HOME=str(self.base / "state"), AFTERPARTY_STYLE="never",
                        AFTERPARTY_TRANSCRIPT_ROOT=str(self.base / "projects"), AFTERPARTY_CODEX_ROOT=str(self.base / "codex"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, PYTHONDONTWRITEBYTECODE="1",
                        APPLY_FIXTURE=str(self.base), APPLY_ROOT=str(self.root), APPLY_CALLS=str(self.log))
        Path(self.env["HOME"]).mkdir()
        self.git("init", "-q")
        (self.root / ".gitignore").write_text(".next/\n.cache/\ndist/\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        project = Path(self.env["AFTERPARTY_TRANSCRIPT_ROOT"]) / "fixture"
        project.mkdir(parents=True)
        self.transcript = project / "session.jsonl"
        self.transcript.write_text(json.dumps({"cwd": str(self.root)}) + "\n")
        old = time.time() - 86400 * 30
        os.utime(self.transcript, (old, old))
        self.tool("ps", '''exists=0; [ ! -f "$APPLY_FIXTURE/group-present" ] || exists=1
extras() {
  local pg command
  for pg in 9002 9003; do
    [ -f "$APPLY_FIXTURE/group-$pg" ] || continue
    command='npm run dev'; [ "$pg" != 9003 ] || command='chrome --headless'
    case "$1" in
      members) printf '%s %s Tue Aug 18 09:00:00 2026 %s\n' "$pg" "$pg" "$command" ;;
      identity) printf '%s Tue Aug 18 09:00:00 2026 %s\n' "$pg" "$command" ;;
      protection) printf '%s %s\n' "$pg" "$command"
        [ "$pg" != 9002 ] || [ ! -f "$APPLY_FIXTURE/protected-second" ] || printf '9002 claude\n' ;;
      audit) printf '%s 1 %s 0.1 10:00 %s\n' "$pg" "$pg" "$command" ;;
      facts) printf '%s %s 0.1 %s\n' "$pg" "$pg" "$command" ;;
    esac
  done
}
case "$*" in
  *pid=,pgid=,lstart=,command=*)
    printf '8000 8000 Tue Aug 18 09:00:00 2026 fixture-scanner\n'
    [ "$exists" = 0 ] || printf '9001 9001 Tue Aug 18 09:00:00 2026 npm run dev\n'
    extras members ;;
  *pgid=,lstart=,command=*)
    [ "$exists" = 0 ] || printf '9001 Tue Aug 18 09:00:00 2026 npm run dev\n'
    extras identity ;;
  *pgid=,command=*)
    printf '8000 fixture-scanner\n'
    [ "$exists" = 0 ] || printf '9001 npm run dev\n'
    [ ! -f "$APPLY_FIXTURE/protected" ] || printf '9001 claude\n'
    extras protection ;;
  *pid,ppid,pgid,%cpu,etime,command*)
    printf 'PID PPID PGID %%CPU ELAPSED COMMAND\n8000 1 8000 0.0 01:00 fixture-scanner\n'
    [ "$exists" = 0 ] || printf '9001 1 9001 0.1 10:00 npm run dev\n'
    extras audit ;;
  *pid,pgid,%cpu*)
    printf 'PID PGID %%CPU COMMAND\n'
    [ "$exists" = 0 ] || printf '9001 9001 0.1 npm run dev\n'
    extras facts ;;
  '-o pgid= -p '*) printf '8000\n' ;;
  *) echo 'unsupported fixture ps request' >&2; exit 97 ;;
esac
exit 0''')
        self.tool("lsof", r'''case "$*" in
  *-d\ cwd*) printf 'p8000\nfcwd\nn%s\n' "$APPLY_FIXTURE"
             [ ! -f "$APPLY_FIXTURE/group-present" ] || printf 'p9001\nfcwd\nn%s\n' "$APPLY_ROOT"
             for pg in 9002 9003; do
               [ ! -f "$APPLY_FIXTURE/group-$pg" ] || printf 'p%s\nfcwd\nn%s\n' "$pg" "$APPLY_ROOT"
             done ;;
  *LISTEN*) exit 1 ;;
  *) echo 'unsupported fixture lsof request' >&2; exit 97 ;;
esac
exit 0''')
        for name in ("kill", "pgrep", "launchctl", "pnpm"):
            self.tool(name, "echo 'unexpected mutation binary' >&2; exit 97")
        self.tool("sleep", "exit 0")
        bash_env = self.base / "bash-env"
        bash_env.write_text('''kill() {
  local IFS=' '
  printf 'intercepted-kill %s\n' "$*" >> "$APPLY_CALLS"
  case "$*" in
    '-TERM -9001'|'-KILL -9001') [ -f "$APPLY_FIXTURE/survive" ] || rm -f "$APPLY_FIXTURE/group-present" ;;
    '-TERM -9002'|'-KILL -9002'|'-TERM -9003'|'-KILL -9003') rm -f "$APPLY_FIXTURE/group-${2#-}" ;;
    *) printf 'unexpected signal request\n' >&2; return 97 ;;
  esac
  return 0
}
''')
        self.env["BASH_ENV"] = str(bash_env)
        self.plan = self.base / "reviewed plan.md"

    def tool(self, name, body):
        path = self.shim / name
        path.write_text('#!/usr/bin/env bash\nprintf "%s %s\\n" "' + name + '" "$*" >> "$APPLY_CALLS"\n' + body + "\n")
        path.chmod(0o755)

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def fingerprint(self, kind, target):
        result = subprocess.run([BASH, "-c", '. "$1/fingerprint.sh"; "fp_for_$2" "$3"',
                                 "fixture", str(self.lib), kind, str(target)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.decode().strip()

    def artifact(self, name=".next"):
        target = self.root / name
        target.mkdir(parents=True)
        (target / "data").write_text("generated\n")
        return target, self.artifact_row(target)

    def artifact_row(self, target):
        return (f"- [x] artifact path {target}\n"
                f"      type: artifact  fingerprint: {self.fingerprint('artifact', target)}  root: {self.root}\n")

    def process_row(self, pgid="9001", category="dev"):
        return f"- [x] stale pgid {pgid}\n      category: {category}  fingerprint: {self.fingerprint('pgid', pgid)}\n"

    def run_apply(self, rows, json_mode=True, status=0):
        self.plan.write_text("# afterparty plan schema: 1\n" + rows, encoding="utf-8")
        args = [BASH, str(self.cli), "apply", *(["--json"] if json_mode else []), str(self.plan)]
        result = subprocess.run(args, cwd=self.root, env=self.env, capture_output=True, timeout=30)
        self.last_result = result
        self.assertEqual(result.returncode, status, result.stderr.decode() + result.stdout.decode())
        self.assertNotRegex(self.log.read_text(), r"(?m)^(kill|pgrep|launchctl|pnpm) ")
        if not json_mode:
            return result
        self.assertNotIn(b"\x1b", result.stdout)
        events = read_stream(result.stdout)
        self.assertEqual(events[-1]["exit_status"], result.returncode)
        if events[0]["section"] == "apply_start":
            self.assertEqual(events[0]["plan_sha256"], digest(self.plan.read_bytes()))
        return events

    def targets(self, events):
        return [event for event in events if event["section"] == "apply_target"]

    def test_artifact_success_lossless_and_private_cleanup(self):
        target, row = self.artifact("日本語 \u2028 \u0085 \v 'quoted' $(no-command)/dist")
        self.env["AFTERPARTY_STYLE"] = "always"
        events = self.run_apply(row)
        item, = self.targets(events)
        self.assertEqual((item["target"], item["scope"]), (str(target), str(self.root)))
        self.assertEqual((item["outcome"], item["mutation_attempted"], item["postcondition_confirmed"], item["receipt_status"]),
                         ("applied", True, True, "recorded"))
        self.assertFalse(target.exists())
        self.assertEqual(events[-2]["counts"]["applied"], 1)
        self.assertFalse(list(Path(self.env["XDG_CACHE_HOME"]).rglob("run.*")))

    def test_empty_plan_and_already_gone_are_noops(self):
        events = self.run_apply("")
        self.assertEqual(events[0]["checked_count"], 0)
        target, row = self.artifact()
        shutil.rmtree(target)
        item, = self.targets(self.run_apply(row))
        self.assertEqual((item["outcome"], item["mutation_attempted"], item["postcondition_confirmed"], item["receipt_status"]),
                         ("gone", False, True, "not-attempted"))

    def test_mixed_partial_success_drift_and_tracked_veto(self):
        applied, a = self.artifact()
        drift, b = self.artifact(".cache")
        (drift / "new").write_text("changed")
        tracked, c = self.artifact("dist")
        self.git("add", "-f", "dist/data")
        events = self.run_apply(a + b + c, status=1)
        self.assertEqual([r["outcome"] for r in self.targets(events)], ["applied", "drift", "vetoed"])
        self.assertEqual(self.targets(events)[2]["reason_code"], "tracked")
        self.assertFalse(applied.exists())
        self.assertTrue(drift.exists() and tracked.exists())
        self.assertEqual(sum(events[-2]["counts"].values()), 3)

    def test_malformed_plan_rejected_before_any_valid_target(self):
        target, row = self.artifact()
        for bad, message in ((row, "duplicate checked target"),
                             ("- [x] broken\n", "has no metadata"),
                             ("- [x] stale path /display\n      type: worktree  fingerprint: deadbeef  path: /different\n", "disagrees")):
            with self.subTest(message=message):
                events = self.run_apply(row + bad, status=2)
                self.assertEqual(events[0]["section"], "apply_rejection")
                self.assertIn(message, events[0]["detail"])
                self.assertTrue(target.exists())
        self.assertNotIn("intercepted-kill", self.log.read_text())

    def test_failed_artifact_removal_is_not_success(self):
        target, row = self.artifact()
        self.env["APPLY_REFUSE_RM"] = str(target)
        self.tool("rm", '''for arg in "$@"; do
  [ "$arg" != "$APPLY_REFUSE_RM" ] || exit 0
done
exec /bin/rm "$@"''')
        for mode in (False, True):
            with self.subTest(json=mode):
                self.log.write_text("")
                result = self.run_apply(row, json_mode=mode, status=1)
                if mode:
                    item, = self.targets(result)
                    self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"], item["postcondition_confirmed"]),
                                     ("failed", "removal-unconfirmed", True, False))
                else:
                    self.assertIn(b"failed to delete", result.stdout)
                self.assertIn("rm -rf -- " + str(target), self.log.read_text())
                self.assertTrue(target.exists())

    def test_failed_artifact_command_preserves_confirmed_path_absence(self):
        self.env["APPLY_REFUSE_RM"] = ""
        self.tool("rm", '''matched=0
for arg in "$@"; do
  [ "$arg" != "$APPLY_REFUSE_RM" ] || matched=1
done
/bin/rm "$@"
rc=$?
[ "$matched" -eq 0 ] || exit 1
exit "$rc"''')
        for mode in (True, False):
            with self.subTest(json=mode):
                target, row = self.artifact("failed-removal-" + str(mode) + "/dist")
                self.env["APPLY_REFUSE_RM"] = str(target)
                self.log.write_text("")
                result = self.run_apply(row, json_mode=mode, status=1)
                self.assertIn("rm -rf -- " + str(target), self.log.read_text())
                self.assertFalse(target.exists())
                journal = Path(self.env["XDG_CACHE_HOME"]) / "agent-processes/actions.jsonl"
                entry, = [record for record in map(json.loads, journal.read_text().splitlines())
                          if record["operation"] == "artifact.clean" and record["target"] == str(target)]
                self.assertEqual(entry["status"], "failed")
                self.assertIn("confirmed absent", entry["detail"])
                if mode:
                    item, = self.targets(result)
                    self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"],
                                      item["postcondition_confirmed"], item["receipt_status"]),
                                     ("failed", "removal-failed", True, True, "recorded"))
                    self.assertIn("exit status 1", item["detail"])
                    self.assertEqual((result[-2]["counts"]["applied"], result[-2]["counts"]["failed"]), (0, 1))
                else:
                    self.assertIn(b"removal failed after path disappeared", result.stdout)
                    self.assertIn(b"0 applied", result.stdout)

    def fail_journal(self):
        # Exercise the real writer's directory refusal after a confirmed effect.
        state = Path(self.env["XDG_CACHE_HOME"]) / "agent-processes"
        state.mkdir(parents=True, exist_ok=True)
        (state / "actions.jsonl").mkdir()

    def test_artifact_journal_failure_preserves_confirmed_effect(self):
        target, row = self.artifact()
        self.fail_journal()
        events = self.run_apply(row, status=1)
        item, = self.targets(events)
        self.assertEqual((item["outcome"], item["postcondition_confirmed"], item["receipt_status"]), ("applied", True, "failed"))
        self.assertFalse(target.exists())
        self.assertGreater(events[-2]["journal_failures"], 0)

    def test_process_success_uses_real_child_and_intercepted_signal(self):
        item, = self.targets(self.run_apply(self.process_row()))
        self.assertEqual((item["outcome"], item["mutation_attempted"], item["postcondition_confirmed"], item["receipt_status"], item["delegation_exit_code"]),
                         ("applied", True, True, "recorded", 0))
        self.assertIn("intercepted-kill -TERM -9001", self.log.read_text())
        self.assertFalse(self.present.exists())

    def test_invalid_member_cpu_refuses_delegation(self):
        row = self.process_row()
        ps = self.shim / "ps"
        original = ps.read_text()
        lsof = self.shim / "lsof"
        lsof.write_text(lsof.read_text().replace("p9001\\nfcwd\\nn%s\\n", "p9001\\nfcwd\\nn%s\\np9004\\nfcwd\\nn%s\\n").replace(
            '"$APPLY_ROOT"\n', '"$APPLY_ROOT" "$APPLY_ROOT"\n', 1))
        for invalid in ("unavailable", "-1", "NaN", "9" * 400, ""):
            with self.subTest(cpu=invalid):
                self.log.write_text("")
                ps.write_text(original.replace("printf '9001 9001 0.1 npm run dev\n'",
                    "printf '9001 9001 0.1 npm run dev\n9004 9001 " + invalid + "\n'"))
                item, = self.targets(self.run_apply(row, status=1))
                self.assertEqual((item["target"], item["outcome"], item["reason_code"], item["mutation_attempted"]),
                                 ("9001", "failed", "scan-incomplete", False))
                self.assertIn("ps -Ao pid,pgid,%cpu", self.log.read_text())
                self.assertNotIn("intercepted-kill", self.log.read_text())
                self.assertTrue(self.present.exists())

    def test_multiple_groups_and_categories_keep_styled_narration_off_json(self):
        for name in ("group-9002", "group-9003", "protected-second"):
            (self.base / name).touch()
        self.env["AFTERPARTY_STYLE"] = "always"
        self.child_wrapper('cat "$AFTERPARTY_APPLY_DIR/child.jsonl" >> "$APPLY_FIXTURE/child-observations"\nexit 0')
        rows = self.process_row() + self.process_row("9002") + self.process_row("9003", "browser")
        events = self.run_apply(rows, status=1)
        targets = self.targets(events)
        self.assertEqual([(t["target_index"], t["target"], t["category"], t["outcome"]) for t in targets],
                         [(0, "9001", "dev", "applied"), (1, "9002", "dev", "vetoed"), (2, "9003", "browser", "applied")])
        self.assertEqual((events[-2]["counts"]["applied"], events[-2]["counts"]["vetoed"]), (2, 1))
        self.assertFalse(self.present.exists() or (self.base / "group-9003").exists())
        self.assertTrue((self.base / "group-9002").exists())
        self.assertNotIn("intercepted-kill -TERM -9002", self.log.read_text())
        self.assertIn(b"Stop process groups in category", self.last_result.stderr)
        self.assertNotIn(b"Stop process groups in category", self.last_result.stdout)
        child_records = [json.loads(line) for line in (self.base / "child-observations").read_bytes().splitlines()]
        self.assertEqual([r["pgid"] for r in child_records], ["9001", "9002", "9003"])
        self.assertEqual({r["run_id"] for r in child_records}, {events[0]["run_id"]})

    def test_process_survival_protection_and_activity_hold(self):
        row = self.process_row()
        (self.base / "survive").touch()
        events = self.run_apply(row, status=1)
        item, = self.targets(events)
        self.assertEqual((item["outcome"], item["mutation_attempted"], item["postcondition_confirmed"]), ("survived", True, False))
        self.assertIn("intercepted-kill -KILL -9001", self.log.read_text())
        (self.base / "protected").touch()
        self.log.write_text("")
        item, = self.targets(self.run_apply(row, status=1))
        self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"]), ("vetoed", "protected", False))
        self.assertNotIn("intercepted-kill", self.log.read_text())
        os.utime(self.transcript, None)
        item, = self.targets(self.run_apply(row, status=1))
        self.assertEqual((item["outcome"], item["reason_code"]), ("held", "no-longer-eligible"))

    def test_process_journal_failure_is_separate_from_action(self):
        row = self.process_row()
        self.fail_journal()
        events = self.run_apply(row, status=1)
        item, = self.targets(events)
        self.assertEqual((item["outcome"], item["postcondition_confirmed"], item["receipt_status"]), ("applied", True, "failed"))
        self.assertNotEqual(item["delegation_exit_code"], 0)
        self.assertGreater(events[-2]["journal_failures"], 0)
        self.assertEqual(events[-2]["invocation_errors"], 1)
        self.assertFalse(self.present.exists())

    def child_wrapper(self, suffix):
        self.tool("audit-processes.sh", '"' + str(self.lib / "audit-processes.sh") + '" "$@"\n' + suffix)

    def test_missing_or_corrupt_child_evidence_never_claims_an_attempt(self):
        row = self.process_row()
        for body in (': > "$AFTERPARTY_APPLY_DIR/child.jsonl"',
                     'printf "{bad\\n" > "$AFTERPARTY_APPLY_DIR/child.jsonl"',
                     'cat "$AFTERPARTY_APPLY_DIR/child.jsonl" > "$APPLY_FIXTURE/copy"; cat "$APPLY_FIXTURE/copy" >> "$AFTERPARTY_APPLY_DIR/child.jsonl"',
                     "sed 's/\"run_id\":\"[a-f0-9]*\"/\"run_id\":\"wrong\"/' \"$AFTERPARTY_APPLY_DIR/child.jsonl\" > \"$APPLY_FIXTURE/copy\"; cat \"$APPLY_FIXTURE/copy\" > \"$AFTERPARTY_APPLY_DIR/child.jsonl\""):
            with self.subTest(body=body):
                self.present.touch()
                self.child_wrapper(body + "\nexit 0")
                events = self.run_apply(row, status=1)
                item, = self.targets(events)
                self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"], item["receipt_status"]),
                                 ("failed", "child-evidence-unavailable", None, None))
                self.assertTrue(item["postcondition_confirmed"])
                self.assertEqual(events[-2]["invocation_errors"], 1)
                journal = Path(self.env["XDG_CACHE_HOME"]) / "agent-processes/actions.jsonl"
                plan_entry = [json.loads(line) for line in journal.read_text().splitlines()
                              if json.loads(line)["operation"] == "plan.apply"][-1]
                self.assertEqual(plan_entry["status"], "failed")
                self.assertIn("invocation_errors=1", plan_entry["detail"])

    def test_failed_child_invocation_stays_nonzero_after_confirmed_absence(self):
        self.child_wrapper("exit 17")
        events = self.run_apply(self.process_row(), status=1)
        item, = self.targets(events)
        self.assertEqual((item["outcome"], item["delegation_exit_code"]), ("applied", 17))
        self.assertEqual(events[-2]["invocation_errors"], 1)

    def test_parent_rechecks_child_claim_and_channel_binding_precedes_signal(self):
        self.child_wrapper('touch "$APPLY_FIXTURE/group-present"')
        item, = self.targets(self.run_apply(self.process_row(), status=1))
        self.assertEqual((item["outcome"], item["postcondition_confirmed"]), ("survived", False))
        self.tool("audit-processes.sh", 'AFTERPARTY_APPLY_RUN_ID=wrong exec "' + str(self.lib / "audit-processes.sh") + '" "$@"')
        self.log.write_text("")
        item, = self.targets(self.run_apply(self.process_row(), status=1))
        self.assertEqual(item["reason_code"], "child-evidence-unavailable")
        self.assertTrue(self.present.exists())
        self.assertNotIn("intercepted-kill", self.log.read_text())

    def test_setup_failure_prevents_artifact_mutation(self):
        target, row = self.artifact()
        self.tool("python3", "echo 'fixture serializer unavailable' >&2; exit 93")
        self.plan.write_text(row)
        result = subprocess.run([BASH, str(self.cli), "apply", "--json", str(self.plan)], cwd=self.root, env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"structured output setup unavailable; no cleanup attempted", result.stderr)
        self.assertTrue(target.exists())
        self.assertNotIn("intercepted-kill", self.log.read_text())

    def test_plain_and_json_execute_same_checked_targets(self):
        for mode in (False, True):
            with self.subTest(json=mode):
                self.present.touch()
                target, row = self.artifact()
                self.run_apply(self.process_row() + row, json_mode=mode)
                self.assertFalse(target.exists() or self.present.exists())
        self.assertEqual(self.log.read_text().count("intercepted-kill -TERM -9001"), 2)

    def test_plain_json_refusal_and_noop_parity(self):
        for mode in (False, True):
            for scenario in ("gone", "drift", "vetoed", "held", "survived", "failed"):
                with self.subTest(json=mode, outcome=scenario):
                    self.present.touch()
                    for flag in ("survive", "protected"):
                        (self.base / flag).unlink(missing_ok=True)
                    old = time.time() - 86400 * 30
                    os.utime(self.transcript, (old, old))
                    self.log.write_text("")
                    if scenario in ("held", "survived", "failed"):
                        row = self.process_row()
                        if scenario == "held":
                            os.utime(self.transcript, None)
                        elif scenario == "survived":
                            (self.base / "survive").touch()
                        else:
                            self.transcript.write_text("invalid JSON\n")
                    else:
                        target, row = self.artifact(f"parity-{mode}-{scenario}/dist")
                        if scenario == "gone":
                            shutil.rmtree(target)
                        elif scenario == "drift":
                            (target / "changed").touch()
                        else:
                            self.git("add", "-f", str(target / "data"))
                    result = self.run_apply(row, json_mode=mode, status=0 if scenario == "gone" else 1)
                    if mode:
                        item, = self.targets(result)
                        self.assertEqual(item["outcome"], scenario)
                    else:
                        self.assertIn({"gone": b"gone (verified absent)", "drift": b"fingerprint changed",
                                       "vetoed": b"tracked veto", "held": b"no longer eligible",
                                       "survived": b"survived; cleanup", "failed": b"activity-unavailable"}[scenario], result.stdout)
                    if scenario in ("held", "failed"):
                        self.assertTrue(self.present.exists())
                        self.assertNotIn("intercepted-kill", self.log.read_text())
                    self.transcript.write_text(json.dumps({"cwd": str(self.root)}) + "\n")

    def serializer_wrapper(self, body):
        self.tool("python3", body + "\nexec " + shlex.quote(sys.executable) + ' "$@"')

    def test_private_channel_setup_failure_precedes_cleanup(self):
        target, row = self.artifact()
        self.serializer_wrapper('if [ "${2:-}" = init ]; then : > "$3/child.jsonl"; fi')
        events = self.run_apply(row, status=2)
        self.assertEqual((events[0]["section"], events[0]["reason_code"]), ("apply_rejection", "event-setup-unavailable"))
        self.assertTrue(target.exists())
        self.assertFalse(list(Path(self.env["XDG_CACHE_HOME"]).rglob("actions.jsonl")))

    def test_event_write_failure_after_effect_preserves_journal(self):
        target, row = self.artifact()
        self.serializer_wrapper('if [ "${2:-}" = target ]; then echo "fixture event writer failed" >&2; exit 93; fi')
        self.plan.write_text(row)
        result = subprocess.run([BASH, str(self.cli), "apply", "--json", str(self.plan)], cwd=self.root, env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"fixture event writer failed", result.stderr)
        self.assertFalse(target.exists())
        journal = Path(self.env["XDG_CACHE_HOME"]) / "agent-processes/actions.jsonl"
        entry, = [json.loads(line) for line in journal.read_text().splitlines()]
        self.assertEqual((entry["operation"], entry["target"], entry["status"]), ("artifact.clean", str(target), "succeeded"))
        with self.assertRaisesRegex(ValueError, "stream-incomplete"):
            read_stream(result.stdout)

    def test_interrupted_run_has_no_completion_after_confirmed_effect(self):
        target, row = self.artifact()
        self.serializer_wrapper('if [ "${2:-}" = target ]; then touch "$APPLY_FIXTURE/paused"; /bin/sleep 30; fi')
        self.plan.write_text(row)
        process = subprocess.Popen([BASH, str(self.cli), "apply", "--json", str(self.plan)], cwd=self.root, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not (self.base / "paused").exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.base / "paused").exists(), "did not reach the post-mutation event writer")
            os.killpg(process.pid, signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0, errors)
            self.assertFalse(target.exists())
            with self.assertRaisesRegex(ValueError, "stream-incomplete"):
                read_stream(output)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_worktree_success_and_dirty_refusal(self):
        worktree = self.base / "worktree"
        self.git("worktree", "add", "-q", "--detach", str(worktree))
        # Independent capability probe; unsupported birth time is an explicit platform limit.
        probe = subprocess.run(["stat", "-c", "%w", str(worktree)], capture_output=True)
        if probe.returncode:
            probe = subprocess.run(["stat", "-f", "%.9FB", str(worktree)], capture_output=True)
        if probe.returncode or probe.stdout.strip() in (b"", b"-", b"0", b"0.000000000"):
            self.skipTest("filesystem has no creation identity")
        row = f"- [x] stale path {worktree}\n      type: worktree  fingerprint: {self.fingerprint('worktree', worktree)}  path: {worktree}\n"
        item, = self.targets(self.run_apply(row))
        self.assertEqual((item["outcome"], item["receipt_status"]), ("applied", "recorded"))
        self.assertFalse(worktree.exists())
        self.git("worktree", "add", "-q", "--detach", str(worktree))
        (worktree / "scratch").write_text("uncommitted")
        row = f"- [x] stale path {worktree}\n      type: worktree  fingerprint: {self.fingerprint('worktree', worktree)}  path: {worktree}\n"
        item, = self.targets(self.run_apply(row, status=1))
        self.assertEqual((item["outcome"], item["reason_code"]), ("vetoed", "dirty"))
        self.assertTrue(worktree.exists())
        (worktree / "scratch").unlink()
        real_git = shlex.quote(shutil.which("git"))
        self.env["APPLY_WORKTREE"] = str(worktree)
        self.tool("git", '''if [ "${3:-}" = worktree ] && [ "${4:-}" = remove ] && [ "${6:-}" = "$APPLY_WORKTREE" ]; then
  ''' + real_git + ''' "$@" || exit $?
  ln -s "$APPLY_FIXTURE/missing" "$APPLY_WORKTREE"
  exit $?
fi
exec ''' + real_git + ' "$@"')
        for mode in (False, True):
            with self.subTest(dangling_replacement=True, json=mode):
                if not worktree.exists():
                    self.git("worktree", "add", "-q", "--detach", str(worktree))
                row = f"- [x] stale path {worktree}\n      type: worktree  fingerprint: {self.fingerprint('worktree', worktree)}  path: {worktree}\n"
                result = self.run_apply(row, json_mode=mode, status=1)
                if mode:
                    item, = self.targets(result)
                    self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"], item["postcondition_confirmed"]),
                                     ("survived", "target-remains", True, False))
                else:
                    self.assertIn(b"survived removal", result.stdout)
                self.assertTrue(worktree.is_symlink())
                self.assertIn("worktree remove -- " + str(worktree), self.log.read_text())
                worktree.unlink()

    def test_failed_worktree_command_preserves_confirmed_path_absence(self):
        real_git = shlex.quote(shutil.which("git"))
        self.tool("git", '''if [ "${3:-}" = worktree ] && [ "${4:-}" = remove ]; then
  ''' + real_git + ''' "$@" || exit $?
  echo 'fixture worktree bookkeeping failed' >&2
  exit 17
fi
exec ''' + real_git + ' "$@"')
        for mode in (False, True):
            with self.subTest(json=mode):
                worktree = self.base / ("failed-worktree-" + str(mode))
                self.git("worktree", "add", "-q", "--detach", str(worktree))
                probe = subprocess.run(["stat", "-c", "%w", str(worktree)], capture_output=True)
                if probe.returncode:
                    probe = subprocess.run(["stat", "-f", "%.9FB", str(worktree)], capture_output=True)
                if probe.returncode or probe.stdout.strip() in (b"", b"-", b"0", b"0.000000000"):
                    self.skipTest("filesystem has no creation identity")
                row = f"- [x] stale path {worktree}\n      type: worktree  fingerprint: {self.fingerprint('worktree', worktree)}  path: {worktree}\n"
                result = self.run_apply(row, json_mode=mode, status=1)
                self.assertIn("worktree remove -- " + str(worktree), self.log.read_text())
                self.assertFalse(worktree.exists())
                if mode:
                    item, = self.targets(result)
                    self.assertEqual((item["outcome"], item["reason_code"], item["mutation_attempted"], item["postcondition_confirmed"], item["receipt_status"]),
                                     ("failed", "removal-failed", True, True, "recorded"))
                    self.assertIn("exit status 17", item["detail"])
                    self.assertEqual((result[-2]["counts"]["applied"], result[-2]["counts"]["failed"]), (0, 1))
                else:
                    self.assertIn(b"removal failed after path disappeared", result.stdout)
                    self.assertIn(b"0 applied", result.stdout)
                journal = Path(self.env["XDG_CACHE_HOME"]) / "agent-processes/actions.jsonl"
                entry, = [record for record in map(json.loads, journal.read_text().splitlines())
                          if record["operation"] == "worktree.remove" and record["target"] == str(worktree)]
                self.assertEqual(entry["status"], "failed")
                self.assertIn("fixture worktree bookkeeping failed", entry["detail"])

    def test_truncated_tampered_and_inconsistent_streams_are_rejected(self):
        events = self.run_apply("")
        raw = b"".join(encoded(row) + b"\n" for row in events)
        for broken in (raw[:-1], b"\n".join(raw.splitlines()[:-1]) + b"\n", raw.replace(b'"checked_count":0', b'"checked_count":1')):
            with self.assertRaises(ValueError):
                read_stream(broken)
        forged = copy.deepcopy(events)
        forged[0]["plan_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "event-digest-mismatch"):
            read_stream(b"".join(encoded(row) + b"\n" for row in forged))
        target, row = self.artifact()
        events = self.run_apply(row)
        for field, value, reason in (("outcome", "invented", "invalid-target-outcome"),
                                     ("mutation_attempted", False, "unconfirmed-application"),
                                     ("receipt_status", "failed", "false-success")):
            changed = copy.deepcopy(events)
            changed[1][field] = value
            changed[-1]["events_sha256"] = digest(b"".join(encoded(r) + b"\n" for r in changed[:-1]))
            with self.assertRaisesRegex(ValueError, reason):
                read_stream(b"".join(encoded(r) + b"\n" for r in changed))
        for edit, reason in ((lambda records: records[1].pop("receipt_status"), "missing-result-field"),
                             (lambda records: records[-2]["counts"].update(applied=True), "target-count-mismatch"),
                             (lambda records: records[0].update(checked_count=True), "target-outcomes-incomplete"),
                             (lambda records: records[1].update(schema_version=True), "event-context-mismatch")):
            changed = copy.deepcopy(events)
            edit(changed)
            changed[-1]["events_sha256"] = digest(b"".join(encoded(r) + b"\n" for r in changed[:-1]))
            with self.assertRaisesRegex(ValueError, reason):
                read_stream(b"".join(encoded(r) + b"\n" for r in changed))

    def test_closed_stdout_stops_before_cleanup(self):
        target, row = self.artifact()
        self.plan.write_text(row)
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            result = subprocess.run([BASH, str(self.cli), "apply", "--json", str(self.plan)], cwd=self.root,
                                    env=self.env, stdout=write_fd, stderr=subprocess.PIPE)
        finally:
            os.close(write_fd)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"event output unavailable", result.stderr)
        self.assertTrue(target.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
