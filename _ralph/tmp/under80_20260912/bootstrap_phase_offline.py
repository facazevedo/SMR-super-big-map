"""Preserve all phase-probe validation results before real-engine work."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/bootstrap_phase_offline_2'
out.mkdir(parents=True,exist_ok=False)
commands=[['luac','-p','_ralph/tmp/under80_20260912/bootstrap_phase_profile.lua'],
 ['lua','_ralph/tmp/under80_20260912/bootstrap_phase_source_test.lua'],
 ['lua','_ralph/tmp/under80_20260912/bootstrap_phase_profile_test.lua'],
 ['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua'],
 ['python','_ralph/tools/deploy.py','audit']]
results=[]
for i,command in enumerate(commands):
    proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=60)
    (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
    results.append(dict(command=command,exit=proc.returncode))
    (out/'results.json').write_text(json.dumps(results,indent=2))
    print(proc.stdout+proc.stderr,end='',flush=True)
assert all(r['exit']==0 for r in results)
print('PASS all5 bootstrap phase prerequisite checks')
