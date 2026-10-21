"""Deterministic review interaction tests; no collector or cleanup tool runs."""

import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
REPO = Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "skills/afterparty/lib"))
import plan_data
import review
from review_data import Review


def snapshot():
    common = dict(contract=plan_data.CONTRACT, schema_version=1, snapshot_id="a" * 32)
    rows = [dict(common, section="plan_scope", root="/work/project", observed_at="2026-10-18T18:30:00+00:00",
                 flags={"all": False, "artifacts_only": False, "caches_only": False}, collection_status="complete")]
    # Deliberately scrambled across type and availability so navigation must
    # enter the backend's sorting path rather than inherit the fixture order.
    targets = [("artifact", "/work/project/other/dist", "available", "safe"),
               ("worktree", "/work/project-wt", "withheld", "occupied"),
               ("process-group", "9900", "withheld", "protected"),
               ("artifact", "/work/project/deep/dist", "available", "safe"),
               ("process-group", "9001", "available", "eligible"),
               ("worktree", "/work/available-wt", "available", "safe"),
               ("artifact", "/work/project/tracked/dist", "withheld", "tracked")]
    lines = []
    for index, (kind, target, availability, code) in enumerate(targets):
        header = ("- [ ] " if availability == "available" else "- [⊘] ") + kind + " " + target
        lines.append(header)
        evidence = {"size_display": "12 MB"}
        if kind == "process-group":
            evidence = {"cpu_max": 0.1, "recorded_purpose": "dev server", "category": "dev",
                        "members": [{"pid": int(target), "command": "dev server"},
                                    {"pid": int(target) + 1, "command": "worker --watch"}],
                        "activity": {"status": "known", "idle_seconds": 86400, "sources": ["codex-session"]}}
        rows.append(dict(common, section="plan_item", item_id=plan_data.item_id(kind, target, "/work/project"),
                         type=kind, target=target, scope="/work/project", fingerprint="abcd" if availability == "available" else None,
                         availability=availability, reason=code, reason_code=code, selected=False,
                         consequence="Stop every group member." if kind == "process-group" else "Remove this directory.",
                         evidence=evidence, markdown={"header_line": index + 1, "checkbox_column": 4 if availability == "available" else None,
                                                     "header_sha256": plan_data.digest(header.encode())}))
    text = "\n".join(lines) + "\n"
    rows.append(dict(common, section="plan_document", text=text, sha256=plan_data.digest(text.encode())))
    rows.append(dict(common, section="plan_complete", snapshot_sha256=plan_data.digest(plan_data.encoded(rows)),
                     counts={"items": 7, "available": 4, "withheld": 3}, sections={}, collection_status="complete"))
    plan_data.validate(rows)
    return rows


class BackendInteractionTests(unittest.TestCase):
    def test_filter_matches_displayed_process_names_and_member_commands(self):
        state = Review(snapshot())
        self.assertEqual(len(state.visible()), 7)
        groups = {item["item_id"] for item in state.items if item["type"] == "process-group"}
        for query in ("dev server", "worker --watch", "DEV SERVER"):
            with self.subTest(query=query):
                state.query = query
                self.assertEqual({item["item_id"] for item in state.visible()}, groups)

    def test_backend_order_is_navigation_order_and_source_stays_exact(self):
        rows = snapshot()
        before = copy.deepcopy(rows)
        state = Review(rows)
        self.assertEqual([(item["type"], item["availability"]) for item in state.items],
                         [("process-group", "available"), ("process-group", "withheld"),
                          ("worktree", "available"), ("worktree", "withheld"),
                          ("artifact", "available"), ("artifact", "available"), ("artifact", "withheld")])
        self.assertEqual(state.focus, state.items[0]["item_id"])
        state.handle("j")
        self.assertEqual(state.focus, state.items[1]["item_id"])
        self.assertEqual(rows, before)
        self.assertEqual(len({item["display_label"] for item in state.items}), len(state.items))

    def test_stale_mutating_keys_are_counted_and_navigation_survives(self):
        state = Review(snapshot())
        first_generation = state.generation
        state.begin_refresh()
        state.finish_refresh(snapshot())
        self.assertEqual(state.generation, first_generation + 1)
        for key in (" ", "ENTER", "s"):
            self.assertIsNone(state.handle(key, first_generation))
        self.assertEqual(state.ignored_keys, 3)
        self.assertIn("Afterparty ignored 3 keys", state.message)
        self.assertEqual(state.marked, set())
        self.assertEqual(state.step, "choose")
        before = state.focus
        state.handle("j", first_generation)
        self.assertNotEqual(state.focus, before)
        state.handle("k", first_generation)
        state.handle(" ", state.generation)
        self.assertIn(before, state.marked, "a fresh Space must still reach marking")

    def test_paged_away_focus_is_revealed_before_space_can_mark_it(self):
        state = Review(snapshot())
        state.reveal_focus = False
        state.handle(" ", state.generation, focus_visible=False)
        self.assertTrue(state.reveal_focus)
        self.assertIn("The target is visible", state.message)
        self.assertEqual(state.marked, set())
        state.handle(" ", state.generation, focus_visible=True)
        self.assertEqual(state.marked, {state.focus})
        self.assertIn("PGID " + state.focused()["target"], state.message)

    def test_position_counts_only_the_filtered_list(self):
        state = Review(snapshot())
        state.query = "dist"
        state.focus = state.visible()[1]["item_id"]
        self.assertEqual(len(state.visible()), 3)
        self.assertTrue(state.position_label().startswith("Target 2 of 3: "), state.position_label())
        self.assertIn("other/dist", state.position_label())

    def test_quit_with_marks_asks_and_esc_preserves_the_draft(self):
        state = Review(snapshot())
        state.handle(" ")
        selected = state.marked.copy()
        self.assertIsNone(state.handle("q"))
        self.assertEqual(state.step, "confirm_quit")
        self.assertIn("Unmark 1 target", state.message)
        self.assertEqual(state.marked, selected)
        state.handle("ESC")
        self.assertEqual(state.step, "choose")
        self.assertEqual(state.marked, selected)
        state.handle("q")
        self.assertEqual(state.handle("q"), "cancel")

    def test_refresh_requires_confirmation_before_clearing_marks(self):
        state = Review(snapshot())
        state.handle(" ")
        generation, selected = state.generation, state.marked.copy()
        self.assertIsNone(state.handle("r"))
        self.assertEqual(state.step, "confirm_refresh")
        self.assertEqual(state.marked, selected)
        self.assertEqual(state.generation, generation)
        state.handle("ESC")
        self.assertEqual(state.marked, selected)
        state.handle("r")
        self.assertEqual(state.handle("ENTER", generation), "refresh")
        self.assertTrue(state.collecting)
        self.assertEqual(state.marked, set())
        self.assertEqual(state.generation, generation + 1)

    def test_q_in_help_or_inspect_only_closes_that_view(self):
        state = Review(snapshot())
        state.handle(" ")
        selected = state.marked.copy()
        for opening, expected in (("i", "evidence"), ("?", "help")):
            state.handle(opening)
            self.assertEqual(state.step, expected)
            self.assertIsNone(state.handle("q"))
            self.assertEqual(state.step, "choose")
            self.assertEqual(state.marked, selected)

    def test_review_summary_unmark_navigation_and_details(self):
        state = Review(snapshot())
        available = [item for item in state.items if item["availability"] == "available"]
        for item in available:
            state.focus = item["item_id"]
            state.handle(" ")
        state.expanded = True
        state.handle("ENTER")
        self.assertEqual(state.step, "review")
        self.assertFalse(state.expanded)
        self.assertEqual(state.summary(), ["1 process group · 2 members", "1 worktree", "2 artifacts"])
        self.assertEqual(state.focus, available[0]["item_id"])
        state.handle("j")
        self.assertEqual(state.focus, available[1]["item_id"])
        state.handle(" ")
        self.assertNotIn(available[1]["item_id"], state.marked)
        self.assertEqual(state.step, "review")
        state.handle("d")
        self.assertTrue(state.expanded)
        while state.step == "review":
            state.handle(" ")
        self.assertEqual(state.step, "choose")
        self.assertEqual(state.marked, set())

    def test_inspection_keeps_full_details_without_advertising_a_toggle(self):
        state = Review(snapshot())
        state.handle("d")
        self.assertTrue(state.expanded)
        state.handle("i")
        self.assertEqual(state.step, "evidence")
        before_message = state.message
        state.handle("d")
        self.assertTrue(state.expanded)
        self.assertEqual(state.message, before_message)
        state.handle("?")
        self.assertEqual(state.return_step, "evidence")
        keys = {entry["key"] for entry in state.help_keys()}
        self.assertIn("PgUp/PgDn", keys)
        self.assertNotIn("d", keys)
        state.handle("q")
        state.handle("q")
        self.assertEqual(state.step, "choose")
        state.handle("d")
        self.assertFalse(state.expanded)

    def test_return_from_review_restores_focus_inside_the_filter(self):
        state = Review(snapshot())
        state.handle(" ")
        selected = state.focus
        state.query = "dist"
        state.focus = state.visible()[0]["item_id"]
        for closing in ("ESC", " "):
            state.handle("ENTER")
            self.assertEqual(state.step, "review")
            self.assertEqual(state.focus, selected)
            state.handle(closing)
            self.assertEqual(state.step, "choose")
            self.assertIn(state.focus, {item["item_id"] for item in state.visible()})
        self.assertEqual(state.marked, set())

    def test_withheld_sentences_explain_then_name_the_code(self):
        state = Review(snapshot())
        for code, sentence in (("occupied", "A live process"), ("tracked", "Git tracks"), ("protected", "A group member")):
            item = next(item for item in state.items if item["reason_code"] == code)
            self.assertTrue(item["reason_sentence"].startswith(sentence), item)
            self.assertTrue(item["reason_sentence"].endswith("(" + code + ")"), item)
            state.focus = item["item_id"]
            state.handle(" ")
            self.assertEqual(state.message_kind, "refused")
            self.assertIn(sentence, state.message)
            self.assertEqual(state.marked, set())

    def test_contextual_keys_match_each_step(self):
        state = Review(snapshot())
        self.assertIn("/", [entry["key"] for entry in state.legend()])
        state.handle("/")
        self.assertNotIn("d", [entry["key"] for entry in state.legend()])
        state.handle("ESC")
        state.handle(" ")
        state.handle("ENTER")
        legend = {entry["key"]: entry["label"] for entry in state.legend()}
        self.assertEqual(legend["Space"], "unmark")
        self.assertNotIn("/", legend)
        state.handle("ENTER")
        self.assertNotIn("Space", [entry["key"] for entry in state.legend()])

    def test_protocol_emits_generation_and_accounts_for_loading_keys(self):
        requests = [{"key": "IGNORED", "generation": 1, "ignored_keys": 4},
                    {"key": " ", "generation": 0}, {"key": " ", "generation": 1},
                    {"key": "CANCEL", "generation": 1}]
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary, patch.object(sys, "argv", ["review.py", "--state-dir", temporary]), \
                patch.object(sys, "stdin", io.StringIO("\n".join(map(json.dumps, requests)) + "\n")), \
                contextlib.redirect_stdout(output), patch.object(review, "collect", return_value=snapshot()):
            self.assertEqual(review.main(), 0)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[0], {"event": "scan", "collecting": True, "generation": 1})
        states = [event for event in events if event["event"] == "state"]
        self.assertEqual([event["ignored_keys"] for event in states], [0, 4, 5, 5])
        self.assertEqual(len(states[-1]["marked"]), 1)
        self.assertTrue(all(event["generation"] == 1 for event in states))
        self.assertEqual(events[-1]["event"], "done")

    def test_saved_exit_lists_choices_and_copyable_absolute_command(self):
        state = Review(snapshot())
        state.handle(" ")
        state.saved_path = "/private/plans/selected plan.md"
        with patch.object(review.shutil, "which", return_value=None):
            lines = review.saved_lines(state)
        self.assertIn("Marked targets:", lines)
        self.assertTrue(any("Stop process group 9001" in line for line in lines))
        self.assertEqual(lines[-2], "Apply the plan with this command:")
        self.assertIn("/bin/afterparty apply ", lines[-1])
        self.assertTrue(lines[-1].endswith("'/private/plans/selected plan.md'"))
        self.assertTrue(Path(lines[-1].split(" apply ")[0].strip("'")).is_absolute())
        with patch.object(review.shutil, "which", return_value="/usr/local/bin/afterparty"):
            self.assertEqual(review.saved_lines(state)[-1], "afterparty apply '/private/plans/selected plan.md'")


if __name__ == "__main__":
    unittest.main()
