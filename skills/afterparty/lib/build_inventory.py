"""Read-only, bounded build-output inventory and its terminal review protocol."""

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile

from terminal_text import safe_text

VERSION = 1
LIB = Path(__file__).resolve().parent
PRUNED = {".git", "node_modules", ".venv", "target", "vendor"}
KINDS = {"cache", "build", "test"}


def encoded(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def stamp(value=None):
    return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).isoformat() if value is not None else datetime.datetime.now(datetime.timezone.utc).isoformat()


def valid_stamp(value):
    if not isinstance(value, str):
        return False
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).tzinfo is not None
    except ValueError:
        return False


def inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def identity(repository, path):
    return hashlib.sha256(encoded([repository, path])).hexdigest()


def load_registry():
    raw = (LIB / "artifact-kinds.tsv").read_bytes()
    directories, files, names = {}, [], set()
    for line in raw.decode("utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError("The artifact registry contains an invalid entry.")
        entry_type, name, kind = fields
        literal = name[2:] if entry_type == "file" and name.startswith("*.") else name
        if (entry_type not in {"directory", "file"} or not re.fullmatch(r"[A-Za-z0-9._-]+", literal)
                or kind not in KINDS or name in names):
            raise ValueError("The artifact registry contains an unsupported or duplicate entry.")
        names.add(name)
        if entry_type == "directory":
            directories[name] = kind
        else:
            files.append((name, kind))
    if not directories or not files:
        raise ValueError("The artifact registry is incomplete.")
    return directories, files, hashlib.sha256(raw).hexdigest()


def add_issue(issues, path, message):
    item = {"path": str(path), "message": str(message)}
    if item not in issues:
        issues.append(item)


def normalized_roots(roots, issues):
    result = set()
    for raw in roots:
        path = os.path.realpath(os.path.abspath(raw))
        result.add(path)
        try:
            if not stat.S_ISDIR(os.stat(path).st_mode):
                raise OSError("The project root is not a directory.")
        except OSError as exc:
            add_issue(issues, path, "Project root unavailable: " + str(exc))
    return sorted(result)


def entries(path, issues):
    try:
        if stat.S_ISLNK(os.lstat(path).st_mode):
            raise OSError("The directory became a symbolic link during inspection.")
        with os.scandir(path) as iterator:
            return sorted(iterator, key=lambda entry: entry.name)
    except OSError as exc:
        add_issue(issues, path, "Directory inspection failed: " + str(exc))
        return None


def git_repository(path, issues):
    try:
        result = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0"), timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        add_issue(issues, path, "Git repository inspection failed: " + str(exc))
        return None
    if result.returncode:
        add_issue(issues, path, "Git repository inspection failed: " + result.stderr.decode("utf-8", "replace").strip())
        return None
    try:
        raw_root = result.stdout[:-1] if result.stdout.endswith(b"\n") else result.stdout
        root = os.path.realpath(os.fsdecode(raw_root))
        if root != path:
            raise ValueError("The Git top level differs from the discovered directory.")
        return root
    except (ValueError, UnicodeError) as exc:
        add_issue(issues, path, "Git repository inspection failed: " + str(exc))
        return None


def discover_repositories(roots, max_depth, directories, issues):
    found, visited = set(), {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        stack = [(root, 0)]
        while stack:
            path, depth = stack.pop()
            remaining = max_depth - depth
            if visited.get(path, -1) >= remaining:
                continue
            visited[path] = remaining
            listing = entries(path, issues)
            if listing is None:
                continue
            marker = next((entry for entry in listing if entry.name == ".git"), None)
            if marker is not None:
                if marker.is_symlink():
                    add_issue(issues, path, "The Git marker is a symbolic link; repository inspection is unavailable.")
                elif (repository := git_repository(path, issues)) is not None:
                    found.add(repository)
            # The explicit starting directory is inspected before its name is
            # pruned, so a repository itself can legitimately be named build.
            if depth >= max_depth or (depth > 0 and Path(path).name in directories):
                continue
            children = []
            for entry in listing:
                if entry.name in PRUNED:
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False):
                        children.append(entry.path)
                except OSError as exc:
                    add_issue(issues, entry.path, "Directory type inspection failed: " + str(exc))
            stack.extend((child, depth + 1) for child in reversed(children))
    return sorted(found)


def artifact_candidates(repository, directories, files, issues):
    found, stack = [], [repository]
    while stack:
        path = stack.pop()
        listing = entries(path, issues)
        if listing is None:
            continue
        # Every physical worktree owns its own output. Never attribute nested
        # repositories to an enclosing repository, even beyond discovery depth.
        if path != repository and any(entry.name == ".git" for entry in listing):
            continue
        for entry in reversed(listing):
            if entry.name == ".git" or entry.is_symlink():
                continue
            try:
                if entry.is_dir(follow_symlinks=False):
                    if entry.name == "node_modules":
                        if ".cache" not in directories:
                            continue
                        cache = Path(entry.path, ".cache")
                        try:
                            info = cache.lstat()
                        except FileNotFoundError:
                            continue
                        if stat.S_ISDIR(info.st_mode):
                            found.append((str(cache), directories[".cache"]))
                    elif entry.name in PRUNED:
                        continue
                    elif entry.name in directories:
                        # An artifact-named repository is still a repository.
                        if not os.path.lexists(Path(entry.path, ".git")):
                            found.append((entry.path, directories[entry.name]))
                    else:
                        stack.append(entry.path)
                elif entry.is_file(follow_symlinks=False):
                    for pattern, kind in files:
                        if fnmatch.fnmatchcase(entry.name, pattern):
                            found.append((entry.path, kind))
                            break
            except OSError as exc:
                add_issue(issues, entry.path, "Artifact discovery failed: " + str(exc))
    return sorted(set(found))


def allocated_size(path, issues):
    total, newest, seen, stack = 0, None, set(), [path]
    while stack:
        current = stack.pop()
        try:
            info = os.lstat(current)
            if not hasattr(info, "st_blocks"):
                raise OSError("Allocated-byte evidence is unavailable on this platform.")
            key = (info.st_dev, info.st_ino)
            if key in seen:
                continue
            seen.add(key)
            total += info.st_blocks * 512
            newest = max(newest, info.st_mtime) if newest is not None else info.st_mtime
            if stat.S_ISDIR(info.st_mode):
                listing = entries(current, issues)
                if listing is None:
                    return None, None
                if any(entry.name == ".git" for entry in listing):
                    add_issue(issues, path, "This output contains a repository boundary; its allocated size is unavailable.")
                    return None, None
                stack.extend(entry.path for entry in listing)
        except (OSError, ValueError, OverflowError) as exc:
            add_issue(issues, current, "Allocated-size inspection failed: " + str(exc))
            return None, None
    try:
        return total, stamp(newest)
    except (ValueError, OverflowError, OSError) as exc:
        add_issue(issues, path, "Modification-time inspection failed: " + str(exc))
        return None, None


def repository_labels(roots):
    parts = {root: Path(root).parts for root in roots}
    labels = {}
    for root, components in parts.items():
        for length in range(1, len(components) + 1):
            label = os.path.join(*components[-length:])
            if all(other == root or os.path.join(*other_parts[-length:]) != label for other, other_parts in parts.items()):
                labels[root] = label
                break
    return labels


def scan(roots, max_depth, directories, files, issues):
    repositories, candidates = [], []
    for repository in discover_repositories(roots, max_depth, directories, issues):
        before = len(issues)
        paths = artifact_candidates(repository, directories, files, issues)
        repositories.append({"root": repository, "label": repository, "status": "complete"})
        for path, kind in paths:
            physical = os.path.realpath(path)
            if physical != path or not inside(physical, repository):
                add_issue(issues, path, "The output path changed physical scope during discovery.")
                continue
            candidates.append((repository, physical, kind))
        if len(issues) != before:
            repositories[-1]["status"] = "unavailable"
    # Parent output already covers its descendants. Root aliases and overlap
    # between supplied project scopes must not duplicate rows or their sizes.
    candidates.sort(key=lambda candidate: (len(Path(candidate[1]).parts), candidate[1], candidate[0]))
    selected, seen_paths = [], []
    for candidate in candidates:
        repository, path, _kind = candidate
        if any(path == previous or (owner == repository and inside(path, previous)) for owner, previous in seen_paths):
            continue
        selected.append(candidate)
        seen_paths.append((repository, path))
    items = []
    repo_map = {repository["root"]: repository for repository in repositories}
    for repository, path, kind in selected:
        before, modified = len(issues), None
        try:
            info = os.lstat(path)
            modified = stamp(info.st_mtime)
            if stat.S_ISLNK(info.st_mode):
                raise OSError("The output path became a symbolic link during inspection.")
        except (OSError, ValueError, OverflowError) as exc:
            add_issue(issues, path, "Modification-time inspection failed: " + str(exc))
        size, modified = allocated_size(path, issues) if len(issues) == before else (None, modified)
        status = "complete" if size is not None else "unavailable"
        if status != "complete":
            repo_map[repository]["status"] = "unavailable"
        items.append({"item_id": identity(repository, path), "repository": repository, "path": path,
                      "relative_path": os.path.relpath(path, repository), "kind": kind,
                      "size_bytes": size, "delta_bytes": None, "modified_at": modified, "status": status})
    items.sort(key=lambda item: (item["size_bytes"] is None, -(item["size_bytes"] or 0), item["repository"], item["path"]))
    labels = repository_labels([repository["root"] for repository in repositories])
    for repository in repositories:
        repository["label"] = labels[repository["root"]]
    return repositories, items


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate history field: " + key)
        result[key] = value
    return result


def validate_baseline(value, scope):
    if (not isinstance(value, dict) or type(value.get("schema_version")) is not int
            or value.get("schema_version") != VERSION or value.get("scope") != scope):
        raise ValueError("History scope or version does not match this inventory.")
    report = value.get("snapshot")
    if not isinstance(report, dict) or value.get("sha256") != hashlib.sha256(encoded(report)).hexdigest():
        raise ValueError("History integrity validation failed.")
    if (type(report.get("schema_version")) is not int or report.get("schema_version") != VERSION
            or report.get("roots") != scope["roots"] or type(report.get("max_depth")) is not int
            or report.get("max_depth") != scope["max_depth"] or report.get("collection_status") != "complete"
            or not valid_stamp(report.get("observed_at"))):
        raise ValueError("History is not a complete matching-scope inventory.")
    repositories = report.get("repositories")
    items = report.get("items")
    if not isinstance(repositories, list) or not isinstance(items, list):
        raise ValueError("History rows are invalid.")
    repo_roots = set()
    for repository in repositories:
        if (not isinstance(repository, dict) or not isinstance(repository.get("root"), str)
                or repository.get("status") != "complete" or not os.path.isabs(repository["root"])
                or not any(inside(repository["root"], root) for root in scope["roots"])
                or repository["root"] in repo_roots):
            raise ValueError("History repository scope is invalid.")
        repo_roots.add(repository["root"])
    known, total = set(), 0
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("History item is invalid.")
        repository, path, size = item.get("repository"), item.get("path"), item.get("size_bytes")
        if (repository not in repo_roots or not isinstance(path, str) or not os.path.isabs(path)
                or not inside(path, repository) or path == repository or os.path.normpath(path) != path
                or item.get("item_id") != identity(repository, path) or path in known
                or item.get("relative_path") != os.path.relpath(path, repository) or item.get("kind") not in KINDS
                or item.get("status") != "complete" or type(size) is not int or size < 0
                or (item.get("modified_at") is not None and not valid_stamp(item["modified_at"]))):
            raise ValueError("History item identity or measurement is invalid.")
        known.add(path)
        total += size
    if type(report.get("total_bytes")) is not int or report["total_bytes"] != total:
        raise ValueError("History allocated-byte total is invalid.")
    return report


class History:
    def __init__(self, directory, roots, max_depth, registry_digest, issues):
        self.directory, self.issues = Path(directory), issues
        self.scope = {"schema_version": VERSION, "roots": roots, "max_depth": max_depth,
                      "registry_sha256": registry_digest}
        key = hashlib.sha256(encoded(self.scope)).hexdigest()
        self.path = self.directory / ("inventory-" + key + ".json")
        self.lock_path = self.directory / ("inventory-" + key + ".lock")
        self.fd, self.available, self.previous = None, True, None

    def fail(self, message):
        self.available = False
        add_issue(self.issues, self.path, "History unavailable: " + str(message))

    def __enter__(self):
        inspecting_history = False
        try:
            import fcntl
            if self.directory.is_symlink() or not self.directory.is_dir():
                raise OSError("The private history directory is unavailable or is a symbolic link.")
            if not hasattr(os, "O_NOFOLLOW"):
                raise OSError("Safe history locking is unavailable on this platform.")
            self.fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            lock_info = os.fstat(self.fd)
            if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_nlink != 1:
                raise OSError("The history lock is not a private regular file.")
            os.fchmod(self.fd, 0o600)
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            inspecting_history = True
            try:
                descriptor = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
            except FileNotFoundError:
                return self
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise OSError("The history snapshot is not a regular file.")
                if os.fstat(stream.fileno()).st_size > 32 * 1024 * 1024:
                    raise ValueError("The history snapshot exceeds the inspection limit.")
                value = json.loads(stream.read(), object_pairs_hook=unique_object)
            self.previous = validate_baseline(value, self.scope)
        except (ImportError, OSError, ValueError, TypeError, KeyError) as exc:
            recovery = " Move the listed history snapshot aside and run builds again." if inspecting_history else ""
            self.fail(str(exc) + recovery)
        return self

    def save(self, report):
        temporary = None
        try:
            value = {"schema_version": VERSION, "scope": self.scope, "snapshot": report,
                     "sha256": hashlib.sha256(encoded(report)).hexdigest()}
            descriptor, temporary = tempfile.mkstemp(prefix=".inventory-", dir=self.directory)
            with os.fdopen(descriptor, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(encoded(value) + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            temporary = None
        except (OSError, ValueError) as exc:
            self.fail(exc)
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError as exc:
                    self.fail(exc)

    def __exit__(self, *_args):
        if self.fd is not None:
            os.close(self.fd)


def collect(roots, max_depth, state_dir):
    issues = []
    roots = normalized_roots(roots, issues)
    try:
        directories, files, registry_digest = load_registry()
    except (OSError, ValueError) as exc:
        add_issue(issues, LIB / "artifact-kinds.tsv", "Artifact definitions unavailable: " + str(exc))
        return {"schema_version": VERSION, "observed_at": stamp(), "roots": roots, "max_depth": max_depth,
                "collection_status": "incomplete", "history_status": "unavailable", "previous_observed_at": None,
                "repositories": [], "items": [], "issues": issues, "total_bytes": 0, "delta_bytes": None}
    with History(state_dir, roots, max_depth, registry_digest, issues) as history:
        scan_issues = []
        repositories, items = scan(roots, max_depth, directories, files, scan_issues)
        issues.extend(scan_issues)
        # State errors do not turn complete filesystem evidence into a partial
        # measurement. They have their own status and still make the CLI fail.
        physical_complete = not scan_issues and not any(issue["message"].startswith("Project root unavailable:") for issue in issues)
        report = {"schema_version": VERSION, "observed_at": stamp(), "roots": roots, "max_depth": max_depth,
                  "collection_status": "complete" if physical_complete else "incomplete",
                  "history_status": "first" if history.previous is None else "compared",
                  "previous_observed_at": history.previous["observed_at"] if history.previous else None,
                  "repositories": repositories, "items": items, "issues": issues,
                  "total_bytes": sum(item["size_bytes"] for item in items if item["size_bytes"] is not None),
                  "delta_bytes": None}
        if history.available and history.previous:
            previous = {item["item_id"]: item for item in history.previous["items"]}
            for item in items:
                prior = previous.get(item["item_id"])
                if prior and item["size_bytes"] is not None:
                    item["delta_bytes"] = item["size_bytes"] - prior["size_bytes"]
            if physical_complete:
                report["delta_bytes"] = report["total_bytes"] - history.previous["total_bytes"]
        if history.available and physical_complete:
            history.save(report)
        if not history.available:
            report["history_status"] = "unavailable"
            report["delta_bytes"] = None
            for item in items:
                item["delta_bytes"] = None
        return report


def exit_status(report):
    return int(report["collection_status"] != "complete" or report["history_status"] == "unavailable")


def plain_lines(report, ascii_only=False):
    lines = ["afterparty builds - read-only inventory", "Project scan roots:"]
    lines.extend("  " + safe_text(root, ascii_only) for root in report["roots"])
    lines.append(f"Repository discovery: at most {report['max_depth']} directory levels below each root.")
    lines.append(f"Scan: {report['collection_status']} | {len(report['repositories'])} repositories | {len(report['items'])} output paths.")
    for repository in report["repositories"]:
        lines.append("Repository: " + safe_text(repository["root"], ascii_only) + " (" + repository["status"] + ")")
    for item in report["items"]:
        size = str(item["size_bytes"]) + " allocated bytes" if item["size_bytes"] is not None else "allocated size unavailable"
        delta = "unknown" if item["delta_bytes"] is None else f"{item['delta_bytes']:+d} bytes"
        lines.append(f"  {size} | change {delta} | {item['kind']}: " + safe_text(item["path"], ascii_only))
        lines.append("    Modified: " + (item["modified_at"] or "unknown") + " (filesystem time, not last use)")
    qualifier = " (known measurements only | scan incomplete)" if report["collection_status"] != "complete" else ""
    lines.append(f"Allocated total: {report['total_bytes']} bytes" + qualifier)
    if report["history_status"] == "first":
        lines.append("History: first complete baseline is not yet available for comparison.")
    elif report["history_status"] == "unavailable":
        lines.append("History: unavailable. Changes are unknown.")
    else:
        lines.append("Previous complete scan: " + report["previous_observed_at"])
        lines.append("Total change: " + (f"{report['delta_bytes']:+d} bytes" if report["delta_bytes"] is not None else "unknown"))
    for issue in report["issues"]:
        lines.append("Unavailable: " + safe_text(issue["path"], ascii_only) + ": " + safe_text(issue["message"], ascii_only))
    lines.append("Allocated sizes are estimates, not promised freed space. Modification times do not show last use.")
    lines.append("This inventory does no cleanup. Review a repository separately before applying a plan.")
    return lines


INVENTORY_ACTION_KEYS = {
    "builds.review_repository": "ENTER", "builds.inspect_path": "i", "builds.show_details": "d",
    "builds.hide_details": "d", "builds.filter_paths": "/", "builds.refresh": "r",
    "builds.finish": "q", "builds.back": "ESC", "builds.help": "?",
}


class InventoryView:
    def __init__(self, report):
        self.report, self.generation = report, 1
        self.focus = report["items"][0]["item_id"] if report["items"] else None
        self.query, self.search_before, self.step, self.return_step = "", "", "inventory", "inventory"
        self.searching, self.expanded, self.reveal_focus = False, False, True
        self.message = "Size and file time do not prove that output is unused."
        self.message_kind, self.ignored_keys = "info", 0
        self.message_id, self.message_transient = 1, False
        self.collecting = False

    def say(self, message, kind="info", transient=False):
        self.message, self.message_kind = message, kind
        self.message_id += 1
        self.message_transient = transient and kind != "refused"

    def guidance(self):
        if self.searching:
            return "Type to filter paths. Enter keeps the filter. Esc restores it."
        if self.step == "inventory_help":
            return "Review scan coverage and issues. Esc returns to the previous view."
        return "No cleanup runs here. Enter opens a fresh artifact review."

    def visible(self):
        query = self.query.casefold()
        return [item for item in self.report["items"] if query in (item["repository"] + " " + item["relative_path"] + " " + item["kind"]).casefold()]

    def focused(self):
        return next((item for item in self.visible() if item["item_id"] == self.focus), None)

    def keep_focus(self):
        if self.focus not in {item["item_id"] for item in self.visible()}:
            self.focus = self.visible()[0]["item_id"] if self.visible() else None

    def ignore(self, count=1):
        self.ignored_keys += count
        self.say(f"Ignored {self.ignored_keys} keys during collection. Review the current inventory.")

    def key_catalog(self, help_keys=False):
        step = self.return_step if self.step == "inventory_help" and help_keys else self.step
        if self.searching:
            pairs = [("Enter", "finish search"), ("Esc", "restore filter")]
        elif step == "inventory_help":
            pairs = [("q/Esc/?", "back"), ("PgUp/PgDn", "scroll")]
        elif step == "inventory_inspect":
            pairs = [("Enter", "review repository"), ("q/Esc", "back"), ("?", "help"), ("PgUp/PgDn", "scroll")]
        else:
            pairs = [("Enter", "review"), ("Up/Down", "focus (j/k)"), ("/", "filter"),
                     ("i", "inspect"), ("d", "details"), ("?", "help"), ("r", "refresh"), ("q", "finish")]
        if not self.searching:
            pairs = [(key, "show or hide details" if key == "d" else label) for key, label in pairs]
            existing = {key for key, _label in pairs}
            extras = [("PgUp/PgDn", "scroll"), ("Ctrl+Z", "suspend and resume with fg"),
                      ("Ctrl+C", "exit"), ("Ctrl+\\", "exit")]
            if step in ("inventory", "inventory_inspect") and not self.collecting:
                extras.append(("Ctrl+P", "commands"))
            pairs.extend(pair for pair in extras if pair[0] not in existing)
        return [{"key": key, "label": label} for key, label in pairs]

    def keys(self, help_keys=False):
        entries = self.key_catalog(help_keys)
        if help_keys or self.searching:
            return entries
        primary = {
            "inventory": ("Enter", "Up/Down", "i", "q"),
            "inventory_inspect": ("Enter", "q/Esc", "PgUp/PgDn"),
            "inventory_help": ("q/Esc/?", "PgUp/PgDn"),
        }.get(self.step, ())
        by_key = {entry["key"]: entry for entry in entries}
        return [by_key[key] for key in (*primary, "Ctrl+P", "?") if key in by_key]

    def actions(self):
        if self.collecting or self.searching or self.step not in ("inventory", "inventory_inspect"):
            return []
        result = []

        def add(name, label, description, enabled=True, reason=""):
            action_id = "builds." + name
            key = INVENTORY_ACTION_KEYS[action_id]
            result.append({"id": action_id, "label": label, "description": description,
                           "key": {"ENTER": "Enter", "ESC": "Esc"}.get(key, key),
                           "enabled": bool(enabled), "reason": "" if enabled else reason})

        focused = self.focused() is not None
        reason = "No output path has focus. Change the filter or refresh the scan."
        add("review_repository", "Review repository", "Open fresh artifact review for this repository without marks.", focused, reason)
        if self.step == "inventory":
            add("inspect_path", "Inspect path", "Show full identity, measurements, and file modification time.", focused, reason)
            add("hide_details" if self.expanded else "show_details", "Hide details" if self.expanded else "Show details",
                "Hide optional path evidence." if self.expanded else "Show optional evidence for the focused path.")
            add("filter_paths", "Filter paths", "Filter the displayed paths. The known-byte scale stays unchanged.")
        else:
            add("back", "Back to inventory", "Return to the output list without changing focus.")
        add("refresh", "Refresh scan", "Collect fresh output measurements. No cleanup runs here.")
        if self.step == "inventory":
            add("finish", "Finish inventory", "Exit this read-only inventory.")
        add("help", "Help", "Show every key, scan coverage, issues, and the latest message.")
        return result

    def handle_action(self, request):
        if (type(request.get("generation")) is not int or request["generation"] != self.generation
                or not isinstance(request.get("step"), str) or request["step"] != self.step
                or not isinstance(request.get("focus"), str) or request["focus"] != (self.focus or "")
                or type(request.get("focus_visible", True)) is not bool):
            self.say("The command is out of date. Open Commands and choose it again.", "refused")
            return None
        action_id = request.get("action")
        action = next((entry for entry in self.actions() if entry["id"] == action_id), None)
        if action is None:
            self.say("This command is not available in this view. Open Commands and choose another command.", "refused")
            return None
        if not action["enabled"]:
            self.say(action["reason"], "refused")
            return None
        return self.handle({"key": INVENTORY_ACTION_KEYS[action_id], "generation": request["generation"],
                            "focus_visible": request.get("focus_visible", True)})

    def state(self):
        result = {"event": "state", "mode": "builds", "inventory": self.report,
                  "focus": self.focus, "visible_ids": [item["item_id"] for item in self.visible()],
                  "query": self.query, "searching": self.searching, "expanded": self.expanded,
                  "step": self.step, "legend": self.keys(), "help_keys": self.keys(True),
                  "message": self.message, "message_kind": self.message_kind,
                  "actions": self.actions(), "guidance": self.guidance(),
                  "message_id": self.message_id, "message_transient": self.message_transient,
                  "generation": self.generation, "ignored_keys": self.ignored_keys,
                  "reveal_focus": self.reveal_focus, "captured_at": self.report["observed_at"], "collecting": self.collecting}
        self.reveal_focus = False
        return result

    def handle(self, request):
        key = request.get("key")
        if not isinstance(key, str) or not 1 <= len(key) <= 32:
            raise ValueError("Invalid inventory key request.")
        if key == "ACTION":
            return self.handle_action(request)
        generation = request.get("generation", -1)
        focus_visible = request.get("focus_visible", True)
        if type(focus_visible) is not bool:
            raise ValueError("Invalid inventory focus visibility.")
        if type(generation) is not int:
            raise ValueError("Invalid inventory input generation.")
        if key == "CANCEL":
            return "done"
        if key == "IGNORED":
            count = request.get("ignored_keys", 0)
            if type(count) is not int or not 0 < count <= 1000000:
                raise ValueError("Invalid ignored-key count.")
            self.ignore(count)
            return None
        if key in {"ENTER", "r", " ", "s"} and generation != self.generation:
            self.ignore()
            return None
        if self.searching:
            if key == "ESC":
                self.query, self.searching = self.search_before, False
            elif key == "ENTER":
                self.searching = False
            elif key == "BACKSPACE":
                self.query = self.query[:-1]
            elif len(key) == 1 and key.isprintable():
                self.query += key
            self.keep_focus()
            self.reveal_focus = True
            return None
        if key in {"q", "ESC"}:
            if self.step == "inventory_help":
                self.step = self.return_step
            elif self.step == "inventory_inspect":
                self.step = "inventory"
            elif key == "q":
                return "done"
            else:
                self.query = ""
                self.keep_focus()
            self.reveal_focus = True
        elif key == "?":
            if self.step == "inventory_help":
                self.step = self.return_step
            else:
                self.return_step, self.step = self.step, "inventory_help"
        elif key == "/" and self.step == "inventory":
            self.search_before, self.searching = self.query, True
        elif key in {"UP", "DOWN", "j", "k"} and self.step != "inventory_help":
            visible = self.visible()
            if visible:
                index = next((index for index, item in enumerate(visible) if item["item_id"] == self.focus), 0)
                index = max(0, min(len(visible) - 1, index + (1 if key in {"DOWN", "j"} else -1)))
                self.focus = visible[index]["item_id"]
                self.reveal_focus = True
        elif key == "i" and self.step == "inventory" and self.focused():
            self.step, self.reveal_focus = "inventory_inspect", True
        elif key == "d" and self.step == "inventory":
            self.expanded, self.reveal_focus = not self.expanded, True
            self.say("Path details are visible." if self.expanded else "Path details are hidden.", transient=True)
        elif key == "r":
            self.generation += 1
            self.collecting = True
            return "refresh"
        elif key == "ENTER" and self.step != "inventory_help":
            if not focus_visible:
                self.reveal_focus = True
                self.say("Focused output revealed. Press Enter again to review its repository.")
            elif self.focused():
                return "review"
            else:
                self.say("No focused output path. Choose a repository with observed output first.", "refused")
        elif key in {" ", "s"}:
            self.say("This inventory has no marks or save action. Press Enter to open a separate artifact review.")
        elif key == "PASTE":
            self.say("Paste ignored. Type inventory keys individually.")
        return None


def emit(event):
    print(json.dumps(event, ensure_ascii=True, allow_nan=False), flush=True)


def serve(options):
    emit({"event": "scan", "mode": "builds", "collecting": True, "generation": 1})
    view = InventoryView(collect(options.projects_root, options.max_depth, options.state_dir))
    emit(view.state())
    for line in sys.stdin:
        request = json.loads(line, object_pairs_hook=unique_object)
        if not isinstance(request, dict):
            raise ValueError("Invalid inventory input.")
        action = view.handle(request)
        if action in {"done", "review"}:
            event = {"event": "done", "exit_code": exit_status(view.report),
                     "lines": ["Build-output inventory finished. No cleanup was run."]}
            if action == "review":
                event["review_root"] = view.focused()["repository"]
                event["lines"].append("Open artifact review for: " + safe_text(event["review_root"]))
            emit(event)
            return 0
        if action == "refresh":
            emit({"event": "scan", "mode": "builds", "collecting": True, "generation": view.generation})
            view.report = collect(options.projects_root, options.max_depth, options.state_dir)
            view.keep_focus()
            view.step, view.reveal_focus = "inventory", True
            view.collecting = False
            view.say("Inventory refreshed. No cleanup was run.", "done")
        emit(view.state())
    return 1


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read-only cross-project build-output inventory.")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--projects-root", action="append", default=[])
    parser.add_argument("--max-depth", type=int, default=6)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--output", default=None)
    parser.add_argument("--ascii", action="store_true")
    formats = parser.add_mutually_exclusive_group()
    formats.add_argument("--json", action="store_true")
    formats.add_argument("--plain", action="store_true")
    arguments = list(sys.argv[1:] if argv is None else argv)
    if "--" in arguments:
        arguments.remove("--")
    options = parser.parse_args(arguments)
    if not 1 <= options.max_depth <= 64:
        parser.error("--max-depth must be between 1 and 64")
    if options.output is not None and not options.serve:
        parser.error("--output is only accepted by the terminal helper")
    options.projects_root = options.projects_root or [os.getcwd()]
    for name in ("SIGTERM", "SIGHUP", "SIGQUIT"):
        signum = getattr(signal, name, None)
        if signum is not None:
            signal.signal(signum, interrupted)
    try:
        if options.serve:
            return serve(options)
        report = collect(options.projects_root, options.max_depth, options.state_dir)
        if options.json:
            print(encoded(report).decode("ascii"))
        else:
            print("\n".join(plain_lines(report, options.ascii)))
        return exit_status(report)
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 1
    except (OSError, ValueError, KeyError, TypeError) as exc:
        if options.serve:
            emit({"event": "error", "exit_code": 1, "lines": ["builds: " + safe_text(exc)]})
        else:
            print("builds: " + safe_text(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
