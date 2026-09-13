local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function serialize(v)
 if type(v)~='table'then return type(v)..':'..tostring(v)end
 local keys={};for k in pairs(v)do keys[#keys+1]=k end
 table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
 local s={};for _,k in ipairs(keys)do s[#s+1]=serialize(k)..'='..serialize(v[k])end
 return '{'..table.concat(s,',')..'}'
end
local production=read('Code/sbm_rock_grounding.lua')
local setup=read('_ralph/tmp/under80_20260912/rock_geometry_census.lua')
local function run(mode,instrument)
 local events={}
 local function event(...)events[#events+1]=serialize(table.pack(...))end
 local ticks=0
 local function point(x,y,z)
  event('point',x,y,z)
  return {x=function()event('point.x',x);return x end,y=function()event('point.y',y);return y end,
   z=function()event('point.z',z);return z end}
 end
 local globals={GetPreciseTicks=function()ticks=ticks+1;return ticks end,point=point,
  const={HeightTileSize=1},EntityData={rock={editor_category='StonesRocksCliffs',entity={material_type='Rock'}}},
  terrain={GetHeight=function(_,p)event('height',p:x(),p:y());return mode=='flat' and 0 or 100 end}}
 local sbm={Config={},Engine={Global=function(name)return globals[name]end},
  ObjectClone={ShouldSkipObject=function()return false end,IsImportantSectorObject=function()return false end,
   ObjectScalesWithTerrain=function()return mode~='ineligible' end},
  GenerationGrids={RebuildFinal=function()
   if mode=='final_error'then error('fixture final')end
   if mode=='final_false'then return false,nil,'failed' end
   return nil,'final',nil
  end}}
 local env=setmetatable({SuperBigMap=sbm},{__index=_G});env._G=env
 assert(load(production,'actual rock module','t',env))()
 local original,final=sbm.RockGrounding.Capture,sbm.GenerationGrids.RebuildFinal
 local harness=setmetatable({ModsLoaded={{env=env}},print=function()end,assert=function()end},{__index=_G})
 harness._G=harness
 harness.AsyncFileToString=function()
  if mode=='missing_source'then return 'missing' end
  if mode=='bad_anchor'then return nil,production:gsub('bounds:minx%(%)','0')end
  return nil,production
 end
 if instrument then assert(load(setup,'census setup','t',harness))()end
 local result=harness.SBM_ROCK_GEOMETRY_CENSUS
 if mode=='missing_source' or mode=='bad_anchor'then
  check(result.status=='fail' and sbm.RockGrounding.Capture==original and sbm.GenerationGrids.RebuildFinal==final,'preflight without hooks')
  return
 end
 if instrument then check(result.status=='ready' and result.joined_cells>0 and result.source_substitutions==15,'actual source installed')end
 local map={mapdata={Environment='Surface'},GetMapSize=function()return 100,100 end}
 sbm.RockGrounding.BeginCapture(map)
 local pos,visual=point(10,10,0),point(10,10,0)
 local bounds={}
 local reads={}
 for _,name in ipairs({'maxz','minz','minx','miny','sizex','sizey'})do
  bounds[name]=function()
   reads[name]=(reads[name] or 0)+1
   if mode=='getter_error' and name=='minz'then error('fixture getter')end
   local value=(name=='minz' and -5 or 10)
   if mode=='short' and name=='maxz'then value=0 end
   if mode=='changed_value' and name=='sizey'then value=value+reads[name] end
   if mode=='subtype' and name=='sizey' and reads[name]>1 then value=value+0.0 end
   if mode=='rebound_method' and name=='miny'then
    bounds[name]=function()event('bounds.'..name,value);return value end
   end
   event('bounds.'..name,value)
   if mode=='nil_tuple' and name=='miny'then return value,nil,'tail' end
   return value
  end
 end
 local obj={}
 function obj:GetParent()event('parent');return false end
 function obj:GetEntity()event('entity');return 'rock' end
 function obj:GetPos()event('pos');return pos end
 function obj:GetVisualPos()event('visual');return visual end
 function obj:IsValidZ()event('validz');return mode~='invalid_z' end
 function obj:GetObjectBBox()event('bbox');return bounds end
 function obj:GetScale()event('scale');return 100 end
 function obj:GetAngle()event('angle');return 0 end
 function obj:GetAxis()event('axis');return 1 end
 function obj:IntersectSegment(a,b)
  event('ray',a:x(),a:y(),a:z(),b:x(),b:y(),b:z())
  if mode=='no_hit'then return false end
  return point(a:x(),a:y(),10)
 end
 local values=table.pack(pcall(sbm.RockGrounding.Capture,map,obj,sbm.ObjectClone.ShouldSkipObject,sbm.ObjectClone.IsImportantSectorObject))
 if mode=='getter_error'then
  check(not values[1],'getter throws')
  if instrument then check(result.status=='fail' and result.restored,'getter failure cleanup')end
 else check(values.n==1 and values[1],mode..' zero Capture return values: '..tostring(values[2]))end
 local record
 for i=1,100 do
  local name,value=debug.getupvalue(original,i)
  if name=='captures'then record=value[map].objects[obj]end
 end
 local replacement=function()end
 if mode=='rebound'then sbm.RockGrounding.Capture=replacement end
 local returned=table.pack(pcall(sbm.GenerationGrids.RebuildFinal,map,'post-pipeline scheduled revalidation'))
 if mode=='final_error'then check(not returned[1],'final error propagation')
 elseif mode=='final_false'then check(returned.n==4 and returned[2]==false and returned[4]=='failed','false final tuple')
 else check(returned.n==4 and returned[2]==nil and returned[3]=='final' and returned[4]==nil,'nil final tuple')end
 if instrument then
  if mode=='rebound'then check(result.status=='fail' and sbm.RockGrounding.Capture==replacement,'preserve unrelated rebound')
  elseif mode=='getter_error' or mode=='final_error' or mode=='final_false'then check(result.status=='fail' and result.restored,'failure latched')
  else check(result.status=='pass' and result.restored and result.config_unchanged,'normal restoration')end
  check(sbm.GenerationGrids.RebuildFinal==final,'final restored')
  check((result.peak_roles or 0)<=9,'bounded role history')
  if mode=='changed_value' or mode=='subtype'then check(result.calls[1].reads['bounds.sizey'].changed_value>0,'value/subtype changes detected')end
  if mode=='rebound_method'then check(result.calls[1].reads['bounds.miny'].changed_method>0,'method changes detected')end
  if mode=='normal'then
   check(result.calls[1].reads['bounds.miny'].calls==9 and result.calls[1].reads['bounds.miny'].repeated==8,'loop census')
   for _,row in pairs(result.calls[1].reads)do check(row.changed_value==0 and row.changed_receiver==0 and row.changed_method==0,'stable read census')end
  end
 end
 local stats=map.SuperBigMapRockGroundingStats
 return serialize(events),serialize(record),serialize(stats)
end
for _,mode in ipairs({'normal','flat','short','ineligible','invalid_z','no_hit','changed_value','subtype','rebound_method','nil_tuple',
 'getter_error','final_error','final_false','rebound'})do
 local a,b,c=run(mode,false)
 local x,y,z=run(mode,true)
 check(a==x,mode..' complete ordered original calls')
 check(b==y,mode..' exact private contact record')
 check(c==z,mode..' exact capture counters')
end
run('missing_source',true);run('bad_anchor',true)
print('PASS '..checks..' actual-source geometry census checks')
