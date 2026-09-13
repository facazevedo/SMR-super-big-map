"""Replay all83 accepted commands unchanged plus actual production cache fixtures."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/v993_offline'
out.mkdir(parents=True,exist_ok=False)
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes()
commands=json.loads((root/'_ralph/runs/under80-20260912/artifacts/v987_signed_copy_model_offline/all_results.json').read_text())
assert len(commands)==83
commands.extend([
 dict(name='filler_paired_production_fixture',command=['lua','_ralph/tmp/under80_20260912/filler_paired_production_test.lua']),
 dict(name='filler_paired_production_source',command=['python','_ralph/tmp/under80_20260912/filler_paired_production_source_test.py'])])
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
print('PASS all85 actual v993 commands',flush=True)


