"""Freeze all83 accepted checks plus4 actual v990 proof/source/raster checks."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/v990_offline_2'
out.mkdir(parents=True,exist_ok=False)
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes()
commands=json.loads((root/'_ralph/runs/under80-20260912/artifacts/v987_signed_copy_model_offline/all_results.json').read_text())
assert len(commands)==83
base='_ralph/tmp/under80_20260912/'
adapted=0
for row in commands:
    if row['name']=='precision_coordinate':
        assert row['command']==['lua','_ralph/tools/parity/precision_coordinate_test.lua']
        row['command']=['lua',base+'apron_tight_legacy_precision_test.lua']
        adapted+=1
assert adapted==1
commands.extend([
 dict(name='apron_tight_proof',command=['python',base+'apron_tight_bound_test.py']),
 dict(name='apron_tight_source',command=['python',base+'apron_tight_source_test.py']),
 dict(name='apron_tight_polynomial',command=['lua',base+'apron_tight_polynomial_test.lua','Code/sbm_terrain_copy.lua']),
 dict(name='apron_tight_raster',command=['lua','_ralph/runs/under80-20260912/artifacts/apron_tight_research/offline_test.lua','Code/sbm_terrain_copy.lua'])])
results=[]
for row in commands:
    start=time.monotonic()
    proc=subprocess.run(row['command'],cwd=root,capture_output=True,text=True,timeout=300)
    (out/(row['name']+'.log')).write_text(proc.stdout+proc.stderr)
    results.append(dict(name=row['name'],command=row['command'],exit=proc.returncode,seconds=round(time.monotonic()-start,3)))
    (out/'all_results.json').write_text(json.dumps(results,indent=2))
    print(row['name'],proc.returncode,flush=True)
assert hashes()==frozen,'Production changed during suite'
(out/'source_hashes.json').write_text(json.dumps(frozen,indent=2))
assert all(r['exit']==0 for r in results),'Regression failed; all outcomes retained'
print('PASS all87 actual v990 checks',flush=True)
