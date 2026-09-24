-- Execute the production finalization block. Owner ruling 2026-09-24: T1 is published
-- after entrance validation; rock seating then runs right after T1, behind the welcome
-- popup when one exists (two presented frames first), else under the loading cover.
-- Readiness is signalled only after seating; every failure fails closed.
local file=assert(io.open('Code/sbm_map_generation.lua','rb'))
local source=file:read('*a');file:close()
local block=assert(source:match('(\t\tif thread_ok and map.SuperBigMapSurfaceStretchDone == true.-)\n\t\tif not thread_ok then'))
for _,welcome in ipairs({true,false}) do
for _,case in ipairs({'success','error','missing','rejected','verification_error','source_cleanup'}) do
 local map={SuperBigMapSurfaceStretchDone=true,SuperBigMapSurfaceFinalGridRebuildPending=true}
 if case=='source_cleanup' then map.SuperBigMapRetainedNativeSourceUnloadFailed='injected cleanup failure' end
 local events,queue={},{}
 local function record(event) events[#events+1]=event end
 local tick=0
 local globals={Maps={},PauseInfiniteLoopDetection=function()end,ResumeInfiniteLoopDetection=function()end,
  GetPreciseTicks=function()tick=tick+1;return tick end,
  WaitNextFrame=function()record('frame')end,
  Pause=function(reason)record('pause:'..reason)end,Resume=function(reason)record('resume:'..reason)end}
 local env=setmetatable({map=map,thread_ok=true,
  cfg_bool=function()return true end,Global=function(name)return globals[name]end,
  SafeCall=function(fn,...)return fn(...)end,yield_protected_call=pcall,
  create_thread=function(fn)queue[#queue+1]=fn end,
  EndSurfaceExpansionLoading=function()record('close')end,
  SignalExpansionReadinessChanged=function()
   assert(map.SuperBigMapSurfaceDecorationCorrectionComplete,'readiness preceded seating')
   record('ready')
  end,
  LoadingFinish=function()record('failure')end,
  SuperBigMap={WelcomePopupPresent=function()return welcome end,
   DecorationValidation={Run=function()record('validate')end},
   DecorationSeating={Run=function()
    assert(map.SuperBigMapSurfacePostPipelineRevalidationComplete and map.SuperBigMapSurfaceT1Ticks,
     'seating did not start after the published T1')
    record('seat')
    if case=='error' then error('injected correction failure')end
    if case=='missing' then return nil end
    if case=='rejected' then return {rejected=1}end
    if case=='verification_error' then return {validation_error='injected failed proof'}end
    return {corrected=17,rejected=0}
   end},GenerationReadiness={RecordSurfaceExpansionFailure=function(_,why)map.failure=why end}},
  TerrainCopy={ValidateSurfacePassageCommitment=function()record('entrances');return true end},
 },{__index=_G})
 local fn=assert(load(block,'production surface finalization','t',env));fn()
 assert(#queue==1 and #events==0,'finalization must be scheduled exactly once under the cover')
 queue[1]()
 assert(#queue==1,'seating escaped into a separate deferred thread')
 local order=table.concat(events,',')
 if case=='source_cleanup' then
  assert(map.failure and not map.SuperBigMapSurfacePostPipelineRevalidationComplete and not order:find('seat'),
   'failed source cleanup advertised T1 or seated rocks: '..order)
 elseif case=='success' then
  local expected=welcome
   and 'close,frame,frame,pause:SuperBigMapSurfaceRockSeating,validate,seat,resume:SuperBigMapSurfaceRockSeating,ready'
   or 'pause:SuperBigMapSurfaceRockSeating,validate,seat,resume:SuperBigMapSurfaceRockSeating,close,ready'
  -- Entrance validation is not recorded without committed passages (empty Maps).
  assert(order==expected,'unexpected post-T1 seating order: '..order)
  assert(map.SuperBigMapSurfacePostPipelineRevalidationComplete and map.SuperBigMapSurfaceDecorationCorrectionComplete
   and not map.failure and map.SuperBigMapSurfaceRockSeatingDoneTicks)
 else
  assert(map.failure and map.SuperBigMapSurfaceDecorationCorrectionComplete~=true and not order:find('ready'),
   'failed seating advertised readiness: '..case)
  assert(order:find('close') and order:find('failure'),'failed seating left the cover in place: '..order)
  assert(order:find('resume:SuperBigMapSurfaceRockSeating'),'failed seating leaked its pause reason')
 end
end
end
print('surface readiness: T1 then post-T1 seating (behind the welcome popup or the cover); failures fail closed')
