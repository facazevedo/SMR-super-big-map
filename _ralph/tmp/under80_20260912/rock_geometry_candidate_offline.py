"""Finite prerequisite batch before native scalar-reuse proof."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_offline'
out.mkdir(parents=True,exist_ok=False)
base='_ralph/tmp/under80_20260912/'
commands=[['luac','-p',base+n] for n in ('rock_geometry_native.lua','rock_geometry_shadow.lua')]
commands += [['luac','-p','_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_2/candidate.lua']]
commands += [['lua',base+n] for n in ('rock_geometry_candidate_test.lua','rock_geometry_native_test.lua','rock_geometry_shadow_test.lua','rock_geometry_census_test.lua')]
commands += [['python','-m','py_compile',base+'rock_geometry_shadow_audit.py',base+'rock_geometry_candidate.py'],
 ['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua'],
 ['python','_ralph/tools/deploy.py','audit']]
results=[]
for i,command in enumerate(commands):
 proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=60)
 (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
 results.append(dict(command=command,exit=proc.returncode))
 (out/'results.json').write_text(json.dumps(results,indent=2))
 print(i,proc.returncode,proc.stdout+proc.stderr,flush=True)
assert all(r['exit']==0 for r in results)
print('PASS all10 geometry candidate prerequisites')
