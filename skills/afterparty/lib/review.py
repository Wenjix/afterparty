"""Review state and save backend for the Bubble Tea terminal application."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unicodedata

from plan_data import SnapshotError, load_snapshot
from review_data import Review, save_review
from terminal_text import safe_text

LIB = Path(__file__).resolve().parent


def shell_word(value):
    if not any(unicodedata.category(char).startswith("C") for char in value):
        return shlex.quote(value)
    # Bash's ANSI-C quoting keeps control bytes out of the terminal while
    # preserving a copyable command, including on macOS's Bash 3.2.
    escaped = ""
    for char in value:
        if unicodedata.category(char).startswith("C"):
            escaped += "".join("\\%03o" % byte for byte in char.encode("utf-8"))
        else:
            escaped += "\\" + char if char in "\\'" else char
    return "$'" + escaped + "'"



def collect(plan_args, session):
    process = subprocess.Popen([str(LIB / "plan.sh"), "--json", *plan_args], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=dict(os.environ, AFTERPARTY_STYLE="never"), start_new_session=True)
    try:
        output, errors = process.communicate()
    except BaseException:
        # This group contains only our collector and its descendants. Keep
        # interrupted discovery from outliving the terminal session.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise
    if process.returncode not in (0, 1):
        raise SnapshotError("The scan failed: " + errors.decode("utf-8", "replace").strip())
    rows = load_snapshot(output)
    Path(session, "snapshot.jsonl").write_bytes(output)
    return rows


def interrupted(signum, _frame):
    raise KeyboardInterrupt



def emit(event):
    print(json.dumps(event, ensure_ascii=True, allow_nan=False), flush=True)


def emit_state(review, destination):
    emit({"event": "state", "scope": review.rows[0],
          "capabilities": [row for row in review.rows if row["section"] == "plan_capability"],
          "items": review.items, "focus": review.focus, "marked": sorted(review.marked),
          "visible_ids": [item["item_id"] for item in review.visible()],
          "query": review.query, "searching": review.searching, "expanded": review.expanded,
          "step": review.step, "message": review.message, "save_enabled": review.save_enabled,
          "saved_path": review.saved_path, "destination": destination,
          "reveal_focus": review.reveal_focus, "generation": review.generation,
          "ignored_keys": review.ignored_keys, "collecting": review.collecting,
          "message_kind": review.message_kind, "legend": review.legend(),
          "summary": review.summary(), "position_label": review.position_label(),
          "help_keys": review.help_keys(),
          "captured_at": review.rows[0]["observed_at"]})
    review.reveal_focus = False


def saved_lines(review):
    lines = ["Plan saved: " + safe_text(review.saved_path), "Marked targets:"]
    for item in review.items:
        if item["item_id"] not in review.marked:
            continue
        if item["type"] == "process-group":
            lines.append("  Stop process group " + item["target"] + ": " + safe_text(item["display_label"]))
        else:
            lines.append("  Remove " + item["type"] + ": " + safe_text(item["target"]))
    executable = "afterparty" if shutil.which("afterparty") else str(LIB.parent / "bin" / "afterparty")
    lines.extend(["Apply the plan with this command:", shell_word(executable) + " apply " + shell_word(review.saved_path)])
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--output", default="")
    options, plan_args = parser.parse_known_args()
    plan_args = plan_args[1:] if plan_args[:1] == ["--"] else plan_args
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(signum, interrupted)
    review = None
    try:
        if options.output and os.path.lexists(options.output):
            raise SnapshotError("The output file already exists. Move it before you retry, or use another --output path. (output-exists: " + options.output + ")")
        with tempfile.TemporaryDirectory(prefix="session-", dir=options.state_dir) as session:
            emit({"event": "scan", "collecting": True, "generation": 1})
            review = Review(collect(plan_args, session))
            destination = options.output or str(Path(options.state_dir, "plan-" + review.rows[0]["snapshot_id"] + ".md"))
            emit_state(review, destination)
            for line in sys.stdin:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise SnapshotError("invalid review input")
                key = request.get("key")
                if not isinstance(key, str) or not 1 <= len(key) <= 32:
                    raise SnapshotError("invalid review input")
                generation = request.get("generation", -1)
                if type(generation) is not int:
                    raise SnapshotError("invalid input generation")
                focus_visible = request.get("focus_visible", True)
                if type(focus_visible) is not bool:
                    raise SnapshotError("invalid focus visibility")
                if key == "IGNORED":
                    count = request.get("ignored_keys", 0)
                    if type(count) is not int or not 0 < count <= 1000000:
                        raise SnapshotError("invalid ignored-key count")
                    review.ignore_keys(count)
                    action = None
                else:
                    action = "cancel" if key == "CANCEL" else review.handle(key, generation, focus_visible)
                if action in ("cancel", "done", "finish"):
                    if review.saved_path:
                        lines = saved_lines(review)
                        status = 0
                    elif action == "finish":
                        lines = ["The review finished. Afterparty did not save a plan.",
                                 "The scan found no available targets."]
                        status = 0 if review.rows[0]["collection_status"] == "complete" else 1
                        if status:
                            lines.append("The scan is incomplete. Run afterparty review again to retry the unavailable checks.")
                    else:
                        lines = ["You canceled the review. Afterparty did not save a plan."]
                        status = 1
                    emit({"event": "done", "exit_code": status, "lines": lines})
                    return 0
                if action == "refresh":
                    emit_state(review, destination)
                    try:
                        review.finish_refresh(collect(plan_args, session))
                    except (OSError, ValueError) as exc:
                        review.say("The scan failed. Afterparty kept the previous results. Refresh to try again. (" + str(exc) + ")", "refused")
                    finally:
                        review.collecting = False
                elif action == "save":
                    try:
                        review.saved_path = save_review(review.rows, review.selection(), destination)
                        review.step = "saved"
                        review.scroll = 0
                        review.say("Afterparty saved the plan. It did not run cleanup.", "done")
                    except (OSError, ValueError) as exc:
                        detail = str(exc)
                        if detail.startswith("output-exists:"):
                            message = "The output file already exists. Move it before you retry, or restart with another --output path."
                        else:
                            message = "Afterparty could not save the plan. Refresh before you retry."
                        review.say(message + " (" + detail + ")", "refused")
                emit_state(review, destination)
        return 1
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 1
    except (OSError, ValueError) as exc:
        emit({"event": "error", "exit_code": 1, "lines": ["review: The review failed. Run afterparty review again. (" + safe_text(exc) + ")"]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
