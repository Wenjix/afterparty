#!/usr/bin/env bash
# End-to-end approval boundaries with disposable data and intercepted machine
# tools. No real processes, launch agents or package stores may be mutated.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: devclean approval fixtures require Python 3'; exit 0; }
export AFTERPARTY_TEST_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Native Windows Python otherwise finds System32/bash.exe (WSL), and cannot
# interpret Git Bash's /c/... paths. Keep the interpreter that launched us.
export AFTERPARTY_TEST_BASH="$BASH" AFTERPARTY_TEST_UID="$(id -u)"
if command -v cygpath >/dev/null 2>&1; then
  AFTERPARTY_TEST_REPO="$(cygpath -am "$AFTERPARTY_TEST_REPO")"
  AFTERPARTY_TEST_BASH="$(cygpath -am "$BASH")"
fi
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
python3 - <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time

repo = pathlib.Path(os.environ['AFTERPARTY_TEST_REPO'])
lib = repo / 'skills/afterparty/lib'
bash = os.environ['AFTERPARTY_TEST_BASH']
if os.name == 'nt' and not bash.endswith('.exe') and pathlib.Path(bash+'.exe').is_file():
    bash += '.exe'
fixture_uid = int(os.environ['AFTERPARTY_TEST_UID'])
root = pathlib.Path(tempfile.mkdtemp(prefix='afterparty devclean approval-')).resolve()
failures = []

def to_shell(path):
    if os.name != 'nt': return str(path)
    return subprocess.check_output([bash, '--noprofile', '--norc', '-c', 'cygpath -u "$1"',
                                    'fixture-path', str(path)], encoding='utf-8').strip()

shell_roots = [(root, to_shell(root)), (repo, to_shell(repo))]
def shell_path(path):
    for native, posix in shell_roots:
        try: return posix + '/' + path.relative_to(native).as_posix()
        except ValueError: pass
    raise ValueError('fixture path outside disposable roots: ' + str(path))

def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)

def put(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Native Windows text defaults would give /usr/bin/env a "bash\r" shebang.
    with path.open('w', encoding='utf-8', newline='\n') as stream: stream.write(text)
    if executable: path.chmod(0o755)

def fixture(name):
    t = root / name; t.mkdir()
    home = t / 'home'; home.mkdir()
    shims = t / 'shims'; shims.mkdir()
    env = os.environ.copy()
    env.update(HOME=shell_path(home), XDG_CACHE_HOME=shell_path(t/'cache'), XDG_STATE_HOME=shell_path(t/'state'),
               REVIEW_SHIMS=shell_path(shims), AFTERPARTY_STYLE='never',
               REVIEW_CALLS=shell_path(t/'calls'), REVIEW_SIGNALS=shell_path(t/'signals'),
               REVIEW_STOPPED=shell_path(t/'stopped'), REVIEW_PROC='0', REVIEW_CPU='0.0',
               REVIEW_COMMAND='next-server', REVIEW_UID=str(fixture_uid),
               REVIEW_WORKSPACE=shell_path(t/'workspace'), REVIEW_AGENTS='0', REVIEW_AGENT_STATE=shell_path(t/'agents'),
               REVIEW_NATIVE_CALLS=str(t/'calls'), REVIEW_NATIVE_SIM_FILE=str(t/'simulators.json'), REVIEW_SIM_NOOP='0',
               AFTERPARTY_TRANSCRIPT_ROOT=shell_path(t/'transcripts'),
               AFTERPARTY_CODEX_ROOT=shell_path(t/'codex-index'), BASH_ENV=shell_path(t/'bash-env'))
    (t/'workspace').mkdir(); (t/'agents').mkdir()
    put(t/'bash-env', '''kill() {
  printf '%s\\n' "$*" >> "$REVIEW_SIGNALS"
  : > "$REVIEW_STOPPED"
  return 0
}
''')
    put(shims/'pgrep', '''#!/usr/bin/env bash
printf 'pgrep %s\\n' "$*" >> "$REVIEW_CALLS"
[ "$REVIEW_PROC" = 1 ] && [ ! -e "$REVIEW_STOPPED" ] || exit 1
printf '999991\\n'
''', True)
    put(shims/'pnpm', '''#!/usr/bin/env bash
printf 'pnpm %s\\n' "$*" >> "$REVIEW_CALLS"
exit 1
''', True)
    put(shims/'launchctl', '''#!/usr/bin/env bash
printf 'launchctl %s\\n' "$*" >> "$REVIEW_CALLS"
[ "$REVIEW_AGENTS" = 1 ] || exit 1
label="${2##*/}"
case "$1" in
  print) [ ! -e "$REVIEW_AGENT_STATE/$label" ] ;;
  disable) : > "$REVIEW_AGENT_STATE/$label" ;;
  bootout) exit 0 ;;
  *) exit 1 ;;
esac
''', True)
    put(shims/'ps', '''#!/usr/bin/env bash
case "$*" in
  '-eo pid='|'-Ao pid='|'-e -o pid=') printf '1\\n'; [ -e "$REVIEW_STOPPED" ] || printf '999991\\n'; exit 0 ;;
esac
[ ! -e "$REVIEW_STOPPED" ] || exit 1
case "$*" in
  '-p 999991') exit 0 ;;
  *ppid=,lstart=,command=*) printf '1 Tue Aug 18 09:00:00 2026 %s\\n' "$REVIEW_COMMAND" ;;
  *uid=,etime=,tty=,%cpu=*) printf '%s 02:00:00 ? %s\\n' "$REVIEW_UID" "$REVIEW_CPU" ;;
  *pid=,ppid=,pgid=,rss=,%cpu=,etime=,command=*) printf '999991 1 999991 65536 %s 02:00:00 %s\\n' "$REVIEW_CPU" "$REVIEW_COMMAND" ;;
  *rss=*) printf '65536\\n' ;;
  *) exit 1 ;;
esac
''', True)
    put(shims/'lsof', '''#!/usr/bin/env bash
printf 'p999991\\nfcwd\\nn%s\\n' "$REVIEW_WORKSPACE"
''', True)
    put(shims/'uname', '#!/usr/bin/env bash\nprintf "Darwin\\n"\n', True)
    put(shims/'xcrun', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['REVIEW_NATIVE_CALLS'], 'a') as log: log.write('xcrun ' + ' '.join(sys.argv[1:]) + '\\n')
path = os.environ['REVIEW_NATIVE_SIM_FILE']
if not os.path.exists(path): sys.exit(1)
with open(path) as source: data = json.load(source)
if sys.argv[1:4] == ['simctl', 'list', 'devices']:
    print(json.dumps(data))
elif sys.argv[1:3] == ['simctl', 'shutdown'] and os.environ['REVIEW_SIM_NOOP'] != '1':
    for group in data['devices'].values():
        for device in group:
            if device['udid'] == sys.argv[3]: device['state'] = 'Shutdown'
    with open(path, 'w') as output: json.dump(data, output)
''', True)
    return t, home, env

bootstrap = '''set -euo pipefail
export PATH="$REVIEW_SHIMS:${BASH%/*}:$PATH"
for tool in pgrep launchctl pnpm; do
  actual="$(command -v "$tool")" || actual=''
  [ "$actual" = "$REVIEW_SHIMS/$tool" ] || { echo "fixture interceptor unavailable: $tool ($actual)" >&2; exit 97; }
done
[ "$(type -t kill)" = function ] || { echo 'fixture kill interceptor unavailable' >&2; exit 97; }
exec "$BASH" "$@"
'''
def run(t, env, *args, cli=False):
    command = [shell_path(repo/'bin/afterparty'), 'devclean'] if cli else [shell_path(lib/'devclean.sh')]
    result = subprocess.run([bash, '--noprofile', '--norc', '-c', bootstrap, 'devclean-fixture',
                             *command, *args], cwd=t, env=env,
                            encoding='utf-8', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode == 97:
        raise RuntimeError('devclean fixture isolation failed: ' + result.stdout)
    return result

def targets(output, effect=''):
    return [m.group(1) for line in output.splitlines() if effect in line
            for m in [re.search(r'target: (\S+) — ', line)] if m]

def blob(path, stale=False):
    put(path, 'fixture data\n' * 180000)
    if stale: os.utime(path, (time.time()-90*86400,)*2)

try:
    t,home,env=fixture('bootstrap')
    put(t/'foreign-path/bash', '#!/bin/sh\necho WRONG_BASH_SELECTED\nexit 96\n', True)
    env['PATH']=str(t/'foreign-path')+os.pathsep+env['PATH']
    result=run(t,env,'--disk','--no-repo-artifacts','--apply')
    check(result.returncode==2 and '--target' in result.stdout,
          'D0: native subprocess must use the launching Bash despite competing PATH entries: '+result.stdout)
    check(all(b'\r' not in shim.read_bytes() for shim in (t/'shims').iterdir()),
          'D0: generated executable shims must use LF on every platform')
    env['BASH_ENV']=shell_path(t/'missing-bash-env')
    try:
        run(t,env,'--disk','--no-repo-artifacts','--apply')
    except RuntimeError as error:
        check('kill interceptor unavailable' in str(error), 'D0: missing interceptor must be diagnosed before cleanup')
    else:
        check(False, 'D0: missing kill interceptor must abort before cleanup')

    t, home, env = fixture('disk')
    gradle=home/'.gradle/caches/blob'; npm=home/'.npm/blob'
    blob(gradle); blob(npm)
    result=run(t,env,'--disk','--no-repo-artifacts','--apply')
    check(result.returncode==2 and '--target' in result.stdout and gradle.exists(), 'D1: blanket apply must refuse visibly: '+result.stdout)
    preview=run(t,env,'--disk','--no-repo-artifacts')
    chosen=targets(preview.stdout, 'Gradle caches')
    check(len(chosen)==1, 'D2: preview must identify the exact Gradle cache action: '+preview.stdout)
    check('pgrep ' not in (t/'calls').read_text(), 'D2: disk preview must not scan orphan processes')
    if chosen:
        result=run(t,env,'--disk','--no-repo-artifacts','--apply','--target',chosen[0])
        check(result.returncode==0 and not gradle.exists() and npm.exists(), 'D2: only the selected cache may be removed: '+result.stdout)
        check('pgrep ' not in (t/'calls').read_text() and not (t/'signals').exists(), 'D2: disk apply must never signal orphans')
    check('--disk --documents-root' in preview.stdout and '--no-repo-artifacts --apply --target' in preview.stdout,
          'D3: next command must retain selected modes and scope')

    t,home,env=fixture('history')
    recent=home/'.codex/sessions/2000/01/01/current.jsonl'; old=home/'.codex/sessions/2000/01/02/old.jsonl'
    blob(recent); blob(old,True)
    check('Codex sessions' not in run(t,env,'--disk','--no-repo-artifacts').stdout, 'D4: history must not be bundled into disk caches')
    preview=run(t,env,'--history'); chosen=targets(preview.stdout,'2000/01/02')
    check('recent activity' in preview.stdout and not targets(preview.stdout,'2000/01/01'), 'D4: fresh activity in an old date bucket must be retained')
    check(len(chosen)==1, 'D4: stale history must have an explicit irreversible target')
    if chosen:
        result=run(t,env,'--history','--apply','--target',chosen[0])
        check(not old.exists() and recent.exists() and result.returncode!=0, 'D4: selected stale history removed; fresh history retained and disclosed')
        check('withheld' in result.stdout and 'No process exits or reclaimed space to report.' not in result.stdout,
              'D4: retention must not produce an empty-success receipt')
    blob(old,True); preview=run(t,env,'--history'); chosen=targets(preview.stdout,'2000/01/02')
    if chosen:
        put(old,'recently resumed\n'*180000)
        result=run(t,env,'--history','--apply','--target',chosen[0])
        check(old.exists() and result.returncode!=0 and 'recent activity' in result.stdout, 'D5: resumed history after preview must invalidate deletion')
    os.utime(old,(time.time()-90*86400,)*2); chosen=targets(run(t,env,'--history').stdout,'2000/01/02')
    env['REVIEW_HISTORY_FILE']=shell_path(old)
    put(t/'shims/find','#!/usr/bin/env bash\nprintf "%s\\0" "$REVIEW_HISTORY_FILE"\nexit 1\n',True)
    if chosen:
        result=run(t,env,'--history','--apply','--target',chosen[0])
        check(old.exists() and result.returncode!=0 and 'activity evidence unavailable' in result.stdout,
              'D6: incomplete history scans must fail closed')

    # A numeric environment override is decimal, including leading zeros.
    # Each retention guard needs a stale selectable control in the same scan.
    for configured, days in (('030',30), ('08',8), ('0'*30+'30',30)):
        t,home,env=fixture('history-decimal-'+configured)
        env['CODEX_SESSION_AGE_DAYS']=configured
        retained=home/'.codex/sessions/2000/01/01/resumed.jsonl'
        expired=home/'.codex/sessions/2000/01/02/expired.jsonl'
        blob(retained); blob(expired)
        os.utime(retained,(time.time()-(days-1)*86400,)*2)
        os.utime(expired,(time.time()-(days+1)*86400,)*2)
        preview=run(t,env,'--history',cli=True)
        chosen=targets(preview.stdout,'2000/01/02')
        check(preview.returncode==0 and len(chosen)==1,
              'D19: decimal '+configured+' retention must offer expired history: '+preview.stdout)
        check('recent activity' in preview.stdout and not targets(preview.stdout,'2000/01/01'),
              'D19: decimal '+configured+' retention must withhold resumed history: '+preview.stdout)
        shorter=dict(env, CODEX_SESSION_AGE_DAYS=str(days-2))
        retained_choice=targets(run(t,shorter,'--history',cli=True).stdout,'2000/01/01')
        check(len(retained_choice)==1, 'D19: shorter retention control must offer the resumed history')
        if retained_choice:
            result=run(t,env,'--history','--apply','--target',retained_choice[0],cli=True)
            check(retained.exists() and result.returncode!=0 and 'recent activity' in result.stdout,
                  'D19: decimal '+configured+' apply must reject an approval under shorter retention: '+result.stdout)
        if chosen:
            result=run(t,env,'--history','--apply','--target',chosen[0],cli=True)
            check(retained.exists() and not expired.exists() and result.returncode!=0
                  and 'recent activity' in result.stdout and '1 history action(s)' in result.stdout,
                  'D19: decimal '+configured+' apply must remove only expired history: '+result.stdout)
    for configured in ('00', '000', '106751991167301', '9223372036854775808'):
        t,home,env=fixture('history-invalid-'+configured)
        env['CODEX_SESSION_AGE_DAYS']=configured
        recent=home/'.codex/sessions/2000/01/01/recent.jsonl'; blob(recent)
        result=run(t,env,'--history',cli=True)
        check(result.returncode==2 and 'CODEX_SESSION_AGE_DAYS requires' in result.stdout
              and not targets(result.stdout) and recent.exists(),
              'D19: zero or overflowing retention must reject the named override before scanning: '+result.stdout)

    if os.name != 'nt':
        t,home,env=fixture('history-archive-alias')
        archived=home/'.codex/archived_sessions/2000/01/01/archived.jsonl'
        log=home/'.codex/log/stale.log'
        blob(archived,True); blob(log,True)
        (home/'.codex/sessions').symlink_to('archived_sessions',target_is_directory=True)
        preview=run(t,env,'--history',cli=True)
        check(len(targets(preview.stdout,'/.codex/log'))==1,
              'D20: independent stale logs must remain selectable in the archive-alias fixture: '+preview.stdout)
        check('excluded archived_sessions' in preview.stdout and not targets(preview.stdout,'/archived_sessions/'),
              'D20: a sessions alias must not offer archived history: '+preview.stdout)
        fingerprint=subprocess.check_output([bash,'-c','. "$1"; fp_for_artifact "$2"',
                                             'history-fingerprint',shell_path(lib/'fingerprint.sh'),
                                             shell_path(archived.parent)],cwd=t,env=env,encoding='utf-8').strip()
        result=run(t,env,'--history','--apply','--target','history:'+fingerprint,cli=True)
        check(result.returncode!=0 and archived.exists() and log.exists()
              and 'excluded archived_sessions' in result.stdout and '0 history action(s)' in result.stdout,
              'D20: even an exact target ID must not override archived-history exclusion: '+result.stdout)

        t,home,env=fixture('history-archive-inside-log')
        archived=home/'.codex/log/archive/archived.jsonl'
        session=home/'.codex/sessions/2000/01/01/session.jsonl'
        blob(archived,True); blob(session,True)
        (home/'.codex/archived_sessions').symlink_to('log/archive',target_is_directory=True)
        preview=run(t,env,'--history',cli=True)
        check(len(targets(preview.stdout,'/sessions/2000/01/01'))==1,
              'D21: independent stale sessions must remain selectable beside protected logs: '+preview.stdout)
        check('excluded archived_sessions' in preview.stdout and not targets(preview.stdout,'/.codex/log'),
              'D21: history that contains the physical archive must be withheld: '+preview.stdout)
        fingerprint=subprocess.check_output([bash,'-c','. "$1"; fp_for_artifact "$2"',
                                             'history-fingerprint',shell_path(lib/'fingerprint.sh'),
                                             shell_path(home/'.codex/log')],cwd=t,env=env,encoding='utf-8').strip()
        result=run(t,env,'--history','--apply','--target','history:'+fingerprint,cli=True)
        check(result.returncode!=0 and archived.exists() and session.exists()
              and 'excluded archived_sessions' in result.stdout and '0 history action(s)' in result.stdout,
              'D21: a checked parent history target cannot remove physical archives: '+result.stdout)

    t,home,env=fixture('settings')
    commented=home/'.vscode/argv.json'; active=home/'.cursor/argv.json'
    put(commented,'{\n // "enable-crash-reporter": true\n}\n')
    original='{\n // explanatory comment stays\n "enable-crash-reporter": true,\n "args": "// is a string",\n}\n'
    put(active,original)
    preview=run(t,env,'--optimize'); chosen=targets(preview.stdout,'crash reporting in cursor')
    check(len(chosen)==1 and not targets(preview.stdout,'crash reporting in vscode'), 'D7: only active top-level JSONC settings are selectable')
    if chosen:
        result=run(t,env,'--optimize','--apply','--target',chosen[0])
        backups=list(active.parent.glob('argv.json.afterparty-*.bak'))
        check(result.returncode==0 and '"enable-crash-reporter": false' in active.read_text(), 'D7: selected active setting must change')
        check('// explanatory comment stays' in active.read_text() and commented.read_text().find(': true')>=0,
              'D7: comments must remain untouched')
        check(len(backups)==1 and backups[0].read_text()==original and 'Restore after closing the app' in result.stdout,
              'D7: persistent changes must retain a usable restore copy and instructions')
    put(active,original); chosen=targets(run(t,env,'--optimize').stdout,'crash reporting in cursor')
    if chosen:
        put(active,original.replace('explanatory','changed'))
        result=run(t,env,'--optimize','--apply','--target',chosen[0])
        check(result.returncode!=0 and '"enable-crash-reporter": true' in active.read_text(), 'D8: changed settings must reject an old target ID')

    portable=t/'portable-argv.json'; put(portable,original)
    without_fchmod='import os, runpy, sys\nif hasattr(os, "fchmod"): del os.fchmod\nsys.argv=sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name="__main__")'
    result=subprocess.run([sys.executable,'-c',without_fchmod,str(lib/'devclean-settings.py'),
                           'disable',str(portable),hashlib.sha256(portable.read_bytes()).hexdigest()],
                          env=env,encoding='utf-8',stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    backups=list(t.glob('portable-argv.json.afterparty-*.bak'))
    check(result.returncode==0 and '"enable-crash-reporter": false' in portable.read_text()
          and len(backups)==1 and backups[0].read_text()==original,
          'D16: settings update and restore copy must work without Unix-only fchmod: '+result.stdout)

    t,home,env=fixture('process')
    env['REVIEW_PROC']='1'; env['REVIEW_CPU']='80.0'
    transcript=t/'transcripts/project/session.jsonl'; put(transcript,json.dumps({'cwd':shell_path(t/'workspace')},separators=(',',':')))
    os.utime(transcript,(time.time()-90*86400,)*2)
    preview=run(t,env,'--orphans')
    check('workspace working' in preview.stdout and not targets(preview.stdout), 'D9: PPID 1 must not authorize stopping an active process')
    env['REVIEW_CPU']='0.0'; preview=run(t,env,'--orphans'); chosen=targets(preview.stdout,'idle PID')
    check(len(chosen)==1, 'D10: known stale, idle, owned process must remain selectable: '+preview.stdout)
    if chosen:
        result=run(t,env,'--orphans','--apply','--target',chosen[0])
        signals=(t/'signals').read_text() if (t/'signals').exists() else ''
        check(result.returncode==0 and signals.strip()=='-TERM 999991' and '1 process(es) stopped' in result.stdout,
              'D10: only the reviewed idle PID is signalled and confirmed: '+result.stdout)
    if (t/'stopped').exists(): (t/'stopped').unlink()
    env['REVIEW_COMMAND']='Codex --dangerously-bypass-approvals-and-sandbox'
    preview=run(t,env,'--orphans')
    check('protected process' in preview.stdout and not targets(preview.stdout), 'D11: orphan adoption must not bypass active-agent protection')
    env['REVIEW_COMMAND']='next-server'; env['REVIEW_UID']=str(fixture_uid+1)
    preview=run(t,env,'--orphans')
    check('owner or activity unavailable' in preview.stdout and not targets(preview.stdout), 'D15: another user must not inherit process approval')
    env['REVIEW_UID']=str(fixture_uid); env['REVIEW_CPU']='unknown'
    preview=run(t,env,'--orphans')
    check('CPU evidence unavailable' in preview.stdout and not targets(preview.stdout), 'D15: malformed activity evidence must fail closed')

    t,home,env=fixture('simulator')
    devices={'devices':{'runtime':[{'udid':'AAAA-1111','name':'First','state':'Booted'}, {'udid':'BBBB-2222','name':'Second','state':'Booted'}]}}
    put(t/'simulators.json',json.dumps(devices))
    chosen=targets(run(t,env,'--deep').stdout,'simulator First')
    check(len(chosen)==1,'D12: booted simulators must be individually selectable')
    if chosen:
        result=run(t,env,'--deep','--apply','--target',chosen[0])
        after=json.loads((t/'simulators.json').read_text())['devices']['runtime']
        check(result.returncode==0 and [d['state'] for d in after]==['Shutdown','Booted'], 'D12: selected simulator only must shut down')
        check('shutdown all' not in (t/'calls').read_text(),'D12: simulator mutation must never target all devices')
    put(t/'simulators.json',json.dumps(devices)); env['REVIEW_SIM_NOOP']='1'
    chosen=targets(run(t,env,'--deep').stdout,'simulator First')
    if chosen:
        result=run(t,env,'--deep','--apply','--target',chosen[0])
        check(result.returncode!=0 and 'could not confirm simulator shutdown' in result.stdout,
              'D13: successful simctl exit cannot replace the Shutdown postcondition')

    t,home,env=fixture('agents'); env['REVIEW_AGENTS']='1'
    chosen=targets(run(t,env,'--optimize').stdout,'Disable FigmaAgent')
    check(len(chosen)==1,'D14: persistent launch-agent changes must have individual targets')
    if chosen:
        result=run(t,env,'--optimize','--apply','--target',chosen[0])
        calls=(t/'calls').read_text()
        check(result.returncode==0 and 'disable gui/'+str(fixture_uid)+'/com.figma.agent' in calls
              and 'disable gui/'+str(fixture_uid)+'/com.openai.chat-helper' not in calls,
              'D14: only selected launch agent may be disabled')
        check('Restore: launchctl enable' in result.stdout,'D14: persistent agent changes must explain restoration')

    # A confirmed mutation and a missing receipt are separate outcomes. A
    # blocked journal must affect the exit status without erasing the success.
    for kind in ('setting', 'cache', 'package-store'):
        t,home,env=fixture('receipt-'+kind)
        blocked=t/'blocked-cache'; put(blocked,'not a directory\n')
        env['XDG_CACHE_HOME']=shell_path(blocked)
        if kind == 'setting':
            target=home/'.vscode/argv.json'; put(target,'{"enable-crash-reporter": true}\n')
            mode=['--optimize']; effect='crash reporting in vscode'; count='1 settings/dump/agent actions'
        else:
            mode=['--disk','--no-repo-artifacts']; count='1 cache action(s)'
            target=home/'.gradle/caches/blob' if kind == 'cache' else t/'package-store/blob'
            blob(target)
            effect='Gradle caches' if kind == 'cache' else 'pnpm store prune'
            if kind == 'package-store':
                env['REVIEW_STORE']=shell_path(target.parent)
                put(t/'shims/pnpm', '''#!/usr/bin/env bash
printf 'pnpm %s\\n' "$*" >> "$REVIEW_CALLS"
case "$*" in
  'store path') printf '%s\\n' "$REVIEW_STORE" ;;
  'store prune') exit 0 ;;
  *) exit 1 ;;
esac
''',True)
        chosen=targets(run(t,env,*mode).stdout,effect)
        check(len(chosen)==1,'D17: receipt failure fixture needs an exact '+kind+' target')
        if chosen:
            result=run(t,env,*mode,'--apply','--target',chosen[0])
            if kind == 'setting':
                changed='"enable-crash-reporter": false' in target.read_text()
            elif kind == 'cache':
                changed=not target.exists()
            else:
                changed='pnpm store prune\n' in (t/'calls').read_text() and target.exists()
            check(changed and count in result.stdout and '0 failed, 1 receipt failure(s)' in result.stdout,
                  'D17: confirmed '+kind+' mutation must survive separate receipt failure accounting: '+result.stdout)
            check(result.returncode!=0 and 'could not create action journal directory' in result.stdout,
                  'D17: '+kind+' receipt failure must be diagnosed and return nonzero: '+result.stdout)

    # Match absence is valid only after a successful scan. Exercise both
    # backends, including a complete process table with no orphan candidates.
    for backend in ('pgrep', 'ps'):
        for outcome in ('empty', 'failed'):
            t,home,env=fixture('discovery-'+backend+'-'+outcome)
            env['AFTERPARTY_STYLE']='always'; env['AFTERPARTY_CARD']='1'
            if backend == 'pgrep':
                put(t/'shims/pgrep', '#!/usr/bin/env bash\nprintf "pgrep discovery\\n" >> "$REVIEW_CALLS"\nexit '+('1' if outcome=='empty' else '2')+'\n',True)
            else:
                # Bootstrap still verifies the installed safety interceptors;
                # only devclean's own lookup simulates an absent pgrep tool.
                with (t/'bash-env').open('a',encoding='utf-8',newline='\n') as stream:
                    stream.write('''case "$0" in
  */devclean.sh)
    command() {
      [ "$*" != '-v pgrep' ] || return 1
      builtin command "$@"
    }
    ;;
esac
''')
                put(t/'shims/ps', '''#!/usr/bin/env bash
case "$*" in
  '-eo ppid=,pid=,command=')
    printf 'ps fallback discovery\\n' >> "$REVIEW_CALLS"
'''+("    printf '0 1 /sbin/init\\n1 200 sleep 10\\n'; exit 0\n" if outcome=='empty' else "    exit 2\n")+'''    ;;
  *) exit 1 ;;
esac
''',True)
            result=run(t,env,'--orphans')
            calls=(t/'calls').read_text() if (t/'calls').exists() else ''
            check(('pgrep discovery' if backend=='pgrep' else 'ps fallback discovery') in calls,
                  'D18: '+backend+' '+outcome+' discovery path must actually run: '+result.stdout)
            if outcome == 'empty':
                check(result.returncode==0 and '(none)' in result.stdout and 'No cleanup candidates found in the inspected scope.' in result.stdout,
                      'D18: completed '+backend+' scan with no matches must remain a successful empty report: '+result.stdout)
            else:
                check(result.returncode!=0 and 'process discovery unavailable' in result.stdout and 'No cleanup candidates found in the inspected scope.' not in result.stdout,
                      'D18: failed '+backend+' discovery must return nonzero without claiming an empty scan: '+result.stdout)
            check(not (t/'signals').exists(),'D18: discovery fixtures must never signal')
finally:
    shutil.rmtree(root)
if failures:
    raise SystemExit(str(len(failures))+' devclean approval assertion(s) failed')
print('ALL PASS: devclean exact approvals, mode boundaries, activity guards and truthful receipts')
PY
