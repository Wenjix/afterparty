"""Lossless plan snapshots. This module never discovers or changes targets."""

import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import uuid

CONTRACT = "afterparty.plan"
TYPES = {"process-group", "worktree", "artifact"}


class SnapshotError(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()


def item_id(kind, target, scope):
    fields = [s.encode("utf-8") for s in (kind, target, scope)]
    return kind + ":" + digest(b"".join(str(len(s)).encode() + b":" + s for s in fields))


def require(condition, message):
    if not condition:
        raise SnapshotError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-field: " + key)
        result[key] = value
    return result


def load_snapshot(data):
    try:
        rows = [json.loads(line, object_pairs_hook=unique_object) for line in data.splitlines()]
        validate(rows)
        return rows
    except (ValueError, KeyError, IndexError, TypeError, UnicodeError) as exc:
        raise SnapshotError("snapshot rejected: " + str(exc)) from exc


def validate(rows):
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), "invalid-records")
    require(len(rows) >= 3 and rows[-1].get("section") == "plan_complete", "stream-incomplete")
    require(rows[0].get("section") == "plan_scope", "scope-required")
    sid = rows[0]["snapshot_id"]
    require(isinstance(sid, str) and re.fullmatch(r"[0-9a-f]{32}", sid), "invalid-snapshot-id")
    for row in rows:
        require(row.get("contract") == CONTRACT and type(row.get("schema_version")) is int
                and row["schema_version"] == 1, "unsupported-schema")
        require(row.get("snapshot_id") == sid, "snapshot-id-mismatch")
        require(row.get("section") in {"plan_scope", "plan_capability", "plan_item", "plan_document", "plan_complete"}, "unknown-section")
    for section in ("plan_scope", "plan_document", "plan_complete"):
        require(sum(row["section"] == section for row in rows) == 1, "duplicate-" + section)
    require(rows[-2]["section"] == "plan_document", "document-order")
    require(rows[-1]["snapshot_sha256"] == digest(encoded(rows[:-1])), "snapshot-digest-mismatch")
    scope = rows[0]
    require(isinstance(scope["root"], str) and scope["root"], "invalid-root")
    require(scope["collection_status"] in ("complete", "incomplete"), "invalid-collection-status")
    require(rows[-1]["collection_status"] == scope["collection_status"], "completion-status-mismatch")
    require(isinstance(scope["flags"], dict) and set(scope["flags"]) == {"all", "artifacts_only", "caches_only"}
            and all(type(value) is bool for value in scope["flags"].values()), "invalid-scope-flags")
    capabilities = {}
    for row in rows:
        if row["section"] != "plan_capability":
            continue
        require(row["name"] not in capabilities and row["status"] in ("complete", "unavailable"), "invalid-capability")
        require(isinstance(row["target_types"], list) and set(row["target_types"]) <= TYPES
                and isinstance(row["reason"], str), "invalid-capability-evidence")
        capabilities[row["name"]] = row["status"]
    require(rows[-1]["sections"] == capabilities, "section-completion-mismatch")
    require(scope["collection_status"] == "incomplete" or all(s == "complete" for s in capabilities.values()), "incomplete-capabilities")
    document = rows[-2]
    require(isinstance(document["text"], str) and document["text"].endswith("\n"), "invalid-document")
    require(digest(document["text"].encode("utf-8")) == document["sha256"], "document-digest-mismatch")
    lines = document["text"].split("\n")
    items = [row for row in rows if row["section"] == "plan_item"]
    ids, headers = set(), set()
    for item in items:
        kind, target, target_scope = item["type"], item["target"], item["scope"]
        require(kind in TYPES and all(isinstance(s, str) and s for s in (target, target_scope)), "invalid-target")
        require(not any(c in target + target_scope for c in "\r\n\t\0"), "unsupported-target-control")
        ident = item["item_id"]
        require(ident == item_id(kind, target, target_scope), "item-id-mismatch")
        require(ident not in ids, "duplicate-item: " + ident)
        ids.add(ident)
        require(item["selected"] is False, "preselected-item: " + ident)
        require(item["availability"] in ("available", "withheld"), "invalid-availability: " + ident)
        require(isinstance(item["reason"], str) and item["reason"] and isinstance(item["consequence"], str)
                and item["consequence"] and isinstance(item["evidence"], dict), "missing-evidence: " + ident)
        mapping = item["markdown"]
        line = mapping["header_line"]
        require(type(line) is int and 1 <= line < len(lines) and line not in headers, "invalid-header-mapping: " + ident)
        headers.add(line)
        header = lines[line - 1]
        require(digest(header.encode("utf-8")) == mapping["header_sha256"], "header-digest-mismatch: " + ident)
        if item["availability"] == "available":
            require(mapping["checkbox_column"] == 4 and header.startswith("- [ ]"), "invalid-checkbox: " + ident)
            require(isinstance(item["fingerprint"], str) and re.fullmatch(r"[0-9a-f]+", item["fingerprint"]), "fingerprint-required: " + ident)
        else:
            require(mapping["checkbox_column"] is None and header.startswith("- [⊘]"), "withheld-mapping: " + ident)
    require(headers == {i + 1 for i, line in enumerate(lines) if line.startswith(("- [ ]", "- [⊘]"))}, "unmapped-rows")
    require(not any(re.match(r"^- \[[xX]\]", line) for line in lines), "checked-source-document")
    available = sum(item["availability"] == "available" for item in items)
    require(rows[-1]["counts"] == {"items": len(items), "available": available, "withheld": len(items) - available}, "count-mismatch")


def fields(path):
    raw = path.read_bytes()
    require(raw.endswith(b"\0"), "incomplete-capture: " + path.name)
    return raw[:-1].decode("utf-8").split("\0")


def number(value, integer=False):
    if not value:
        return None
    value = int(value) if integer else float(value)
    require(math.isfinite(value) and value >= 0, "invalid-numeric-evidence")
    return value


def evidence(raw, kind):
    require(len(raw) % 2 == 0, "invalid-evidence-capture")
    values = unique_object(zip(raw[::2], raw[1::2]))
    result = dict(values)
    if kind in ("process-group", "worktree"):
        touched = number(result.pop("touched", ""), True)
        now = number(result.pop("observed_epoch", ""), True)
        result["activity"] = {"status": "known" if touched is not None else "unknown", "last_touched": touched,
                              "idle_seconds": max(0, now - touched) if touched is not None else None,
                              "sources": result.pop("sources", "").split(",") if values.get("sources") else []}
    if kind == "process-group":
        result["cpu_max"] = number(result.get("cpu_max", ""))
        result["ports"] = sorted({int(p) for p in result.get("ports", "").split()})
        members = []
        member_text = result.get("members", "")
        for line in member_text.split("\n") if member_text else []:
            pid, command = line.split("\t", 1)
            members.append({"pid": int(pid), "command": command})
        result["members"] = members
        result["recorded_purpose"] = result.get("recorded_purpose") or None
        result["category"] = result.get("category") or None
    if kind in ("worktree", "artifact"):
        result["size_bytes"] = None
    return result


def capture(directory, root, all_scope, artifacts_only, caches_only, now, returncode):
    directory = Path(directory)
    sid = uuid.uuid4().hex
    rows = []

    def add(section, **values):
        row = dict(contract=CONTRACT, schema_version=1, snapshot_id=sid, section=section, **values)
        rows.append(row)
        return row

    scope = add("plan_scope", root=root, artifact_scope=root,
                process_worktree_scope="machine-wide" if all_scope else "current-repository",
                flags={"all": all_scope, "artifacts_only": artifacts_only, "caches_only": caches_only},
                observed_at=datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat(),
                collection_status="complete")
    text = (directory / "document").read_bytes().decode("utf-8")
    lines = text.split("\n")
    offset = int((directory / "artifact-offset").read_text())
    incomplete = bool(returncode)
    sections = {}
    for folder, adjustment in ((directory, 0), (directory / "artifacts", offset)):
        if not folder.exists():
            incomplete = True
            add("plan_capability", name="artifact-collection", target_types=["artifact"], status="unavailable", reason="Artifact collector did not finish.")
            sections["artifact-collection"] = "unavailable"
            continue
        for path in sorted((folder / "capabilities").iterdir()):
            name, types, status, reason = fields(path)
            require(status in ("complete", "unavailable"), "invalid-capability")
            add("plan_capability", name=name, target_types=types.split(","), status=status, reason=reason)
            sections[name] = status
            incomplete |= status == "unavailable"
        for path in sorted((folder / "items").glob("[0-9]*"), key=lambda p: int(p.stem)):
            if path.suffix:
                continue
            row = fields(path)
            require(len(row) == 9, "invalid-item-capture")
            line, kind, target, target_scope, fp, availability, code, reason, consequence = row
            line = int(line) + adjustment
            require(0 < line < len(lines), "invalid-captured-line")
            mapping = {"header_line": line, "checkbox_column": 4 if availability == "available" else None,
                       "header_sha256": digest(lines[line - 1].encode("utf-8"))}
            ev_path = path.with_suffix(".evidence")
            ev = fields(ev_path) if ev_path.stat().st_size else []
            add("plan_item", item_id=item_id(kind, target, target_scope), type=kind, target=target, scope=target_scope,
                fingerprint=fp or None, availability=availability, reason_code=code, reason=reason,
                selected=False, evidence=evidence(ev, kind), consequence=consequence, markdown=mapping)
            incomplete |= "unavailable" in code or "incomplete" in code
    scope["collection_status"] = "incomplete" if incomplete else "complete"
    add("plan_document", text=text, sha256=digest(text.encode("utf-8")))
    items = [row for row in rows if row["section"] == "plan_item"]
    available = sum(row["availability"] == "available" for row in items)
    add("plan_complete", snapshot_sha256=digest(encoded(rows)), counts={"items": len(items), "available": available, "withheld": len(items) - available},
        sections=sections, collection_status=scope["collection_status"])
    validate(rows)
    return rows


def main():
    try:
        directory, root, all_scope, artifacts, caches, now, rc = sys.argv[1:]
        rows = capture(directory, root, bool(int(all_scope)), bool(int(artifacts)), bool(int(caches)), int(now), int(rc))
        for row in rows:
            print(encoded(row).decode("ascii"))
        return 1 if rows[0]["collection_status"] == "incomplete" else 0
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print("plan: snapshot rejected: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
