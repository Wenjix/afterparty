"""Exercise the installed CLI interface, without importing its implementation."""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(sys.argv.pop(1))
BASH = sys.argv.pop(1)
if os.name == 'nt' and Path(BASH + '.exe').is_file():
    BASH += '.exe'


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='afterparty-docs-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'repository space'
        self.root.mkdir()
        self.bundle = self.base / 'installed skill'
        shutil.copytree(REPO / 'skills/afterparty', self.bundle)
        self.cli = self.bundle / 'bin/afterparty'
        self.env = os.environ.copy()
        self.env.update(XDG_CACHE_HOME=str(self.base / 'cache'), GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, AFTERPARTY_STYLE='never',
                        PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
        self.git('init', '-q')
        self.put('README.md', '# Project\nSee [CLI](docs/cli.md).\n')
        self.put('src/runner.py', 'MODE = "--legacy-mode"\n')
        self.put('docs/cli.md', '# Usage\nRun with `--legacy-mode`.\n')
        self.put('docs/plans/old.md', '# Old plan\nHistorical implementation record for v1.\nUsed `--legacy-mode`.\n')
        self.put('docs/unrelated.md', '# Unrelated topic\nStable prose.\n')
        self.put('.gitignore', 'ignored/\n')
        self.commit()
        self.initial = self.git('rev-parse', 'HEAD').stdout.strip()

    def put(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding='utf-8')

    def git(self, *args):
        result = subprocess.run(['git', '-C', str(self.root), *args], env=self.env,
                                capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def commit(self):
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def invoke(self, *args, success=True, command='docs', cwd=None):
        result = subprocess.run([BASH, str(self.cli), command, *args], cwd=cwd or self.root,
                                env=self.env, capture_output=True, text=True, encoding='utf-8')
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def scan(self, *args, success=True):
        result = self.invoke(*args, '--json', success=success)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(rows[0]['section'], 'docs_scope')
        return rows

    def changed(self):
        self.put('src/runner.py', 'MODE = "--new-mode"\n')

    def review(self, rows):
        return {'schema_version': 1, 'scan_id': rows[0]['scan_id'], 'status': 'complete',
                'summary': 'Checked current claims and preserved the historical plan.',
                'reviewed_paths': [row['path'] for row in rows if row['section'] == 'docs_document' and row['candidate']],
                'findings': [{'path': 'docs/cli.md', 'line': 2, 'finding': 'Example uses removed option.',
                              'confidence': 'confirmed', 'treatment': 'update', 'alternatives': ['flag'],
                              'reason': 'The implementation now exposes the replacement.',
                              'preview': '--- a/docs/cli.md\n+++ b/docs/cli.md\n@@ -2 +2 @@\n-Run with `--legacy-mode`.\n+Run with `--new-mode`.',
                              'decision': 'pending', 'evidence': [{'path': 'src/runner.py', 'line': 1,
                              'description': 'Defines --new-mode.'}]}]}

    def record(self, value, success=True):
        path = self.base / 'review input.json'
        path.write_text(json.dumps(value), encoding='utf-8')
        return self.invoke('--save-review', str(path), '--json', success=success)

    def tree(self):
        return {str(path.relative_to(self.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in self.root.rglob('*') if path.is_file() and '.git' not in path.parts}

    def test_collects_affected_docs_without_mutation_or_staleness_verdicts(self):
        self.changed()
        before = self.tree()
        rows = self.scan()
        docs = {row['path']: row for row in rows if row['section'] == 'docs_document'}
        self.assertEqual(rows[0]['collection_status'], 'complete')
        self.assertEqual(rows[0]['review_status'], 'not-reviewed')
        self.assertTrue(docs['README.md']['candidate'])
        self.assertTrue(docs['docs/cli.md']['candidate'])
        self.assertFalse(docs['docs/unrelated.md']['candidate'])
        self.assertEqual(docs['docs/plans/old.md']['purpose_hint'], 'historical')
        self.assertIn('--legacy-mode', json.dumps(docs['docs/cli.md']['reasons']))
        self.assertEqual(before, self.tree())
        self.assertFalse((self.base / 'cache').exists())

    def test_since_includes_committed_work_and_default_discloses_its_scope(self):
        self.changed()
        self.commit()
        default = self.scan()
        self.assertFalse(any(row.get('candidate') for row in default))
        self.assertIn('earlier session commits are not included', default[0]['scope'])
        since = self.scan('--since', self.initial)
        self.assertTrue(any(row.get('path') == 'docs/cli.md' and row.get('candidate') for row in since))
        self.assertEqual(since[0]['base'], self.initial)
        self.invoke('--since', 'missing-ref', success=False)
        self.invoke('--since=--help', success=False)

    def test_staged_unstaged_untracked_deleted_and_renamed_paths(self):
        self.changed()
        self.git('add', 'src/runner.py')
        self.put('docs/cli.md', '# CLI changed locally\n')
        self.put('notes/新 note.md', '# New notes\n')
        self.git('mv', 'docs/unrelated.md', 'docs/renamed.md')
        rows = self.scan()
        changed = {row['path']: row for row in rows if row['section'] == 'docs_change'}
        self.assertTrue({'src/runner.py', 'docs/cli.md', 'notes/新 note.md', 'docs/unrelated.md', 'docs/renamed.md'} <= changed.keys())
        self.assertEqual(changed['docs/unrelated.md']['state'], 'deleted')
        self.assertEqual(changed['notes/新 note.md']['state'], 'untracked')

    def test_full_scope_ignores_dependencies_and_checks_markdown_links(self):
        self.put('node_modules/package/README.md', '# Dependency\n')
        self.put('ignored/notes.md', '# Ignore\n')
        self.put('docs/My Guide.md', '# Guide\n')
        self.put('docs/links.md', '# Links\n[good](<My Guide.md>)\n[missing](missing.md)\n'
                 '[reference]: absent.md\n```md\n[fake](fake.md)\n```\n`[literal](literal.md)`\n'
                 '[web](https://invalid.example/a.md)\n[site](/guide)\n[heading](#top)\n')
        rows = self.scan('--full')
        docs = {row['path'] for row in rows if row['section'] == 'docs_document'}
        self.assertIn('docs/unrelated.md', docs)
        self.assertNotIn('ignored/notes.md', docs)
        self.assertNotIn('node_modules/package/README.md', docs)
        missing = {row['target'] for row in rows if row['section'] == 'docs_observation'}
        self.assertEqual(missing, {'docs/missing.md', 'docs/absent.md'})
        self.assertTrue(all(row['confidence'] == 'needs-review' for row in rows if row['section'] == 'docs_observation'))

    def test_empty_repository_and_root_from_another_directory(self):
        empty = self.base / 'empty'
        empty.mkdir()
        subprocess.run(['git', 'init', '-q', str(empty)], env=self.env, check=True)
        (empty / 'README.md').write_text('# New\n')
        result = self.invoke('--root', str(empty), '--json', cwd=self.base)
        header = json.loads(result.stdout.splitlines()[0])
        self.assertIsNone(header['base'])
        self.assertEqual(Path(header['root']), empty.resolve())
        self.assertIn('document-changed', result.stdout)

    def test_saved_review_and_findings_survive_another_scan(self):
        self.changed()
        rows = self.scan('--report')
        before = self.tree()
        record = json.loads(self.record(self.review(rows)).stdout)
        self.assertTrue(record['basis_current'])
        self.assertEqual(record['findings'][0]['id'], 1)
        self.assertEqual(before, self.tree())
        self.scan('--full', '--report')
        shown = json.loads(self.invoke('--show', '--json').stdout)
        self.assertEqual(shown['scan_id'], rows[0]['scan_id'])
        self.assertEqual(shown['findings'][0]['decision'], 'pending')
        report_path = Path(self.invoke('--report-path').stdout.strip())
        self.assertTrue(report_path.is_file())
        self.assertIn('Example uses removed option', report_path.read_text())
        reminder = self.invoke('--remind', command='report').stdout
        self.assertIn('1 unresolved', reminder)
        self.assertIn('agent review is separate', reminder)
        if os.name != 'nt':
            for path in (self.base / 'cache').rglob('*'):
                self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)

    def test_check_rejects_changed_evidence_and_preserves_action_outcomes(self):
        self.changed()
        rows = self.scan('--report')
        scan_id = rows[0]['scan_id']
        self.assertIn('still matches', self.invoke('--check', scan_id).stdout)
        review = self.review(rows)
        self.record(review)
        self.put('docs/cli.md', '# Usage\nRun with `--new-mode`.\n')
        refusal = self.invoke('--check', scan_id, '--json', success=False)
        self.assertFalse(json.loads(refusal.stdout)['current'])
        review['findings'][0]['decision'] = 'resolved'
        record = json.loads(self.record(review).stdout)
        self.assertFalse(record['basis_current'])
        self.assertEqual(record['findings'][0]['decision'], 'resolved')
        self.assertEqual(len(list((self.base / 'cache').rglob('reviews/*.json'))), 2)

    def test_check_rejects_source_change_even_when_docs_unchanged(self):
        self.changed()
        rows = self.scan('--report')
        self.put('src/runner.py', 'MODE = "--another-mode"\n')
        self.assertIn('changed or is incomplete', self.invoke('--check', rows[0]['scan_id'], success=False).stdout)

    def test_check_rejects_changed_link_evidence_even_for_ignored_targets(self):
        self.put('README.md', '# Project\n[generated note](ignored/note.md)\n')
        rows = self.scan('--report')
        self.assertTrue(any(row.get('kind') == 'unresolved-local-link' for row in rows))
        self.assertIn('still matches', self.invoke('--check', rows[0]['scan_id']).stdout)
        self.put('ignored/note.md', '# Generated\n')
        self.assertIn('changed or is incomplete', self.invoke('--check', rows[0]['scan_id'], success=False).stdout)

    def test_review_rejects_unsupported_or_unreviewed_actions(self):
        self.changed()
        rows = self.scan('--report')
        review = self.review(rows)
        cases = []
        value = copy.deepcopy(review); value['reviewed_paths'] = []; cases.append((value, 'every candidate'))
        value = copy.deepcopy(review); value['findings'][0]['treatment'] = 'rm-rf'; cases.append((value, 'unknown treatment'))
        value = copy.deepcopy(review); value['findings'][0]['preview'] = ''; cases.append((value, 'concrete change preview'))
        value = copy.deepcopy(review); value['findings'][0]['evidence'][0]['path'] = '../outside'; cases.append((value, 'escapes repository'))
        value = copy.deepcopy(review); value['findings'][0]['confidence'] = 'needs-review'; cases.append((value, 'uncertain findings'))
        for invalid, message in cases:
            with self.subTest(message=message):
                self.assertIn(message, self.record(invalid, success=False).stderr)
        self.assertFalse(list((self.base / 'cache').rglob('reviews/*.json')))
        self.record(review)  # Positive control enters the writer after all refusals.

    def test_redaction_keeps_multiline_previews_valid_json(self):
        self.changed()
        rows = self.scan('--report')
        review = self.review(rows)
        review['summary'] = 'Observed --password "private multiword"\nSecond line.'
        review['findings'][0]['preview'] += '\n+ TOKEN=preview-secret\n+ More content'
        result = self.record(review)
        self.assertNotIn('private multiword', result.stdout)
        self.assertNotIn('preview-secret', result.stdout)
        record = json.loads(result.stdout)
        self.assertIn('[REDACTED]', record['summary'])
        self.assertIn('More content', record['findings'][0]['preview'])
        self.assertNotIn('preview-secret', self.invoke('--show').stdout)

    def test_oversized_document_reports_incomplete_and_cannot_be_complete_review(self):
        self.put('docs/huge.md', 'x' * (2 * 1024 * 1024 + 1))
        rows = self.scan('--full', '--report', success=False)
        self.assertEqual(rows[0]['collection_status'], 'incomplete')
        self.assertIn('exceeds 2 MiB', json.dumps(rows[-1]['errors']))
        self.assertIn('Inspection gaps', self.invoke('--show', success=False).stdout)
        self.invoke('--check', rows[0]['scan_id'], success=False)
        review = self.review(rows)
        self.assertIn('complete collection', self.record(review, success=False).stderr)
        review['status'] = 'partial'
        review['findings'] = []
        self.record(review)

    def test_symlink_does_not_read_outside_repository(self):
        outside = self.base / 'outside.md'
        outside.write_text('outside-secret-do-not-read')
        try:
            (self.root / 'docs/escape.md').symlink_to(outside)
        except OSError:
            self.skipTest('symlinks unavailable')
        self.assertTrue((self.root / 'docs/escape.md').is_symlink())
        result = self.invoke('--full', '--json', success=False)
        self.assertIn('symlink excluded', result.stdout)
        self.assertNotIn('outside-secret-do-not-read', result.stdout)

    def test_scan_ids_are_bound_to_workspace_and_cannot_escape_state(self):
        self.changed()
        rows = self.scan('--report')
        self.invoke('--template', '../../escape', success=False)
        other = self.base / 'another'
        other.mkdir()
        subprocess.run(['git', 'init', '-q', str(other)], env=self.env, check=True)
        self.invoke('--root', str(other), '--template', rows[0]['scan_id'], success=False)
        template = json.loads(self.invoke('--template', rows[0]['scan_id']).stdout)
        self.assertEqual(template['reviewed_paths'], [])
        self.assertEqual(template['status'], 'partial')

    def test_read_only_interface_rejects_apply_and_bad_mode_combinations(self):
        before = self.tree()
        self.assertIn('--apply', self.invoke('--apply', success=False).stderr)
        self.invoke('--full', '--since', 'HEAD', success=False)
        self.invoke('--show', '--report', success=False)
        self.assertEqual(before, self.tree())
        self.assertIn('not reviewed', self.invoke('--full').stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
