"""Immutable actual-helper replay and literal supported bridge extraction."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=(root/'_ralph/runs/under80-20260912/artifacts/playable_distance_production_observer/observer.lua').read_text()
source=source.replace('return function(ticks,make_cache)','return function(ticks,replay_support)',1)
a=source.index(' local function benchmark(scope,cached)')
b=source.index(' local hook_names=',a)
source=source[:a]+Path(__file__).with_name('playable_distance_helper_benchmark.lua').read_text()+'\n'+source[b:]
anchor='  context={owner=owner,api=api,id=row.id,key=key()};return true'
assert source.count(anchor)==1
source=source.replace(anchor,"  for name,fn in pairs(native_originals)do if type(fn)=='function'then api[name]=fn end end\n"+anchor)
anchor='old_stats=old.stats,new_stats=new.stats}'
assert source.count(anchor)==1
source=source.replace(anchor,'old_stats=old.stats,new_stats=new.stats,helper_stats=new.helper}')
production=(root/'Code/sbm_map_generation.lua').read_text()
a=production.index('local function mark_grid_bridge_read(name)')
b=production.index('local mark_grid_class =',a)
bridge=production[a:b].rstrip()
# Literal production bridge body, executed with only its _G bound to an isolated sandbox.
bridge='return function(owner)\n local _G=setmetatable({}, {__index=owner,__newindex=owner})\n '+bridge+'\n return mark_grid_bridge_read,mark_grid_bridge_write\nend\n'
out=root/'_ralph/runs/under80-20260912/artifacts/playable_distance_helper_replay'
out.mkdir(parents=True,exist_ok=False)
for name,text in [('observer.lua',source),('bridge.lua',bridge)]: (out/name).write_text(text)
(out/'manifest.json').write_text(json.dumps(dict(observer_sha256=hashlib.sha256(source.encode()).hexdigest(),
 bridge_sha256=hashlib.sha256(bridge.encode()).hexdigest(),
 qualification='Target-operation sequence through actual helper, including literal supported bridge on isolated private owner; unchanged weighting/RNG excluded.'),indent=2))
print(out)
