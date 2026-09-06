#!/usr/bin/env bash
# End-to-end approval boundaries with disposable data and intercepted machine
# tools. No real processes, launch agents or package stores may be mutated.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: devclean approval fixtures require Python 3'; exit 0; }
export AFTERPARTY_TEST_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time

repo = pathlib.Path(os.environ['AFTERPARTY_TEST_REPO'])
lib = repo / 'skills/afterparty/lib'
fixture_uid = int(subprocess.check_output(['id', '-u'], text=True).strip())
root = pathlib.Path(tempfile.mkdtemp(prefix='afterparty-devclean-approval-'))
failures = []

def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)

def put(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable: path.chmod(0o755)

def fixture(name):
    t = root / name; t.mkdir()
    home = t / 'home'; home.mkdir()
    shims = t / 'shims'; shims.mkdir()
    env = os.environ.copy()
    env.update(HOME=str(home), XDG_CACHE_HOME=str(t/'cache'), XDG_STATE_HOME=str(t/'state'),
               PATH=str(shims)+os.pathsep+env['PATH'], AFTERPARTY_STYLE='never',
               REVIEW_CALLS=str(t/'calls'), REVIEW_SIGNALS=str(t/'signals'),
               REVIEW_STOPPED=str(t/'stopped'), REVIEW_PROC='0', REVIEW_CPU='0.0',
               REVIEW_COMMAND='next-server', REVIEW_UID=str(fixture_uid),
               REVIEW_WORKSPACE=str(t/'workspace'), REVIEW_AGENTS='0', REVIEW_AGENT_STATE=str(t/'agents'),
               REVIEW_SIM_FILE=str(t/'simulators.json'), REVIEW_SIM_NOOP='0',
               AFTERPARTY_TRANSCRIPT_ROOT=str(t/'transcripts'), BASH_ENV=str(t/'bash-env'))
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
with open(os.environ['REVIEW_CALLS'], 'a') as log: log.write('xcrun ' + ' '.join(sys.argv[1:]) + '\\n')
path = os.environ['REVIEW_SIM_FILE']
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

def run(t, env, *args):
    return subprocess.run(['bash', str(lib/'devclean.sh'), *args], cwd=t, env=env,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def targets(output, effect=''):
    return [m.group(1) for line in output.splitlines() if effect in line
            for m in [re.search(r'target: (\S+) — ', line)] if m]

def blob(path, stale=False):
    put(path, 'fixture data\n' * 180000)
    if stale: os.utime(path, (time.time()-90*86400,)*2)

try:
    t, home, env = fixture('disk')
    gradle=home/'.gradle/caches/blob'; npm=home/'.npm/blob'
    blob(gradle); blob(npm)
    result=run(t,env,'--disk','--no-repo-artifacts','--apply')
    check(result.returncode==2 and '--target' in result.stdout and gradle.exists(), 'D1: blanket apply must refuse visibly')
    preview=run(t,env,'--disk','--no-repo-artifacts')
    chosen=targets(preview.stdout, 'Gradle caches')
    check(len(chosen)==1, 'D2: preview must identify the exact Gradle cache action')
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
        check('withheld' in result.stdout and 'already spotless' not in result.stdout, 'D4: retention must not yield a spotless receipt')
    blob(old,True); preview=run(t,env,'--history'); chosen=targets(preview.stdout,'2000/01/02')
    if chosen:
        put(old,'recently resumed\n'*180000)
        result=run(t,env,'--history','--apply','--target',chosen[0])
        check(old.exists() and result.returncode!=0 and 'recent activity' in result.stdout, 'D5: resumed history after preview must invalidate deletion')
    os.utime(old,(time.time()-90*86400,)*2); chosen=targets(run(t,env,'--history').stdout,'2000/01/02')
    env['REVIEW_HISTORY_FILE']=str(old)
    put(t/'shims/find','#!/usr/bin/env bash\nprintf "%s\\0" "$REVIEW_HISTORY_FILE"\nexit 1\n',True)
    if chosen:
        result=run(t,env,'--history','--apply','--target',chosen[0])
        check(old.exists() and result.returncode!=0 and 'activity evidence unavailable' in result.stdout,
              'D6: incomplete history scans must fail closed')

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
                          env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    backups=list(t.glob('portable-argv.json.afterparty-*.bak'))
    check(result.returncode==0 and '"enable-crash-reporter": false' in portable.read_text()
          and len(backups)==1 and backups[0].read_text()==original,
          'D16: settings update and restore copy must work without Unix-only fchmod: '+result.stdout)

    t,home,env=fixture('process')
    env['REVIEW_PROC']='1'; env['REVIEW_CPU']='80.0'
    transcript=t/'transcripts/project/session.jsonl'; put(transcript,json.dumps({'cwd':str(t/'workspace')},separators=(',',':')))
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
    chosen=targets(run(t,env,'--optimize').stdout,'disable FigmaAgent')
    check(len(chosen)==1,'D14: persistent launch-agent changes must have individual targets')
    if chosen:
        result=run(t,env,'--optimize','--apply','--target',chosen[0])
        calls=(t/'calls').read_text()
        check(result.returncode==0 and 'disable gui/'+str(fixture_uid)+'/com.figma.agent' in calls
              and 'disable gui/'+str(fixture_uid)+'/com.openai.chat-helper' not in calls,
              'D14: only selected launch agent may be disabled')
        check('Restore: launchctl enable' in result.stdout,'D14: persistent agent changes must explain restoration')
finally:
    shutil.rmtree(root)
if failures:
    raise SystemExit(str(len(failures))+' devclean approval assertion(s) failed')
print('ALL PASS: devclean exact approvals, mode boundaries, activity guards and truthful receipts')
PY
