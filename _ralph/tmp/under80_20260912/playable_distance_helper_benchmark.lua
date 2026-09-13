 -- Replay the recorded target operations through the actual production helper.
 -- This is not the whole Playable loop: unchanged weighting/RNG work is excluded.
 local function benchmark(scope,cached)
  local api=scope.api;local started=ticks()
  local place=clone(scope.initial_place);local bounds=clone(scope.frozen_bounds)
  if not place or not bounds then return end
  local owner={};for name,fn in pairs(api)do owner[name]=fn end
  owner.GridOpFree=function(g)
   if g and not owned[g]then error('replay tried to free non-replay input');return end
   local out=pack(api.GridOpFree(g));if g then owned[g]=nil end
   return unpack_values(out,1,out.n)
  end
  local originals={};for name,fn in pairs(owner)do originals[name]=fn end
  local class={ProcStart=function()end,ProcEnd=function()end};local generator={}
  local saved_start,saved_end=class.ProcStart,class.ProcEnd
  local close,helper
  if cached then
   local read,write=replay_support.bridge(owner)
   close,helper=replay_support.install(generator,class,read,write)
   if not helper.installed or helper.failure then if close then close()end;fail('replay helper install');return end
  end
  local primary
  local stats={primary=0,secondary=0,writes=0,primary_frees=0,transforms=0,unions=0,minimums=0,copies=0}
  local ok,why=pcall(function()
   class.ProcStart(generator,'FindPrefabPos_Playable')
   for index,event in ipairs(scope.events)do
    if event.kind=='primary'then
     if primary then error('replay primary lifetime');return end
     primary=own(owner.GridDest(place));if not primary then return end
     owner.GridOr(place,primary,bounds);stats.unions=stats.unions+1
     local out=pack(owner.GridDistanceMars(primary,1,1))
     if out.n~=1 or out[1]~=primary then error('replay primary tuple');return end
     stats.primary=stats.primary+1
    elseif event.kind=='secondary'then
     local dest=own(owner.GridDest(place));if not dest then return end
     local out=pack(owner.GridDistanceMars(place,dest,1,1))
     if out.n~=1 or out[1]~=dest then error('replay secondary tuple');return end
     -- Stock frees this short-lived weighting output with its userdata method.
     free(dest);stats.secondary=stats.secondary+1
    elseif event.kind=='write'then
     owner.GridCircleSet(place,event.value,event.center,event.radius);stats.writes=stats.writes+1
    elseif event.kind=='release_primary'then
     if not primary then error('replay missing primary');return end
     -- Last native release occurs after bounds/place frees. Preserve that order.
     if index~=#scope.events then owner.GridOpFree(primary);primary=nil end
     stats.primary_frees=stats.primary_frees+1
    else error('unknown replay event');return end
   end
   if not primary or scope.events[#scope.events].kind~='release_primary'then error('replay final lifetime');return end
   scope.final_place:copy(place);scope.final_bounds:copy(bounds)
   owner.GridOpFree(bounds);owner.GridOpFree(place);owner.GridOpFree(primary);primary=nil
   class.ProcEnd(generator,'FindPrefabPos_Playable')
  end)
  local closed,close_why=true,nil
  if close then closed,close_why=close()end
  local elapsed=ticks()-started
  if not ok or not closed then fail('complete helper replay: '..tostring(why or close_why));return end
  if class.ProcStart~=saved_start or class.ProcEnd~=saved_end then fail('replay class restoration');return end
  for name,fn in pairs(originals)do if owner[name]~=fn then fail('replay owner restoration');return end end
  if elapsed<0 or not equal(scope,scope.final_place,scope.place_guard,'replay_place')
   or not equal(scope,scope.final_bounds,scope.frozen_bounds,'replay_bounds')then return end
  if cached then
   stats.transforms=helper.transforms+helper.native_primary+helper.native_secondary
   stats.minimums=helper.minimums;stats.copies=helper.copies
   if helper.failure or not helper.restored or helper.live~=0 then fail('replay helper cleanup');return end
  else stats.transforms=stats.primary+stats.secondary end
  return {ms=elapsed,cached=cached,stats=stats,helper=helper}
 end
