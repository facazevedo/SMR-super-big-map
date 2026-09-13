"""Retain actual private-v3 offline results before native investigation."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/decor_positive_cell_v3_offline'
out.mkdir(parents=True,exist_ok=False)
base=root/'_ralph/tmp/under80_20260912'
a=(base/'decor_positive_cell_v2.lua').read_text()
b=(base/'decor_positive_cell_v3.lua').read_text()
anchor='        local active ='
assert a[a.index(anchor):]==b[b.index(anchor):],'Post-admission numeric algorithm changed'
commands=[['lua',str(base/'decor_positive_cell_admission_test.lua')],
    ['lua',str(base/'decor_positive_cell_test.lua'),str(base/'decor_positive_cell_v3.lua'),'admitted'],
    ['lua',str(base/'decor_positive_cell_test.lua'),str(base/'decor_positive_cell_v2.lua')],
    ['python',str(base/'decor_positive_cell_bound_test.py')],
    ['luac','-p',str(base/'decor_positive_cell_v3.lua')]]
results=[]
for i,command in enumerate(commands):
    proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=300)
    (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
    results.append(dict(command=command,exit=proc.returncode))
    print(proc.stdout+proc.stderr,end='')
(out/'results.json').write_text(json.dumps(results,indent=2))
assert all(r['exit']==0 for r in results)
print('PASS all5 checks plus literal post-admission algorithm equality')
