"""Finite paired-boundary prerequisites before real native experiments."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/filler_paired_offline'
out.mkdir(parents=True,exist_ok=False)
base='_ralph/tmp/under80_20260912/'
commands=[['luac','-p',base+n] for n in ('filler_paired_cache.lua','filler_paired_profile.lua')]
commands += [['luac','-p','_ralph/runs/under80-20260912/artifacts/filler_paired_observer/observer.lua']]
commands += [['lua',base+n] for n in ('filler_paired_cache_test.lua','filler_paired_observer_test.lua','native_proc_profile_test.lua')]
commands += [['python','-m','py_compile',base+'filler_paired_build.py',base+'filler_paired_audit.py'],
 ['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua'],['python','_ralph/tools/deploy.py','audit']]
results=[]
for i,command in enumerate(commands):
 proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=60)
 (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
 results.append(dict(command=command,exit=proc.returncode))
 (out/'results.json').write_text(json.dumps(results,indent=2))
 print(i,proc.returncode,proc.stdout+proc.stderr,flush=True)
assert all(r['exit']==0 for r in results)
print('PASS all9 paired-boundary prerequisites')
