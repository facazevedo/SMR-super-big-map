"""Observe actual cached outputs using independent original-native oracle APIs."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=(root/'_ralph/runs/under80-20260912/artifacts/playable_distance_observer_v2/observer.lua').read_text()
anchor='  local api={}\n'
assert source.count(anchor)==1
source=source.replace(anchor,"""  local api={}
  -- PRIVATE diagnostic only: unwrap the supported helper's saved native table.
  -- Private oracle calls must never pass through or invalidate production cache.
  local native_originals
  for i=1,200 do
   local name,value=debug.getupvalue(owner.GridDistanceMars,i)
   if not name then break end
   if name=='originals' and type(value)=='table'then native_originals=value;break end
  end
  if not native_originals then return fail('production original API table missing')end
""")
anchor='   api[name]=owner[name]'
assert source.count(anchor)==1
source=source.replace(anchor,"   api[name]=native_originals[name]\n   if type(api[name])~='function'then return fail('production native API missing '..name)end")
out=root/'_ralph/runs/under80-20260912/artifacts/playable_distance_production_observer'
out.mkdir(parents=True,exist_ok=False)
(out/'observer.lua').write_text(source)
(out/'manifest.json').write_text(json.dumps(dict(sha256=hashlib.sha256(source.encode()).hexdigest(),
 qualification='Exact v2 shadow with private oracle calls unwrapped from production wrappers; no production debug usage.'),indent=2))
print(out)
