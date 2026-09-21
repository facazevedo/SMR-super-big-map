local kept={class='MapSector',notify_thread={live=true}}
local orphan={class='MapSector',notify_thread={live=true}}
local done,deleted={},{}
local current={}
local globals={
 IsValid=function(o)return not o.destroyed end,
 CurrentThread=function()return current end,
 DeleteThread=function(t)deleted[t]=true;t.live=false end,
 DoneObject=function(o)
  assert(not (o.notify_thread and o.notify_thread.live),'sector destroyed with a live notification worker')
  o.destroyed=true;done[#done+1]=o
 end,
}
local map={MapForEach=function(_,_,_,f)f(kept);f(orphan)end}
SuperBigMap={Engine={Global=function(n)return globals[n]end,SafeCall=function(fn,...)local ok,v=pcall(fn,...);if ok then return v end end},
 SectorGrid={ForEachSector=function(_,f)f(kept)end}}
dofile('Code/sbm_sector_exploration.lua')
local prune=SuperBigMap.SectorExploration.PruneOrphanMapSectors
local worker=orphan.notify_thread
local removed=prune({},map)
assert(removed==1 and orphan.destroyed and deleted[worker],'orphan notification must be cancelled before native object destruction')
assert(not kept.destroyed and kept.notify_thread.live and not deleted[kept.notify_thread],'retained sectors keep their workers')
assert(#done==1)
-- A failed cancellation must leave the object alive, not leak a stale callback.
orphan.destroyed=nil;orphan.notify_thread={live=true}
globals.DeleteThread=function()error('cancel failed')end
removed=prune({},map)
assert(removed==0 and not orphan.destroyed and orphan.notify_thread.live,'failed cancellation must not destroy the owner')
-- Never terminate the pruning caller halfway through its own native callback.
globals.DeleteThread=function(t)deleted[t]=true;t.live=false end
orphan.notify_thread=current;current.live=true
removed=prune({},map)
assert(removed==0 and not orphan.destroyed and not deleted[current],'current notification owner must be deferred')
print('sector cleanup: cancel orphan notification before destruction, preserve live owners and fail closed')
