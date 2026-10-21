"""Explicit review state and a no-clobber writer for captured Markdown plans."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from plan_data import SnapshotError, load_snapshot, require, validate


def save_review(rows, selection, destination):
    validate(rows)
    require(selection.get("snapshot_id") == rows[0]["snapshot_id"], "selection-snapshot-mismatch")
    marked = selection.get("marked_ids")
    require(isinstance(marked, list) and all(isinstance(ident, str) for ident in marked), "invalid-marked-ids")
    require(type(selection.get("mark_count")) is int and selection["mark_count"] == len(marked), "mark-count-mismatch")
    require(len(marked) > 0, "explicit-marks-required")
    require(len(set(marked)) == len(marked), "duplicate-marks")
    items = {row["item_id"]: row for row in rows if row["section"] == "plan_item"}
    lines = rows[-2]["text"].split("\n")
    expected = []
    for ident in marked:
        require(ident in items, "unknown-mark: " + ident)
        item = items[ident]
        require(item["availability"] == "available", "withheld-mark: " + ident)
        mapping = item["markdown"]
        line = mapping["header_line"] - 1
        require(lines[line].startswith("- [ ]") and mapping["checkbox_column"] == 4, "stale-mapping: " + ident)
        lines[line] = lines[line][:3] + "x" + lines[line][4:]
        kind = item["type"]
        expected.append((kind, item["target"], item["fingerprint"],
                         item["evidence"].get("category", "-") if kind == "process-group" else "-",
                         item["scope"] if kind == "artifact" else "-"))
    output = Path(destination).absolute()
    require(not os.path.lexists(output), "output-exists: " + str(output))
    fd, temporary = tempfile.mkstemp(prefix=".afterparty-plan-", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write("\n".join(lines).encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        parser = Path(__file__).with_name("plan-format.sh")
        result = subprocess.run(["bash", "-c", '. "$1"; plan_read_checked "$2"', "afterparty-review", parser.as_posix(), Path(temporary).as_posix()],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(result.returncode == 0, "checked-plan-rejected: " + result.stderr.decode("utf-8", "replace").strip())
        parsed = [tuple(line.split("\t")) for line in result.stdout.decode("utf-8").split("\n")[:-1]]
        require(sorted(parsed) == sorted(expected), "checked-target-mismatch")
        # Linking a private, fully written file is atomic and cannot replace an
        # existing file or symlink, including one created after the check above.
        os.link(temporary, output)
    finally:
        os.unlink(temporary)
    return str(output)


REASON_SENTENCES = {
    "protected": "A group member matches a protection pattern.",
    "gone": "Afterparty could not find the expected target.",
    "inspection-unavailable": "Afterparty could not complete the process protection check. Refresh to try again.",
    "mixed": "Afterparty cannot attribute all group members to one workspace.",
    "no-rule": "No supported cleanup category matches this command. Stop it manually if necessary.",
    "in-use": "The workspace has recent recorded activity.",
    "working": "The process group uses CPU despite older recorded activity.",
    "unknown": "Afterparty found no usable recorded activity. The last activity time is unknown.",
    "identity-unavailable": "Afterparty could not check the target's identity. Refresh to try again.",
    "occupied": "A live process has its working directory at or inside this target.",
    "occupancy-unavailable": "Afterparty could not complete the scan of process directories. Refresh to try again.",
    "ignored-local-data": "Ignored local files remain. Preserve them before removal.",
    "dirty": "Afterparty cannot confirm that this worktree has no uncommitted changes. Check Git status before you refresh.",
    "current": "This review uses the worktree.",
    "main-worktree": "This is the repository's main worktree.",
    "symlink": "This path is a symbolic link.",
    "unreachable": "Afterparty could not scan the target's physical directory. Check the path and access permissions.",
    "unreachable-scope": "Afterparty could not scan the scope's physical directory. Check the path and access permissions.",
    "broad-scope": "This scope is too broad for artifact removal.",
    "scope-root": "The target is the root directory for this scan.",
    "scope-escape": "The target's physical directory is outside the selected scope.",
    "repo-root": "This directory is a repository root.",
    "nested-repo": "This directory contains or belongs to another repository.",
    "tracked": "Git tracks the target or files inside it.",
    "scan-incomplete": "Afterparty could not complete a required scan. Refresh to try again.",
    "git-unavailable": "Afterparty could not complete the required Git checks. Refresh to try again.",
}


def reason_sentence(item):
    code, reason = item.get("reason_code", ""), item["reason"]
    sentence = REASON_SENTENCES.get(code) if item["availability"] != "available" else None
    sentence = sentence or (reason if reason != code else "The target did not pass the required safety checks. Refresh to try again.")
    sentence = sentence.rstrip(". ") + "."
    return sentence + (" (" + code + ")" if code and item["availability"] != "available" else "")


def counted(number, singular, plural=None):
    return f"{number} {singular if number == 1 else (plural or singular + 's')}"


def review_items(rows):
    """Decorate copies; the captured snapshot and its Markdown remain exact."""
    root = rows[0]["root"].rstrip("/")
    result = []
    for row in rows:
        if row["section"] != "plan_item":
            continue
        item = dict(row)
        if item["type"] == "process-group":
            ev = item["evidence"]
            command = ev.get("recorded_purpose") or next((m["command"] for m in ev.get("members", [])), "Command unavailable")
            label = command + " | PGID " + item["target"]
        elif item["target"].startswith(root + "/"):
            label = item["target"][len(root) + 1:]
        else:
            label = item["target"]
        item["display_label"] = label
        item["reason_sentence"] = reason_sentence(item)
        result.append(item)
    # Category order is shared with focus/navigation rather than imposed by a
    # renderer. Available rows precede withheld rows within each category.
    order = {"process-group": 0, "worktree": 1, "artifact": 2}
    result.sort(key=lambda item: (order[item["type"]], item["availability"] != "available",
                                 item["display_label"].casefold(), item["target"], item["item_id"]))
    labels = {}
    for item in result:
        labels.setdefault(item["display_label"], []).append(item)
    for duplicates in labels.values():
        if len(duplicates) > 1:
            for item in duplicates:
                item["display_label"] += " | " + item["type"] + " " + item["scope"]
    return result


class Review:
    def __init__(self, rows):
        validate(rows)
        self.rows = rows
        self.items = review_items(rows)
        self.focus = self.items[0]["item_id"] if self.items else None
        self.marked = set()
        self.query = ""
        self.searching = False
        self.search_before = ""
        self.expanded = False
        self.step = "choose"
        self.return_step = "choose"
        self.confirm_return = "choose"
        self.message = "Mark targets to include in the plan."
        self.message_kind = "info"
        self.save_enabled = True
        self.scroll = 0
        self.reveal_focus = True
        self.saved_path = None
        self.generation = 1
        self.ignored_keys = 0
        self.collecting = False

    def say(self, message, kind="info"):
        self.message, self.message_kind = message, kind

    def visible(self):
        query = self.query.casefold()
        return [item for item in self.items if query in " ".join(
            [item["target"], item["type"], item["display_label"], item["reason_sentence"]]
            + [member["command"] for member in item["evidence"].get("members", [])]
        ).casefold()]

    def active_items(self):
        step = self.return_step if self.step == "help" else self.step
        if step in ("review", "save", "saved"):
            return [item for item in self.items if item["item_id"] in self.marked]
        return self.visible()

    def focused(self):
        return next((item for item in self.active_items() if item["item_id"] == self.focus), None)

    def retain_visible_focus(self):
        visible = self.active_items()
        if self.focus not in {item["item_id"] for item in visible}:
            self.focus = visible[0]["item_id"] if visible else None

    def position_label(self):
        items = self.active_items()
        for index, item in enumerate(items):
            if item["item_id"] == self.focus:
                return f"Target {index + 1} of {len(items)}: {item['display_label']}"
        return "No matching targets" if self.items else "No targets"

    def summary(self):
        items = [item for item in self.items if item["item_id"] in self.marked]
        groups = [item for item in items if item["type"] == "process-group"]
        members = sum(len(item["evidence"].get("members", [])) for item in groups)
        return [counted(len(groups), "process group") + " · " + counted(members, "member"),
                counted(sum(item["type"] == "worktree" for item in items), "worktree"),
                counted(sum(item["type"] == "artifact" for item in items), "artifact")]

    def legend(self, step=None):
        def keys(*pairs):
            return [{"key": key, "label": label} for key, label in pairs]
        searching = self.searching if step is None else False
        step = self.step if step is None else step
        if searching:
            return keys(("Enter", "finish filter"), ("Esc", "restore filter"), ("Ctrl+C", "exit"))
        if step == "confirm_quit":
            return keys(("q/Enter", "unmark and quit"), ("Esc", "continue review"))
        if step == "confirm_refresh":
            return keys(("r/Enter", "unmark and refresh"), ("Esc", "continue review"))
        if step == "help":
            return keys(("q/Esc/?", "back"), ("PgUp/PgDn", "scroll"))
        if step == "saved":
            return keys(("Enter/q", "finish"), ("d", "details"), ("?", "help"))
        if step == "save":
            return keys(("Enter", "Save plan"), ("Esc", "Review choices"), ("q", "quit"), ("?", "help"))
        if step == "review":
            return keys(("Enter", "Continue to Save plan"), ("Space", "unmark"), ("Up/Down", "focus (j/k)"),
                        ("d", "details"), ("Esc", "Choose"), ("q", "quit"), ("?", "help"))
        if step == "evidence":
            return keys(("Space", "mark/unmark"), ("Enter", "Review choices"), ("Up/Down", "focus (j/k)"),
                        ("PgUp/PgDn", "scroll"), ("q/Esc", "Choose"), ("?", "help"))
        enter = "Review choices" if any(item["availability"] == "available" for item in self.items) else "Finish review (no plan)"
        return keys(("Space", "mark/unmark"), ("Enter", enter), ("Up/Down", "focus (j/k)"), ("i", "inspect"),
                    ("d", "details"), ("/", "filter"), ("r", "refresh"), ("q", "quit"), ("?", "help"))

    def help_keys(self):
        step = self.return_step if self.step == "help" else self.step
        entries = self.legend(step)
        extras = [("PgUp/PgDn", "scroll. Keep target focus"),
                  ("Ctrl+Z", "suspend. Use fg to resume"), ("Ctrl+C", "exit without a new plan")]
        if step in ("choose", "evidence"):
            extras.append(("s", "Review choices"))
        if step not in ("saved", "confirm_quit", "confirm_refresh"):
            extras.extend([("r", "refresh. Confirm before unmarking"), ("Esc", "return. Keep marks")])
            if step != "evidence":
                extras.append(("d", "show or hide details"))
        existing = {entry["key"] for entry in entries}
        entries.extend({"key": key, "label": label} for key, label in extras if key not in existing)
        return entries

    def selection(self):
        return {"snapshot_id": self.rows[0]["snapshot_id"], "marked_ids": sorted(self.marked), "mark_count": len(self.marked)}

    def ignore_keys(self, count=1):
        self.ignored_keys += count
        noun = "key" if self.ignored_keys == 1 else "keys"
        self.say(f"Afterparty ignored {self.ignored_keys} {noun} during the scan.")

    def begin_refresh(self):
        self.marked.clear()
        self.save_enabled = False
        self.collecting = True
        self.generation += 1
        self.step = "choose"
        self.say("Afterparty unmarked all targets. A new scan starts. (marks-cleared)")
        self.scroll = 0

    def finish_refresh(self, rows):
        validate(rows)
        require(rows[0]["root"] == self.rows[0]["root"] and rows[0]["flags"] == self.rows[0]["flags"], "refresh-scope-mismatch")
        self.rows = rows
        self.items = review_items(rows)
        visible = self.visible()
        self.focus = visible[0]["item_id"] if visible else None
        self.save_enabled = True
        self.collecting = False
        self.marked.clear()
        self.say("The scan finished. Mark targets again. (marks-cleared)", "done")
        self.reveal_focus = True

    def handle(self, key, generation=None, focus_visible=True):
        if key in (" ", "ENTER", "s") and generation is not None and generation != self.generation:
            self.ignore_keys()
            return None
        if self.step in ("confirm_quit", "confirm_refresh"):
            if key == "ESC":
                self.step = self.confirm_return
                self.say(f"You kept {counted(len(self.marked), 'mark')}. Continue the review.")
            elif key == "ENTER" or key == ("q" if self.step == "confirm_quit" else "r"):
                if self.step == "confirm_quit":
                    return "cancel"
                self.begin_refresh()
                return "refresh"
            return None
        if self.searching:
            if key == "ESC":
                self.query = self.search_before
                self.searching = False
            elif key == "ENTER":
                self.searching = False
            elif key == "BACKSPACE":
                self.query = self.query[:-1]
            elif len(key) == 1 and key.isprintable():
                self.query += key
            visible = self.visible()
            if self.focus not in {item["item_id"] for item in visible}:
                self.focus = visible[0]["item_id"] if visible else None
            self.reveal_focus = True
            return None
        if key == "PASTE":
            self.say("Afterparty ignored the paste. Press one key at a time.")
            return None
        if key == "q":
            if self.step == "help":
                self.step = self.return_step
            elif self.step == "evidence":
                self.step = "choose"
            elif self.saved_path:
                return "done"
            elif self.marked:
                self.confirm_return, self.step = self.step, "confirm_quit"
                self.say(f"Unmark {counted(len(self.marked), 'target')} and quit? Press q or Enter. Esc returns to the review.")
            else:
                return "cancel"
            self.retain_visible_focus()
            self.scroll = 0
            self.reveal_focus = True
        elif self.step == "saved" and key in ("ENTER", "ESC"):
            return "done"
        elif key == "r" and not self.saved_path:
            if self.marked:
                self.confirm_return, self.step = self.step, "confirm_refresh"
                self.say(f"Unmark {counted(len(self.marked), 'target')} and refresh? Press r or Enter. Esc returns to the review.")
            else:
                self.begin_refresh()
                return "refresh"
        elif key == "?":
            if self.step == "help":
                self.step = self.return_step
            else:
                self.return_step, self.step = self.step, "help"
            self.scroll = 0
        elif key == "ESC":
            if self.step == "help":
                self.step = self.return_step
            elif self.step == "save":
                self.step = "review"
            else:
                self.step = "choose"
            self.retain_visible_focus()
            self.scroll = 0
            self.reveal_focus = True
        elif key == "d" and self.step in ("choose", "review", "save", "saved"):
            self.expanded = not self.expanded
            self.say(("Details are visible." if self.expanded else "Details are hidden.") + f" {len(self.marked)} marked.")
            self.reveal_focus = True
        elif key == "/" and self.step == "choose":
            self.searching = True
            self.search_before = self.query
        elif key in ("DOWN", "j", "UP", "k") and self.step in ("choose", "evidence", "review"):
            visible = self.active_items()
            if visible:
                index = next((i for i, item in enumerate(visible) if item["item_id"] == self.focus), 0)
                index = max(0, min(len(visible) - 1, index + (1 if key in ("DOWN", "j") else -1)))
                self.focus = visible[index]["item_id"]
                self.reveal_focus = True
        elif key == " " and self.step in ("choose", "evidence", "review"):
            item = self.focused()
            if not focus_visible:
                self.reveal_focus = True
                self.say("The target is visible. Press Space to mark or unmark it.")
            elif item and item["availability"] == "available" and self.save_enabled:
                index = self.active_items().index(item)
                label = "PGID " + item["target"] if item["type"] == "process-group" else item["display_label"]
                if self.focus in self.marked:
                    self.marked.remove(self.focus)
                    self.say(f"You unmarked {label}. {len(self.marked)} marked.", "done")
                    if self.step == "review":
                        remaining = self.active_items()
                        if remaining:
                            self.focus = remaining[min(index, len(remaining) - 1)]["item_id"]
                        else:
                            self.step = "choose"
                            self.retain_visible_focus()
                else:
                    self.marked.add(self.focus)
                    self.say(f"You marked {label}. {len(self.marked)} marked.", "done")
                self.reveal_focus = True
            elif item:
                self.say("Withheld: " + item["reason_sentence"] if self.save_enabled else "The scan failed. Refresh before you save the plan.", "refused")
            else:
                self.say("No target has focus. Change the filter or refresh the scan.", "refused")
        elif key == "i" and self.step == "choose" and self.focused():
            self.step = "evidence"
            self.scroll = 0
            self.reveal_focus = True
        elif key in ("s", "ENTER") and self.step in ("choose", "evidence"):
            if not self.marked:
                if key == "ENTER" and not any(item["availability"] == "available" for item in self.items):
                    return "finish"
                self.say("Press Space to mark a target before you continue. (explicit-marks-required)", "refused")
            elif not self.save_enabled:
                self.say("Refresh before you save the plan.", "refused")
            else:
                self.step = "review"
                self.expanded = False
                self.focus = next(item["item_id"] for item in self.items if item["item_id"] in self.marked)
                self.scroll = 0
                self.reveal_focus = True
                self.say(f"Review {counted(len(self.marked), 'marked target')}. Press Space to unmark a target.")
        elif key == "ENTER":
            if self.step == "review" and self.marked:
                self.step = "save"
                self.scroll = 0
            elif self.step == "save" and self.marked and self.save_enabled:
                return "save"
        return None


def main():
    try:
        snapshot, choices, destination = sys.argv[1:]
        rows = load_snapshot(Path(snapshot).read_bytes())
        selection = json.loads(Path(choices).read_text(encoding="utf-8"))
        print(save_review(rows, selection, destination))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("review: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
