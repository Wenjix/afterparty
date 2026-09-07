#!/usr/bin/env python3
"""Inspect/update the active top-level crash-reporting key without editing comments."""
import hashlib
import json
import os
import stat
import sys
import tempfile


def clean_jsonc(text):
    chars = list(text)
    i, quoted = 0, False
    while i < len(chars):
        if quoted:
            if chars[i] == "\\":
                i += 2
                continue
            if chars[i] == '"':
                quoted = False
        elif chars[i] == '"':
            quoted = True
        elif text[i:i + 2] in ("//", "/*"):
            block = text[i:i + 2] == "/*"
            end = text.find("*/", i + 2) + 2 if block else text.find("\n", i + 2)
            if block and end == 1:
                raise ValueError("unterminated JSONC comment")
            if end < 0:
                end = len(chars)
            for k in range(i, end):
                if chars[k] not in "\r\n":
                    chars[k] = " "
            i = end
            continue
        i += 1
    cleaned = "".join(chars)
    i, quoted = 0, False
    while i < len(chars):
        if quoted:
            if chars[i] == "\\":
                i += 2
                continue
            if chars[i] == '"':
                quoted = False
        elif chars[i] == '"':
            quoted = True
        elif chars[i] == ",":
            after = i + 1
            while after < len(chars) and chars[after].isspace():
                after += 1
            if after < len(chars) and chars[after] in "}]":
                chars[i] = " "
        i += 1
    return "".join(chars)


def no_duplicates(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate JSONC key")
        obj[key] = value
    return obj


def setting_span(text):
    cleaned = clean_jsonc(text)
    obj = json.loads(cleaned, object_pairs_hook=no_duplicates)
    if not isinstance(obj, dict):
        raise ValueError("settings root must be an object")
    decoder = json.JSONDecoder()
    pos = cleaned.index("{") + 1
    while True:
        while cleaned[pos].isspace() or cleaned[pos] == ",":
            pos += 1
        if cleaned[pos] == "}":
            return "unset", None
        key, pos = decoder.raw_decode(cleaned, pos)
        while cleaned[pos].isspace() or cleaned[pos] == ":":
            pos += 1
        start = pos
        value, pos = decoder.raw_decode(cleaned, pos)
        if key == "enable-crash-reporter":
            if not isinstance(value, bool):
                raise ValueError("crash reporter setting is not boolean")
            return "enabled" if value else "disabled", (start, pos)


def main():
    command, path = sys.argv[1:3]
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("settings target is not a regular file")
        data = source.read()
    digest = hashlib.sha256(data).hexdigest()
    text = data.decode("utf-8")
    state, span = setting_span(text)
    if command == "inspect":
        print(state + "\t" + digest)
        return
    if command != "disable" or sys.argv[3] != digest or state != "enabled":
        raise ValueError("settings changed since preview")
    backup = path + ".afterparty-" + digest[:16] + ".bak"
    try:
        backup_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if os.path.islink(backup) or open(backup, "rb").read() != data:
            raise ValueError("unrelated backup already owns the restore path")
    else:
        with os.fdopen(backup_fd, "wb") as restore:
            restore.write(data)
            restore.flush()
            os.fsync(restore.fileno())
    changed = text[:span[0]] + "false" + text[span[1]:]
    if setting_span(changed)[0] != "disabled":
        raise ValueError("setting change could not be verified")
    tmp_fd, temporary = tempfile.mkstemp(prefix=".afterparty-settings-", dir=os.path.dirname(path))
    try:
        with os.fdopen(tmp_fd, "wb") as output:
            permissions = stat.S_IMODE(metadata.st_mode)
            if hasattr(os, "fchmod"):
                os.fchmod(output.fileno(), permissions)
            else:
                os.chmod(temporary, permissions)
            output.write(changed.encode("utf-8"))
            output.flush()
            os.fsync(output.fileno())
        current = os.lstat(path)
        if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
            metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_size
        ):
            raise ValueError("settings identity changed before replacement")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(backup)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, IndexError) as error:
        print("devclean settings: " + str(error), file=sys.stderr)
        sys.exit(1)
