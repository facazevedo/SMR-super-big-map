-- Execute the production finalization block to verify that rock seating is part of T1.
local file=assert(io.open('Code/sbm_map_generation.lua','rb'))
local source=file:read('*a');file:close()
local block=assert(source:match('(\t\tif thread_ok and map.SuperBigMapSurfaceStretchDone == true.-)\n\t\tif not thread_ok then'))
for _,case in ipairs({'success','error','missing','rejected','verification_error','source_cleanup','commit_error','entrance_error','late_support_error'}) do
 local map={SuperBigMapSurfaceStretchDone=true,SuperBigMapSurfaceFinalGridRebuildPending=true}
 if case=='source_cleanup' then map.SuperBigMapRetainedNativeSourceUnloadFailed='injected cleanup failure' end
 local events,queue={},{}
 local pending={objects={}};local clearance=function()return true end
 local function record(event) events[#events+1]=event end
 local underground={mapdata={Environment='Underground'},SuperBigMapDesiredWidthTiles=8192,
  SuperBigMapPassageBootstrapComplete=true}
 local globals={Maps={[2]=underground},PauseInfiniteLoopDetection=function()end,ResumeInfiniteLoopDetection=function()end}
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
  Engine={MapDataEnvironment=function(data)return data.Environment end},
  AlignPassagePairsToSharedHex=function(owner,options)
   assert(owner==underground and options.prepare_surface_pad and options.surface_clearance==clearance and map.SuperBigMapSurfaceDecorationCorrectionComplete,
    'entrance coordinates committed before the decorations settled')
   record('commit');return case~='commit_error',{error='injected commitment failure'}
  end,
  SetLoadingPhase=function()end,
  MoveEntranceVisualsToScale=function(owner)
   assert(owner==map and map.SuperBigMapSurfaceDecorationCorrectionComplete,'entrance moved before decoration correction')
   record('entrance')
   if case=='entrance_error' then error('injected entrance failure') end
  end,
  SuperBigMap={DecorationValidation={Run=function()record('validate')end,
   WithCorrectionEvidence=function(owner,layer,fn)return fn(owner)end,
   SurfaceSupportSummary=function()
    assert(events[#events]=='validate','final support was checked before entrance placement')
    record('support');return {unresolved=case=='late_support_error' and 1 or 0}
   end},
   DecorationSeating={Run=function(owner,excluded)
    assert(owner==map and excluded==pending.objects)
    assert(not map.SuperBigMapSurfacePostPipelineRevalidationComplete,'T1 published before seating')
    assert(#events==0,'loading cover closed before seating');record('seat')
    if case=='error' then error('injected correction failure')end
    if case=='missing' then return nil end
    if case=='rejected' then return {rejected=1}end
    if case=='verification_error' then return {validation_error='injected failed proof'}end
    return {corrected=17,rejected=0}
   end},SectorHighlight={EnsureEntranceVisualsReady=function()
    assert(events[#events]=='entrance','badge preceded the final entrance');record('badge')
   end},GenerationReadiness={RecordSurfaceExpansionFailure=function(_,why)map.failure=why end}},
  TerrainCopy={PendingSurfaceEntranceObjects=function()return pending end,
   BuildSurfaceEntranceClearance=function(owner,scene)assert(owner==map and scene==pending);return clearance end,
   ValidateSurfacePassageCommitment=function()return true end},
 },{__index=_G})
 assert(load(block,'production surface finalization','t',env))()
 assert(#queue==1 and #events==0,'finalization must be scheduled exactly once under the cover')
 queue[1]()
 assert(#queue==1,'seating escaped into a separate deferred thread')
 if case=='success' then
  assert(table.concat(events,',')=='seat,commit,entrance,badge,validate,support,close,ready')
  assert(map.SuperBigMapSurfacePostPipelineRevalidationComplete and not map.failure)
 else
  assert(map.failure and not map.SuperBigMapSurfacePostPipelineRevalidationComplete,
   'failed seating advertised T1: '..case)
 end
end
print('surface readiness: seating and proof precede T1; missing/failed/rejected corrections fail closed')
