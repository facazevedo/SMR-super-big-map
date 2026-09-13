"""Private candidate only: complete native proof and timing remain separate gates."""
import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',default='decor_rejection_offline');args=p.parse_args()
out=root/'_ralph/runs/under80-20260912/artifacts'/args.out
out.mkdir(parents=True,exist_ok=False)
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes()
base='_ralph/tmp/under80_20260912/'
art='_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2/'
commands=[['luac','-p',art+'candidate.lua'],['luac','-p',art+'oracle_factory.lua'],
 ['luac','-p',base+'decor_rejection_probe.lua'],['luac','-p',base+'decor_rejection_shadow.lua'],
 ['lua',base+'decor_rejection_test.lua',art],['lua',base+'decor_rejection_probe_test.lua'],
 ['python',base+'decor_rejection_source_test.py'],
 ['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua'],
 ['python','_ralph/tools/deploy.py','audit']]
results=[]
for i,command in enumerate(commands):
 start=time.monotonic();proc=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=300)
 (out/f'{i}.log').write_text(proc.stdout+proc.stderr)
 results.append(dict(command=command,exit=proc.returncode,seconds=round(time.monotonic()-start,3)))
 (out/'results.json').write_text(json.dumps(results,indent=2))
 print(i,proc.returncode,proc.stdout+proc.stderr,flush=True)
assert hashes()==frozen,'Production changed'
(out/'source_hashes.json').write_text(json.dumps(frozen,indent=2))
assert all(r['exit']==0 for r in results),'Failed private prerequisite; preserve evidence'
print('PASS all9 private decor rejection prerequisites')
