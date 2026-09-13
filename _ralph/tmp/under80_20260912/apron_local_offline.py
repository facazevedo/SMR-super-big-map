"""Retain finite private checks, including any failure; no native timing claim."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/apron_local_offline'
out.mkdir(parents=True,exist_ok=False)
candidate='_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua'
commands=[['python','_ralph/tmp/under80_20260912/apron_local_bound_test.py'],
 ['luac','-p',candidate],
 ['lua','_ralph/tmp/under80_20260912/apron_local_raster_test.lua',candidate],
 ['lua','_ralph/tmp/under80_20260912/precision_coordinate_encoding_test.lua',candidate],
 ['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua']]
results=[]
for i,command in enumerate(commands):
    proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=300)
    (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
    results.append(dict(command=command,exit=proc.returncode))
    (out/'results.json').write_text(json.dumps(results,indent=2))
    print(proc.stdout+proc.stderr,end='',flush=True)
assert all(r['exit']==0 for r in results)
print('PASS all5 initial private checks; native oracle and performance still required',flush=True)
