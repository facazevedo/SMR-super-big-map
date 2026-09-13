"""Replay all83 accepted commands plus5 actual production offer/model checks."""
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
commands=json.loads((root/'_ralph/runs/under80-20260912/artifacts/v987_signed_copy_model_offline/all_results.json').read_text())
assert len(commands)==83
for name,script in [('crease_offer_grid','crease_offer_test.lua'),('crease_offer_collect','crease_offer_collect_test.lua'),
                    ('crease_offer_failure','crease_offer_failure_test.lua'),('crease_offer_source','crease_offer_source_test.lua')]:
    commands.append(dict(name=name,command=['lua','_ralph/tmp/under80_20260912/'+script,'Code/sbm_terrain_copy.lua']))
commands.append(dict(name='signed_copy_model',command=['lua','_ralph/tmp/under80_20260912/native_signed_copy_test.lua']))
results=[]
for row in commands:
    start=time.monotonic()
    proc=subprocess.run(row['command'],cwd=root,capture_output=True,text=True,timeout=300)
    (out/(row['name']+'.log')).write_text(proc.stdout+proc.stderr)
    results.append(dict(name=row['name'],command=row['command'],exit=proc.returncode,seconds=round(time.monotonic()-start,3)))
    (out/'all_results.json').write_text(json.dumps(results,indent=2))
    print(row['name'],proc.returncode,flush=True)
assert hashes()==frozen,'Production changed during offline suite'
(out/'source_hashes.json').write_text(json.dumps(frozen,indent=2))
assert all(row['exit']==0 for row in results),'Regression failed; all outcomes retained'
print('PASS all88 commands; inherited83 plus5 new actual production/model checks',flush=True)
