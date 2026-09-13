local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
for _,candidate in ipairs({false,true})do
 for _,mode in ipairs({'normal','annotation_error','annotation_false','final_error','final_false','rebound','missing_source','bad_qualification'})do
  local ticks,initializations=0,0
  local env=setmetatable({}, {__index=_G});env._G=env
  local sbm={Config={},Engine={Global=function()end},ObjectClone={},GenerationGrids={}}
  env.SuperBigMap=sbm
  assert(load(read('Code/sbm_rock_grounding.lua'),'actual rock module','t',env))()
  local capture=sbm.RockGrounding.Capture
  local function AnnotateDecorRelief(map)
   check((sbm.RockGrounding.Capture~=capture)==candidate,'only annotation sees candidate')
   local tuple=table.pack(sbm.RockGrounding.Capture(map,{}))
   check(tuple.n==0,'actual Capture original private no-context behavior')
   if mode=='annotation_error'then error('annotation error')end
   if mode=='annotation_false'then return false,nil,'failed' end
   return 7,nil,'annotation',nil
  end
  sbm.TerrainCopy={AnnotateDecorRelief=AnnotateDecorRelief}
  local function caller(...)return AnnotateDecorRelief(...)end
  sbm.MapGeneration={RunSurfaceStretchIfEnabled=caller}
  sbm.GenerationGrids.RebuildFinal=function()
   if mode=='final_error'then error('final error')end
   if mode=='final_false'then return false,nil,'failed' end
   return nil,'final',nil
  end
  local final=sbm.GenerationGrids.RebuildFinal
  local harness=setmetatable({ModsLoaded={{env=env}},print=function()end,assert=function()end,
   GetPreciseTicks=function()ticks=ticks+1;return ticks end},{__index=_G});harness._G=harness
  env.fixture_init=function()
   initializations=initializations+1;check(ticks==1,'helper initialized inside first measured annotation')
   return {enabled=mode~='bad_qualification'}
  end
  harness.AsyncFileToString=function(path)
   if mode=='missing_source'then return 'missing' end
   if path:find('rock_geometry_native.lua',1,true)then return nil,'return function() return fixture_init() end' end
   return nil,read(path:gsub('^D:/PROJS/SMR/super%-big%-map/',''))
  end
  local factory=assert(load(read('_ralph/tmp/under80_20260912/rock_geometry_coarse.lua'),'actual coarse setup','t',harness))()
  factory(candidate)
  local result=harness.SBM_ROCK_GEOMETRY_COARSE
  if candidate and mode=='missing_source'then
   check(result.status=='fail' and sbm.RockGrounding.Capture==capture and sbm.GenerationGrids.RebuildFinal==final,'preflight unchanged')
  else
   check(result.status=='ready' and sbm.RockGrounding.Capture==capture and initializations==0,'no setup-time Capture mutation or initialization')
   local map={mapdata={Environment='Surface'}}
   local values=table.pack(pcall(caller,map))
   if mode=='annotation_error'then check(not values[1],'annotation throws')
   elseif mode=='annotation_false' or candidate and mode=='bad_qualification'then check(values[2]==false,'false annotation preserved')
   else check(values.n==5 and values[2]==7 and values[3]==nil and values[4]=='annotation' and values[5]==nil,'annotation nil tuple')end
   check(ticks==2 and result.calls[1].duration_ms==1,'two whole annotation clocks')
   check(sbm.RockGrounding.Capture==capture,'Capture restored immediately after annotation')
   local replacement=function()end
   if mode=='rebound'then
    for i=1,10 do local name=debug.getupvalue(caller,i);if name=='AnnotateDecorRelief'then debug.setupvalue(caller,i,replacement);break end end
   end
   local returned=table.pack(pcall(sbm.GenerationGrids.RebuildFinal,map,'post-pipeline scheduled revalidation'))
   if mode=='final_error'then check(not returned[1],'final throws')
   elseif mode=='final_false'then check(returned[2]==false and returned[4]=='failed','false final tuple')
   else check(returned.n==4 and returned[2]==nil and returned[3]=='final' and returned[4]==nil,'final nil tuple')end
   local failed=mode=='annotation_error' or mode=='annotation_false' or mode=='final_error' or mode=='final_false' or mode=='rebound' or candidate and mode=='bad_qualification'
   check(result.status==(failed and 'fail' or 'pass'),'terminal diagnostic status')
   check(sbm.GenerationGrids.RebuildFinal==final and result.config_unchanged,'final/config restored')
   check(mode=='rebound' and not result.restored or mode~='rebound' and result.restored,'owned annotation restoration')
   check(initializations==(candidate and 1 or 0),'candidate-only initialization')
  end
 end
end
print('PASS '..checks..' coarse actual-Capture scope/lifecycle/timing checks')
