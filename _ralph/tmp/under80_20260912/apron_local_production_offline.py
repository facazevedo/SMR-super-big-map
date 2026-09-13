"""Replay83 accepted commands (one extended contract) plus5 actual v991 checks."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/v991_offline'
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
        row['command']=['lua',base+'apron_local_legacy_precision_test.lua']
        adapted+=1
assert adapted==1
commands.extend([
 dict(name='apron_local_proof',command=['python',base+'apron_local_bound_test.py']),
 dict(name='apron_local_source',command=['python',base+'apron_local_production_source_test.py']),
 dict(name='apron_local_oracle',command=['lua',base+'apron_local_oracle_test.lua','Code/sbm_terrain_copy.lua']),
 dict(name='apron_local_failure',command=['lua',base+'apron_local_failure_test.lua','Code/sbm_terrain_copy.lua']),
 dict(name='apron_local_raster',command=['lua',base+'apron_local_raster_test.lua','Code/sbm_terrain_copy.lua'])])
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
print('PASS all88 actual v991 checks',flush=True)
