-- Native-pair doubles exercise qualification; live C equivalence is separate.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local function baseline(name)
 local f=assert(io.popen('git show 1c75b81:Code/sbm_'..name..'.lua'))
 local s=f:read('*a');assert(f:close());return s
end
local old_engine=baseline('engine')
local old_clone=baseline('object_clone')
local candidate_dir=arg[1] or '_ralph/runs/under80-20260912/artifacts/class_batch_research_4'
local new_engine=read('Code/sbm_engine.lua')
local new_clone=read('Code/sbm_object_clone.lua')
local kinds={'MysteryBase','BlackCubeStockpileBase','BlackCubeMonolithBase','BlackCubeDumpSite',
 'SurfaceUndergroundTunnelMarker','SurfacePassageBase','UndergroundPassageBase',
 'SurfaceUndergroundTunnelSign','SurfacePassageRocks','UndergroundWonder','Building',
 'BuriedWonderMarker','Colonist','ConstructionSite','DroneBase','BaseRover','RocketBase',
 'ResourceStockpileBase','Unit','SurfaceDepositMarker','SubsurfaceDepositMarker',
 'TerrainDepositMarker','Deposit','SubsurfaceAnomaly','SubsurfaceAnomalyMarker','EffectDepositMarker'}
local checks=0
local function same(a,b)
 checks=checks+1;assert(type(a)==type(b),'return type changed')
 if type(a)=='table' then
  for k,v in pairs(a)do same(v,b[k])end
  for k in pairs(b)do assert(a[k]~=nil,'extra field')end
 else assert(a==b,'value changed: '..tostring(a)..'/'..tostring(b))end
end
local function world(engine,clone,mode)
 local events,counts={},{single=0,batch=0}
 local env={SuperBigMap={}};env._G=env;setmetatable(env,{__index=_G})
 local function scalar(obj,kind)
  counts.single=counts.single+1
  if obj.query_error then error('query failure',0) end
  if obj.kinds[kind]==true then return true end
  if mode=='native_nil' then return nil end
  return false
 end
 local function batch(obj,list,...)
  if type(list)~='table' then list={list,...} end
  counts.batch=counts.batch+1
  if mode=='batch_error' then error('batch failure',0) end
  for _,kind in ipairs(list)do if obj.kinds[kind] then return true end end
  if mode=='native_nil' then return nil end
  return false
 end
 env.IsKindOf=scalar;env.IsKindOfClasses=mode~='missing_batch' and batch or nil
 env.string={};for key,value in pairs(string)do env.string[key]=value end
 env.string.dump=mode~='missing_dump' and function(fn)
  if mode=='inspection_error' then error('inspection failure',0)end
  if fn==pcall or (mode~='lua_pair' and (fn==scalar or fn==batch)) then
   error('fixture native function cannot be dumped',0)
  end
  return string.dump(fn)
 end or nil
 env.IsValid=function(o)events[#events+1]='valid';return o and not o.dead end
 assert(load(engine,'@engine-fixture','t',env))()
 local E=env.SuperBigMap.Engine
 if mode=='custom_engine' then
  E.IsKindOf=function(o,kind)
   counts.single=counts.single+1
   if not o then return nil end
   return o.kinds[kind] and 'custom match' or nil
  end
 end
 if mode=='missing_helper' then E.FirstKindOf=nil end
 assert(load(clone,'@clone-fixture','t',env))()
 if mode=='rebound_single' then
  local function next_scalar(o,kind)return scalar(o,kind)end
  env.IsKindOf=function(o,kind)
   env.IsKindOf=next_scalar;return scalar(o,kind)
  end
 elseif mode=='rebound_batch' then env.IsKindOfClasses=function()error('must not call rebound batch',0)end
 elseif mode=='rebound_safe_call' then
  local original=E.SafeCall
  E.SafeCall=function(fn,...)events[#events+1]='safe';return original(fn,...)end
 elseif mode=='rebound_engine_field' then E.IsKindOf=function()error('captured alias must remain in use',0)end
 elseif mode=='rebound_global_and_single' then
  E.Global=function(name)
   if name=='IsKindOf' then return scalar elseif name=='IsKindOfClasses' then return batch end
   return env[name]
  end
  env.IsKindOf=function(o,kind)return not scalar(o,kind)end
 elseif mode=='missing_single' then env.IsKindOf=nil
 end
 return env.SuperBigMap.ObjectClone,events,counts,env
end
local function object(index,events)
 local obj={class='Rock',kinds={}}
 if index%3==0 then obj.kinds[kinds[(index%#kinds)+1]]=true end
 if index%7==0 then for _,k in ipairs(kinds)do obj.kinds[k]=true end end
 local fields={'entity','template_name','template','name','class'}
 if index%11==0 then obj[fields[(index%#fields)+1]]='SurfaceUndergroundTunnelVariant' end
 if index%13==0 then obj.class='MysteryArtifact' end
 if index%17==0 then obj.class='MapSector' end
 if index%19==0 then obj.SuperBigMapEnrichmentClone=true end
 if index%23==0 then obj.dead=true end
 if index%29==0 then obj.query_error=true end
 if index%31==0 then obj.class=23 end
 function obj:GetPos()events[#events+1]='pos';return 0 end
 function obj:GetEntity()events[#events+1]='entity';if index%37==0 then error('entity failure',0)end;return self.entity end
 function obj:IsKindOf(kind)events[#events+1]='method:'..kind;return self.kinds[kind] end
 function obj:GetParent()events[#events+1]='parent';return self.parent end
 if index%5==0 then
  obj.parent={class='Parent',kinds={SurfacePassageBase=index%10==0,UndergroundWonder=true},
   entity=index%15==0 and 'ElevatorBuildIndicator_UndergroundRocks' or nil}
  obj.parent.GetEntity=obj.GetEntity
 end
 return obj
end
local funcs={'IsMysteryRelatedObject','IsUndergroundAccessObject','IsResourceDepositMarker',
 'ShouldSkipObject','IsImportantSectorObject','ObjectScalesWithTerrain','IsLiveGameObject'}
local function compare(mode)
 local old,a,ac=world(old_engine,old_clone,mode)
 local new,b,bc=world(new_engine,new_clone,mode)
 for index=1,1400 do
  local x,y=object(index,a),object(index,b)
  for _,name in ipairs(funcs)do same(table.pack(old[name](x)),table.pack(new[name](y)))end
 end
 for _,name in ipairs(funcs)do same(table.pack(old[name](nil)),table.pack(new[name](nil)))end
 same(a,b) -- Non-class queries retain their exact order, including live validity guards.
 if mode=='native' or mode=='native_nil' then
  assert(bc.batch>0 and bc.single<ac.single*0.40,'native negative batches did not remove enough queries')
 elseif mode~='batch_error' then assert(bc.batch==0,'unqualified batch used: '..mode)end
 print(mode,'scalar',ac.single,'->',bc.single,'batch',bc.batch)
end
for _,mode in ipairs({'native','native_nil','missing_helper','lua_pair','missing_dump','inspection_error','missing_batch',
 'custom_engine','rebound_single','rebound_batch','rebound_safe_call','rebound_engine_field',
 'missing_single','batch_error','rebound_global_and_single'})do compare(mode)end
print('PASS class-list candidate: '..checks..' exact return/query-order checks')
