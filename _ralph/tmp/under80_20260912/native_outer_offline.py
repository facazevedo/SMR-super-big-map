"""Replay every accepted v983 regression plus staged outer-mask tests; no deployment."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

root=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('--name',required=True)
args=parser.parse_args()
out=root/'_ralph/runs/under80-20260912/artifacts'/args.name
out.mkdir(parents=True,exist_ok=False)
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes()
commands=json.loads((root/'_ralph/runs/under80-20260912/artifacts/v983_offline/all_results.json').read_text())
assert len(commands)==80
commands += [
    {'name':'native_outer_embedded','command':['lua','_ralph/tmp/under80_20260912/native_outer_integration_kernel_test.lua','Code/sbm_terrain_copy.lua']},
    {'name':'native_outer_source','command':['lua','_ralph/tmp/under80_20260912/native_outer_source_test.lua']},
    {'name':'native_outer_bounds','command':['python','_ralph/tmp/under80_20260912/native_outer_mask_bound_test.py']},
]
results=[]
for row in commands:
    start=time.monotonic()
    proc=subprocess.run(row['command'],cwd=root,capture_output=True,text=True,timeout=300)
    (out/(row['name']+'.log')).write_text(proc.stdout+proc.stderr)
    results.append({'name':row['name'],'command':row['command'],'exit':proc.returncode,'seconds':round(time.monotonic()-start,3)})
    (out/'all_results.json').write_text(json.dumps(results,indent=2))
    print(row['name'],proc.returncode,flush=True)
assert hashes()==frozen,'Source changed during offline suite'
(out/'source_hashes.json').write_text(json.dumps(frozen,indent=2))
assert all(r['exit']==0 for r in results),'Offline regression failed; all outcomes preserved'
print('PASS all',len(results),'commands; accepted80 plus3 new checks',flush=True)
