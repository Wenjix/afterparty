"""Lossless apply receipts and the private, run-bound delegated outcome channel.

This module serializes observations; it never approves or executes cleanup.
"""

import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

from plan_data import digest, encoded, unique_object

CONTRACT = "afterparty.apply"
OUTCOMES = {"applied", "gone", "held", "vetoed", "drift", "survived", "failed"}
RECEIPTS = {"recorded", "failed", "not-attempted"}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read_json(path):
    return json.loads(Path(path).read_bytes(), object_pairs_hook=unique_object)


def private_file(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def context(directory):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "channel-directory-unavailable")
    if os.name != "nt":
        info = directory.stat()
        require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "channel-directory-not-private")
    return read_json(directory / "context.json")


def row(run_id, section, **values):
    return dict(contract=CONTRACT, schema_version=1, run_id=run_id, section=section, **values)


def publish(directory, record):
    data = encoded(record) + b"\n"
    with (Path(directory) / "events.jsonl").open("ab") as stream:
        stream.write(data)
        stream.flush()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def read_stream(data):
    """Validate a finished receipt. Missing completion never means success."""
    require(data.endswith(b"\n"), "stream-incomplete")
    rows = [json.loads(line, object_pairs_hook=unique_object) for line in data.splitlines()]
    require(all(isinstance(r, dict) for r in rows), "invalid-event")
    require(len(rows) >= 3 and rows[-1].get("section") == "apply_complete", "stream-incomplete")
    run_id = rows[0]["run_id"]
    require(re.fullmatch(r"[0-9a-f]{32}", run_id), "invalid-run-id")
    for record in rows:
        require(record.get("contract") == CONTRACT and type(record.get("schema_version")) is int
                and record["schema_version"] == 1 and record.get("run_id") == run_id, "event-context-mismatch")
    require(rows[-1]["events_sha256"] == digest(b"".join(encoded(r) + b"\n" for r in rows[:-1])), "event-digest-mismatch")
    require(type(rows[-1]["event_count"]) is int and rows[-1]["event_count"] == len(rows) - 1, "event-count-mismatch")
    require(rows[-2]["section"] == "apply_summary", "summary-required")
    require(sum(r["section"] == "apply_complete" for r in rows) == 1, "duplicate-completion")
    require(sum(r["section"] == "apply_summary" for r in rows) == 1, "duplicate-summary")
    targets = [r for r in rows if r["section"] == "apply_target"]
    for target in targets:
        validate_result(target, nullable=True)
        require(type(target.get("target_index")) is int and target["target_index"] >= 0
                and target.get("type") in ("process-group", "worktree", "artifact")
                and isinstance(target.get("target"), str) and bool(target["target"])
                and isinstance(target.get("fingerprint"), str), "invalid-target")
    require(len({r["target_index"] for r in targets}) == len(targets), "duplicate-target-outcome")
    counts = {name: sum(r["outcome"] == name for r in targets) for name in sorted(OUTCOMES)}
    require(rows[-2]["counts"] == counts and all(type(v) is int for v in rows[-2]["counts"].values())
            and type(rows[-1]["target_count"]) is int and rows[-1]["target_count"] == len(targets), "target-count-mismatch")
    if rows[0]["section"] == "apply_start":
        require(type(rows[0]["checked_count"]) is int and rows[0]["checked_count"] == len(targets), "target-outcomes-incomplete")
        require({r["target_index"] for r in targets} == set(range(len(targets)))
                and all(r["section"] == "apply_target" for r in rows[1:-2]), "invalid-event-order")
        require(re.fullmatch(r"[0-9a-f]{64}", rows[0]["plan_sha256"]), "invalid-plan-digest")
    else:
        require(rows[0]["section"] == "apply_rejection" and len(rows) == 3
                and rows[-2]["exit_status"] == 2, "invalid-rejection")
    require(rows[-1]["exit_status"] == rows[-2]["exit_status"], "exit-status-mismatch")
    summary = rows[-2]
    require(type(summary["exit_status"]) is int and summary["exit_status"] in (0, 1, 2), "invalid-exit-status")
    for value in (summary["invocation_errors"], summary["journal_failures"], *summary["legacy_counters"].values()):
        require(type(value) is int and value >= 0, "invalid-counter")
    incomplete = any(r["outcome"] not in ("applied", "gone") or r["receipt_status"] in ("failed", None)
                     or r["delegation_exit_code"] not in (0, None) for r in targets)
    require(summary["exit_status"] != 0 or not (incomplete or summary["invocation_errors"] or summary["journal_failures"]),
            "false-success")
    return rows


def validate_result(record, nullable=False):
    require({"outcome", "reason_code", "detail", "mutation_attempted", "postcondition_confirmed",
             "receipt_status", "delegation_exit_code"} <= record.keys(), "missing-result-field")
    require(record.get("outcome") in OUTCOMES and isinstance(record.get("reason_code"), str)
            and re.fullmatch(r"[a-z][a-z0-9-]*", record["reason_code"])
            and isinstance(record.get("detail"), str), "invalid-target-outcome")
    attempted = record.get("mutation_attempted")
    confirmed = record.get("postcondition_confirmed")
    receipt = record.get("receipt_status")
    require((type(attempted) is bool or nullable and attempted is None) and type(confirmed) is bool,
            "invalid-effect-evidence")
    require(receipt in RECEIPTS or nullable and receipt is None, "invalid-receipt-status")
    require(record.get("delegation_exit_code") is None or type(record["delegation_exit_code"]) is int
            and 0 <= record["delegation_exit_code"] <= 255, "invalid-delegation-status")
    if record["outcome"] == "applied":
        require(attempted is True and confirmed is True, "unconfirmed-application")
    if record["outcome"] == "gone":
        require(attempted is False and confirmed is True, "unconfirmed-noop")


def result_fields(outcome, reason, detail, attempted, confirmed, receipt, invocation):
    require(outcome in OUTCOMES and re.fullmatch(r"[a-z][a-z0-9-]*", reason), "invalid-target-outcome")
    require(attempted in ("0", "1", "unknown") and confirmed in ("0", "1"), "invalid-effect-evidence")
    require(receipt in RECEIPTS or receipt == "unavailable", "invalid-receipt-status")
    result = dict(outcome=outcome, reason_code=reason, detail=detail,
                mutation_attempted=None if attempted == "unknown" else attempted == "1",
                postcondition_confirmed=confirmed == "1", receipt_status=None if receipt == "unavailable" else receipt,
                delegation_exit_code=None if invocation == "-" else int(invocation))
    validate_result(result, nullable=True)
    return result


def finish(directory, exit_status, counters, invocation_errors, journal_failures):
    directory = Path(directory)
    ctx = context(directory)
    records = [json.loads(line) for line in (directory / "events.jsonl").read_bytes().splitlines()]
    targets = [r for r in records if r["section"] == "apply_target"]
    expected = read_json(directory / "targets.json") if (directory / "targets.json").exists() else []
    require({r["target_index"] for r in targets} == set(range(len(expected))), "target-outcomes-incomplete")
    counts = {name: sum(r["outcome"] == name for r in targets) for name in sorted(OUTCOMES)}
    publish(directory, row(ctx["run_id"], "apply_summary", counts=counts, legacy_counters=counters,
                           invocation_errors=invocation_errors, journal_failures=journal_failures, exit_status=exit_status))
    raw = (directory / "events.jsonl").read_bytes()
    publish(directory, row(ctx["run_id"], "apply_complete", event_count=len(raw.splitlines()),
                           target_count=len(targets), events_sha256=digest(raw), exit_status=exit_status))


def child_request(directory, run_id):
    ctx = context(directory)
    request = read_json(Path(directory) / "child-request.json")
    require(ctx["run_id"] == request["run_id"] == run_id, "child-run-mismatch")
    channel = Path(directory) / "child.jsonl"
    info = channel.lstat()
    require(stat.S_ISREG(info.st_mode), "child-channel-unavailable")
    if os.name != "nt":
        require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0, "child-channel-not-private")
    return request


def main(args):
    operation, directory, *args = args
    directory = Path(directory)
    if operation == "early-reject":
        run_id = uuid.uuid4().hex
        records = [row(run_id, "apply_rejection", reason_code=str(directory), detail=args[0]),
                   row(run_id, "apply_summary", counts={name: 0 for name in sorted(OUTCOMES)}, legacy_counters={},
                       invocation_errors=0, journal_failures=0, exit_status=2)]
        raw = b"".join(encoded(record) + b"\n" for record in records)
        sys.stdout.buffer.write(raw + encoded(row(run_id, "apply_complete", event_count=2, target_count=0,
                                                 events_sha256=digest(raw), exit_status=2)) + b"\n")
        sys.stdout.buffer.flush()
    elif operation == "init":
        plan = Path(args[0]).read_bytes()
        plan.decode("utf-8")
        ctx = dict(run_id=uuid.uuid4().hex, plan_sha256=digest(plan))
        private_file(directory / "context.json", encoded(ctx))
        private_file(directory / "plan.md", plan)
        private_file(directory / "events.jsonl", b"")
        private_file(directory / "child.jsonl", b"")
        print(ctx["run_id"])
    elif operation == "start":
        ctx = context(directory)
        targets = []
        checked = Path(args[0]).read_bytes().decode("utf-8")
        require(not checked or checked.endswith("\n"), "checked-targets-incomplete")
        for line in checked.split("\n")[:-1]:
            kind, target, fingerprint, category, scope = line.split("\t")
            targets.append(dict(target_index=len(targets), type=kind, target=target, fingerprint=fingerprint,
                                category=None if category == "-" else category, scope=None if scope == "-" else scope))
        private_file(directory / "targets.json", encoded(targets))
        publish(directory, row(ctx["run_id"], "apply_start", plan_sha256=ctx["plan_sha256"], checked_count=len(targets)))
    elif operation == "target":
        kind, target, *fields = args
        ctx = context(directory)
        found = [t for t in read_json(directory / "targets.json") if t["type"] == kind and t["target"] == target]
        require(len(found) == 1, "unchecked-target-event")
        seen = [json.loads(line) for line in (directory / "events.jsonl").read_bytes().splitlines()]
        require(not any(r.get("target_index") == found[0]["target_index"] for r in seen), "duplicate-target-outcome")
        publish(directory, row(ctx["run_id"], "apply_target", **found[0], **result_fields(*fields)))
    elif operation == "reject":
        ctx = context(directory)
        publish(directory, row(ctx["run_id"], "apply_rejection", reason_code=args[0], detail=args[1]))
        finish(directory, 2, {}, 0, 0)
    elif operation == "summary":
        names = ("applied", "drift", "gone", "held", "vetoed", "survived", "failed")
        finish(directory, int(args[0]), dict(zip(names, map(int, args[3:]))), int(args[1]), int(args[2]))
    elif operation == "child-prepare":
        category, pgids, expects = args
        ctx = context(directory)
        expected = dict(pair.split(":", 1) for pair in expects.split(","))
        targets = {t["target"]: t for t in read_json(directory / "targets.json") if t["type"] == "process-group"}
        chosen = pgids.split(",")
        require(len(set(chosen)) == len(chosen) and all(pg in targets and targets[pg]["category"] == category
                and targets[pg]["fingerprint"] == expected.get(pg) for pg in chosen), "child-request-not-approved")
        request = dict(run_id=ctx["run_id"], category=category, pgids=chosen, expects=expects)
        for name, data in (("child-request.json", encoded(request)), ("child.jsonl", b"")):
            path = directory / name
            if path.exists():
                path.unlink()
            private_file(path, data)
    elif operation == "child-check":
        run_id, category, pgids, expects = args
        request = child_request(directory, run_id)
        require((category, pgids.split(","), expects) == (request["category"], request["pgids"], request["expects"]), "child-request-mismatch")
    elif operation == "child-target":
        run_id, pgid, *fields = args
        request = child_request(directory, run_id)
        require(pgid in request["pgids"], "child-target-not-requested")
        record = dict(schema_version=1, run_id=run_id, pgid=pgid, **result_fields(*fields))
        with (directory / "child.jsonl").open("ab") as stream:
            stream.write(encoded(record) + b"\n")
    elif operation == "child-read":
        run_id, pgid = args
        request = child_request(directory, run_id)
        raw = (directory / "child.jsonl").read_bytes()
        require(raw.endswith(b"\n"), "child-evidence-incomplete")
        records = [json.loads(line, object_pairs_hook=unique_object) for line in raw.splitlines()]
        require(len(records) == len(request["pgids"]) and {r.get("pgid") for r in records} == set(request["pgids"]), "child-targets-mismatch")
        for record in records:
            require(record.get("run_id") == run_id and type(record.get("schema_version")) is int
                    and record["schema_version"] == 1, "child-context-mismatch")
            validate_result(record)
        record = next(r for r in records if r["pgid"] == pgid)
        # Only machine tokens cross back into shell fields; detail remains JSON.
        print("\t".join((record["outcome"], record["reason_code"], str(int(record["mutation_attempted"])),
                         str(int(record["postcondition_confirmed"])), record["receipt_status"])))
    else:
        raise ValueError("unknown event operation")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print("apply: event evidence unavailable: " + str(exc), file=sys.stderr)
        sys.exit(1)
