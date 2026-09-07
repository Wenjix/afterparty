#!/usr/bin/env bash
# Transcript-provider regressions. Reads only disposable transcript fixtures;
# no process discovery, signals, cleanup, or real user history is involved.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO/skills/afterparty/lib" "$BASH" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

LIB = Path(sys.argv[1])
BASH = sys.argv[2]
spec = importlib.util.spec_from_file_location('workspace_index', LIB / 'workspace-index.py')
indexer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indexer)


def expected_path(path):
    value = Path(path).resolve().as_posix()
    if len(value) > 2 and value[1] == ':':
        return '/' + value[0].lower() + value[2:]
    return value


class TranscriptIndex(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='afterparty-index-')
        self.root = Path(self.temp.name)
        self.claude = self.root / 'claude'
        self.codex = self.root / 'codex'
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def transcript(self, path, records, epoch):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(row, ensure_ascii=True) + '\n' for row in records), encoding='utf-8')
        os.utime(path, (epoch, epoch))
        return path

    def claude_file(self, epoch, cwd=None, name='project/session.jsonl'):
        return self.transcript(self.claude / name, [{'cwd': str(cwd or self.workspace)}], epoch)

    def codex_file(self, epoch, cwds=None, name='sessions/2026/09/07/session.jsonl'):
        cwds = cwds or [self.workspace]
        rows = [{'type': 'session_meta' if i == 0 else 'turn_context', 'payload': {'cwd': str(cwd)}}
                for i, cwd in enumerate(cwds)]
        return self.transcript(self.codex / name, rows, epoch)

    def collect(self):
        return indexer.collect(str(self.claude), str(self.codex))

    def assert_atomic_failure(self):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            rc = indexer.main(['--claude-root', str(self.claude), '--codex-root', str(self.codex)])
        self.assertEqual(rc, 1)
        self.assertEqual(output.getvalue(), '')
        self.assertIn('unavailable:', errors.getvalue())
        self.assertNotIn('PRIVATE_BODY', errors.getvalue())
        return errors.getvalue()

    def test_01_merge_newest_across_all_sessions_and_provider_orders(self):
        self.claude_file(100, name='project/aaa.jsonl')
        self.claude_file(300, name='other-project/zzz.jsonl')
        self.codex_file(200)
        key = expected_path(self.workspace)
        rows = self.collect()
        self.assertEqual(list(rows), [key])
        self.assertEqual(rows[key].epoch, 300)
        self.assertEqual(rows[key].sources, {'claude-transcript', 'codex-transcript'})
        reverse = {}
        indexer.scan_codex(str(self.codex), reverse)
        indexer.scan_claude(str(self.claude), reverse)
        self.assertEqual(reverse[key].epoch, 300)
        self.codex_file(400)
        self.assertEqual(self.collect()[key].epoch, 400)

    def test_02_resumed_old_date_folder_refreshes_all_cwds(self):
        moved = self.root / 'moved'
        moved.mkdir()
        self.claude_file(100)
        self.codex_file(500, [self.workspace, moved], 'sessions/2001/01/01/resumed.jsonl')
        rows = self.collect()
        self.assertEqual(rows[expected_path(self.workspace)].epoch, 500)
        self.assertEqual(rows[expected_path(moved)].epoch, 500)

    def test_03_archived_sessions_participate(self):
        self.claude_file(100)
        self.codex_file(600, name='archived_sessions/resumed.jsonl')
        self.assertEqual(self.collect()[expected_path(self.workspace)].epoch, 600)

    def test_04_escaped_metadata_and_body_fields_are_distinguished(self):
        named = self.root / 'プロジェクト with spaces'
        named.mkdir()
        path = self.codex_file(200, [named])
        with path.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'type': 'response_item', 'payload': {'cwd': 'PRIVATE_BODY',
                                     'text': '"cwd":"/unrelated"'}}) + '\n')
        os.utime(path, (200, 200))
        rows = self.collect()
        self.assertEqual(list(rows), [expected_path(named)])
        if os.name != 'nt':
            quoted = self.root / 'quote" and back\\slash'
            quoted.mkdir()
            self.codex_file(300, [quoted], 'archived_sessions/quoted.jsonl')
            self.assertIn(expected_path(quoted), self.collect())

    def test_05_invalid_workspace_metadata_never_allows_stale_fallback(self):
        self.claude_file(100)
        for bad in ['relative/path', '/path\twithtab', '/path\nnewline', '/bad\x00path', None, 123]:
            with self.subTest(bad=repr(bad)):
                self.transcript(self.codex / 'sessions/recent.jsonl',
                                [{'type': 'session_meta', 'payload': {'cwd': bad}}], 200)
                self.assert_atomic_failure()

    def test_06_corrupt_recent_file_and_partial_trailing_record_are_unavailable(self):
        self.claude_file(100)
        path = self.codex_file(200)
        for bad in ['{"type":"session_meta","payload": PRIVATE_BODY',
                    '{"type":"turn_context","payload":']:
            with self.subTest(bad=bad):
                self.codex_file(200)
                with path.open('a', encoding='utf-8') as stream:
                    stream.write(bad)
                self.assert_atomic_failure()

    def test_07_unreadable_file_and_discovery_fail_without_partial_rows(self):
        self.claude_file(100)
        path = self.codex_file(200)
        real_open = open
        reads = []
        def denied_file(candidate, *args, **kwargs):
            if os.fspath(candidate) == str(path):
                reads.append(candidate)
                raise PermissionError('PRIVATE_BODY')
            return real_open(candidate, *args, **kwargs)
        with patch('builtins.open', side_effect=denied_file):
            self.assertIn(json.dumps(str(path)), self.assert_atomic_failure())
        self.assertEqual(len(reads), 1)
        real_scan = os.scandir
        scans = []
        def denied_folder(candidate):
            if os.fspath(candidate) == str(path.parent):
                scans.append(candidate)
                raise PermissionError('PRIVATE_BODY')
            return real_scan(candidate)
        with patch.object(indexer.os, 'scandir', side_effect=denied_folder):
            self.assertIn(json.dumps(str(path.parent)), self.assert_atomic_failure())
        self.assertEqual(len(scans), 1)

    def test_08_empty_optional_roots_succeed_and_non_directory_roots_fail(self):
        self.assertEqual(self.collect(), {})
        self.claude.mkdir()
        self.codex.mkdir()
        self.assertEqual(self.collect(), {})
        self.codex.rmdir()
        self.codex.write_text('PRIVATE_BODY', encoding='utf-8')
        self.assert_atomic_failure()

    def test_09_newer_ancestor_activity_withholds_stale_descendants(self):
        child = self.workspace / 'nested'
        child.mkdir()
        similar = self.root / 'workspace-other'
        similar.mkdir()
        self.claude_file(100, child)
        self.claude_file(100, similar, name='other/session.jsonl')
        self.codex_file(600)
        rows = self.collect()
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[expected_path(child)].epoch, 600)
        self.assertEqual(rows[expected_path(child)].sources, {'claude-transcript', 'codex-transcript'})
        self.assertEqual(rows[expected_path(similar)].epoch, 100)

    def test_10_existing_aliases_merge_without_collapsing_worktrees(self):
        alias = self.root / 'alias'
        try:
            alias.symlink_to(self.workspace, target_is_directory=True)
        except OSError:
            self.skipTest('native symlinks unavailable')
        self.claude_file(100, self.workspace)
        self.codex_file(200, [alias])
        rows = self.collect()
        self.assertEqual(list(rows), [expected_path(self.workspace)])
        self.assertEqual(rows[expected_path(self.workspace)].epoch, 200)

    def test_11_claude_scope_ignores_root_and_nested_non_session_files(self):
        self.claude_file(100)
        (self.claude / 'ignored.jsonl').write_text('PRIVATE_BODY', encoding='utf-8')
        nested = self.claude / 'project/subagents'
        nested.mkdir()
        (nested / 'ignored.jsonl').write_text('PRIVATE_BODY', encoding='utf-8')
        self.assertEqual(self.collect()[expected_path(self.workspace)].epoch, 100)

    def test_12_record_limit_has_a_working_positive_control(self):
        self.claude_file(100)
        path = self.codex_file(200)
        row = json.dumps({'type': 'response_item', 'payload': 'PRIVATE_BODY'})
        with path.open('a', encoding='utf-8') as stream:
            stream.write(row + '\n')
        valid_size = max(map(len, path.read_bytes().splitlines(keepends=True)))
        with patch.object(indexer, 'MAX_RECORD_BYTES', valid_size):
            self.assertIn(expected_path(self.workspace), self.collect())
        with patch.object(indexer, 'MAX_RECORD_BYTES', valid_size - 1):
            errors = self.assert_atomic_failure()
        self.assertIn('inspection limit', errors)

    def test_13_file_changes_during_inspection_are_detected(self):
        self.claude_file(100)
        target = self.codex_file(200)
        original_reader = indexer.codex_workspaces
        entered = []
        def append_after_parse(record):
            entered.append(True)
            with target.open('ab') as stream:
                stream.write(b'{"type":"response_item"}\n')
            yield from original_reader(record)
        # Alter only the metadata record to avoid extending the stream forever.
        def changed_reader(record):
            if record.get('type') == 'session_meta':
                yield from append_after_parse(record)
            else:
                yield from original_reader(record)
        with patch.object(indexer, 'codex_workspaces', side_effect=changed_reader):
            self.assertIn('changed', self.assert_atomic_failure())
        self.assertEqual(len(entered), 1)

    def test_14_shell_roots_overrides_and_column_contract(self):
        self.claude_file(100)
        self.codex_file(200)
        override = self.root / 'override'
        moved = self.root / 'other-workspace'
        moved.mkdir()
        self.transcript(override / 'sessions/one.jsonl',
                        [{'type': 'session_meta', 'payload': {'cwd': str(moved)}}], 300)
        env = dict(os.environ, AFTERPARTY_TRANSCRIPT_ROOT=str(self.claude),
                   CODEX_HOME=str(self.codex), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
        env.pop('AFTERPARTY_CODEX_ROOT', None)
        def run(sources=False):
            command = '. "$1"; ws_index' + (' --sources' if sources else '')
            # Bash uses this argument in BASH_SOURCE/dirname; native Windows
            # backslashes must not turn its library directory into '.'.
            result = subprocess.run([BASH, '-c', command, '_', (LIB / 'workspace.sh').as_posix()],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    universal_newlines=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            return [line.split('\t') for line in result.stdout.splitlines()]
        rows = run()
        self.assertEqual(rows, [['200', expected_path(self.workspace)]])
        self.assertEqual(run(True), [['200', expected_path(self.workspace), 'claude-transcript,codex-transcript']])
        env['AFTERPARTY_CODEX_ROOT'] = str(override)
        self.assertEqual({row[1] for row in run()}, {expected_path(self.workspace), expected_path(moved)})

    def test_15_normalized_alias_cannot_introduce_control_characters(self):
        if os.name == 'nt':
            self.skipTest('Windows does not permit control characters in directory names')
        unsafe = self.root / 'unsafe\tname'
        unsafe.mkdir()
        alias = self.root / 'safe-alias'
        try:
            alias.symlink_to(unsafe, target_is_directory=True)
        except OSError:
            self.skipTest('native symlinks unavailable')
        self.claude_file(100)
        self.codex_file(200, [alias])
        self.assertIn('normalized workspace', self.assert_atomic_failure())

    def test_16_later_provider_cannot_hide_new_activity_in_an_earlier_file(self):
        target = self.claude_file(100)
        self.codex_file(200)
        original_scan = indexer.scan_codex
        entered = []
        def changed_scan(root, index, observations=None):
            original_scan(root, index, observations)
            with target.open('a', encoding='utf-8') as stream:
                stream.write(json.dumps({'cwd': str(self.workspace)}) + '\n')
            entered.append(True)
        with patch.object(indexer, 'scan_codex', side_effect=changed_scan):
            self.assertIn('before index completion', self.assert_atomic_failure())
        self.assertEqual(len(entered), 1)

    def test_17_new_optional_provider_root_is_detected_before_emit(self):
        self.codex_file(200)
        original_scan = indexer.scan_codex
        def created_scan(root, index, observations=None):
            original_scan(root, index, observations)
            self.claude_file(500)
        with patch.object(indexer, 'scan_codex', side_effect=created_scan):
            self.assertIn('before index completion', self.assert_atomic_failure())

    def descriptor_stat(self, fd, **changes):
        # Match the fields consumed by stat_identity and samestat without
        # depending on the host's ability to construct Windows stat_result.
        actual = self.real_fstat(fd)
        values = {name: getattr(actual, name) for name in
                  ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')}
        values.update(changes)
        return SimpleNamespace(**values)

    def test_18_cross_api_windows_ctime_and_permissions_do_not_fake_drift(self):
        target = self.claude_file(100)
        before = target.stat()
        self.real_fstat = os.fstat
        calls = []
        def windows_fstat(fd):
            calls.append(fd)
            return self.descriptor_stat(fd, st_ctime_ns=before.st_ctime_ns + 1_000_000,
                                        st_mode=before.st_mode ^ indexer.stat.S_IXUSR)
        with patch.object(indexer.os, 'fstat', side_effect=windows_fstat):
            rows = self.collect()
        self.assertEqual(len(calls), 2)
        self.assertEqual(rows[expected_path(self.workspace)].epoch, 100)

    def test_19_descriptor_changes_remain_a_refusal_with_distinct_baseline(self):
        target = self.claude_file(100)
        before = target.stat()
        self.real_fstat = os.fstat
        calls = []
        def changed_fstat(fd):
            calls.append(fd)
            return self.descriptor_stat(fd, st_ctime_ns=before.st_ctime_ns + 1_000_000 + len(calls))
        with patch.object(indexer.os, 'fstat', side_effect=changed_fstat):
            self.assertIn('while it was being read', self.assert_atomic_failure())
        self.assertEqual(len(calls), 2)

    def test_20_opened_handle_must_match_path_identity_and_content_metadata(self):
        target = self.claude_file(100)
        before = target.stat()
        self.real_fstat = os.fstat
        for field in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns'):
            with self.subTest(field=field):
                calls = []
                def replaced_fstat(fd):
                    calls.append(fd)
                    return self.descriptor_stat(fd, **{field: getattr(before, field) + 1})
                with patch.object(indexer.os, 'fstat', side_effect=replaced_fstat):
                    self.assertIn('before it could be read', self.assert_atomic_failure())
                self.assertEqual(len(calls), 1)

    def test_21_virtual_unix_workspaces_preserve_git_bash_identity(self):
        for cwd in ('/w/loupe', '/w/プロジェクト/web'):
            with self.subTest(cwd=cwd):
                self.assertEqual(indexer.normalize_workspace(cwd), cwd)


suite = unittest.defaultTestLoader.loadTestsFromTestCase(TranscriptIndex)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.wasSuccessful():
    print('ok: transcript index — %s provider, metadata, merge and failure checks' % result.testsRun)
raise SystemExit(not result.wasSuccessful())
PY
