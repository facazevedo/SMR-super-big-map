"""Complete pre-native private replay, preserving initial five-check evidence."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/apron_local_checks_2'
out.mkdir(parents=True,exist_ok=False)
candidate='_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua'
commands=[['python','_ralph/tmp/under80_20260912/apron_local_bound_test.py'],
 ['luac','-p',candidate],
 ['lua','_ralph/tmp/under80_20260912/apron_local_raster_test.lua',candidate],
 ['lua','_ralph/tmp/under80_20260912/precision_coordinate_encoding_test.lua',candidate],
 ['lua','_ralph/tmp/under80_20260912/apron_local_oracle_test.lua',candidate],
 ['lua','_ralph/tmp/under80_20260912/apron_local_failure_test.lua',candidate],
 ['python','_ralph/tmp/under80_20260912/apron_local_source_test.py'],
 ['luac','-p','_ralph/runs/under80-20260912/artifacts/apron_local_setup/forward.lua'],
 ['luac','-p','_ralph/runs/under80-20260912/artifacts/apron_local_setup/reverse.lua']]
results=[]
for i,command in enumerate(commands):
    proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=300)
    (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
    results.append(dict(command=command,exit=proc.returncode))
    (out/'results.json').write_text(json.dumps(results,indent=2))
    print(proc.stdout+proc.stderr,end='',flush=True)
assert all(r['exit']==0 for r in results)
print('PASS all9 private checks; native oracle and performance still required',flush=True)
