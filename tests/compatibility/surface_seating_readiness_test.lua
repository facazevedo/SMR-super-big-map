-- Execute the production finalization block to verify that rock seating is part of T1.
local file=assert(io.open('Code/sbm_map_generation.lua','rb'))
local source=file:read('*a');file:close()
local block=assert(source:match('(\t\tif thread_ok and map.SuperBigMapSurfaceStretchDone == true.-)\n\t\tif not thread_ok then'))
for _,case in ipairs({'success','error','missing','rejected','verification_error','source_cleanup'}) do
 local map={SuperBigMapSurfaceStretchDone=true,SuperBigMapSurfaceFinalGridRebuildPending=true}
 if case=='source_cleanup' then map.SuperBigMapRetainedNativeSourceUnloadFailed='injected cleanup failure' end
 local events,queue={},{}
 local function record(event) events[#events+1]=event end
 local globals={Maps={},PauseInfiniteLoopDetection=function()end,ResumeInfiniteLoopDetection=function()end}
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
  SuperBigMap={DecorationValidation={Run=function()record('validate')end},
   DecorationSeating={Run=function()
    assert(not map.SuperBigMapSurfacePostPipelineRevalidationComplete,'T1 published before seating')
    assert(#events==1,'loading cover closed before seating');record('seat')
    if case=='error' then error('injected correction failure')end
    if case=='missing' then return nil end
    if case=='rejected' then return {rejected=1}end
    if case=='verification_error' then return {validation_error='injected failed proof'}end
    return {corrected=17,rejected=0}
   end},GenerationReadiness={RecordSurfaceExpansionFailure=function(_,why)map.failure=why end}},
  TerrainCopy={ValidateSurfacePassageCommitment=function()return true end},
 },{__index=_G})
 assert(load(block,'production surface finalization','t',env))()
 assert(#queue==1 and #events==0,'finalization must be scheduled exactly once under the cover')
 queue[1]()
 assert(#queue==1,'seating escaped into a separate deferred thread')
 if case=='success' then
  assert(table.concat(events,',')=='validate,seat,close,ready')
  assert(map.SuperBigMapSurfacePostPipelineRevalidationComplete and not map.failure)
 else
  assert(map.failure and not map.SuperBigMapSurfacePostPipelineRevalidationComplete,
   'failed seating advertised T1: '..case)
 end
end
print('surface readiness: seating and proof precede T1; missing/failed/rejected corrections fail closed')
