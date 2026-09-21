#!/usr/bin/env python3
"""Deterministic watcher for approved user-space capabilities."""
import json, os, subprocess, time
from pathlib import Path
CAT=Path('/data/state/workspace/capability-catalog.json')
LOG=Path('/var/log/capability-watch.log')
LOCK=Path('/run/lock/capability-watch.lock')

def log(x):
    LOG.parent.mkdir(parents=True,exist_ok=True)
    with LOG.open('a') as f: f.write(time.strftime('%F %T ')+x+'\n')

def main():
    try:
        fd=os.open(LOCK,os.O_CREAT|os.O_RDWR,0o644)
        import fcntl
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except Exception: return 0
    try:
        data=json.loads(CAT.read_text()); caps=data.get('capabilities',{})
    except Exception as e:
        log('catalog_error '+type(e).__name__); return 1
    names=subprocess.check_output(['docker','ps','--filter','name=openclaw-sbx-workspace-','--format','{{.Names}}'],text=True).splitlines()
    main_sbx=''
    for n in names:
        try:
            mounts=subprocess.check_output(['docker','inspect',n,'--format','{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'],text=True)
            if '/home/node/.openclaw/workspace -> /workspace' in mounts:
                main_sbx=n; break
        except Exception: pass
    if not main_sbx:
        log('main_sandbox_absent skip'); return 0
    failed=0
    for name, spec in caps.items():
        if spec.get('scope')!='main' or spec.get('status')!='approved': continue
        r=subprocess.run(['docker','exec',main_sbx,'sh','-lc',f'PATH=/opt/tools/bin:$PATH capability-recover inspect {name}'],capture_output=True,text=True,timeout=30)
        try: obj=json.loads(r.stdout.strip().splitlines()[-1])
        except Exception: obj={'ok':False,'error':'bad_helper_output','raw':r.stdout[-200:]}
        if obj.get('present') and obj.get('output') and spec.get('expected_contains') in obj.get('output',''):
            continue
        log(f'{name} missing_or_invalid; attempting restore')
        r2=subprocess.run(['docker','exec',main_sbx,'sh','-lc',f'PATH=/opt/tools/bin:$PATH capability-recover restore {name}'],capture_output=True,text=True,timeout=30)
        try: obj2=json.loads(r2.stdout.strip().splitlines()[-1])
        except Exception: obj2={'ok':False,'error':'bad_restore_output','raw':r2.stdout[-200:]}
        if obj2.get('ok') and obj2.get('verified'):
            log(f'{name} restored verified')
        else:
            failed+=1; log(f'{name} restore_failed {json.dumps(obj2,ensure_ascii=False)}')
    return 1 if failed else 0
if __name__=='__main__': raise SystemExit(main())
