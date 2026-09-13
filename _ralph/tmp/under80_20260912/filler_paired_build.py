"""Derive the paired observer with explicit, checked changes to the proven observer."""
from pathlib import Path
import hashlib
import json
root=Path(__file__).resolve().parents[3]
original=(root/'_ralph/runs/under80-20260912/artifacts/filler_eligibility_observer/observer.lua').read_text()
source=original
edits=[]
def replace(old,new,count=1):
 global source
 if source.count(old)!=count:raise RuntimeError('observer anchor '+old)
 source=source.replace(old,new);edits.append(dict(old=old,new=new,count=count))
replace('filler_eligibility_shadow','filler_paired_shadow')
replace('math.floor(16777216/(w*h*4))','math.floor(33554432/(w*h*8))')
replace('row.cache_byte_bound=row.capacity*w*h*4','row.cache_byte_bound=row.capacity*w*h*8')
replace(' local function verify_and(scope,args)', ''' local function verify_mask(scope,args,returned)
  scope.api.GridFill(scope.destination,7)
  local good,why=scope.cache.mask(scope.destination,args[3],args[4],args[5])
  if not good then return fail(why)end
  if not equal(scope,scope.destination,args[2],'live_mask')
   or not equal(scope,scope.source,scope.guard,'actual_mask_source')then return false end
  scope.row.raw_outputs=scope.row.raw_outputs+1
  if returned.n==2 and returned[2]==args[2]then scope.row.mask_destination_returns=scope.row.mask_destination_returns+1 end
  return true
 end
 local function verify_and(scope,args,returned)''')
replace('  scope.api.GridFill(scope.destination,7)\n  local good,why=scope.cache.apply(scope.destination,request.from,request.to,request.scale)',
 '  local good,why=scope.cache.intersect(scope.destination,scope.place)')
replace('  local row=scope.row\n  row.requests', '''  local row=scope.row
  row.eligible_outputs=row.eligible_outputs+1
  if returned.n==2 and returned[2]==args[1]then row.and_destination_returns=row.and_destination_returns+1 end
  row.requests''')
replace('local ok,why=cache.apply(dest,event.from,event.to,event.scale);if not ok then fail(why);return end',
 'local ok,why=cache.mask(dest,event.from,event.to,event.scale);if not ok then fail(why);return end\n     ok,why=cache.intersect(dest,place);if not ok then fail(why);return end')
replace('requests={},unique_keys=0,clears=0,distance_calls=0,',
 'requests={},unique_keys=0,clears=0,distance_calls=0,raw_outputs=0,eligible_outputs=0,mask_destination_returns=0,and_destination_returns=0,')
replace('scope.pending={destination=args[2],from=args[3],to=args[4],scale=args[5]}',
 'scope.pending={destination=args[2],from=args[3],to=args[4],scale=args[5]}\n       verify_mask(scope,args,returned)')
replace('if scope.pending then verify_and(scope,args)','if scope.pending then verify_and(scope,args,returned)')
out=root/'_ralph/runs/under80-20260912/artifacts/filler_paired_observer'
out.mkdir(parents=True,exist_ok=False)
reversed_source=source
for edit in reversed(edits):
 if reversed_source.count(edit['new'])!=edit['count']:raise RuntimeError('reverse anchor')
 reversed_source=reversed_source.replace(edit['new'],edit['old'])
assert reversed_source==original
(out/'observer.lua').write_text(source)
(out/'manifest.json').write_text(json.dumps(dict(base_sha256=hashlib.sha256(original.encode()).hexdigest(),
 observer_sha256=hashlib.sha256(source.encode()).hexdigest(),edits=edits,reverse_exact=True),indent=2))
print('PASS paired observer: '+str(len(edits))+' reversible changes')
