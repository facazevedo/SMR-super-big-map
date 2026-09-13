"""Reuse reviewed native ownership/comparator helpers; generate private observer."""
from pathlib import Path
import hashlib
import json
root=Path(__file__).resolve().parents[3];base=Path(__file__).parent
source=(base/'filler_mask_observer.lua').read_text()
prefix=source[:source.index(' local function cache_api(scope)')]
prefix=prefix.replace('filler_mask_shadow','filler_eligibility_shadow')
prefix=prefix.replace("result.status='fail';result.issues[#result.issues+1]=tostring(why)",
 "result.status='fail';if #result.issues<32 then result.issues[#result.issues+1]=tostring(why)end")
prefix=prefix.replace('(active and grid==active.source)','(active and (grid==active.source or grid==active.place))')
tail=(base/'filler_eligibility_observer_tail.lua').read_text()
out=root/'_ralph/runs/under80-20260912/artifacts/filler_eligibility_observer'
out.mkdir(parents=True,exist_ok=False)
result=prefix+tail
(out/'observer.lua').write_text(result)
(out/'manifest.json').write_text(json.dumps(dict(base_sha256=hashlib.sha256(source.encode()).hexdigest(),
 observer_sha256=hashlib.sha256(result.encode()).hexdigest(),helper_boundary='local function cache_api(scope)'),indent=2))
print('PASS generated private eligibility observer')
