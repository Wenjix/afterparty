#!/usr/bin/env python3
"""Documentation evidence and durable, explicitly agent-authored reviews.

This module never edits project files, executes documented commands, fetches
links, or decides that a document is stale. Its public interface is `docs.sh`.
Only the standard library and Git are needed. Stored evidence contains paths,
symbols and hashes, not source bodies; review prose uses the shared redactor.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import unquote, urlsplit
import uuid


SCHEMA = 1
MAX_FILE = 2 * 1024 * 1024
MAX_INPUT = 4 * 1024 * 1024
EXCLUDED = {'.git', 'node_modules', 'vendor', 'dist', 'build', 'coverage',
            '.next', '.nuxt', '.cache', '.venv', 'venv', '__pycache__', 'target'}
EXTENSIONS = {'.md', '.mdx', '.rst', '.adoc', '.asciidoc', '.txt'}
GUIDANCE = {'readme', 'readme.md', 'readme.rst', 'agents.md', 'claude.md',
            'contributing.md'}
TREATMENTS = ('update', 'mark-historical', 'consolidate', 'archive', 'delete', 'flag', 'keep')
DECISIONS = ('pending', 'deferred', 'resolved', 'dismissed')
TOKEN = re.compile(r'--[a-zA-Z][a-zA-Z0-9-]{2,}|\b[A-Z][A-Z0-9_]{3,}\b|'
                   r'\b(?:def|class|function|const)\s+([A-Za-z_][A-Za-z0-9_]{2,})')
LINK = re.compile(r'\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)]+)(?:\s+[^)\n]*)?\)|'
                  r'^\s{0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)')


class DocsError(Exception):
    pass


def encode(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def git(root, *args, optional=False):
    result = subprocess.run(['git', '-C', str(root), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    if result.returncode and not optional:
        raise DocsError('Git inspection failed: ' + result.stderr.decode('utf-8', 'replace').strip())
    return result


def names(data):
    try:
        paths = data.decode('utf-8').split('\0')
    except UnicodeDecodeError:
        raise DocsError('Git paths must be UTF-8') from None
    return sorted(set(path for path in paths if path))


def relative_path(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise DocsError('invalid repository-relative path')
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or '\\' in value or ':' in value:
        raise DocsError('path escapes repository or uses unsupported syntax: ' + encode(value))
    if str(path) != value or '.git' in path.parts:
        raise DocsError('path is not canonical: ' + encode(value))
    return value


def excluded(path):
    return bool(EXCLUDED.intersection(PurePosixPath(path).parts))


def is_doc(path):
    name = PurePosixPath(path).name.lower()
    return PurePosixPath(path).suffix.lower() in EXTENSIONS or name in GUIDANCE or name == 'changelog'


def safe_file(root, name):
    """Never traverse symlinks or another repository, including ignored ones."""
    relative_path(name)
    path = root
    parts = PurePosixPath(name).parts
    for index, part in enumerate(parts):
        path = path / part
        if path.is_symlink():
            raise DocsError('symlink excluded: ' + encode(name))
        if index < len(parts) - 1 and (path / '.git').exists():
            raise DocsError('nested repository excluded: ' + encode(name))
    return path


def read_file(root, name):
    path = safe_file(root, name)
    try:
        before = path.stat()
    except FileNotFoundError:
        return None, None
    if not stat.S_ISREG(before.st_mode):
        raise DocsError('not a regular file: ' + encode(name))
    if before.st_size > MAX_FILE:
        raise DocsError('file exceeds 2 MiB inspection limit: ' + encode(name))
    with path.open('rb') as stream:
        data = stream.read(MAX_FILE + 1)
    after = path.stat()
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if len(data) > MAX_FILE or identity(before) != identity(after) or path.is_symlink():
        raise DocsError('file changed during inspection: ' + encode(name))
    return data, digest(data)


def visible_lines(text):
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is None:
            yield number, re.sub(r'(`+).*?\1', '', line)


def local_links(root, path, text):
    """Conservative Markdown destinations; anchors and site routes aren't checked."""
    links = []
    if PurePosixPath(path).suffix.lower() not in ('.md', '.mdx'):
        return links
    for line, content in visible_lines(text):
        for match in LINK.finditer(content):
            destination = (match.group(1) or match.group(2)).strip('<>')
            parsed = urlsplit(destination)
            if parsed.scheme or parsed.netloc or not parsed.path or parsed.path.startswith('/'):
                continue
            decoded = unquote(parsed.path)
            # Site routes, templates and complex Markdown need the agent's interpretation.
            if any(char in decoded for char in '{}<>') or not PurePosixPath(decoded).suffix:
                continue
            target = os.path.normpath(str(PurePosixPath(path).parent / decoded)).replace('\\', '/')
            try:
                target_path = safe_file(root, target)
                exists = target_path.exists()
            except (DocsError, OSError):
                continue
            links.append({'line': line, 'target': target, 'exists': exists})
    return links


def purpose(path, text):
    intro = text[:2000].lower()
    if 'historical implementation record' in intro or re.search(r'^status:\s*(historical|superseded|archived)', intro, re.M):
        return 'historical'
    parts = PurePosixPath(path).parts
    if PurePosixPath(path).name.lower().startswith('changelog'):
        return 'release-history'
    if 'plans' in parts:
        return 'plan'
    if 'reviews' in parts:
        return 'review-record'
    return 'unclassified'


def collect(root, since=None, full=False):
    head_result = git(root, 'rev-parse', '--verify', 'HEAD', optional=True)
    head = head_result.stdout.decode().strip() if head_result.returncode == 0 else None
    if since is not None:
        base_result = git(root, 'rev-parse', '--verify', '--end-of-options', since + '^{commit}')
        base = base_result.stdout.decode().strip()
    else:
        base = head
    files = names(git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').stdout)
    untracked = names(git(root, 'ls-files', '-z', '--others', '--exclude-standard').stdout)
    if base:
        diff_args = ('diff', '--no-ext-diff', '--no-textconv', '--no-renames')
        changed = names(git(root, *diff_args, '--name-only', '-z', base, '--').stdout)
        patch = git(root, *diff_args, '--unified=0', base, '--').stdout
    else:
        changed, patch = files[:], b''
    changed = sorted(set(changed + untracked))
    errors, skipped, hashes, changes, texts, documents = [], [], {}, [], {}, []
    if len(patch) > MAX_INPUT:
        errors.append('Git diff exceeds 4 MiB token inspection limit; changed paths are still reported')
        patch = b''
    tokens = set()
    for line in patch.decode('utf-8', 'replace').splitlines():
        if line.startswith(('+', '-')) and not line.startswith(('+++', '---')):
            for match in TOKEN.finditer(line[1:]):
                tokens.add(match.group(1) or match.group())
    if len(tokens) > 2000:
        errors.append('More than 2000 changed symbols; symbol matching was limited')
        tokens = set(sorted(tokens)[:2000])
    for path in sorted(set(files + changed)):
        try:
            relative_path(path.rstrip('/') if path.endswith('/') else path)
            if excluded(path):
                skipped.append({'path': path, 'reason': 'generated/dependency directory'})
                continue
            if path.endswith('/') or (root / path).is_dir():
                skipped.append({'path': path, 'reason': 'directory or submodule'})
                continue
            if path not in changed and not is_doc(path):
                continue
            data, sha = read_file(root, path)
            hashes[path] = sha
            if path in changed:
                changes.append({'path': path, 'sha256': sha, 'state': 'deleted' if data is None else
                                ('untracked' if path in untracked else 'changed')})
            if data is None or not is_doc(path):
                continue
            text = data.decode('utf-8')
            texts[path] = text
            documents.append({'path': path, 'sha256': sha, 'purpose_hint': purpose(path, text),
                              'candidate': False, 'reasons': [], 'links': local_links(root, path, text)})
        except (DocsError, OSError, UnicodeError, ValueError) as error:
            errors.append(str(error) + ' (' + encode(path) + ')')
    changed_paths = [item['path'] for item in changes]
    needles = set(changed_paths)
    needles.update(PurePosixPath(path).name for path in changed_paths if len(PurePosixPath(path).name) >= 5)
    needles.update(tokens)
    observations = []
    for doc in documents:
        path, reasons = doc['path'], doc['reasons']
        if full:
            reasons.append({'kind': 'full-review'})
        if path in changed_paths:
            reasons.append({'kind': 'document-changed'})
        parent = PurePosixPath(path).parent
        if changed_paths and PurePosixPath(path).name.lower() in GUIDANCE and any(
                parent == PurePosixPath('.') or parent in PurePosixPath(item).parents for item in changed_paths):
            reasons.append({'kind': 'project-guidance'})
        # References are hints, never proof that the surrounding claim is stale.
        for number, line in enumerate(texts[path].splitlines(), 1):
            matches = sorted(needle for needle in needles if needle in line)
            if matches:
                reasons.append({'kind': 'changed-reference', 'line': number, 'references': matches[:20]})
            if len(reasons) >= 25:
                break
        doc['candidate'] = bool(reasons)
        if doc['candidate']:
            for link in doc['links']:
                if not link['exists']:
                    observations.append({'path': path, 'line': link['line'], 'kind': 'unresolved-local-link',
                                         'target': link['target'], 'confidence': 'needs-review'})
    # Re-read inspected files and the inventory so an in-flight edit isn't a complete scan.
    for path, sha in hashes.items():
        try:
            if read_file(root, path)[1] != sha:
                errors.append('File changed during scan: ' + encode(path))
        except (DocsError, OSError) as error:
            errors.append(str(error))
    if names(git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').stdout) != files:
        errors.append('Repository file inventory changed during scan')
    final_head = git(root, 'rev-parse', '--verify', 'HEAD', optional=True)
    if (final_head.stdout.decode().strip() if final_head.returncode == 0 else None) != head:
        errors.append('HEAD changed during scan')
    scope = ('all repository documentation' if full else
             ('changes since ' + since if since else
              'staged, unstaged and untracked changes since HEAD; earlier session commits are not included'))
    signature = digest(encode({'base': base, 'head': head, 'files': files, 'hashes': hashes,
                               'links': {doc['path']: doc['links'] for doc in documents}}).encode())
    return {'schema_version': SCHEMA, 'scan_id': uuid.uuid4().hex, 'created_at': timestamp(),
            'root': str(root), 'mode': 'full' if full else 'changes', 'since': since, 'base': base,
            'head': head, 'scope': scope, 'collection_status': 'incomplete' if errors else 'complete',
            'review_status': 'not-reviewed', 'fingerprint': signature, 'changes': changes,
            'documents': documents, 'observations': observations, 'errors': errors,
            'excluded': skipped, 'persisted': False}


def atomic_write(path, text):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix='.docs-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{32}', value):
        raise DocsError('invalid scan/review identifier')
    return value


def load_json(path):
    if path.stat().st_size > MAX_INPUT:
        raise DocsError('JSON input exceeds 4 MiB')
    with path.open(encoding='utf-8') as stream:
        value = json.load(stream)
    if not isinstance(value, dict) or value.get('schema_version') != SCHEMA:
        raise DocsError('expected a schema_version: 1 object')
    return value


def load_scan(state, scan_id, root):
    scan = load_json(state / 'scans' / (identifier(scan_id) + '.json'))
    if scan['root'] != str(root) or scan['scan_id'] != scan_id:
        raise DocsError('scan belongs to another repository or identity')
    return scan


def scan_current(scan, root):
    # A branch name may disappear; the reviewed comparison used its resolved commit.
    current = collect(root, scan['base'], scan['mode'] == 'full')
    return (scan['collection_status'] == 'complete' and current['collection_status'] == 'complete'
            and scan['fingerprint'] == current['fingerprint'])


def markdown_scan(scan):
    candidates = [doc for doc in scan['documents'] if doc['candidate']]
    lines = ['# Afterparty documentation evidence', '', 'Scan: ' + scan['scan_id'],
             'Generated: ' + scan['created_at'], 'Scope: ' + scan['scope'],
             'Collection: ' + scan['collection_status'] + '. Agent review: not reviewed.',
             '', '%d changed paths; %d documentation candidates; %d documents inspected.' %
             (len(scan['changes']), len(candidates), len(scan['documents'])),
             'Purpose labels and unresolved links are review hints, not staleness verdicts.', '']
    for doc in candidates:
        lines.append('- ' + encode(doc['path']) + ' [' + doc['purpose_hint'] + ']: ' +
                     ', '.join(sorted(set(reason['kind'] for reason in doc['reasons']))))
    if not candidates:
        lines.append('No candidates in this scope. Use --since REF or --full to widen the review.')
    if scan['observations']:
        lines.extend(['', '## Mechanical observations', ''])
        for item in scan['observations']:
            lines.append('- %s:%s — unresolved local link to %s; needs review.' %
                         (encode(item['path']), item['line'], encode(item['target'])))
    if scan['excluded']:
        lines.extend(['', 'Excluded %d generated/dependency paths, directories or submodules.' % len(scan['excluded'])])
    if scan['errors']:
        lines.extend(['', '## Inspection gaps', ''] + ['- ' + error for error in scan['errors']])
    lines.extend(['', 'Treatments: ' + ', '.join(TREATMENTS) + '.',
                  'The agent must read candidates and implementation before recommending a treatment.',
                  'This command does not modify documentation.'])
    if scan['persisted']:
        lines.extend(['', 'Prepare a review record: afterparty docs --template ' + scan['scan_id'],
                      'Before editing reviewed files: afterparty docs --check ' + scan['scan_id']])
    return '\n'.join(lines) + '\n'


def json_rows(scan):
    header = {key: value for key, value in scan.items() if key not in
              ('changes', 'documents', 'observations', 'errors', 'excluded')}
    yield dict(header, section='docs_scope')
    for field, section in (('changes', 'docs_change'), ('documents', 'docs_document'),
                           ('observations', 'docs_observation')):
        for value in scan[field]:
            yield dict(value, schema_version=SCHEMA, section=section, scan_id=scan['scan_id'])
    yield {'schema_version': SCHEMA, 'section': 'docs_coverage', 'errors': scan['errors'],
           'excluded': scan['excluded'], 'scan_id': scan['scan_id']}


def save_scan(state, scan):
    scan['persisted'] = True
    scan_id = scan['scan_id']
    serialized = encode(scan) + '\n'
    if len(serialized.encode('utf-8')) > MAX_INPUT:
        raise DocsError('evidence exceeds 4 MiB persistence limit; narrow the repository scope')
    atomic_write(state / 'scans' / (scan_id + '.json'), serialized)
    path = state / 'scans' / (scan_id + '.md')
    atomic_write(path, markdown_scan(scan))
    atomic_write(state / 'latest-scan', scan_id + '\n')
    atomic_write(state / 'scan-summary.txt', 'Afterparty docs: evidence %s (%s); agent review is separate. %s\n' %
                 (scan_id, scan['collection_status'], path))
    return path


def nonempty(value, field):
    if not isinstance(value, str) or not value.strip():
        raise DocsError(field + ' must be nonempty text')
    return value


def validate_review(review, scan):
    if review.get('status') not in ('complete', 'partial'):
        raise DocsError('review status must be complete or partial')
    nonempty(review.get('summary'), 'summary')
    paths = review.get('reviewed_paths')
    known = {doc['path'] for doc in scan['documents']}
    candidates = {doc['path'] for doc in scan['documents'] if doc['candidate']}
    if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
        raise DocsError('reviewed_paths must be an array of document paths')
    if len(set(paths)) != len(paths) or not set(paths) <= known:
        raise DocsError('reviewed_paths contains duplicate or uninspected documents')
    if review['status'] == 'complete' and (scan['collection_status'] != 'complete' or not candidates <= set(paths)):
        raise DocsError('complete review requires complete collection and every candidate in reviewed_paths')
    findings = review.get('findings')
    if not isinstance(findings, list):
        raise DocsError('findings must be an array')
    for index, item in enumerate(findings, 1):
        if not isinstance(item, dict) or item.get('path') not in paths:
            raise DocsError('each finding must name a reviewed document')
        line = item.get('line')
        if type(line) is not int or line < 1:
            raise DocsError('finding line must be a positive integer')
        for field in ('finding', 'reason'):
            nonempty(item.get(field), field)
        if item.get('confidence') not in ('confirmed', 'needs-review'):
            raise DocsError('finding confidence must be confirmed or needs-review')
        if item.get('treatment') not in TREATMENTS or item.get('decision') not in DECISIONS:
            raise DocsError('unknown treatment or decision')
        alternatives = item.get('alternatives', [])
        if not isinstance(alternatives, list) or any(value not in TREATMENTS for value in alternatives):
            raise DocsError('unknown alternative treatment')
        if item['confidence'] == 'needs-review' and item['treatment'] not in ('flag', 'keep'):
            raise DocsError('uncertain findings must recommend flag or keep')
        if item['treatment'] not in ('flag', 'keep'):
            nonempty(item.get('preview'), 'concrete change preview')
        if 'preview' in item and not isinstance(item['preview'], str):
            raise DocsError('preview must be text')
        evidence = item.get('evidence')
        if not isinstance(evidence, list) or not evidence:
            raise DocsError('each finding needs evidence')
        for source in evidence:
            if not isinstance(source, dict):
                raise DocsError('evidence must contain objects')
            relative_path(source.get('path'))
            if type(source.get('line')) is not int or source['line'] < 1:
                raise DocsError('evidence line must be a positive integer')
            nonempty(source.get('description'), 'evidence description')
        item['id'] = index


def redact_review(review, bash):
    # Use privacy.sh without serializing prose into shell code or scrubbing JSON
    # delimiters. A fresh separator preserves multiline strings through awk.
    result = json.loads(encode(review))
    slots = [(result, 'summary')]
    for item in result['findings']:
        slots.extend((item, key) for key in ('finding', 'reason', 'preview') if key in item)
        slots.extend((source, 'description') for source in item['evidence'])
    separator = '\nAFTERPARTY_REDACT_' + uuid.uuid4().hex + '\n'
    payload = separator.join(container[key] for container, key in slots)
    scrub = subprocess.run([bash, '-c', '. "$1"; privacy_redact', '_',
                            str(Path(__file__).with_name('privacy.sh'))], input=payload + '\n',
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', timeout=30)
    if scrub.returncode:
        raise DocsError('could not redact review text')
    output = scrub.stdout[:-1] if scrub.stdout.endswith('\n') else scrub.stdout
    values = output.split(separator)
    if len(values) != len(slots):
        raise DocsError('redaction did not preserve review fields')
    for (container, key), value in zip(slots, values):
        container[key] = value
    return result


def markdown_review(review):
    lines = ['# Afterparty documentation review', '', 'Scan: ' + review['scan_id'],
             'Recorded: ' + review['recorded_at'], 'Agent-reported review: ' + review['status'] + '.',
             'Scope: ' + review['scope'], 'Current at recording: ' + str(review['basis_current']).lower() + '.',
             '', review['summary'], '', '| # | Document | Finding | Treatment | Decision |',
             '| --- | --- | --- | --- | --- |']
    cell = lambda text: str(text).replace('|', '\\|').replace('\n', ' ')
    for item in review['findings']:
        lines.append('| %s | %s:%s | %s | %s | %s |' %
                     (item['id'], cell(item['path']), item['line'], cell(item['finding']),
                      item['treatment'], item['decision']))
    if not review['findings']:
        lines.append('| — | — | No findings reported in reviewed scope | — | — |')
    for item in review['findings']:
        lines.extend(['', '## Finding ' + str(item['id']), '', item['reason'],
                      'Confidence: ' + item['confidence'] + '.',
                      'Alternatives: ' + ', '.join(item.get('alternatives', [])) + '.'])
        for source in item['evidence']:
            lines.append('- %s:%s — %s' % (encode(source['path']), source['line'], source['description']))
        if item.get('preview'):
            lines.extend(['', 'Proposed change:', '', item['preview']])
    lines.extend(['', 'Decisions and outcomes are recorded by the agent; saving this report does not apply changes.',
                  'Recheck evidence before acting: afterparty docs --check ' + review['scan_id']])
    return '\n'.join(lines) + '\n'


def save_review(state, root, review, bash):
    scan = load_scan(state, review.get('scan_id'), root)
    validate_review(review, scan)
    # Store only the contract fields, so unexpected input cannot become state.
    review = {key: review[key] for key in ('schema_version', 'scan_id', 'status', 'summary', 'reviewed_paths', 'findings')}
    review['findings'] = [{key: item[key] for key in ('id', 'path', 'line', 'finding', 'confidence',
                           'treatment', 'alternatives', 'reason', 'preview', 'decision', 'evidence') if key in item}
                          for item in review['findings']]
    for item in review['findings']:
        item['evidence'] = [{key: source[key] for key in ('path', 'line', 'description')}
                            for source in item['evidence']]
    review = redact_review(review, bash)
    review.update(recorded_at=timestamp(), review_id=uuid.uuid4().hex,
                  scope=scan['scope'], basis_current=scan_current(scan, root))
    review_id = review['review_id']
    atomic_write(state / 'reviews' / (review_id + '.json'), encode(review) + '\n')
    path = state / 'reviews' / (review_id + '.md')
    atomic_write(path, markdown_review(review))
    atomic_write(state / 'latest-review', review_id + '\n')
    pending = sum(item['decision'] in ('pending', 'deferred') for item in review['findings'])
    atomic_write(state / 'review-summary.txt',
                 'Afterparty docs: last agent review %s (%s), %s unresolved; evidence may have changed. %s\n' %
                 (review['scan_id'], review['status'], pending, path))
    return review, path


def latest(state):
    for kind in ('review', 'scan'):
        pointer = state / ('latest-' + kind)
        if pointer.exists():
            value = identifier(pointer.read_text(encoding='utf-8').strip())
            return kind, state / (kind + 's') / value
    raise DocsError('no saved documentation report; run docs --report first')


def parser():
    result = argparse.ArgumentParser(prog='afterparty docs', description=
        'Collect documentation evidence for agent review. Does not edit project files.')
    result.add_argument('--root', default=os.getcwd(), help='repository directory (default: current)')
    mode = result.add_mutually_exclusive_group()
    mode.add_argument('--since', metavar='REF', help='compare REF to the working tree, including untracked files')
    mode.add_argument('--full', action='store_true', help='include all repository documentation')
    mode.add_argument('--show', action='store_true', help='show the last agent review, or evidence if none')
    mode.add_argument('--report-path', action='store_true', help='locate that saved report')
    mode.add_argument('--template', metavar='SCAN_ID', help='print an empty agent review JSON template')
    mode.add_argument('--check', metavar='SCAN_ID', help='refuse changed or incomplete evidence before edits')
    mode.add_argument('--save-review', metavar='FILE', help='record agent-authored review JSON; never applies changes')
    result.add_argument('--json', action='store_true', help='emit versioned JSON Lines (templates are JSON objects)')
    result.add_argument('--report', action='store_true', help='persist evidence in private workspace state')
    return result


def main(state, bash, argv):
    args = parser().parse_args(argv)
    if args.report and any((args.show, args.report_path, args.template, args.check, args.save_review)):
        raise DocsError('--report applies only to evidence collection')
    root = Path(git(Path(args.root), 'rev-parse', '--show-toplevel').stdout.decode('utf-8').strip()).resolve()
    if args.report_path or args.show:
        kind, base = latest(state)
        if args.report_path:
            print(str(base.with_suffix('.md')))
            return 0
        content = load_json(base.with_suffix('.json'))
        if args.json:
            if kind == 'scan':
                for row in json_rows(content):
                    print(encode(row))
            else:
                print(encode(dict(content, section='docs_review')))
        else:
            print(base.with_suffix('.md').read_text(encoding='utf-8'), end='')
            if kind == 'review' and (state / 'latest-scan').exists():
                recent = (state / 'latest-scan').read_text().strip()
                if recent != content['scan_id']:
                    print('\nA separate evidence scan exists: ' + recent + '; this review remains available.')
        return int(content.get('collection_status', content.get('status')) != 'complete')
    if args.template or args.check:
        scan = load_scan(state, args.template or args.check, root)
        if args.template:
            print(json.dumps({'schema_version': SCHEMA, 'scan_id': scan['scan_id'], 'status': 'partial',
                              'summary': 'Replace with the actual review summary.', 'reviewed_paths': [],
                              'findings': []}, indent=2))
            return 0
        current = scan_current(scan, root)
        message = ('Evidence still matches; document changes still require the selected scope.' if current else
                   'Evidence changed or is incomplete; collect and review again before editing.')
        if args.json:
            print(encode({'schema_version': SCHEMA, 'section': 'docs_check', 'scan_id': scan['scan_id'],
                          'current': current, 'message': message}))
        else:
            print(message)
        return int(not current)
    if args.save_review:
        review, path = save_review(state, root, load_json(Path(args.save_review)), bash)
        print(encode(dict(review, section='docs_review')) if args.json else markdown_review(review), end='\n')
        print('docs: saved agent review to ' + str(path), file=sys.stderr)
        return 0
    scan = collect(root, args.since, args.full)
    if args.report:
        print('docs: saved evidence to ' + str(save_scan(state, scan)), file=sys.stderr)
    if args.json:
        for row in json_rows(scan):
            print(encode(row))
    else:
        print(markdown_scan(scan), end='')
    return int(scan['collection_status'] != 'complete')


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    try:
        sys.exit(main(Path(sys.argv[1]), sys.argv[2], sys.argv[3:]))
    except (DocsError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('docs: ' + str(error), file=sys.stderr)
        sys.exit(1)
