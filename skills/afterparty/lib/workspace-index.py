#!/usr/bin/env python3
"""Read transcript activity without retaining message bodies or writing state.

Every JSONL record is parsed using the standard library. A 32 MiB record limit
bounds transient memory; oversized or incomplete records make the whole index
unavailable. Only normalized workspace paths, file mtimes and provider names
survive a record. File mtime is an observation, not proof of human presence.
"""

import argparse
import json
import ntpath
import os
import posixpath
import re
import stat
import subprocess
import sys
import unicodedata


MAX_RECORD_BYTES = 32 * 1024 * 1024


class IndexUnavailable(Exception):
    """An inspection could not establish complete activity evidence."""

    def __init__(self, reason, location=None):
        self.reason = reason
        self.location = location
        # Quoting prevents filename control characters from forging output.
        suffix = '' if location is None else ' at ' + json.dumps(os.fspath(location), ensure_ascii=True)
        super().__init__(reason + suffix)


def locate_failure(error, path):
    return error if error.location is not None else IndexUnavailable(error.reason, path)


class Activity:
    def __init__(self, epoch, sources):
        self.epoch = epoch
        self.sources = sources


def stat_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def bash_path(path):
    """Represent native Windows paths like the corresponding Git Bash cwd."""
    if path.startswith('\\\\?\\UNC\\'):
        path = '\\\\' + path[8:]
    elif path.startswith('\\\\?\\'):
        path = path[4:]
    if re.match(r'^[A-Za-z]:[/\\]', path):
        normalized = ntpath.normpath(path).replace('\\', '/')
        return '/' + normalized[0].lower() + normalized[2:]
    if path.startswith('\\\\'):
        return posixpath.normpath(path.replace('\\', '/'))
    return posixpath.normpath(path)


def normalize_workspace(value):
    if not isinstance(value, str) or not value:
        raise IndexUnavailable('invalid workspace metadata')
    if any(unicodedata.category(char) in ('Cc', 'Cs') for char in value):
        raise IndexUnavailable('workspace metadata contains unsupported control characters')
    windows_path = bool(re.match(r'^[A-Za-z]:[/\\]', value)) or value.startswith('\\\\')
    if not windows_path and not value.startswith('/'):
        raise IndexUnavailable('workspace metadata is not an absolute path')
    try:
        if os.name == 'nt':
            if windows_path:
                normalized = bash_path(os.path.realpath(value))
            elif re.match(r'^/[A-Za-z](/|$)', value):
                native = value[1].upper() + ':' + value[2:].replace('/', '\\')
                normalized = bash_path(os.path.realpath(native + ('\\' if len(native) == 2 else '')))
            elif value.startswith('//'):
                normalized = bash_path(os.path.realpath(value.replace('/', '\\')))
            else:
                # Real MSYS mounts such as /tmp need cygpath. Do not convert
                # virtual Unix fixture paths into the Git installation's cwd.
                try:
                    converted = subprocess.run(['cygpath', '-w', value],
                                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                               check=False, universal_newlines=True)
                    native = converted.stdout.rstrip('\r\n')
                except OSError:
                    native = ''
                if native and converted.returncode == 0 and os.path.exists(native):
                    normalized = bash_path(os.path.realpath(native))
                else:
                    normalized = posixpath.normpath(value)
        else:
            normalized = os.path.realpath(bash_path(value) if windows_path else value)
    except (OSError, ValueError):
        raise IndexUnavailable('workspace path normalization failed') from None
    if not normalized.startswith('/'):
        raise IndexUnavailable('workspace normalization did not produce an absolute path')
    if any(unicodedata.category(char) in ('Cc', 'Cs') for char in normalized):
        raise IndexUnavailable('normalized workspace contains unsupported control characters')
    return normalized


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate object key')
        result[key] = value
    return result


def invalid_constant(_value):
    raise ValueError('non-JSON numeric constant')


def claude_workspaces(record):
    if 'cwd' in record:
        yield normalize_workspace(record['cwd'])


def codex_workspaces(record):
    if record.get('type') in ('session_meta', 'turn_context'):
        payload = record.get('payload')
        if not isinstance(payload, dict) or 'cwd' not in payload:
            raise IndexUnavailable('Codex session metadata lacks a workspace')
        yield normalize_workspace(payload['cwd'])


def observe(observations, path, info, follow_symlinks):
    if observations is not None:
        observations.append((path, None if info is None else stat_identity(info), follow_symlinks))


def inspect_transcript(path, provider, index, observations=None):
    try:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode):
            raise IndexUnavailable('transcript is not a regular file')
        observe(observations, path, before, False)
        workspaces = set()
        records = 0
        reader = claude_workspaces if provider == 'claude-transcript' else codex_workspaces
        with open(path, 'rb') as source:
            opened = os.fstat(source.fileno())
            # CPython's Windows path stat exposes legacy creation-time ctime,
            # while fstat can expose metadata ChangeTime. Permission bits can
            # also depend on the pathname. Bind the handle to the same object
            # using device/inode and compare shared content metadata; retain
            # full same-API baselines for later change/replacement checks.
            if (not before.st_ino or not opened.st_ino
                    or not os.path.samestat(before, opened)
                    or not stat.S_ISREG(opened.st_mode)
                    or opened.st_size != before.st_size
                    or opened.st_mtime_ns != before.st_mtime_ns
                    or stat_identity(os.lstat(path)) != stat_identity(before)):
                raise IndexUnavailable('transcript changed before it could be read')
            while True:
                raw = source.readline(MAX_RECORD_BYTES + 1)
                if not raw:
                    break
                if len(raw) > MAX_RECORD_BYTES:
                    raise IndexUnavailable('transcript record exceeds the 32 MiB inspection limit')
                try:
                    record = json.loads(raw, object_pairs_hook=unique_object,
                                        parse_constant=invalid_constant)
                except (ValueError, UnicodeError, RecursionError):
                    raise IndexUnavailable('malformed or incomplete transcript record') from None
                if not isinstance(record, dict):
                    raise IndexUnavailable('transcript record is not an object')
                workspaces.update(reader(record))
                records += 1
                del record, raw
            if stat_identity(os.fstat(source.fileno())) != stat_identity(opened):
                raise IndexUnavailable('transcript changed while it was being read')
        if stat_identity(os.lstat(path)) != stat_identity(before):
            raise IndexUnavailable('transcript was replaced while it was being read')
        if not records or not workspaces:
            raise IndexUnavailable('transcript has no readable workspace metadata')
        epoch = before.st_mtime_ns // 1_000_000_000
        if epoch < 0:
            raise IndexUnavailable('transcript activity time is unavailable')
        # A resumed file's mtime conservatively refreshes every cwd it records,
        # including earlier directories where its processes may still remain.
        for cwd in workspaces:
            if cwd not in index:
                index[cwd] = Activity(epoch, {provider})
            else:
                index[cwd].epoch = max(index[cwd].epoch, epoch)
                index[cwd].sources.add(provider)
    except IndexUnavailable as error:
        raise locate_failure(error, path) from None
    except OSError:
        raise IndexUnavailable('transcript could not be completely read', path) from None


def scan_directory(path, provider, index, optional=False, max_depth=None,
                   include_files=True, observations=None):
    try:
        try:
            before_link = os.lstat(path)
        except FileNotFoundError:
            if optional:
                observe(observations, path, None, False)
                return
            raise
        # A configured root may be a symlink; resolve it once. Symlinks found
        # inside a provider tree are refused rather than silently skipped.
        before = os.stat(path)
        if not stat.S_ISDIR(before.st_mode):
            raise IndexUnavailable('transcript root or folder is not a directory')
        observe(observations, path, before_link, False)
        observe(observations, path, before, True)
        with os.scandir(path) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    if max_depth != 0 or (include_files and entry.name.endswith('.jsonl')):
                        raise IndexUnavailable('transcript tree contains a symlink')
                    continue
                if stat.S_ISDIR(info.st_mode):
                    if max_depth is None or max_depth > 0:
                        remaining = None if max_depth is None else max_depth - 1
                        scan_directory(entry.path, provider, index, max_depth=remaining,
                                       observations=observations)
                elif include_files and entry.name.endswith('.jsonl'):
                    inspect_transcript(entry.path, provider, index, observations)
        if (stat_identity(os.stat(path)) != stat_identity(before)
                or stat_identity(os.lstat(path)) != stat_identity(before_link)):
            raise IndexUnavailable('transcript directory changed during inspection')
    except IndexUnavailable as error:
        raise locate_failure(error, path) from None
    except OSError:
        raise IndexUnavailable('transcript root or folder could not be completely inspected', path) from None


def scan_claude(root, index, observations=None):
    # Match the documented Claude layout: immediate project directories and
    # their direct JSONL session files. Nested subagent data is outside scope.
    scan_directory(root, 'claude-transcript', index, optional=True,
                   max_depth=1, include_files=False, observations=observations)


def scan_codex(root, index, observations=None):
    try:
        try:
            before_link = os.lstat(root)
        except FileNotFoundError:
            observe(observations, root, None, False)
            return
        before = os.stat(root)
        if not stat.S_ISDIR(before.st_mode):
            raise IndexUnavailable('Codex home is not a directory')
        observe(observations, root, before_link, False)
        observe(observations, root, before, True)
        # Inspect only transcript trees, never databases, logs or report text.
        for name in ('sessions', 'archived_sessions'):
            scan_directory(os.path.join(root, name), 'codex-transcript', index,
                           optional=True, observations=observations)
        if stat_identity(os.stat(root)) != stat_identity(before):
            raise IndexUnavailable('Codex home changed during inspection')
    except IndexUnavailable as error:
        raise locate_failure(error, root) from None
    except OSError:
        raise IndexUnavailable('Codex home could not be inspected', root) from None


def propagate_ancestor_activity(index):
    for cwd in sorted(index, key=lambda value: (len(value), value)):
        parent = posixpath.dirname(cwd)
        while parent and parent != cwd:
            if parent in index and index[parent].epoch >= index[cwd].epoch:
                index[cwd].epoch = index[parent].epoch
                index[cwd].sources.update(index[parent].sources)
            ancestor = posixpath.dirname(parent)
            if ancestor == parent:
                break
            parent = ancestor


def collect(claude_root, codex_root):
    index = {}
    observations = []
    for provider, scanner, root in (
            ('Claude', scan_claude, claude_root), ('Codex', scan_codex, codex_root)):
        try:
            scanner(root, index, observations)
        except IndexUnavailable as error:
            # Reasons are authored strings, never parser excerpts or transcripts.
            raise IndexUnavailable(provider + ' activity unavailable: ' + str(error)) from None
    propagate_ancestor_activity(index)
    # Providers can take several seconds to scan. Recheck earlier observations
    # after the final provider so new Claude activity cannot be hidden by time
    # spent reading Codex history. This remains a snapshot, not an OS lock.
    try:
        for path, before, follow_symlinks in observations:
            try:
                after = os.stat(path) if follow_symlinks else os.lstat(path)
            except FileNotFoundError:
                if before is None:
                    continue
                raise
            if before is None or stat_identity(after) != before:
                raise IndexUnavailable('Workspace activity unavailable: transcript tree changed before index completion', path)
    except OSError:
        raise IndexUnavailable('Workspace activity unavailable: final transcript inspection failed', path) from None
    return index


def main(argv=None):
    # This TSV is consumed by Bash read as well as awk. Native Windows stdout
    # otherwise adds CR to the final field, making a workspace path unmatchable.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude-root', required=True)
    parser.add_argument('--codex-root', required=True)
    parser.add_argument('--sources', action='store_true')
    args = parser.parse_args(argv)
    try:
        index = collect(args.claude_root, args.codex_root)
    except IndexUnavailable as error:
        print(str(error), file=sys.stderr)
        return 1
    # No output escapes until every provider and file has passed inspection.
    for cwd, activity in sorted(index.items()):
        row = str(activity.epoch) + '\t' + cwd
        if args.sources:
            row += '\t' + ','.join(sorted(activity.sources))
        print(row)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
